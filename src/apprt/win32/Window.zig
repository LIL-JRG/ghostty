//! A top-level Ghostty window: hosts a native tab strip (comctl32 tab
//! control) and, per tab, a tree of terminal surfaces (splits). Surfaces
//! are WS_CHILD windows laid out inside the content area.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const TabBar = @import("TabBar.zig");
const winapi = @import("winapi.zig");

const log = std.log.scoped(.win32_window);

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");

/// Gap in pixels between splits (scaled by DPI).
const split_gap: i32 = 4;

app: *App,
hwnd: winapi.HWND,

/// The custom tab strip; only visible with more than one tab.
tab_bar: *TabBar,

tabs: std.ArrayList(*Tab) = .empty,
active_tab: usize = 0,

/// Brush for the window background (split gaps, resize flashes).
/// Recreated when the chrome colors change.
bg_brush: ?winapi.HBRUSH = null,

/// True while minimized; the first size/activate after restoring
/// triggers a full chrome + surface refresh (the layered window's
/// backing store is discarded while minimized).
was_minimized: bool = false,

deinited: bool = false,

/// One terminal tab: a tree of surfaces.
pub const Tab = struct {
    window: *Window,
    root: ?Node = null,
    active_surface: ?*Surface = null,

    /// Find the parent split of a leaf along with which side the leaf
    /// is on. Returns null when the leaf is the root or absent.
    fn findParent(self: *Tab, surface: *Surface) ?ParentRef {
        const root = self.root orelse return null;
        return findParentIn(root, surface);
    }

    fn findParentIn(node: Node, surface: *Surface) ?ParentRef {
        switch (node) {
            .leaf => return null,
            .split => |s| {
                if (s.first == .leaf and s.first.leaf == surface)
                    return .{ .split = s, .side = .first };
                if (s.second == .leaf and s.second.leaf == surface)
                    return .{ .split = s, .side = .second };
                if (findParentIn(s.first, surface)) |r| return r;
                if (findParentIn(s.second, surface)) |r| return r;
                return null;
            },
        }
    }

    fn contains(self: *Tab, surface: *Surface) bool {
        const root = self.root orelse return false;
        return containsIn(root, surface);
    }

    fn containsIn(node: Node, surface: *Surface) bool {
        return switch (node) {
            .leaf => |s| s == surface,
            .split => |s| containsIn(s.first, surface) or
                containsIn(s.second, surface),
        };
    }

    const ParentRef = struct {
        split: *Split,
        side: enum { first, second },
    };
};

pub const Node = union(enum) {
    leaf: *Surface,
    split: *Split,
};

pub const Split = struct {
    /// horizontal: children are side by side; vertical: stacked.
    layout: enum { horizontal, vertical },
    /// Share of the first child (0..1).
    ratio: f32 = 0.5,
    first: Node,
    second: Node,
};

pub fn create(app: *App) !*Window {
    const alloc = app.core_app.alloc;
    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);

    self.* = .{
        .app = app,
        .hwnd = undefined,
        .tab_bar = undefined,
    };

    const title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    const hwnd = winapi.CreateWindowExW(
        winapi.WS_EX_APPWINDOW,
        class_name,
        title,
        winapi.WS_OVERLAPPEDWINDOW | winapi.WS_CLIPCHILDREN,
        winapi.CW_USEDEFAULT,
        winapi.CW_USEDEFAULT,
        winapi.CW_USEDEFAULT,
        winapi.CW_USEDEFAULT,
        null,
        null,
        app.instance,
        self,
    ) orelse {
        log.err("CreateWindowExW(window) failed err={}", .{winapi.GetLastError()});
        return error.WindowCreationFailed;
    };
    errdefer _ = winapi.DestroyWindow(hwnd);
    self.hwnd = hwnd;

    // Title bar colors and the window background brush.
    self.applyChrome();

    // Transparency and blur-behind.
    const bg = app.chrome.background;
    const opacity = app.config.@"background-opacity";
    const wants_alpha = opacity < 1.0;
    const wants_blur = switch (app.config.@"background-blur") {
        .false => false,
        .true => true,
        .radius => |r| r > 0,
        // macOS-specific glass styles map to plain blur here.
        .@"macos-glass-regular", .@"macos-glass-clear" => true,
    };

    if (wants_alpha) {
        // Whole-window opacity via a layered window. (Per-pixel GL
        // alpha compositing is unreliable with the DWM, so the alpha
        // applies uniformly like a classic translucent window.)
        const ex = winapi.GetWindowLongPtrW(hwnd, winapi.GWL_EXSTYLE);
        _ = winapi.SetWindowLongPtrW(
            hwnd,
            winapi.GWL_EXSTYLE,
            ex | @as(isize, winapi.WS_EX_LAYERED),
        );
        const alpha: u8 = @intFromFloat(std.math.clamp(opacity, 0.0, 1.0) * 255.0);
        _ = winapi.SetLayeredWindowAttributes(hwnd, 0, alpha, winapi.LWA_ALPHA);
    }

    if (wants_blur) {
        // Acrylic blur behind the window via the compositor accent
        // policy; the tint uses the terminal background color.
        var policy: winapi.ACCENT_POLICY = .{
            .AccentState = winapi.ACCENT_ENABLE_ACRYLICBLURBEHIND,
            .AccentFlags = 2,
            .GradientColor = (@as(u32, 0xCC) << 24) |
                (@as(u32, bg.b) << 16) |
                (@as(u32, bg.g) << 8) |
                @as(u32, bg.r),
            .AnimationId = 0,
        };
        var attrib: winapi.WINDOWCOMPOSITIONATTRIBDATA = .{
            .Attrib = winapi.WCA_ACCENT_POLICY,
            .pvData = &policy,
            .cbData = @sizeOf(winapi.ACCENT_POLICY),
        };
        _ = winapi.SetWindowCompositionAttribute(hwnd, &attrib);
    }

    // The tab strip. Created hidden; shown when there is more than
    // one tab.
    self.tab_bar = try alloc.create(TabBar);
    errdefer alloc.destroy(self.tab_bar);
    try self.tab_bar.init(self);

    try app.windows.append(alloc, self);
    errdefer _ = app.windows.pop();

    // Create the initial tab + surface.
    _ = try self.newTab(.window);

    // Restore the previous window placement if requested, otherwise
    // show with defaults.
    if (!self.restorePlacement()) {
        _ = winapi.ShowWindow(hwnd, winapi.SW_SHOWDEFAULT);
    }
    _ = winapi.UpdateWindow(hwnd);

    return self;
}

