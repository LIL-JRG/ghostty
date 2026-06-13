//! Keyboard translation helpers for the win32 apprt: Windows scancodes
//! and virtual keys to Ghostty input types.
const std = @import("std");
const input = @import("../../input.zig");
const winapi = @import("winapi.zig");

/// Convert a Windows native keycode (OEM scancode with the extended
/// prefix, e.g. 0x001E or 0xE01D) to a Ghostty physical key. This is the
/// same "native" encoding used by the Chromium table that backs
/// input.keycodes on Windows.
pub fn keyFromScancode(native: u32) input.Key {
    for (input.keycodes.entries) |entry| {
        if (entry.native == native) return entry.key;
    }

    return .unidentified;
}

/// Extract the native keycode from a WM_KEYDOWN/WM_KEYUP lParam.
/// This is the scancode in bits 16-23 plus the extended bit mapped
/// to the 0xE000 prefix. Synthesized input (SendInput without a scan
/// code) has no scancode in lParam, so we fall back to deriving it
/// from the virtual key.
pub fn nativeFromLParam(vk: winapi.WPARAM, lparam: winapi.LPARAM) u32 {
    const bits: usize = @bitCast(lparam);
    var scancode: u32 = @intCast((bits >> 16) & 0xFF);
    var extended = (bits & (1 << 24)) != 0;

    if (scancode == 0) {
        scancode = winapi.MapVirtualKeyW(
            @intCast(vk),
            winapi.MAPVK_VK_TO_VSC,
        );

        // Synthesized input also lacks the extended flag. These
        // virtual keys are delivered for the extended-position keys
        // (the numpad variants deliver VK_NUMPAD*), so infer it;
        // otherwise e.g. VK_PRIOR maps to the numpad 9 scancode and
        // page_up bindings won't match.
        if (!extended) extended = switch (vk) {
            0x21, // VK_PRIOR (page up)
            0x22, // VK_NEXT (page down)
            0x23, // VK_END
            0x24, // VK_HOME
            0x25, // VK_LEFT
            0x26, // VK_UP
            0x27, // VK_RIGHT
            0x28, // VK_DOWN
            0x2D, // VK_INSERT
            0x2E, // VK_DELETE
            0x5B, // VK_LWIN
            0x5C, // VK_RWIN
            0x5D, // VK_APPS
            0x6F, // VK_DIVIDE
            => true,
            else => false,
        };
    }

    return if (extended) scancode | 0xE000 else scancode;
}

/// Query the current keyboard modifier state.
pub fn mods() input.Mods {
    var result: input.Mods = .{};

    if (down(winapi.VK_SHIFT)) {
        result.shift = true;
        if (down(winapi.VK_RSHIFT)) result.sides.shift = .right;
    }

    if (down(winapi.VK_CONTROL)) {
        result.ctrl = true;
        if (down(winapi.VK_RCONTROL)) result.sides.ctrl = .right;
    }

    if (down(winapi.VK_MENU)) {
        result.alt = true;
        if (down(winapi.VK_RMENU)) result.sides.alt = .right;
    }

    if (down(winapi.VK_LWIN) or down(winapi.VK_RWIN)) {
        result.super = true;
        if (down(winapi.VK_RWIN)) result.sides.super = .right;
    }

    if (toggled(winapi.VK_CAPITAL)) result.caps_lock = true;
    if (toggled(winapi.VK_NUMLOCK)) result.num_lock = true;

    return result;
}

fn down(vk: c_int) bool {
    return (winapi.GetKeyState(vk) & @as(i16, @bitCast(@as(u16, 0x8000)))) != 0;
}

fn toggled(vk: c_int) bool {
    return (winapi.GetKeyState(vk) & 1) != 0;
}

/// The unshifted codepoint for a virtual key in the current keyboard
/// layout. For example for the "A" virtual key this is 'a'.
pub fn unshiftedCodepoint(vk: u32) u21 {
    const raw = winapi.MapVirtualKeyW(vk, winapi.MAPVK_VK_TO_CHAR);

    // The high bit set means a dead key.
    const masked = raw & 0x7FFFFFFF;
    if (masked == 0) return 0;

    const cp = std.math.cast(u21, masked) orelse return 0;

    // MapVirtualKey returns uppercase letters; we want the unshifted
    // (lowercase) form. This is best-effort for the ASCII range.
    if (cp >= 'A' and cp <= 'Z') return cp + ('a' - 'A');

    return cp;
}

test "nativeFromLParam" {
    // 'A' key: scancode 0x1E, not extended, repeat=1
    const lparam: winapi.LPARAM = @bitCast(@as(usize, 0x1E0001));
    try std.testing.expectEqual(@as(u32, 0x1E), nativeFromLParam(0x41, lparam));
}
