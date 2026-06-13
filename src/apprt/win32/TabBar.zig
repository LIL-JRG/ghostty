//! A custom-drawn tab strip for Ghostty windows. The classic comctl32
//! tab control can't be themed dark, so this draws a flat, modern strip
//! using colors derived from the terminal configuration: close button
//! per tab, a "+" button, hover states and middle-click to close.
const TabBar = @This();

const std = @import("std");

const winapi = @import("winapi.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32_tabbar);

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyTabBar");

/// GDI+ token, started lazily on first paint (main thread only).
var gdiplus_token: ?usize = null;

fn ensureGdiplus() bool {
    if (gdiplus_token != null) return true;
    var token: usize = 0;
    const input: winapi.GdiplusStartupInput = .{};
    if (winapi.GdiplusStartup(&token, &input, null) != 0) return false;
    gdiplus_token = token;
    return true;
}

/// Fill a rounded rectangle (pill) with antialiasing.
fn fillRoundedRect(
    gfx: winapi.GpGraphics,
    rect: winapi.RECT,
    radius: i32,
    color: winapi.COLORREF,
) void {
    const w = rect.right - rect.left;
    const h = rect.bottom - rect.top;
    if (w <= 0 or h <= 0) return;
    const r = @min(radius, @min(@divTrunc(w, 2), @divTrunc(h, 2)));
    const d = r * 2;

    var brush: ?winapi.GpSolidFill = null;
    if (winapi.GdipCreateSolidFill(winapi.argbFromColorref(color), &brush) != 0) return;
    defer _ = winapi.GdipDeleteBrush(brush.?);

    var path: ?winapi.GpPath = null;
    if (winapi.GdipCreatePath(winapi.FillModeAlternate, &path) != 0) return;
    defer _ = winapi.GdipDeletePath(path.?);

    const x = rect.left;
    const y = rect.top;
    _ = winapi.GdipAddPathArcI(path.?, x, y, d, d, 180, 90);
    _ = winapi.GdipAddPathArcI(path.?, x + w - d, y, d, d, 270, 90);
    _ = winapi.GdipAddPathArcI(path.?, x + w - d, y + h - d, d, d, 0, 90);
    _ = winapi.GdipAddPathArcI(path.?, x, y + h - d, d, d, 90, 90);
    _ = winapi.GdipClosePathFigure(path.?);

    _ = winapi.GdipFillPath(gfx, brush.?, path.?);
}

window: *Window,
hwnd: winapi.HWND,

/// Colors derived from the terminal config.
bar_bg: winapi.COLORREF,
tab_active_bg: winapi.COLORREF,
tab_hover_bg: winapi.COLORREF,
text_color: winapi.COLORREF,
text_dim_color: winapi.COLORREF,

/// Hover state.
hover: ?Hit = null,
mouse_tracked: bool = false,

const Hit = union(enum) {
    tab: usize,
    close: usize,
    plus,

    fn eql(a: ?Hit, b: ?Hit) bool {
        const av = a orelse return b == null;
        const bv = b orelse return false;
        return switch (av) {
            .tab => |i| bv == .tab and bv.tab == i,
            .close => |i| bv == .close and bv.close == i,
            .plus => bv == .plus,
        };
    }
};

pub fn init(self: *TabBar, window: *Window) !void {
    self.* = .{
        .window = window,
        .hwnd = undefined,
        .bar_bg = 0,
        .tab_active_bg = 0,
        .tab_hover_bg = 0,
        .text_color = 0,
        .text_dim_color = 0,
    };
    self.computeColors();

    self.hwnd = winapi.CreateWindowExW(
        0,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        winapi.WS_CHILD | winapi.WS_CLIPSIBLINGS,
        0,
        0,
        0,
        0,
        window.hwnd,
        null,
        window.app.instance,
        self,
    ) orelse return error.WindowCreationFailed;
}

fn scaleColor(c: u8, factor: f32) u8 {
    return @intFromFloat(@min(
        255.0,
        @as(f32, @floatFromInt(c)) * factor,
    ));
}

/// Derive the palette from the resolved chrome colors. For dark themes
/// the bar sits darker than the terminal; for light themes, lighter.
fn computeColors(self: *TabBar) void {
    const chrome = self.window.app.chrome;
    const bg = chrome.background;
    const fg = chrome.foreground;
    const dark = chrome.isDark();

    const bar_f: f32 = if (dark) 0.55 else 1.12;
    const hover_f: f32 = if (dark) 0.8 else 1.06;

    self.bar_bg = winapi.rgb(
        scaleColor(bg.r, bar_f),
        scaleColor(bg.g, bar_f),
        scaleColor(bg.b, bar_f),
    );
    self.tab_active_bg = winapi.rgb(bg.r, bg.g, bg.b);
    self.tab_hover_bg = winapi.rgb(
        scaleColor(bg.r, hover_f),
        scaleColor(bg.g, hover_f),
        scaleColor(bg.b, hover_f),
    );
    self.text_color = winapi.rgb(fg.r, fg.g, fg.b);
    self.text_dim_color = winapi.rgb(
        scaleColor(fg.r, 0.6),
        scaleColor(fg.g, 0.6),
        scaleColor(fg.b, 0.6),
    );
}

/// Recompute the palette (after a theme change) and repaint.
pub fn updateColors(self: *TabBar) void {
    self.computeColors();
    self.invalidate();
}

pub fn invalidate(self: *TabBar) void {
    _ = winapi.InvalidateRect(self.hwnd, null, 0);
}

//-------------------------------------------------------------------
// Metrics

fn scale(self: *const TabBar) f32 {
    const dpi: f32 = @floatFromInt(winapi.GetDpiForWindow(self.hwnd));
    return @max(1.0, dpi / 96.0);
}

fn px(self: *const TabBar, v: f32) i32 {
    return @intFromFloat(v * self.scale());
}

fn tabRect(self: *const TabBar, index: usize) winapi.RECT {
    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &client);

    const count = self.window.tabs.items.len;
    const plus_w = self.px(34);
    const avail = @max(0, client.right - client.left - plus_w);
    const max_w = self.px(220);
    const tab_w = if (count == 0)
        max_w
    else
        @min(max_w, @divTrunc(avail, @as(i32, @intCast(count))));

    const i: i32 = @intCast(index);
    return .{
        .left = i * tab_w,
        .top = 0,
        .right = (i + 1) * tab_w,
        .bottom = client.bottom,
    };
}