/// Apply title bar colors and the background brush from the resolved
/// chrome colors. Called at creation and when the system theme flips.
pub fn applyChrome(self: *Window) void {
    const chrome = self.app.chrome;
    const bg = chrome.background;
    const fg = chrome.foreground;
    const is_dark = chrome.isDark();

    // Immersive dark mode only when the theme is dark; it controls the
    // default caption button/text palette.
    const dark: winapi.BOOL = @intFromBool(is_dark);
    _ = winapi.DwmSetWindowAttribute(
        self.hwnd,
        winapi.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &dark,
        @sizeOf(winapi.BOOL),
    );

    const caption = winapi.rgb(bg.r, bg.g, bg.b);
    _ = winapi.DwmSetWindowAttribute(
        self.hwnd,
        winapi.DWMWA_CAPTION_COLOR,
        &caption,
        @sizeOf(winapi.COLORREF),
    );

    const text = winapi.rgb(fg.r, fg.g, fg.b);
    _ = winapi.DwmSetWindowAttribute(
        self.hwnd,
        winapi.DWMWA_TEXT_COLOR,
        &text,
        @sizeOf(winapi.COLORREF),
    );

    if (self.bg_brush) |brush| _ = winapi.DeleteObject(brush);
    self.bg_brush = winapi.CreateSolidBrush(caption);
}

/// Re-tint everything after a chrome color change (system theme flip).
pub fn updateChrome(self: *Window) void {
    self.applyChrome();
    self.tab_bar.updateColors();
    _ = winapi.InvalidateRect(self.hwnd, null, 1);
}

/// Toggle maximize/restore (double click on the tab bar).
pub fn toggleMaximize(self: *Window) void {
    _ = winapi.ShowWindow(
        self.hwnd,
        if (winapi.IsZoomed(self.hwnd) != 0)
            winapi.SW_RESTORE
        else
            winapi.SW_MAXIMIZE,
    );
}

//-------------------------------------------------------------------
// Window placement persistence (window-save-state)

fn placementPath(alloc: std.mem.Allocator) ?[]const u8 {
    const base = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(base);
    return std.fs.path.join(alloc, &.{ base, "ghostty", "window-placement" }) catch null;
}

fn savePlacement(self: *Window) void {
    if (self.app.config.@"window-save-state" != .always) return;

    const alloc = self.app.core_app.alloc;
    const path = placementPath(alloc) orelse return;
    defer alloc.free(path);

    var placement: winapi.WINDOWPLACEMENT = .{};
    if (winapi.GetWindowPlacement(self.hwnd, &placement) == 0) return;

    const file = std.fs.createFileAbsolute(path, .{}) catch return;
    defer file.close();
    file.writeAll(std.mem.asBytes(&placement)) catch {};
}

