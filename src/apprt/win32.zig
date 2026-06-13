//! Application runtime that uses the Win32 API directly. This is the
//! native runtime for Windows.
const internal_os = @import("../os/main.zig");

pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const winapi = @import("win32/winapi.zig");
pub const resourcesDir = internal_os.resourcesDir;

test {
    @import("std").testing.refAllDecls(@This());
}
