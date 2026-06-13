//! A Win32 window hosting a single Ghostty terminal surface.
//!
//! The window owns a private DC (CS_OWNDC) and an OpenGL 4.3+ core profile
//! context. The context is created on the main thread but is made current
//! on the renderer thread (see renderer/OpenGL.zig win32 branches); the
//! renderer thread draws and swaps independently of the Win32 message loop.
const Surface = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const internal_os = @import("../../os/main.zig");
const terminal = @import("../../terminal/main.zig");
const CoreSurface = @import("../../Surface.zig");

const App = @import("App.zig");
const Window = @import("Window.zig");
const winapi = @import("winapi.zig");
const keypkg = @import("key.zig");

const log = std.log.scoped(.win32_surface);

/// The window class name, registered by App.
pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttySurface");

app: *App,

/// The window (tab/split host) that owns this surface.
window: *Window,

/// Win32 window state.
hwnd: winapi.HWND,
hdc: winapi.HDC,
hglrc: winapi.HGLRC,

/// The core surface (terminal state, renderer thread, IO thread).
core_surface: CoreSurface,

/// True once core_surface is initialized; window messages that arrive
/// during CreateWindowExW must not touch the core surface.
core_inited: bool = false,

/// True once deinit ran (WM_DESTROY); guards double-deinit.
deinited: bool = false,

/// The last reported cursor position in pixels.
cursor_pos: apprt.CursorPos = .{ .x = -1, .y = -1 },

/// The current title (UTF-8), owned by the app allocator.
title: ?[:0]const u8 = null,

/// Number of currently pressed mouse buttons, to balance SetCapture.
mouse_capture_count: u32 = 0,

/// Whether we requested WM_MOUSELEAVE tracking.
mouse_tracked: bool = false,

/// The cursor to show while the pointer is over our client area.
current_cursor: ?winapi.HCURSOR = null,

/// Whether the mouse cursor is hidden (mouse-hide-while-typing).
cursor_hidden: bool = false,

/// True while an IME composition (e.g. CJK input) is in progress.
ime_composing: bool = false,

pub const Options = struct {
    context: apprt.surface.NewSurfaceContext = .window,
};

pub fn init(self: *Surface, app: *App, window: *Window, opts: Options) !void {
    self.* = .{
        .app = app,
        .window = window,
        .hwnd = undefined,
        .hdc = undefined,
        .hglrc = undefined,
        .core_surface = undefined,
    };

    // Create the surface as a child window of the host window. The
    // WndProc receives our pointer via CREATESTRUCT and stores it in
    // GWLP_USERDATA. The host lays us out and makes us visible.
    const title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    const hwnd = winapi.CreateWindowExW(
        0,
        class_name,
        title,
        winapi.WS_CHILD | winapi.WS_CLIPSIBLINGS,
        0,
        0,
        800,
        600,
        window.hwnd,
        null,
        app.instance,
        self,
    ) orelse {
        log.err("CreateWindowExW failed, err={}", .{winapi.GetLastError()});
        return error.WindowCreationFailed;
    };
    errdefer _ = winapi.DestroyWindow(hwnd);
    self.hwnd = hwnd;

    // Our window class uses CS_OWNDC so this DC is private and persistent;
    // it is valid to use from the renderer thread for SwapBuffers.
    self.hdc = winapi.GetDC(hwnd) orelse return error.DCFailed;

    // Initialize our OpenGL context (created here, made current only on
    // the renderer thread).
    try self.initGlContext();
    errdefer _ = winapi.wglDeleteContext(self.hglrc);

    // Build the surface configuration and initialize the core surface.
    // This spins up the renderer and IO threads.
    var config = try apprt.surface.newConfig(
        app.core_app,
        &app.config,
        opts.context,
    );
    defer config.deinit();

    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    try self.core_surface.init(
        app.core_app.alloc,
        &config,
        app.core_app,
        app,
        self,
    );
    errdefer self.core_surface.deinit();
    self.core_inited = true;
}