/// Restore the saved window placement. Returns true when the window
/// was shown by the restore.
fn restorePlacement(self: *Window) bool {
    if (self.app.config.@"window-save-state" != .always) return false;

    const alloc = self.app.core_app.alloc;
    const path = placementPath(alloc) orelse return false;
    defer alloc.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();

    var placement: winapi.WINDOWPLACEMENT = .{};
    const n = file.readAll(std.mem.asBytes(&placement)) catch return false;
    if (n != @sizeOf(winapi.WINDOWPLACEMENT)) return false;
    placement.length = @sizeOf(winapi.WINDOWPLACEMENT);

    // Never restore minimized.
    if (placement.showCmd == 2) placement.showCmd = winapi.SW_SHOW; // SW_SHOWMINIMIZED

    return winapi.SetWindowPlacement(self.hwnd, &placement) != 0;
}

fn deinit(self: *Window) void {
    if (self.deinited) return;
    self.deinited = true;

    const alloc = self.app.core_app.alloc;

    // Destroy all surfaces in all tabs. Surface window destruction
    // frees the surface; the tree nodes are freed here.
    for (self.tabs.items) |tab| {
        if (tab.root) |root| self.destroyNode(root);
        alloc.destroy(tab);
    }
    self.tabs.deinit(alloc);

    // The tab bar child window is destroyed with the parent; we only
    // free the struct.
    alloc.destroy(self.tab_bar);

    if (self.bg_brush) |brush| {
        _ = winapi.DeleteObject(brush);
        self.bg_brush = null;
    }

    // Remove ourselves from the app's window list.
    for (self.app.windows.items, 0..) |w, i| {
        if (w == self) {
            _ = self.app.windows.swapRemove(i);
            break;
        }
    }
}

/// Destroy every surface window in a subtree and free split nodes.
/// Used during window teardown only.
fn destroyNode(self: *Window, node: Node) void {
    switch (node) {
        .leaf => |surface| {
            // DestroyWindow synchronously runs WM_DESTROY which
            // deinits and frees the surface.
            _ = winapi.DestroyWindow(surface.hwnd);
        },
        .split => |split| {
            self.destroyNode(split.first);
            self.destroyNode(split.second);
            self.app.core_app.alloc.destroy(split);
        },
    }
}

//-------------------------------------------------------------------
// Tabs

/// Create a new tab with a fresh surface and select it.
pub fn newTab(
    self: *Window,
    context: apprt.surface.NewSurfaceContext,
) !*Surface {
    const alloc = self.app.core_app.alloc;

    const tab = try alloc.create(Tab);
    errdefer alloc.destroy(tab);
    tab.* = .{ .window = self };

    const surface = try self.createSurface(tab, context);
    tab.root = .{ .leaf = surface };
    tab.active_surface = surface;

    try self.tabs.append(alloc, tab);
    errdefer _ = self.tabs.pop();

    self.selectTab(self.tabs.items.len - 1);
    return surface;
}

/// Close a tab: destroys all its surfaces. If it is the last tab the
/// window is closed. Confirms when the tab holds more than one pane so
/// a stray close doesn't wipe out several terminals at once.
pub fn closeTab(self: *Window, tab: *Tab) void {
    const index = for (self.tabs.items, 0..) |t, i| {
        if (t == tab) break i;
    } else return;

    if (!self.confirmClose(tabPaneCount(tab))) return;

    // Last tab closes the window.
    if (self.tabs.items.len == 1) {
        _ = winapi.DestroyWindow(self.hwnd);
        return;
    }

    const alloc = self.app.core_app.alloc;
    if (tab.root) |root| {
        tab.root = null;
        self.destroyNode(root);
    }
    _ = self.tabs.orderedRemove(index);
    alloc.destroy(tab);

    const new_active = @min(
        if (self.active_tab > index) self.active_tab - 1 else self.active_tab,
        self.tabs.items.len - 1,
    );
    self.selectTab(new_active);
}

/// Close a tab by index (used by the tab bar buttons).
pub fn closeTabIndex(self: *Window, index: usize) void {
    if (index >= self.tabs.items.len) return;
    self.closeTab(self.tabs.items[index]);
}

/// Select a tab by index: shows its surfaces, hides the others.
pub fn selectTab(self: *Window, index: usize) void {
    if (index >= self.tabs.items.len) return;
    self.active_tab = index;
    self.tab_bar.invalidate();

    // Hide surfaces of inactive tabs.
    for (self.tabs.items, 0..) |tab, i| {
        if (i == index) continue;
        if (tab.root) |root| setNodeVisible(root, false);
    }

    self.layout();

    const tab = self.tabs.items[index];
    if (tab.root) |root| setNodeVisible(root, true);
    if (tab.active_surface) |surface| {
        _ = winapi.SetFocus(surface.hwnd);
        self.updateTitle(surface);
    }
}