fn closeRect(self: *const TabBar, tab: winapi.RECT) winapi.RECT {
    const size = self.px(18);
    const margin = self.px(8);
    const cy = @divTrunc(tab.top + tab.bottom, 2);
    return .{
        .left = tab.right - margin - size,
        .top = cy - @divTrunc(size, 2),
        .right = tab.right - margin,
        .bottom = cy + size - @divTrunc(size, 2),
    };
}

fn plusRect(self: *const TabBar) winapi.RECT {
    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &client);

    const count = self.window.tabs.items.len;
    const last = if (count == 0) winapi.RECT{
        .left = 0,
        .top = 0,
        .right = 0,
        .bottom = client.bottom,
    } else self.tabRect(count - 1);

    const size = self.px(28);
    const cy = @divTrunc(client.bottom, 2);
    return .{
        .left = last.right + self.px(4),
        .top = cy - @divTrunc(size, 2),
        .right = last.right + self.px(4) + size,
        .bottom = cy + size - @divTrunc(size, 2),
    };
}

fn hitTest(self: *const TabBar, x: i32, y: i32) ?Hit {
    const plus = self.plusRect();
    if (ptIn(plus, x, y)) return .plus;

    const count = self.window.tabs.items.len;
    for (0..count) |i| {
        const rect = self.tabRect(i);
        if (!ptIn(rect, x, y)) continue;

        // The close button only hit-tests when visible (active or
        // hovered tab), but hovering implies we're in it now anyway.
        if (ptIn(self.closeRect(rect), x, y)) return .{ .close = i };
        return .{ .tab = i };
    }

    return null;
}

fn ptIn(r: winapi.RECT, x: i32, y: i32) bool {
    return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
}

//-------------------------------------------------------------------
// Painting