pub fn deinit(self: *Surface) void {
    if (self.deinited) return;
    self.deinited = true;

    const alloc = self.app.core_app.alloc;

    if (self.title) |t| alloc.free(t);
    self.title = null;

    // Remove ourselves from the app. This may start the quit timer.
    self.app.core_app.deleteSurface(self);

    // Shut down the core surface (stops renderer + IO threads). This
    // must happen before we destroy the GL context below since the
    // renderer thread uses it.
    if (self.core_inited) {
        self.core_inited = false;
        self.core_surface.deinit();
    }

    _ = winapi.wglDeleteContext(self.hglrc);
    _ = winapi.ReleaseDC(self.hwnd, self.hdc);
}

/// Create the OpenGL context for this window: set a pixel format, create
/// a legacy context to fetch wglCreateContextAttribsARB, then create the
/// real 4.3 core profile context.
fn initGlContext(self: *Surface) !void {
    const pfd: winapi.PIXELFORMATDESCRIPTOR = .{
        .dwFlags = winapi.PFD_DRAW_TO_WINDOW |
            winapi.PFD_SUPPORT_OPENGL |
            winapi.PFD_DOUBLEBUFFER,
        .iPixelType = winapi.PFD_TYPE_RGBA,
        .cColorBits = 32,
        .cAlphaBits = 8,
        .cDepthBits = 0,
        .cStencilBits = 0,
        .iLayerType = winapi.PFD_MAIN_PLANE,
    };

    const format = winapi.ChoosePixelFormat(self.hdc, &pfd);
    if (format == 0) return error.PixelFormatFailed;
    if (winapi.SetPixelFormat(self.hdc, format, &pfd) == 0)
        return error.PixelFormatFailed;

    // Legacy context to bootstrap WGL extensions.
    const legacy = winapi.wglCreateContext(self.hdc) orelse
        return error.GLContextFailed;
    if (winapi.wglMakeCurrent(self.hdc, legacy) == 0) {
        _ = winapi.wglDeleteContext(legacy);
        return error.GLContextFailed;
    }

    const CreateContextAttribsFn = *const fn (
        winapi.HDC,
        ?winapi.HGLRC,
        [*]const c_int,
    ) callconv(.winapi) ?winapi.HGLRC;

    const create_attribs: ?CreateContextAttribsFn = @ptrCast(@alignCast(
        winapi.wglGetProcAddress("wglCreateContextAttribsARB"),
    ));

    const modern: ?winapi.HGLRC = if (create_attribs) |f| modern: {
        const attribs = [_]c_int{
            winapi.WGL_CONTEXT_MAJOR_VERSION_ARB, 4,
            winapi.WGL_CONTEXT_MINOR_VERSION_ARB, 3,
            winapi.WGL_CONTEXT_PROFILE_MASK_ARB,
            winapi.WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            0,
        };
        break :modern f(self.hdc, null, &attribs);
    } else null;

    // Release the legacy context from this thread. The context for the
    // surface must not be current anywhere; the renderer thread will
    // make it current.
    _ = winapi.wglMakeCurrent(null, null);

    if (modern) |ctx| {
        _ = winapi.wglDeleteContext(legacy);
        self.hglrc = ctx;
    } else {
        // No ARB create context: fall back to the legacy context and
        // hope it exposes 4.3+ (compat profile). glad will verify.
        log.warn("wglCreateContextAttribsARB unavailable, using legacy context", .{});
        self.hglrc = legacy;
    }
}

//-------------------------------------------------------------------
// Renderer thread integration (called via renderer/OpenGL.zig)

/// Make our GL context current on the calling thread (renderer thread).
pub fn makeContextCurrent(self: *Surface) !void {
    if (winapi.wglMakeCurrent(self.hdc, self.hglrc) == 0) {
        log.err("wglMakeCurrent failed, err={}", .{winapi.GetLastError()});
        return error.GLContextFailed;
    }

    // Enable vsync so SwapBuffers paces us to the display.
    const SwapIntervalFn = *const fn (c_int) callconv(.winapi) winapi.BOOL;
    const swap_interval: ?SwapIntervalFn = @ptrCast(@alignCast(
        winapi.wglGetProcAddress("wglSwapIntervalEXT"),
    ));
    if (swap_interval) |f| _ = f(1);
}