fn setNodeVisible(node: Node, visible: bool) void {
    switch (node) {
        .leaf => |s| _ = winapi.ShowWindow(
            s.hwnd,
            if (visible) winapi.SW_SHOW else winapi.SW_HIDE,
        ),
        .split => |s| {
            setNodeVisible(s.first, visible);
            setNodeVisible(s.second, visible);
        },
    }
}

pub fn gotoTab(self: *Window, target: apprt.action.GotoTab) void {
    const count = self.tabs.items.len;
    if (count == 0) return;

    const index: usize = switch (target) {
        .previous => if (self.active_tab == 0) count - 1 else self.active_tab - 1,
        .next => (self.active_tab + 1) % count,
        .last => count - 1,
        _ => index: {
            // Positive values are 1-based tab indexes.
            const raw = @intFromEnum(target);
            if (raw < 1) return;
            const idx: usize = @intCast(raw - 1);
            break :index @min(idx, count - 1);
        },
    };

    self.selectTab(index);
}

pub fn activeTab(self: *Window) ?*Tab {
    if (self.tabs.items.len == 0) return null;
    return self.tabs.items[self.active_tab];
}

/// Find the tab containing a surface.
pub fn tabFor(self: *Window, surface: *Surface) ?*Tab {
    for (self.tabs.items) |tab| {
        if (tab.contains(surface)) return tab;
    }
    return null;
}

//-------------------------------------------------------------------
// Splits

/// Split the given surface in the given direction, creating a new
/// surface. Returns the new surface.
pub fn newSplit(
    self: *Window,
    surface: *Surface,
    direction: apprt.action.SplitDirection,
) !*Surface {
    const alloc = self.app.core_app.alloc;
    const tab = self.tabFor(surface) orelse return error.SurfaceNotFound;

    const new_surface = try self.createSurface(tab, .split);
    errdefer _ = winapi.DestroyWindow(new_surface.hwnd);

    const split = try alloc.create(Split);
    errdefer alloc.destroy(split);

    split.* = switch (direction) {
        .right => .{
            .layout = .horizontal,
            .first = .{ .leaf = surface },
            .second = .{ .leaf = new_surface },
        },
        .left => .{
            .layout = .horizontal,
            .first = .{ .leaf = new_surface },
            .second = .{ .leaf = surface },
        },
        .down => .{
            .layout = .vertical,
            .first = .{ .leaf = surface },
            .second = .{ .leaf = new_surface },
        },
        .up => .{
            .layout = .vertical,
            .first = .{ .leaf = new_surface },
            .second = .{ .leaf = surface },
        },
    };

    // Replace the leaf with the new split in the tree.
    if (tab.findParent(surface)) |ref| {
        switch (ref.side) {
            .first => ref.split.first = .{ .split = split },
            .second => ref.split.second = .{ .split = split },
        }
    } else {
        // Leaf was the root.
        tab.root = .{ .split = split };
    }

    tab.active_surface = new_surface;
    self.layout();
    _ = winapi.ShowWindow(new_surface.hwnd, winapi.SW_SHOW);
    _ = winapi.SetFocus(new_surface.hwnd);
    return new_surface;
}

/// Called by a surface (via its WM_APP_SURFACE_CLOSE) to remove it
/// from the window. Destroys the surface window; collapses its parent
/// split; closes the tab/window when it was the last surface.
pub fn closeSurface(self: *Window, surface: *Surface) void {
    const alloc = self.app.core_app.alloc;
    const tab = self.tabFor(surface) orelse return;

    if (tab.findParent(surface)) |ref| {
        // Collapse the parent split into the sibling.
        const sibling = switch (ref.side) {
            .first => ref.split.second,
            .second => ref.split.first,
        };

        const dead_split = ref.split;
        if (tab.root.? == .split and tab.root.?.split == dead_split) {
            tab.root = sibling;
        } else replace: {
            // Find the grandparent referencing dead_split.
            const root = tab.root orelse break :replace;
            replaceChild(root, dead_split, sibling);
        }
        alloc.destroy(dead_split);

        // New focus: first leaf of the sibling subtree.
        const next_focus = firstLeaf(sibling);
        tab.active_surface = next_focus;

        _ = winapi.DestroyWindow(surface.hwnd);
        self.layout();
        if (next_focus) |s| {
            _ = winapi.SetFocus(s.hwnd);
            self.updateTitle(s);
        }
        return;
    }

    // Surface was the root of its tab: close the whole tab.
    tab.root = null;
    tab.active_surface = null;
    _ = winapi.DestroyWindow(surface.hwnd);

    const index = for (self.tabs.items, 0..) |t, i| {
        if (t == tab) break i;
    } else return;

    if (self.tabs.items.len == 1) {
        // Last tab: close the window.
        _ = winapi.DestroyWindow(self.hwnd);
        return;
    }

    _ = self.tabs.orderedRemove(index);
    alloc.destroy(tab);

    const new_active = @min(
        if (self.active_tab > index) self.active_tab - 1 else self.active_tab,
        self.tabs.items.len - 1,
    );
    self.selectTab(new_active);
}

