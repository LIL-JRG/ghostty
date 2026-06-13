//! The Win32 application runtime for Ghostty.
//!
//! Owns the Win32 message loop and a hidden message-only window used to
//! wake the loop from other threads (core mailbox pushes call wakeup()
//! which posts WM_APP_TICK; the handler drains the core app mailbox).
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const internal_os = @import("../../os/main.zig");
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");

const winapi = @import("winapi.zig");
const Surface = @import("Surface.zig");
const TabBar = @import("TabBar.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32_app);

const msg_class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyMessage");

core_app: *CoreApp,

/// The configuration. Loaded at startup; owned by this struct.
config: configpkg.Config,

/// Our module instance.
instance: winapi.HINSTANCE,

/// Hidden message-only window for cross-thread wakeups.
msg_hwnd: winapi.HWND,

/// All open top-level windows.
windows: std.ArrayList(*Window) = .empty,

/// Chrome colors resolved for the current system light/dark theme
/// (the raw config may hold an unresolved conditional theme).
chrome: Chrome,

/// Set when the run loop should exit.
quit_requested: bool = false,

pub const Chrome = struct {
    background: configpkg.Config.Color,
    foreground: configpkg.Config.Color,

    /// Whether the background reads as dark (drives title bar text
    /// color and dark-mode hints).
    pub fn isDark(self: Chrome) bool {
        const bg = self.background;
        const luminance = 0.299 * @as(f32, @floatFromInt(bg.r)) +
            0.587 * @as(f32, @floatFromInt(bg.g)) +
            0.114 * @as(f32, @floatFromInt(bg.b));
        return luminance < 140.0;
    }

    pub fn eql(a: Chrome, b: Chrome) bool {
        return a.background.r == b.background.r and
            a.background.g == b.background.g and
            a.background.b == b.background.b and
            a.foreground.r == b.foreground.r and
            a.foreground.g == b.foreground.g and
            a.foreground.b == b.foreground.b;
    }
};

/// Compute the chrome colors from a config with the given conditional
/// state applied.
fn deriveChrome(
    config: *const configpkg.Config,
    state: configpkg.ConditionalState,
) Chrome {
    var derived_: ?configpkg.Config = config.changeConditionalState(state) catch |err| err: {
        log.warn("error deriving themed config err={}", .{err});
        break :err null;
    };
    defer if (derived_) |*c| c.deinit();
    const c: *const configpkg.Config = if (derived_) |*d| d else config;
    return .{
        .background = c.background,
        .foreground = c.foreground,
    };
}

pub const Options = struct {};

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: Options,
) !void {
    _ = opts;

    const alloc = core_app.alloc;

    // Opt in to per-monitor DPI awareness if available (Win10 1703+).
    // Failure is fine; we just get DPI virtualization.
    _ = winapi.SetProcessDpiAwarenessContext(
        winapi.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
    );

    // Load the configuration.
    var config = configpkg.Config.load(alloc) catch |err| err: {
        log.warn("error loading config err={}", .{err});
        var default = try configpkg.Config.default(alloc);
        errdefer default.deinit();
        break :err default;
    };
    errdefer config.deinit();

    // Resolve the system light/dark scheme before any window or
    // surface exists so conditional themes (light:...,dark:...) pick
    // the right branch everywhere, including window chrome colors.
    core_app.config_conditional_state.theme = switch (systemColorScheme()) {
        .light => .light,
        .dark => .dark,
    };

    const instance: winapi.HINSTANCE = @ptrCast(winapi.GetModuleHandleW(null) orelse
        return error.ModuleHandleFailed);

    const chrome = deriveChrome(&config, core_app.config_conditional_state);

    self.* = .{
        .core_app = core_app,
        .config = config,
        .instance = instance,
        .msg_hwnd = undefined,
        .chrome = chrome,
    };

    // Register the surface window class.
    const surface_class: winapi.WNDCLASSEXW = .{
        .style = winapi.CS_OWNDC,
        .lpfnWndProc = Surface.wndProc,
        .hInstance = instance,
        .hCursor = null, // cursor managed via WM_SETCURSOR
        .lpszClassName = Surface.class_name,
    };
    if (winapi.RegisterClassExW(&surface_class) == 0) {
        log.err("RegisterClassExW(surface) failed err={}", .{winapi.GetLastError()});
        return error.ClassRegistrationFailed;
    }
    errdefer _ = winapi.UnregisterClassW(Surface.class_name, instance);

    // Register the top-level window class. The background brush uses
    // the configured terminal background so split gaps and resize
    // flashes blend with the content. The icon is the Ghostty logo
    // embedded in the executable resources (dist/windows/ghostty.rc).
    const bg = chrome.background;
    const app_icon = winapi.LoadIconW(instance, winapi.makeIntResourceW(1));
    const window_class: winapi.WNDCLASSEXW = .{
        .lpfnWndProc = Window.wndProc,
        .hInstance = instance,
        .hIcon = app_icon,
        .hIconSm = app_icon,
        .hCursor = winapi.LoadCursorW(null, winapi.makeIntResourceW(winapi.IDC_ARROW)),
        .hbrBackground = winapi.CreateSolidBrush(winapi.rgb(bg.r, bg.g, bg.b)),
        .lpszClassName = Window.class_name,
    };
    if (winapi.RegisterClassExW(&window_class) == 0) {
        log.err("RegisterClassExW(window) failed err={}", .{winapi.GetLastError()});
        return error.ClassRegistrationFailed;
    }
    errdefer _ = winapi.UnregisterClassW(Window.class_name, instance);

    // Register the custom tab bar class. It paints itself fully.
    // Double clicks toggle maximize like a title bar.
    const tabbar_class: winapi.WNDCLASSEXW = .{
        .style = winapi.CS_DBLCLKS,
        .lpfnWndProc = TabBar.wndProc,
        .hInstance = instance,
        .hCursor = winapi.LoadCursorW(null, winapi.makeIntResourceW(winapi.IDC_ARROW)),
        .lpszClassName = TabBar.class_name,
    };
    if (winapi.RegisterClassExW(&tabbar_class) == 0) {
        log.err("RegisterClassExW(tabbar) failed err={}", .{winapi.GetLastError()});
        return error.ClassRegistrationFailed;
    }
    errdefer _ = winapi.UnregisterClassW(TabBar.class_name, instance);

    // Register and create the hidden message window.
    const msg_class: winapi.WNDCLASSEXW = .{
        .lpfnWndProc = msgWndProc,
        .hInstance = instance,
        .lpszClassName = msg_class_name,
    };
    if (winapi.RegisterClassExW(&msg_class) == 0) {
        log.err("RegisterClassExW(message) failed err={}", .{winapi.GetLastError()});
        return error.ClassRegistrationFailed;
    }
    errdefer _ = winapi.UnregisterClassW(msg_class_name, instance);

    self.msg_hwnd = winapi.CreateWindowExW(
        0,
        msg_class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("GhosttyMessageWindow"),
        0,
        0,
        0,
        0,
        0,
        winapi.HWND_MESSAGE,
        null,
        instance,
        self,
    ) orelse return error.WindowCreationFailed;
}