/// Clear the current GL context on the calling thread.
pub fn clearContextCurrent() void {
    _ = winapi.wglMakeCurrent(null, null);
}

/// Swap front/back buffers; called by the renderer thread at frame end.
pub fn swapBuffers(self: *Surface) void {
    if (winapi.SwapBuffers(self.hdc) == 0) {
        log.warn("SwapBuffers failed, err={}", .{winapi.GetLastError()});
    }
}

/// The size of the client area in pixels. Safe to call from any thread.
pub fn clientSize(self: *const Surface) apprt.SurfaceSize {
    var rect: winapi.RECT = undefined;
    if (winapi.GetClientRect(self.hwnd, &rect) == 0) {
        return .{ .width = 800, .height = 600 };
    }

    return .{
        .width = @intCast(@max(0, rect.right - rect.left)),
        .height = @intCast(@max(0, rect.bottom - rect.top)),
    };
}

//-------------------------------------------------------------------
// apprt.Surface interface

pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

pub fn rtApp(self: *const Surface) *App {
    return self.app;
}

pub fn close(self: *const Surface, process_alive: bool) void {
    // This may be called from the middle of core surface message
    // processing, so the actual destruction must be deferred: post
    // a close request and handle it on a clean stack.
    _ = winapi.PostMessageW(
        self.hwnd,
        winapi.WM_APP_SURFACE_CLOSE,
        @intFromBool(process_alive),
        0,
    );
}

pub fn shouldClose(self: *const Surface) bool {
    _ = self;
    return false;
}

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    const dpi: f32 = @floatFromInt(winapi.GetDpiForWindow(self.hwnd));
    const scale = @max(1.0, dpi / 96.0);
    return .{ .x = scale, .y = scale };
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    return self.clientSize();
}

pub fn getTitle(self: *Surface) ?[:0]const u8 {
    return self.title;
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    return self.cursor_pos;
}

pub fn supportsClipboard(
    self: *const Surface,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard => true,
        .selection, .primary => false,
    };
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !bool {
    if (clipboard_type != .standard) return false;

    const alloc = self.app.core_app.alloc;
    const text = readClipboardText(alloc, self.hwnd) catch |err| switch (err) {
        error.EmptyClipboard => "",
        else => return err,
    };
    defer if (text.len > 0) alloc.free(text);

    const text_z = try alloc.dupeZ(u8, text);
    defer alloc.free(text_z);

    self.core_surface.completeClipboardRequest(
        state,
        text_z,
        false,
    ) catch |err| switch (err) {
        error.UnsafePaste,
        error.UnauthorizedPaste,
        => {
            // Ask the user for confirmation with a simple message box.
            const result = winapi.MessageBoxW(
                self.hwnd,
                std.unicode.utf8ToUtf16LeStringLiteral(
                    "Pasting this text may be unsafe " ++
                        "(it contains control characters or a newline).\n\n" ++
                        "Paste anyway?",
                ),
                std.unicode.utf8ToUtf16LeStringLiteral("Ghostty - Confirm Paste"),
                0x00000004 | 0x00000030, // MB_YESNO | MB_ICONWARNING
            );
            if (result == 6) { // IDYES
                try self.core_surface.completeClipboardRequest(state, text_z, true);
            }
            return true;
        },

        else => return err,
    };

    return true;
}

pub fn setClipboard(
    self: *const Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    _ = confirm;
    if (clipboard_type != .standard) return;

    // Find a text content to write.
    const text: []const u8 = text: {
        for (contents) |content| {
            if (std.mem.eql(u8, content.mime, "text/plain")) break :text content.data;
        }
        if (contents.len > 0) break :text contents[0].data;
        return;
    };

    try writeClipboardText(self.app.core_app.alloc, self.hwnd, text);
}

pub fn defaultTermioEnv(self: *const Surface) !std.process.EnvMap {
    const alloc = self.app.core_app.alloc;
    return try internal_os.getEnvMap(alloc);
}

pub fn newSurfaceOptions(
    self: *const Surface,
    context: apprt.surface.NewSurfaceContext,
) Options {
    _ = self;
    return .{ .context = context };
}