fn replaceChild(node: Node, dead: *Split, replacement: Node) void {
    switch (node) {
        .leaf => {},
        .split => |s| {
            if (s.first == .split and s.first.split == dead) {
                s.first = replacement;
                return;
            }
            if (s.second == .split and s.second.split == dead) {
                s.second = replacement;
                return;
            }
            replaceChild(s.first, dead, replacement);
            replaceChild(s.second, dead, replacement);
        },
    }
}

fn firstLeaf(node: Node) ?*Surface {
    return switch (node) {
        .leaf => |s| s,
        .split => |s| firstLeaf(s.first) orelse firstLeaf(s.second),
    };
}

/// Move focus between splits.
pub fn gotoSplit(self: *Window, from: *Surface, target: apprt.action.GotoSplit) void {
    const tab = self.tabFor(from) orelse return;

    const next: ?*Surface = switch (target) {
        .previous => self.leafNeighbor(tab, from, -1),
        .next => self.leafNeighbor(tab, from, 1),
        .up => self.spatialNeighbor(tab, from, .up),
        .down => self.spatialNeighbor(tab, from, .down),
        .left => self.spatialNeighbor(tab, from, .left),
        .right => self.spatialNeighbor(tab, from, .right),
    };

    if (next) |surface| {
        tab.active_surface = surface;
        _ = winapi.SetFocus(surface.hwnd);
        self.updateTitle(surface);
    }
}

/// Collect leaves in DFS order and pick the neighbor at +/-1.
fn leafNeighbor(self: *Window, tab: *Tab, from: *Surface, offset: i2) ?*Surface {
    _ = self;
    var leaves: [64]*Surface = undefined;
    var n: usize = 0;
    const root = tab.root orelse return null;
    collectLeaves(root, &leaves, &n);
    if (n <= 1) return null;

    const idx = for (leaves[0..n], 0..) |s, i| {
        if (s == from) break i;
    } else return null;

    const next_idx: usize = if (offset > 0)
        (idx + 1) % n
    else
        (idx + n - 1) % n;
    return leaves[next_idx];
}

fn collectLeaves(node: Node, leaves: *[64]*Surface, n: *usize) void {
    switch (node) {
        .leaf => |s| {
            if (n.* < leaves.len) {
                leaves[n.*] = s;
                n.* += 1;
            }
        },
        .split => |s| {
            collectLeaves(s.first, leaves, n);
            collectLeaves(s.second, leaves, n);
        },
    }
}

/// Pick the closest surface in the given direction using the laid-out
/// window rectangles.
fn spatialNeighbor(
    self: *Window,
    tab: *Tab,
    from: *Surface,
    direction: enum { up, down, left, right },
) ?*Surface {
    _ = self;
    var from_rect: winapi.RECT = undefined;
    if (winapi.GetWindowRect(from.hwnd, &from_rect) == 0) return null;

    var leaves: [64]*Surface = undefined;
    var n: usize = 0;
    const root = tab.root orelse return null;
    collectLeaves(root, &leaves, &n);

    var best: ?*Surface = null;
    var best_dist: i32 = std.math.maxInt(i32);

    for (leaves[0..n]) |s| {
        if (s == from) continue;
        var r: winapi.RECT = undefined;
        if (winapi.GetWindowRect(s.hwnd, &r) == 0) continue;

        const ok = switch (direction) {
            .left => r.right <= from_rect.left,
            .right => r.left >= from_rect.right,
            .up => r.bottom <= from_rect.top,
            .down => r.top >= from_rect.bottom,
        };
        if (!ok) continue;

        const dist: i32 = switch (direction) {
            .left => from_rect.left - r.right,
            .right => r.left - from_rect.right,
            .up => from_rect.top - r.bottom,
            .down => r.top - from_rect.bottom,
        };
        if (dist < best_dist) {
            best_dist = dist;
            best = s;
        }
    }

    return best;
}

/// Resize the split containing the surface in the given direction.
pub fn resizeSplit(
    self: *Window,
    from: *Surface,
    value: apprt.action.ResizeSplit,
) void {
    const tab = self.tabFor(from) orelse return;
    const root = tab.root orelse return;

    // Find the nearest ancestor split whose axis matches.
    const want_layout: @TypeOf(root.split.layout) = switch (value.direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };

    const split = findAncestorSplit(root, from, want_layout) orelse return;

    var rect: winapi.RECT = undefined;
    if (winapi.GetClientRect(self.hwnd, &rect) == 0) return;
    const total: f32 = switch (split.layout) {
        .horizontal => @floatFromInt(rect.right - rect.left),
        .vertical => @floatFromInt(rect.bottom - rect.top),
    };
    if (total <= 0) return;

    const delta = @as(f32, @floatFromInt(value.amount)) / total;
    const grow_first = switch (value.direction) {
        .right, .down => true,
        .left, .up => false,
    };
    split.ratio = std.math.clamp(
        if (grow_first) split.ratio + delta else split.ratio - delta,
        0.1,
        0.9,
    );
    self.layout();
}

