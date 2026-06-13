//! Standalone ConPTY ^C experiment: spawn `ping -t localhost` under a
//! pseudoconsole, write 0x03 into the input pipe after a few seconds and
//! observe whether the process is interrupted. This mirrors ghostty's
//! Command.zig spawn flags exactly.
//!
//! Build/run:
//!   zig run test/windows/conpty_ctrlc_test.zig
const std = @import("std");
const win = std.os.windows;

const HPCON = *opaque {};

const COORD = extern struct { X: i16, Y: i16 };

extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: win.HANDLE,
    hOutput: win.HANDLE,
    dwFlags: u32,
    phPC: *HPCON,
) callconv(.winapi) win.HRESULT;
extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
extern "kernel32" fn CreatePipe(
    hReadPipe: *win.HANDLE,
    hWritePipe: *win.HANDLE,
    lpPipeAttributes: ?*anyopaque,
    nSize: u32,
) callconv(.winapi) win.BOOL;
extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?[*]u8,
    dwAttributeCount: u32,
    dwFlags: u32,
    lpSize: *usize,
) callconv(.winapi) win.BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: [*]u8,
    dwFlags: u32,
    Attribute: usize,
    lpValue: *anyopaque,
    cbSize: usize,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*usize,
) callconv(.winapi) win.BOOL;
extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: win.BOOL,
    dwCreationFlags: u32,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *anyopaque,
    lpProcessInformation: *win.PROCESS_INFORMATION,
) callconv(.winapi) win.BOOL;
extern "kernel32" fn ReadFile(
    h: win.HANDLE,
    buf: [*]u8,
    len: u32,
    read: ?*u32,
    overlapped: ?*anyopaque,
) callconv(.winapi) win.BOOL;
extern "kernel32" fn WriteFile(
    h: win.HANDLE,
    buf: [*]const u8,
    len: u32,
    written: ?*u32,
    overlapped: ?*anyopaque,
) callconv(.winapi) win.BOOL;
extern "kernel32" fn PeekNamedPipe(
    h: win.HANDLE,
    buf: ?[*]u8,
    len: u32,
    read: ?*u32,
    avail: ?*u32,
    left: ?*u32,
) callconv(.winapi) win.BOOL;
extern "kernel32" fn WaitForSingleObject(h: win.HANDLE, ms: u32) callconv(.winapi) u32;

const STARTUPINFOEXW = extern struct {
    StartupInfo: win.STARTUPINFOW,
    lpAttributeList: ?[*]u8,
};

const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x20016;
const EXTENDED_STARTUPINFO_PRESENT: u32 = 0x00080000;
const CREATE_UNICODE_ENVIRONMENT: u32 = 0x00000400;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const out = &stdout_writer.interface;

    var in_read: win.HANDLE = undefined;
    var in_write: win.HANDLE = undefined;
    var out_read: win.HANDLE = undefined;
    var out_write: win.HANDLE = undefined;
    if (CreatePipe(&in_read, &in_write, null, 0) == 0) return error.PipeFailed;
    if (CreatePipe(&out_read, &out_write, null, 0) == 0) return error.PipeFailed;

    var hpcon: HPCON = undefined;
    const hr = CreatePseudoConsole(
        .{ .X = 80, .Y = 25 },
        in_read,
        out_write,
        0,
        &hpcon,
    );
    if (hr != 0) return error.ConPtyFailed;

    var attr_size: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    const attr_buf = try alloc.alignedAlloc(u8, .of(usize), attr_size);
    defer alloc.free(attr_buf);
    if (InitializeProcThreadAttributeList(attr_buf.ptr, 1, 0, &attr_size) == 0)
        return error.AttrFailed;
    if (UpdateProcThreadAttribute(
        attr_buf.ptr,
        0,
        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        hpcon,
        @sizeOf(HPCON),
        null,
        null,
    ) == 0) return error.AttrFailed;

    var startup: STARTUPINFOEXW = std.mem.zeroes(STARTUPINFOEXW);
    startup.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
    startup.lpAttributeList = attr_buf.ptr;

    var cmdline = std.unicode.utf8ToUtf16LeStringLiteral(
        "C:\\Windows\\System32\\PING.EXE -t localhost",
    ).*;

    var proc_info: win.PROCESS_INFORMATION = undefined;
    if (CreateProcessW(
        null,
        @ptrCast(&cmdline),
        null,
        null,
        win.TRUE,
        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
        null,
        null,
        @ptrCast(&startup.StartupInfo),
        &proc_info,
    ) == 0) {
        try out.print("CreateProcessW failed: {}\n", .{win.GetLastError()});
        try out.flush();
        return error.SpawnFailed;
    }

    try out.print("spawned ping, reading 3s...\n", .{});
    try out.flush();

    const start = std.time.milliTimestamp();
    var total_before: usize = 0;
    var buf: [4096]u8 = undefined;

    while (std.time.milliTimestamp() - start < 3000) {
        var avail: u32 = 0;
        if (PeekNamedPipe(out_read, null, 0, null, &avail, null) == 0) break;
        if (avail == 0) {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        }
        var n: u32 = 0;
        if (ReadFile(out_read, &buf, @min(buf.len, avail), &n, null) == 0) break;
        total_before += n;
    }

    try out.print("read {d} bytes before ^C. writing 0x03...\n", .{total_before});
    try out.flush();

    var written: u32 = 0;
    if (WriteFile(in_write, &[_]u8{0x03}, 1, &written, null) == 0) {
        try out.print("WriteFile failed: {}\n", .{win.GetLastError()});
        try out.flush();
        return error.WriteFailed;
    }

    var tail_buf: [8192]u8 = undefined;
    var tail_len: usize = 0;
    const start2 = std.time.milliTimestamp();
    var exited = false;
    var exit_ms: i64 = -1;

    while (std.time.milliTimestamp() - start2 < 5000) {
        if (WaitForSingleObject(proc_info.hProcess, 0) == 0) {
            exited = true;
            exit_ms = std.time.milliTimestamp() - start2;
            break;
        }
        var avail: u32 = 0;
        if (PeekNamedPipe(out_read, null, 0, null, &avail, null) == 0) break;
        if (avail == 0) {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        }
        var n: u32 = 0;
        if (ReadFile(out_read, &buf, @min(buf.len, avail), &n, null) == 0) break;
        const space = tail_buf.len - tail_len;
        const copy_n = @min(space, n);
        @memcpy(tail_buf[tail_len..][0..copy_n], buf[0..copy_n]);
        tail_len += copy_n;
    }

    try out.print("process exited={} after {d}ms\n", .{ exited, exit_ms });
    try out.print("--- output after ^C ({d} bytes) ---\n", .{tail_len});
    try out.flush();

    for (tail_buf[0..tail_len]) |c| {
        if ((c >= 0x20 and c < 0x7F) or c == '\n' or c == '\r') {
            try out.print("{c}", .{c});
        }
    }
    try out.print("\n--- end ---\n", .{});
    try out.flush();

    ClosePseudoConsole(hpcon);
}