/// Set the title from an apprt action. The host window reflects it in
/// the tab strip and the window caption.
pub fn setTitle(self: *Surface, title: [:0]const u8) !void {
    const alloc = self.app.core_app.alloc;

    const copy = try alloc.dupeZ(u8, title);
    errdefer alloc.free(copy);
    if (self.title) |t| alloc.free(t);
    self.title = copy;

    self.window.updateTitle(self);
}

/// Set the mouse shape (cursor) from an apprt action.
pub fn setMouseShape(self: *Surface, shape: terminal.MouseShape) void {
    const idc: usize = switch (shape) {
        .default => winapi.IDC_ARROW,
        .text => winapi.IDC_IBEAM,
        .pointer => winapi.IDC_HAND,
        .crosshair => winapi.IDC_CROSS,
        .progress => winapi.IDC_APPSTARTING,
        .wait => winapi.IDC_WAIT,
        .help => winapi.IDC_HELP,
        .not_allowed => winapi.IDC_NO,
        .move => winapi.IDC_SIZEALL,
        .ns_resize, .n_resize, .s_resize => winapi.IDC_SIZENS,
        .ew_resize, .e_resize, .w_resize => winapi.IDC_SIZEWE,
        .nesw_resize, .ne_resize, .sw_resize => winapi.IDC_SIZENESW,
        .nwse_resize, .nw_resize, .se_resize => winapi.IDC_SIZENWSE,
        else => winapi.IDC_ARROW,
    };

    self.current_cursor = winapi.LoadCursorW(null, winapi.makeIntResourceW(idc));

    // If the cursor is currently inside our client area, apply now.
    _ = winapi.SetCursor(self.current_cursor);
}

pub fn setMouseVisibility(self: *Surface, visible: bool) void {
    if (self.cursor_hidden == !visible) return;
    self.cursor_hidden = !visible;
    _ = winapi.ShowCursor(if (visible) 1 else 0);
}

//-------------------------------------------------------------------
// Window procedure