/// Find the deepest split with the given layout that contains the
/// surface.
fn findAncestorSplit(
    node: Node,
    surface: *Surface,
    layout_kind: anytype,
) ?*Split {
    switch (node) {
        .leaf => return null,
        .split => |s| {
            const in_first = Tab.containsIn(s.first, surface);
            const in_second = Tab.containsIn(s.second, surface);
            if (!in_first and !in_second) return null;

            const child = if (in_first) s.first else s.second;
            if (findAncestorSplit(child, surface, layout_kind)) |deeper|
                return deeper;
            if (s.layout == layout_kind) return s;
            return null;
        },
    }
}

pub fn equalizeSplits(self: *Window) void {
    const tab = self.activeTab() orelse return;
    const root = tab.root orelse return;
    equalizeNode(root);
    self.layout();
}

fn equalizeNode(node: Node) void {
    switch (node) {
        .leaf => {},
        .split => |s| {
            s.ratio = 0.5;
            equalizeNode(s.first);
            equalizeNode(s.second);
        },
    }
}

//-------------------------------------------------------------------
// Layout & title

/// The DPI scale for this window.
fn scale(self: *Window) f32 {
    const dpi: f32 = @floatFromInt(winapi.GetDpiForWindow(self.hwnd));
    return @max(1.0, dpi / 96.0);
}

/// Whether the tab strip should be visible.
fn tabBarVisible(self: *Window) bool {
    return self.tabs.items.len > 1;
}

/// Lay out the tab strip and the active tab's surfaces.
pub fn layout(self: *Window) void {
    var client: winapi.RECT = undefined;
    if (winapi.GetClientRect(self.hwnd, &client) == 0) return;

    const width = client.right - client.left;
    const height = client.bottom - client.top;
    if (width <= 0 or height <= 0) return;

    var content_top: i32 = 0;

    if (self.tabBarVisible()) {
        const tab_h: i32 = @intFromFloat(38.0 * self.scale());
        _ = winapi.SetWindowPos(
            self.tab_bar.hwnd,
            null,
            0,
            0,
            width,
            tab_h,
            winapi.SWP_NOZORDER | winapi.SWP_SHOWWINDOW,
        );
        self.tab_bar.invalidate();
        content_top = tab_h;
    } else {
        _ = winapi.SetWindowPos(
            self.tab_bar.hwnd,
            null,
            0,
            0,
            0,
            0,
            winapi.SWP_NOZORDER | winapi.SWP_HIDEWINDOW,
        );
    }

    const tab = self.activeTab() orelse return;
    const root = tab.root orelse return;
    const gap: i32 = @intFromFloat(@as(f32, split_gap) * self.scale());
    self.layoutNode(root, .{
        .left = 0,
        .top = content_top,
        .right = width,
        .bottom = height,
    }, gap);
}

fn layoutNode(self: *Window, node: Node, rect: winapi.RECT, gap: i32) void {
    switch (node) {
        .leaf => |surface| {
            _ = winapi.SetWindowPos(
                surface.hwnd,
                null,
                rect.left,
                rect.top,
                @max(1, rect.right - rect.left),
                @max(1, rect.bottom - rect.top),
                winapi.SWP_NOZORDER,
            );
        },
        .split => |split| {
            switch (split.layout) {
                .horizontal => {
                    const total = rect.right - rect.left - gap;
                    const first_w: i32 = @intFromFloat(
                        @as(f32, @floatFromInt(total)) * split.ratio,
                    );
                    self.layoutNode(split.first, .{
                        .left = rect.left,
                        .top = rect.top,
                        .right = rect.left + first_w,
                        .bottom = rect.bottom,
                    }, gap);
                    self.layoutNode(split.second, .{
                        .left = rect.left + first_w + gap,
                        .top = rect.top,
                        .right = rect.right,
                        .bottom = rect.bottom,
                    }, gap);
                },
                .vertical => {
                    const total = rect.bottom - rect.top - gap;
                    const first_h: i32 = @intFromFloat(
                        @as(f32, @floatFromInt(total)) * split.ratio,
                    );
                    self.layoutNode(split.first, .{
                        .left = rect.left,
                        .top = rect.top,
                        .right = rect.right,
                        .bottom = rect.top + first_h,
                    }, gap);
                    self.layoutNode(split.second, .{
                        .left = rect.left,
                        .top = rect.top + first_h + gap,
                        .right = rect.right,
                        .bottom = rect.bottom,
                    }, gap);
                },
            }
        },
    }
}