fn paint(self: *TabBar) void {
    var ps: winapi.PAINTSTRUCT = undefined;
    const hdc = winapi.BeginPaint(self.hwnd, &ps) orelse return;
    defer _ = winapi.EndPaint(self.hwnd, &ps);

    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &client);
    const width = client.right - client.left;
    const height = client.bottom - client.top;
    if (width <= 0 or height <= 0) return;

    // Double buffer to avoid flicker.
    const mem_dc = winapi.CreateCompatibleDC(hdc) orelse return;
    defer _ = winapi.DeleteDC(mem_dc);
    const bitmap = winapi.CreateCompatibleBitmap(hdc, width, height) orelse return;
    defer _ = winapi.DeleteObject(bitmap);
    _ = winapi.SelectObject(mem_dc, bitmap);

    // Background.
    if (winapi.CreateSolidBrush(self.bar_bg)) |brush| {
        defer _ = winapi.DeleteObject(brush);
        _ = winapi.FillRect(mem_dc, &client, brush);
    }

    // UI font (Segoe UI at ~12pt visual size).
    const font = winapi.CreateFontW(
        -self.px(14),
        0,
        0,
        0,
        winapi.FW_NORMAL,
        0,
        0,
        0,
        winapi.DEFAULT_CHARSET,
        winapi.OUT_DEFAULT_PRECIS,
        winapi.CLIP_DEFAULT_PRECIS,
        winapi.CLEARTYPE_QUALITY,
        winapi.DEFAULT_PITCH,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    defer if (font) |f| {
        _ = winapi.DeleteObject(f);
    };
    if (font) |f| {
        _ = winapi.SelectObject(mem_dc, f);
    }
    _ = winapi.SetBkMode(mem_dc, winapi.TRANSPARENT);

    // GDI+ context for the antialiased rounded pills. On failure we
    // fall back to square GDI fills.
    var gfx: ?winapi.GpGraphics = null;
    if (ensureGdiplus()) {
        if (winapi.GdipCreateFromHDC(mem_dc, &gfx) == 0) {
            if (gfx) |g| _ = winapi.GdipSetSmoothingMode(g, winapi.SmoothingModeAntiAlias);
        } else gfx = null;
    }
    defer if (gfx) |g| {
        _ = winapi.GdipDeleteGraphics(g);
    };

    // Tabs.
    const count = self.window.tabs.items.len;
    for (0..count) |i| {
        self.paintTab(mem_dc, gfx, i);
    }

    // "+" button.
    const plus = self.plusRect();
    if (Hit.eql(self.hover, .plus)) {
        self.fillBg(mem_dc, gfx, plus, self.px(6), self.tab_hover_bg);
    }
    _ = winapi.SetTextColor(mem_dc, self.text_dim_color);
    var plus_rect = plus;
    _ = winapi.DrawTextW(
        mem_dc,
        std.unicode.utf8ToUtf16LeStringLiteral("+"),
        1,
        &plus_rect,
        winapi.DT_CENTER | winapi.DT_VCENTER | winapi.DT_SINGLELINE,
    );

    _ = winapi.BitBlt(hdc, 0, 0, width, height, mem_dc, 0, 0, winapi.SRCCOPY);
}

/// Fill a background shape: rounded via GDI+ when available, square
/// GDI fill otherwise.
fn fillBg(
    self: *TabBar,
    dc: winapi.HDC,
    gfx: ?winapi.GpGraphics,
    rect: winapi.RECT,
    radius: i32,
    color: winapi.COLORREF,
) void {
    _ = self;
    if (gfx) |g| {
        fillRoundedRect(g, rect, radius, color);
        return;
    }
    if (winapi.CreateSolidBrush(color)) |brush| {
        defer _ = winapi.DeleteObject(brush);
        _ = winapi.FillRect(dc, &rect, brush);
    }
}