pub fn terminate(self: *App) void {
    _ = winapi.DestroyWindow(self.msg_hwnd);
    _ = winapi.UnregisterClassW(Surface.class_name, self.instance);
    _ = winapi.UnregisterClassW(Window.class_name, self.instance);
    _ = winapi.UnregisterClassW(TabBar.class_name, self.instance);
    _ = winapi.UnregisterClassW(msg_class_name, self.instance);
    self.windows.deinit(self.core_app.alloc);
    self.config.deinit();
}

/// The current system color scheme (Windows light/dark apps setting).
pub fn systemColorScheme() apprt.ColorScheme {
    var data: u32 = 1;
    var size: winapi.DWORD = @sizeOf(u32);
    const status = winapi.RegGetValueW(
        winapi.HKEY_CURRENT_USER,
        std.unicode.utf8ToUtf16LeStringLiteral(
            "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        ),
        std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme"),
        winapi.RRF_RT_REG_DWORD,
        null,
        &data,
        &size,
    );
    if (status != 0) return .light;
    return if (data == 0) .dark else .light;
}

/// Read the system color scheme and notify the core. Safe to call
/// repeatedly; the core ignores no-op changes. Window chrome is
/// re-tinted when the resolved colors change.
pub fn syncColorScheme(self: *App) void {
    self.core_app.config_conditional_state.theme = switch (systemColorScheme()) {
        .light => .light,
        .dark => .dark,
    };

    self.core_app.colorSchemeEvent(self, systemColorScheme()) catch |err| {
        log.warn("error syncing color scheme err={}", .{err});
    };

    const chrome = deriveChrome(&self.config, self.core_app.config_conditional_state);
    if (!chrome.eql(self.chrome)) {
        self.chrome = chrome;
        for (self.windows.items) |window| window.updateChrome();
    }
}

/// Reload the configuration. A soft reload re-applies the current
/// config (e.g. so conditional light/dark themes re-resolve); a full
/// reload re-reads the configuration from disk.
fn reloadConfig(self: *App, soft: bool) !void {
    if (soft) {
        try self.core_app.updateConfig(self, &self.config);
        return;
    }

    const alloc = self.core_app.alloc;
    var config = try configpkg.Config.load(alloc);
    errdefer config.deinit();
    try self.core_app.updateConfig(self, &config);
    self.config.deinit();
    self.config = config;
}

/// Run the Win32 message loop until quit.
pub fn run(self: *App) !void {
    // Apply the system light/dark scheme before any surface exists so
    // conditional themes (theme = light:...,dark:...) resolve right.
    self.syncColorScheme();

    // Create the initial window.
    if (self.windows.items.len == 0) {
        const window = try Window.create(self);

        // Test hooks (debug builds) so UI automation can exercise the
        // window without synthesizing keyboard input:
        //   GHOSTTY_TEST_TABS=N opens N tabs at startup.
        //   GHOSTTY_TEST_SPLIT=right|down|left|up splits the surface.
        if (comptime builtin.mode == .Debug) {
            const alloc = self.core_app.alloc;

            tabs: {
                const val = std.process.getEnvVarOwned(alloc, "GHOSTTY_TEST_TABS") catch
                    break :tabs;
                defer alloc.free(val);
                const n = std.fmt.parseInt(usize, val, 10) catch break :tabs;
                for (1..n) |_| _ = window.newTab(.tab) catch break :tabs;
            }

            split: {
                const val = std.process.getEnvVarOwned(alloc, "GHOSTTY_TEST_SPLIT") catch
                    break :split;
                defer alloc.free(val);
                const direction = std.meta.stringToEnum(
                    apprt.action.SplitDirection,
                    val,
                ) orelse break :split;
                const tab = window.activeTab() orelse break :split;
                const surface = tab.active_surface orelse break :split;
                _ = window.newSplit(surface, direction) catch break :split;
            }
        }
    }

    // Drain anything the surface creation queued.
    try self.core_app.tick(self);

    var msg: winapi.MSG = undefined;
    while (true) {
        const result = winapi.GetMessageW(&msg, null, 0, 0);
        if (result == 0) break; // WM_QUIT
        if (result == -1) {
            log.err("GetMessageW failed err={}", .{winapi.GetLastError()});
            return error.MessageLoopFailed;
        }

        _ = winapi.TranslateMessage(&msg);
        _ = winapi.DispatchMessageW(&msg);
    }

    // Tear down any remaining windows. DestroyWindow is synchronous:
    // WM_DESTROY destroys all child surfaces (stopping their renderer
    // and IO threads) and frees the window.
    while (self.windows.items.len > 0) {
        const window = self.windows.items[self.windows.items.len - 1];
        _ = winapi.DestroyWindow(window.hwnd);
    }
}

/// Wake up the event loop from any thread and process core messages.
pub fn wakeup(self: *const App) void {
    _ = winapi.PostMessageW(self.msg_hwnd, winapi.WM_APP_TICK, 0, 0);
}

/// Called by a Window when it was destroyed. If no windows remain and
/// quit was requested, exit the loop.
pub fn windowDestroyed(self: *App) void {
    // When the last top-level window closes, the app quits (standard
    // Windows behavior), whether the close came from a window's X
    // button or an explicit quit.
    if (self.windows.items.len == 0) {
        winapi.PostQuitMessage(0);
    }
}

pub fn keyboardLayout(self: *const App) input.KeyboardLayout {
    _ = self;
    return .unknown;
}

/// Perform an apprt action. Returns true if the action was handled.
pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            self.quit_requested = true;

            // Close all windows; once the last one is gone we post
            // the quit message (windowDestroyed).
            if (self.windows.items.len == 0) {
                winapi.PostQuitMessage(0);
            } else {
                // Iterate over a copy since destruction mutates the list.
                const alloc = self.core_app.alloc;
                const copy = try alloc.dupe(*Window, self.windows.items);
                defer alloc.free(copy);
                for (copy) |window| {
                    _ = winapi.PostMessageW(window.hwnd, winapi.WM_CLOSE, 0, 0);
                }
            }
            return true;
        },

        .new_window => {
            _ = Window.create(self) catch |err| {
                log.err("error creating new window err={}", .{err});
                return false;
            };
            return true;
        },

        .close_window => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                const surface: *Surface = core_surface.rt_surface;
                _ = winapi.PostMessageW(surface.window.hwnd, winapi.WM_CLOSE, 0, 0);
                return true;
            },
        },

        .new_tab => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                const surface: *Surface = core_surface.rt_surface;
                _ = surface.window.newTab(.tab) catch |err| {
                    log.err("error creating new tab err={}", .{err});
                    return false;
                };
                return true;
            },
        },

        .close_tab => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                const surface: *Surface = core_surface.rt_surface;
                const window = surface.window;
                switch (value) {
                    .this => {
                        const tab = window.tabFor(surface) orelse return false;
                        window.closeTab(tab);
                    },
                    // "other"/"right" modes are not supported yet.
                    else => return false,
                }
                return true;
            },
        },

        .goto_tab => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                const surface: *Surface = core_surface.rt_surface;
                surface.window.gotoTab(value);
                return true;
            },
        },

        .new_split => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                const surface: *Surface = core_surface.rt_surface;
                _ = surface.window.newSplit(surface, value) catch |err| {
                    log.err("error creating split err={}", .{err});
                    return false;
                };
                return true;
            },
        },

        .goto_split => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                const surface: *Surface = core_surface.rt_surface;
                surface.window.gotoSplit(surface, value);
                return true;
            },
        },

        .resize_split => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                const surface: *Surface = core_surface.rt_surface;
                surface.window.resizeSplit(surface, value);
                return true;
            },
        },

        .equalize_splits => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                const surface: *Surface = core_surface.rt_surface;
                surface.window.equalizeSplits();
                return true;
            },
        },

        .set_title => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                const surface: *Surface = core_surface.rt_surface;
                surface.setTitle(value.title) catch |err| {
                    log.err("error setting title err={}", .{err});
                    return false;
                };
                return true;
            },
        },

        .mouse_shape => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                const surface: *Surface = core_surface.rt_surface;
                surface.setMouseShape(value);
                return true;
            },
        },

        .mouse_visibility => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                const surface: *Surface = core_surface.rt_surface;
                surface.setMouseVisibility(value == .visible);
                return true;
            },
        },

        .quit_timer => {
            // We quit when the last window closes (typical Windows
            // behavior), so the timer is handled implicitly.
            switch (value) {
                .start => if (self.windows.items.len == 0) {
                    winapi.PostQuitMessage(0);
                },
                .stop => {},
            }
            return true;
        },

        // The renderer thread draws on its own on Windows so a render
        // request doesn't need apprt involvement.
        .render => return true,

        .reload_config => {
            self.reloadConfig(value.soft) catch |err| {
                log.err("error reloading config err={}", .{err});
                return false;
            };
            return true;
        },

        .config_change => return true,

        // Unimplemented actions. Returning false logs at the call site
        // and the core handles the fallback behavior.
        else => {
            log.debug("unimplemented action={}", .{action});
            return false;
        },
    }
}

/// IPC between Ghostty instances; not yet supported on Windows.
pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime ipc_action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(ipc_action),
) !bool {
    return false;
}

/// The window procedure for the hidden message window.
fn msgWndProc(
    hwnd: winapi.HWND,
    msg: winapi.UINT,
    wparam: winapi.WPARAM,
    lparam: winapi.LPARAM,
) callconv(.winapi) winapi.LRESULT {
    if (msg == winapi.WM_NCCREATE) {
        const create: *const winapi.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        _ = winapi.SetWindowLongPtrW(
            hwnd,
            winapi.GWLP_USERDATA,
            @bitCast(@intFromPtr(create.lpCreateParams)),
        );
        return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    if (msg == winapi.WM_APP_TICK) {
        const ptr = winapi.GetWindowLongPtrW(hwnd, winapi.GWLP_USERDATA);
        if (ptr != 0) {
            const self: *App = @ptrFromInt(@as(usize, @bitCast(ptr)));
            self.core_app.tick(self) catch |err| {
                log.err("error ticking app err={}", .{err});
            };
        }
        return 0;
    }

    return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
}