/// The title to display in UI for a raw terminal title. The ConPTY
/// default title is the full shell path (C:\WINDOWS\system32\cmd.exe);
/// reduce paths like that to the program name.
fn displayTitle(raw: []const u8) []const u8 {
    if (raw.len == 0) return "Ghostty";
    if (std.mem.indexOfScalar(u8, raw, '\\') != null and
        std.ascii.endsWithIgnoreCase(raw, ".exe"))
    {
        const base = std.fs.path.basenameWindows(raw);
        return base[0 .. base.len - ".exe".len];
    }
    return raw;
}

/// The display title for a tab (used by the tab bar).
pub fn tabDisplayTitle(self: *Window, index: usize) []const u8 {
    if (index >= self.tabs.items.len) return "Ghostty";
    const tab = self.tabs.items[index];
    const surface = tab.active_surface orelse return "Ghostty";
    return displayTitle(surface.title orelse "Ghostty");
}

/// Update the window title and tab text for the tab containing the
/// given surface.
pub fn updateTitle(self: *Window, surface: *Surface) void {
    const alloc = self.app.core_app.alloc;

    const tab = self.tabFor(surface) orelse return;
    const index = for (self.tabs.items, 0..) |t, i| {
        if (t == tab) break i;
    } else return;

    self.tab_bar.invalidate();

    // Update the window title when this surface's tab is active and
    // the surface is the active one. The caption is branded:
    // "Ghostty - <what the terminal reports>" (program, path, ssh...).
    if (index == self.active_tab and tab.active_surface == surface) {
        const pretty = displayTitle(surface.title orelse "Ghostty");

        var caption_owned: ?[]const u8 = null;
        defer if (caption_owned) |c| alloc.free(c);
        const caption: []const u8 = caption: {
            if (std.mem.eql(u8, pretty, "Ghostty")) break :caption pretty;
            const owned = std.fmt.allocPrint(
                alloc,
                "Ghostty - {s}",
                .{pretty},
            ) catch break :caption pretty;
            caption_owned = owned;
            break :caption owned;
        };

        if (std.unicode.utf8ToUtf16LeAllocZ(alloc, caption)) |wide| {
            defer alloc.free(wide);
            _ = winapi.SetWindowTextW(self.hwnd, wide);
        } else |_| {}
    }
}

/// Track focus changes from surfaces.
pub fn surfaceFocused(self: *Window, surface: *Surface) void {
    if (self.tabFor(surface)) |tab| {
        tab.active_surface = surface;
        self.updateTitle(surface);
    }
}

fn createSurface(
    self: *Window,
    tab: *Tab,
    context: apprt.surface.NewSurfaceContext,
) !*Surface {
    _ = tab;
    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);
    try surface.init(self.app, self, .{ .context = context });
    return surface;
}

//-------------------------------------------------------------------
// Window procedure