pub fn wndProc(
    hwnd: winapi.HWND,
    msg: winapi.UINT,
    wparam: winapi.WPARAM,
    lparam: winapi.LPARAM,
) callconv(.winapi) winapi.LRESULT {
    // WM_NCCREATE delivers our *Surface pointer.
    if (msg == winapi.WM_NCCREATE) {
        const create: *const winapi.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        _ = winapi.SetWindowLongPtrW(
            hwnd,
            winapi.GWLP_USERDATA,
            @bitCast(@intFromPtr(create.lpCreateParams)),
        );
        return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const self: *Surface = self: {
        const ptr = winapi.GetWindowLongPtrW(hwnd, winapi.GWLP_USERDATA);
        if (ptr == 0) return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        break :self @ptrFromInt(@as(usize, @bitCast(ptr)));
    };

    return self.handleMessage(hwnd, msg, wparam, lparam);
}

fn handleMessage(
    self: *Surface,
    hwnd: winapi.HWND,
    msg: winapi.UINT,
    wparam: winapi.WPARAM,
    lparam: winapi.LPARAM,
) winapi.LRESULT {
    switch (msg) {
        // A close request for this single surface (pane), posted by
        // close() or sent by the host window. Closing one console is
        // cheap and expected, so it never prompts; multi-terminal
        // confirmation lives at the tab/window level (Window.zig).
        winapi.WM_APP_SURFACE_CLOSE => {
            // The window collapses the split tree and destroys us.
            self.window.closeSurface(self);
            return 0;
        },

        winapi.WM_DESTROY => {
            const app = self.app;
            self.deinit();
            app.core_app.alloc.destroy(self);
            return 0;
        },

        winapi.WM_ERASEBKGND => return 1,

        // Windows invalidated our area (restore from minimize, uncover,
        // etc). The GL content lives in the renderer thread; ask it to
        // re-present, then validate via DefWindowProc.
        winapi.WM_PAINT => {
            if (self.core_inited) {
                self.core_surface.refreshCallback() catch |err| {
                    log.err("error in refresh callback err={}", .{err});
                };
            }
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_SIZE => {
            if (self.core_inited) {
                const width: u32 = winapi.loWord(@bitCast(lparam));
                const height: u32 = winapi.hiWord(@bitCast(lparam));
                self.core_surface.sizeCallback(.{
                    .width = width,
                    .height = height,
                }) catch |err| {
                    log.err("error in size callback err={}", .{err});
                };
            }
            return 0;
        },

        winapi.WM_SETFOCUS, winapi.WM_KILLFOCUS => {
            const focused = msg == winapi.WM_SETFOCUS;
            if (self.core_inited) {
                self.app.core_app.focusEvent(focused);
                self.core_surface.focusCallback(focused) catch |err| {
                    log.err("error in focus callback err={}", .{err});
                };
            }
            if (focused) self.window.surfaceFocused(self);
            return 0;
        },

        winapi.WM_SETCURSOR => {
            // Only override the cursor inside the client area.
            const hit: winapi.LRESULT = @bitCast(@as(usize, winapi.loWord(@bitCast(lparam))));
            if (hit == winapi.HTCLIENT) {
                _ = winapi.SetCursor(self.current_cursor orelse
                    winapi.LoadCursorW(null, winapi.makeIntResourceW(winapi.IDC_IBEAM)));
                return 1;
            }
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_KEYDOWN,
        winapi.WM_SYSKEYDOWN,
        winapi.WM_KEYUP,
        winapi.WM_SYSKEYUP,
        => return self.handleKey(hwnd, msg, wparam, lparam),

        winapi.WM_IME_SETCONTEXT => {
            // Suppress the IME's own composition window: we render the
            // preedit inline in the terminal. The candidate list window
            // is unaffected.
            const cleared = @as(usize, @bitCast(lparam)) &
                ~winapi.ISC_SHOWUICOMPOSITIONWINDOW;
            return winapi.DefWindowProcW(hwnd, msg, wparam, @bitCast(cleared));
        },

        winapi.WM_IME_STARTCOMPOSITION => {
            self.ime_composing = true;
            self.updateImePosition();
            return 0;
        },

        winapi.WM_IME_COMPOSITION => {
            self.handleImeComposition(@bitCast(lparam));
            return 0;
        },

        winapi.WM_IME_ENDCOMPOSITION => {
            self.ime_composing = false;
            if (self.core_inited) self.core_surface.preeditCallback(null) catch |err| {
                log.err("error in preedit callback err={}", .{err});
            };
            return 0;
        },

        // We consume composition results ourselves; swallow these to
        // avoid double input.
        winapi.WM_IME_CHAR => return 0,

        winapi.WM_MOUSEMOVE => {
            if (!self.core_inited) return 0;

            // Request a WM_MOUSELEAVE when the mouse leaves the window.
            if (!self.mouse_tracked) {
                var tme: winapi.TRACKMOUSEEVENT = .{
                    .dwFlags = winapi.TME_LEAVE,
                    .hwndTrack = hwnd,
                };
                if (winapi.TrackMouseEvent(&tme) != 0) self.mouse_tracked = true;
            }

            const x: f64 = @floatFromInt(winapi.getXLParam(lparam));
            const y: f64 = @floatFromInt(winapi.getYLParam(lparam));
            self.cursor_pos = .{ .x = @floatCast(x), .y = @floatCast(y) };
            self.core_surface.cursorPosCallback(self.cursor_pos, keypkg.mods()) catch |err| {
                log.err("error in cursor pos callback err={}", .{err});
            };
            return 0;
        },

        winapi.WM_MOUSELEAVE => {
            self.mouse_tracked = false;
            if (self.core_inited) {
                self.cursor_pos = .{ .x = -1, .y = -1 };
                self.core_surface.cursorPosCallback(self.cursor_pos, keypkg.mods()) catch |err| {
                    log.err("error in cursor pos callback err={}", .{err});
                };
            }
            return 0;
        },

        winapi.WM_LBUTTONDOWN => return self.handleMouseButton(.press, .left),
        winapi.WM_LBUTTONUP => return self.handleMouseButton(.release, .left),
        winapi.WM_RBUTTONDOWN => return self.handleMouseButton(.press, .right),
        winapi.WM_RBUTTONUP => return self.handleMouseButton(.release, .right),
        winapi.WM_MBUTTONDOWN => return self.handleMouseButton(.press, .middle),
        winapi.WM_MBUTTONUP => return self.handleMouseButton(.release, .middle),

        winapi.WM_MOUSEWHEEL => {
            if (!self.core_inited) return 0;
            const delta: f64 = @floatFromInt(@as(i16, @bitCast(winapi.hiWord(wparam))));
            self.core_surface.scrollCallback(
                0,
                delta / @as(f64, winapi.WHEEL_DELTA),
                .{},
            ) catch |err| {
                log.err("error in scroll callback err={}", .{err});
            };
            return 0;
        },

        winapi.WM_MOUSEHWHEEL => {
            if (!self.core_inited) return 0;
            const delta: f64 = @floatFromInt(@as(i16, @bitCast(winapi.hiWord(wparam))));
            self.core_surface.scrollCallback(
                -delta / @as(f64, winapi.WHEEL_DELTA),
                0,
                .{},
            ) catch |err| {
                log.err("error in scroll callback err={}", .{err});
            };
            return 0;
        },

        else => return winapi.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn handleMouseButton(
    self: *Surface,
    action: input.MouseButtonState,
    button: input.MouseButton,
) winapi.LRESULT {
    if (!self.core_inited) return 0;

    // Capture the mouse while any button is held so drag-selection
    // continues outside the window. Clicking also focuses the surface
    // (focus-follows-click between splits).
    switch (action) {
        .press => {
            _ = winapi.SetFocus(self.hwnd);
            if (self.mouse_capture_count == 0) _ = winapi.SetCapture(self.hwnd);
            self.mouse_capture_count += 1;
        },
        .release => {
            if (self.mouse_capture_count > 0) {
                self.mouse_capture_count -= 1;
                if (self.mouse_capture_count == 0) _ = winapi.ReleaseCapture();
            }
        },
    }

    _ = self.core_surface.mouseButtonCallback(
        action,
        button,
        keypkg.mods(),
    ) catch |err| {
        log.err("error in mouse button callback err={}", .{err});
    };

    return 0;
}

/// Handle a key down/up message. Returns the LRESULT for the message.
///
/// Text is obtained by removing the WM_(SYS)CHAR/WM_(SYS)DEADCHAR messages
/// that TranslateMessage already posted for this keystroke. This keeps
/// dead-key composition (´ + a = á) working through the OS keyboard layout
/// while still delivering text together with the key event, which is what
/// the core expects.
fn handleKey(
    self: *Surface,
    hwnd: winapi.HWND,
    msg: winapi.UINT,
    wparam: winapi.WPARAM,
    lparam: winapi.LPARAM,
) winapi.LRESULT {
    // While the IME is composing, keystrokes belong to the IME (they
    // arrive as VK_PROCESSKEY); the result reaches us via WM_IME_*.
    if (wparam == winapi.VK_PROCESSKEY) return 0;

    const is_down = msg == winapi.WM_KEYDOWN or msg == winapi.WM_SYSKEYDOWN;
    const is_sys = msg == winapi.WM_SYSKEYDOWN or msg == winapi.WM_SYSKEYUP;

    const lparam_bits: usize = @bitCast(lparam);
    const was_down = (lparam_bits & (1 << 30)) != 0;

    const action: input.Action = if (!is_down)
        .release
    else if (was_down)
        .repeat
    else
        .press;

    // Physical key from the scancode.
    const native = keypkg.nativeFromLParam(wparam, lparam);
    const physical_key = keypkg.keyFromScancode(native);

    // Collect any character messages that TranslateMessage posted for
    // this keystroke.
    var utf16_buf: [8]u16 = undefined;
    var utf16_len: usize = 0;
    var composing = false;

    if (is_down) {
        const first: winapi.UINT = if (is_sys) winapi.WM_SYSCHAR else winapi.WM_CHAR;
        const last: winapi.UINT = if (is_sys) winapi.WM_SYSDEADCHAR else winapi.WM_DEADCHAR;

        var char_msg: winapi.MSG = undefined;
        while (winapi.PeekMessageW(
            &char_msg,
            hwnd,
            first,
            last,
            winapi.PM_REMOVE,
        ) != 0) {
            if (char_msg.message == winapi.WM_DEADCHAR or
                char_msg.message == winapi.WM_SYSDEADCHAR)
            {
                composing = true;
                continue;
            }

            if (utf16_len < utf16_buf.len) {
                utf16_buf[utf16_len] = @truncate(char_msg.wParam);
                utf16_len += 1;
            }
        }
    }

    // Convert UTF-16 to UTF-8, filtering control characters: the core
    // encodes those from the key + mods itself (e.g. ctrl+c).
    var utf8_buf: [16]u8 = undefined;
    const utf8: []const u8 = utf8: {
        if (utf16_len == 0) break :utf8 "";
        const len = std.unicode.utf16LeToUtf8(
            &utf8_buf,
            utf16_buf[0..utf16_len],
        ) catch break :utf8 "";
        const result = utf8_buf[0..len];
        if (result.len == 1 and (result[0] < 0x20 or result[0] == 0x7F))
            break :utf8 "";
        break :utf8 result;
    };

    const mods = keypkg.mods();

    // Compute consumed mods: if this key produced text, shift was
    // consumed producing it, and so was AltGr (ctrl+alt on Windows).
    var consumed_mods: input.Mods = .{};
    if (utf8.len > 0) {
        if (mods.shift) consumed_mods.shift = true;
        if (mods.ctrl and mods.alt) {
            consumed_mods.ctrl = true;
            consumed_mods.alt = true;
        }
    }

    const event: input.KeyEvent = .{
        .action = action,
        .key = physical_key,
        .mods = mods,
        .consumed_mods = consumed_mods,
        .composing = composing,
        .utf8 = utf8,
        .unshifted_codepoint = keypkg.unshiftedCodepoint(@intCast(wparam)),
    };

    if (!self.core_inited) return 0;

    const effect = self.core_surface.keyCallback(event) catch |err| {
        log.err("error in key callback err={}", .{err});
        return 0;
    };

    switch (effect) {
        .closed, .consumed => return 0,
        .ignored => {},
    }

    // Not consumed: let DefWindowProc handle system keys (Alt+F4,
    // Alt+Space system menu, etc).
    if (is_sys) return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
    return 0;
}

//-------------------------------------------------------------------
// IME helpers

/// Handle WM_IME_COMPOSITION: deliver committed text to the terminal
/// and composing (preedit) text to the renderer.
fn handleImeComposition(self: *Surface, lparam_bits: usize) void {
    if (!self.core_inited) return;

    const himc = winapi.ImmGetContext(self.hwnd) orelse return;
    defer _ = winapi.ImmReleaseContext(self.hwnd, himc);

    const alloc = self.app.core_app.alloc;

    // Committed text: send to the terminal and clear the preedit.
    if (lparam_bits & winapi.GCS_RESULTSTR != 0) {
        if (getCompositionString(alloc, himc, winapi.GCS_RESULTSTR)) |text| {
            defer alloc.free(text);

            self.core_surface.preeditCallback(null) catch |err| {
                log.err("error in preedit callback err={}", .{err});
            };
            if (text.len > 0) {
                _ = self.core_surface.textCallback(text) catch |err| {
                    log.err("error in text callback err={}", .{err});
                };
            }
        }
    }

    // In-progress composition: show as preedit.
    if (lparam_bits & winapi.GCS_COMPSTR != 0) {
        if (getCompositionString(alloc, himc, winapi.GCS_COMPSTR)) |text| {
            defer alloc.free(text);

            self.core_surface.preeditCallback(
                if (text.len > 0) text else null,
            ) catch |err| {
                log.err("error in preedit callback err={}", .{err});
            };
        }

        self.updateImePosition();
    }
}

/// Read a composition string (GCS_COMPSTR or GCS_RESULTSTR) as UTF-8.
/// Returns null when the string is unavailable.
fn getCompositionString(
    alloc: Allocator,
    himc: winapi.HIMC,
    kind: winapi.DWORD,
) ?[]const u8 {
    const byte_len = winapi.ImmGetCompositionStringW(himc, kind, null, 0);
    if (byte_len <= 0) return null;

    const units = @divTrunc(@as(usize, @intCast(byte_len)), 2);
    const buf = alloc.alloc(u16, units) catch return null;
    defer alloc.free(buf);

    const read = winapi.ImmGetCompositionStringW(
        himc,
        kind,
        buf.ptr,
        @intCast(byte_len),
    );
    if (read <= 0) return null;

    return std.unicode.utf16LeToUtf8Alloc(
        alloc,
        buf[0..@divTrunc(@as(usize, @intCast(read)), 2)],
    ) catch null;
}

/// Position the IME candidate window near the terminal cursor.
fn updateImePosition(self: *Surface) void {
    if (!self.core_inited) return;

    const himc = winapi.ImmGetContext(self.hwnd) orelse return;
    defer _ = winapi.ImmReleaseContext(self.hwnd, himc);

    // imePoint returns unscaled coordinates; convert back to pixels.
    const pos = self.core_surface.imePoint();
    const scale = self.getContentScale() catch apprt.ContentScale{ .x = 1, .y = 1 };
    const pt: winapi.POINT = .{
        .x = @intFromFloat(@max(0, pos.x * scale.x)),
        .y = @intFromFloat(@max(0, pos.y * scale.y)),
    };

    var comp_form: winapi.COMPOSITIONFORM = .{
        .dwStyle = winapi.CFS_POINT,
        .ptCurrentPos = pt,
        .rcArea = std.mem.zeroes(winapi.RECT),
    };
    _ = winapi.ImmSetCompositionWindow(himc, &comp_form);

    var cand_form: winapi.CANDIDATEFORM = .{
        .dwIndex = 0,
        .dwStyle = winapi.CFS_CANDIDATEPOS,
        .ptCurrentPos = pt,
        .rcArea = std.mem.zeroes(winapi.RECT),
    };
    _ = winapi.ImmSetCandidateWindow(himc, &cand_form);
}

//-------------------------------------------------------------------
// Clipboard helpers

fn readClipboardText(alloc: Allocator, hwnd: winapi.HWND) ![]const u8 {
    if (winapi.IsClipboardFormatAvailable(winapi.CF_UNICODETEXT) == 0)
        return error.EmptyClipboard;
    if (winapi.OpenClipboard(hwnd) == 0) return error.ClipboardBusy;
    defer _ = winapi.CloseClipboard();

    const handle = winapi.GetClipboardData(winapi.CF_UNICODETEXT) orelse
        return error.EmptyClipboard;
    const ptr: [*:0]const u16 = @ptrCast(@alignCast(
        winapi.GlobalLock(handle) orelse return error.ClipboardBusy,
    ));
    defer _ = winapi.GlobalUnlock(handle);

    const wide = std.mem.sliceTo(ptr, 0);
    return try std.unicode.utf16LeToUtf8Alloc(alloc, wide);
}

fn writeClipboardText(alloc: Allocator, hwnd: winapi.HWND, text: []const u8) !void {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, text);
    defer alloc.free(wide);

    if (winapi.OpenClipboard(hwnd) == 0) return error.ClipboardBusy;
    defer _ = winapi.CloseClipboard();
    _ = winapi.EmptyClipboard();

    const bytes = (wide.len + 1) * @sizeOf(u16);
    const handle = winapi.GlobalAlloc(winapi.GMEM_MOVEABLE, bytes) orelse
        return error.OutOfMemory;

    const dst: [*]u16 = @ptrCast(@alignCast(
        winapi.GlobalLock(handle) orelse {
            _ = winapi.GlobalFree(handle);
            return error.OutOfMemory;
        },
    ));
    @memcpy(dst[0..wide.len], wide);
    dst[wide.len] = 0;
    _ = winapi.GlobalUnlock(handle);

    if (winapi.SetClipboardData(winapi.CF_UNICODETEXT, handle) == null) {
        _ = winapi.GlobalFree(handle);
        return error.ClipboardBusy;
    }
}