fn paintTab(self: *TabBar, dc: winapi.HDC, gfx: ?winapi.GpGraphics, i: usize) void {
    const is_active = i == self.window.active_tab;
    const is_hover = Hit.eql(self.hover, .{ .tab = i }) or
        Hit.eql(self.hover, .{ .close = i });
    const rect = self.tabRect(i);

    // Tab background: rounded pills floating in the strip (active uses
    // the terminal background, hover a subtle highlight).
    const bg: ?winapi.COLORREF = if (is_active)
        self.tab_active_bg
    else if (is_hover)
        self.tab_hover_bg
    else
        null;

    if (bg) |color| {
        var pill = rect;
        pill.top += self.px(5);
        pill.bottom -= self.px(5);
        pill.left += self.px(3);
        pill.right -= self.px(3);
        self.fillBg(dc, gfx, pill, self.px(8), color);
    }

    // Title text.
    const title = self.window.tabDisplayTitle(i);
    var buf: [128]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, title) catch 0;
    if (n > 0) {
        _ = winapi.SetTextColor(
            dc,
            if (is_active) self.text_color else self.text_dim_color,
        );
        var text_rect = rect;
        text_rect.left += self.px(12);
        text_rect.right = self.closeRect(rect).left - self.px(4);
        if (text_rect.right > text_rect.left) {
            _ = winapi.DrawTextW(
                dc,
                @ptrCast(buf[0..n]),
                @intCast(n),
                &text_rect,
                winapi.DT_LEFT | winapi.DT_VCENTER |
                    winapi.DT_SINGLELINE | winapi.DT_END_ELLIPSIS,
            );
        }
    }

    // Close button, visible on the active or hovered tab.
    if (is_active or is_hover) {
        const close = self.closeRect(rect);
        if (Hit.eql(self.hover, .{ .close = i })) {
            self.fillBg(dc, gfx, close, self.px(5), self.tab_hover_bg);
        }
        _ = winapi.SetTextColor(dc, self.text_dim_color);
        var close_rect = close;
        _ = winapi.DrawTextW(
            dc,
            std.unicode.utf8ToUtf16LeStringLiteral("✕"),
            1,
            &close_rect,
            winapi.DT_CENTER | winapi.DT_VCENTER | winapi.DT_SINGLELINE,
        );
    }
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

    const self: *TabBar = self: {
        const ptr = winapi.GetWindowLongPtrW(hwnd, winapi.GWLP_USERDATA);
        if (ptr == 0) return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        break :self @ptrFromInt(@as(usize, @bitCast(ptr)));
    };

    switch (msg) {
        winapi.WM_PAINT => {
            self.paint();
            return 0;
        },

        winapi.WM_ERASEBKGND => return 1,

        winapi.WM_MOUSEMOVE => {
            if (!self.mouse_tracked) {
                var tme: winapi.TRACKMOUSEEVENT = .{
                    .dwFlags = winapi.TME_LEAVE,
                    .hwndTrack = hwnd,
                };
                if (winapi.TrackMouseEvent(&tme) != 0) self.mouse_tracked = true;
            }

            const hit = self.hitTest(
                winapi.getXLParam(lparam),
                winapi.getYLParam(lparam),
            );
            if (!Hit.eql(hit, self.hover)) {
                self.hover = hit;
                self.invalidate();
            }
            return 0;
        },

        winapi.WM_MOUSELEAVE => {
            self.mouse_tracked = false;
            if (self.hover != null) {
                self.hover = null;
                self.invalidate();
            }
            return 0;
        },

        winapi.WM_LBUTTONDOWN => {
            const hit = self.hitTest(
                winapi.getXLParam(lparam),
                winapi.getYLParam(lparam),
            ) orelse {
                // Empty strip area drags the window, like a title bar.
                _ = winapi.ReleaseCapture();
                _ = winapi.SendMessageW(
                    self.window.hwnd,
                    winapi.WM_NCLBUTTONDOWN,
                    winapi.HTCAPTION,
                    0,
                );
                return 0;
            };

            switch (hit) {
                .tab => |i| self.window.selectTab(i),
                .close => |i| self.window.closeTabIndex(i),
                .plus => _ = self.window.newTab(.tab) catch |err| {
                    log.err("error creating tab err={}", .{err});
                },
            }
            return 0;
        },

        winapi.WM_LBUTTONDBLCLK => {
            // Double click on the empty strip toggles maximize.
            const hit = self.hitTest(
                winapi.getXLParam(lparam),
                winapi.getYLParam(lparam),
            );
            if (hit == null) self.window.toggleMaximize();
            return 0;
        },

        winapi.WM_MBUTTONUP => {
            const hit = self.hitTest(
                winapi.getXLParam(lparam),
                winapi.getYLParam(lparam),
            ) orelse return 0;

            switch (hit) {
                .tab, .close => |i| self.window.closeTabIndex(i),
                .plus => {},
            }
            return 0;
        },

        else => return winapi.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