pub fn wndProc(
    hwnd: winapi.HWND,
    msg: winapi.UINT,
    wparam: winapi.WPARAM,
    lparam: winapi.LPARAM,
) callconv(.winapi) winapi.LRESULT {
    if (msg == winapi.WM_NCCREATE) {
        const cs: *const winapi.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        _ = winapi.SetWindowLongPtrW(
            hwnd,
            winapi.GWLP_USERDATA,
            @bitCast(@intFromPtr(cs.lpCreateParams)),
        );
        return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const self: *Window = self: {
        const ptr = winapi.GetWindowLongPtrW(hwnd, winapi.GWLP_USERDATA);
        if (ptr == 0) return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        break :self @ptrFromInt(@as(usize, @bitCast(ptr)));
    };

    switch (msg) {
        winapi.WM_CLOSE => {
            // Confirm only when more than one terminal would be lost,
            // like the "close all tabs" prompt in Windows Terminal.
            if (!self.confirmClose(self.totalPaneCount())) return 0;
            _ = winapi.DestroyWindow(hwnd);
            return 0;
        },

        winapi.WM_DESTROY => {
            const app = self.app;
            self.savePlacement();
            self.deinit();
            app.core_app.alloc.destroy(self);
            app.windowDestroyed();
            return 0;
        },

        winapi.WM_ERASEBKGND => {
            if (self.bg_brush) |brush| {
                const dc: winapi.HDC = @ptrFromInt(wparam);
                var client: winapi.RECT = undefined;
                if (winapi.GetClientRect(hwnd, &client) != 0) {
                    _ = winapi.FillRect(dc, &client, brush);
                }
                return 1;
            }
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_GETMINMAXINFO => {
            const info: *winapi.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const s = self.scale();
            info.ptMinTrackSize.x = @intFromFloat(320.0 * s);
            info.ptMinTrackSize.y = @intFromFloat(240.0 * s);
            return 0;
        },

        winapi.WM_SIZE => {
            // Nothing to lay out while minimized (zero client area).
            if (wparam == winapi.SIZE_MINIMIZED) {
                self.was_minimized = true;
                return 0;
            }

            self.layout();

            // Restoring from minimize discards the layered window's
            // backing store and nothing marks the children dirty, so
            // repaint the chrome and re-present every terminal pane
            // (idle panes have no other reason to redraw).
            _ = winapi.InvalidateRect(self.tab_bar.hwnd, null, 1);
            if (self.was_minimized) {
                self.was_minimized = false;
                self.refreshAllSurfaces();
            }
            return 0;
        },

        winapi.WM_ACTIVATE => {
            // Becoming active (including after a restore) can follow a
            // discarded backing store; repaint chrome and panes.
            if (winapi.loWord(wparam) != winapi.WA_INACTIVE) {
                _ = winapi.InvalidateRect(self.tab_bar.hwnd, null, 1);
                if (self.was_minimized) {
                    self.was_minimized = false;
                    self.refreshAllSurfaces();
                }
            }
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_DPICHANGED => {
            // Resize to the suggested rect and notify all surfaces of
            // the new content scale.
            const rect: *const winapi.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = winapi.SetWindowPos(
                hwnd,
                null,
                rect.left,
                rect.top,
                rect.right - rect.left,
                rect.bottom - rect.top,
                winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE,
            );

            const dpi: f32 = @floatFromInt(winapi.loWord(wparam));
            const new_scale = @max(1.0, dpi / 96.0);
            for (self.tabs.items) |tab| {
                if (tab.root) |root| notifyScale(root, new_scale);
            }
            self.layout();
            return 0;
        },

        winapi.WM_SETFOCUS => {
            // Forward focus to the active surface.
            if (self.activeTab()) |tab| {
                if (tab.active_surface) |surface| {
                    _ = winapi.SetFocus(surface.hwnd);
                }
            }
            return 0;
        },

        // System theme (light/dark) changes; conditional themes follow.
        winapi.WM_SETTINGCHANGE => {
            self.app.syncColorScheme();
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        else => return winapi.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// Ask every terminal pane (all tabs, visible or not) to re-present
/// its frame. Used after the window backing store was discarded.
fn refreshAllSurfaces(self: *Window) void {
    for (self.tabs.items) |tab| {
        const root = tab.root orelse continue;
        refreshNode(root);
    }
}

fn refreshNode(node: Node) void {
    switch (node) {
        .leaf => |s| {
            if (s.core_inited) {
                _ = winapi.InvalidateRect(s.hwnd, null, 0);
                s.core_surface.refreshCallback() catch |err| {
                    log.err("error in refresh callback err={}", .{err});
                };
            }
        },
        .split => |sp| {
            refreshNode(sp.first);
            refreshNode(sp.second);
        },
    }
}

/// Number of terminal panes in a subtree.
fn nodePaneCount(node: Node) usize {
    return switch (node) {
        .leaf => 1,
        .split => |s| nodePaneCount(s.first) + nodePaneCount(s.second),
    };
}

/// Number of terminal panes in a tab.
fn tabPaneCount(tab: *Tab) usize {
    const root = tab.root orelse return 0;
    return nodePaneCount(root);
}

/// Total terminal panes across all tabs of the window.
fn totalPaneCount(self: *Window) usize {
    var total: usize = 0;
    for (self.tabs.items) |tab| total += tabPaneCount(tab);
    return total;
}

/// Ask the user to confirm closing `count` terminals. Returns true to
/// proceed. A single terminal closes without asking.
fn confirmClose(self: *Window, count: usize) bool {
    if (count <= 1) return true;
    if (self.app.config.@"confirm-close-surface" == .false) return true;

    var buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrintZ(
        &buf,
        "This will close {d} terminals.\n\nClose them all?",
        .{count},
    ) catch "Close all terminals?";

    const alloc = self.app.core_app.alloc;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, msg) catch return true;
    defer alloc.free(wide);

    const result = winapi.MessageBoxW(
        self.hwnd,
        wide,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty - Confirm Close"),
        0x00000004 | 0x00000030, // MB_YESNO | MB_ICONWARNING
    );
    return result == 6; // IDYES
}

fn notifyScale(node: Node, new_scale: f32) void {
    switch (node) {
        .leaf => |s| {
            if (s.core_inited) {
                s.core_surface.contentScaleCallback(.{
                    .x = new_scale,
                    .y = new_scale,
                }) catch |err| {
                    log.err("error in content scale callback err={}", .{err});
                };
            }
        },
        .split => |sp| {
            notifyScale(sp.first, new_scale);
            notifyScale(sp.second, new_scale);
        },
    }
}
