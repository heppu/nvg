/// Neovim hook — detect nvim instances and navigate splits.
///
/// Detection: matches processes where argv[0] contains "nvim" or the
/// resolved executable path contains nvim. Works for both embedded
/// (--embed) and terminal nvim.
///
/// Navigation: connects to nvim's RPC transport — a Unix socket on Linux
/// ($XDG_RUNTIME_DIR/nvim.<pid>.0) or a named pipe on Windows
/// (\\.\pipe\nvim.<pid>.0). Uses msgpack-RPC to query winnr() / winnr('<dir>')
/// and send wincmd commands.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const Hook = @import("../hook.zig").Hook;
const Direction = @import("../direction.zig").Direction;
const msgpack = @import("../msgpack.zig");
const net = @import("../net.zig");
const platform = @import("../platform.zig");

const nvim_move_max: u32 = 999;

pub const hook = Hook{
    .name = "nvim",
    .detectFn = &detect,
    .canMoveFn = &canMove,
    .moveFocusFn = &moveFocus,
    .moveToEdgeFn = &moveToEdge,
};

/// Detect an nvim process.
/// Returns child_pid if matched, null otherwise.
fn detect(child_pid: i32, cmd: []const u8, exe: []const u8, _: []const u8) ?i32 {
    const is_nvim = std.mem.indexOf(u8, cmd, "nvim") != null or
        std.mem.indexOf(u8, exe, "nvim") != null;
    if (!is_nvim) return null;

    return child_pid;
}

/// Check if nvim can move focus in the given direction (not at edge).
/// Returns true if winnr() != winnr('<dir>'), false if at edge, null on error.
fn canMove(pid: i32, dir: Direction, timeout_ms: u32) ?bool {
    var nvim = connectToNvim(pid, timeout_ms) orelse return null;
    defer nvim.disconnect();

    const current = nvim.getFocus() orelse return null;
    const next = nvim.getNextFocus(dir) orelse return null;

    return current != next;
}

/// Move nvim focus one step in the given direction.
fn moveFocus(pid: i32, dir: Direction, timeout_ms: u32) void {
    var nvim = connectToNvim(pid, timeout_ms) orelse return;
    defer nvim.disconnect();
    nvim.moveFocus(dir, 1);
}

/// Move nvim focus to the edge in the given direction (wincmd 999 <key>).
/// Called after sway moves window focus — moves to the split closest to
/// where the user came from.
fn moveToEdge(pid: i32, dir: Direction, timeout_ms: u32) void {
    var nvim = connectToNvim(pid, timeout_ms) orelse return;
    defer nvim.disconnect();
    nvim.moveFocus(dir, nvim_move_max);
}

// ─── Nvim RPC client (internal) ───

const NvimClient = struct {
    transport: Transport,
    next_msgid: u32,

    fn connect(socket_path: []const u8, timeout_ms: u32) !NvimClient {
        const t = try Transport.connect(socket_path, timeout_ms);
        return .{ .transport = t, .next_msgid = 0 };
    }

    fn disconnect(self: *NvimClient) void {
        self.transport.disconnect();
    }

    /// Evaluate a vimscript expression via nvim_eval and return the result as u64.
    /// Note: this only handles unsigned integer results. winnr() always returns
    /// a positive integer so this is safe for our use case. Expressions that
    /// return strings or other types will be treated as errors (returns null).
    fn eval(self: *NvimClient, expression: []const u8) ?u64 {
        const msgid = self.next_msgid;
        var req_buf: [256]u8 = undefined;
        const req = msgpack.encodeRequest(&req_buf, msgid, "nvim_eval", expression) catch return null;

        self.transport.writeAll(req) catch return null;
        self.next_msgid += 1;

        var resp_buf: [2048]u8 = undefined;
        const resp = readResponse(&self.transport, &resp_buf) orelse return null;

        return msgpack.decodeResponse(resp, msgid) catch null;
    }

    fn command(self: *NvimClient, cmd: []const u8) void {
        const msgid = self.next_msgid;
        var req_buf: [256]u8 = undefined;
        const req = msgpack.encodeRequest(&req_buf, msgid, "nvim_command", cmd) catch return;

        self.transport.writeAll(req) catch return;
        self.next_msgid += 1;

        // Read and discard response
        var resp_buf: [2048]u8 = undefined;
        _ = readResponse(&self.transport, &resp_buf);
    }

    fn getFocus(self: *NvimClient) ?u64 {
        return self.eval("winnr()");
    }

    fn getNextFocus(self: *NvimClient, direction: Direction) ?u64 {
        var expr_buf: [16]u8 = undefined;
        const expr = std.fmt.bufPrint(&expr_buf, "winnr('{c}')", .{direction.toVimKey()}) catch return null;
        return self.eval(expr);
    }

    fn moveFocus(self: *NvimClient, direction: Direction, count: u32) void {
        var cmd_buf: [32]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "wincmd {d} {c}", .{ count, direction.toVimKey() }) catch return;
        self.command(cmd);
    }
};

// ─── Transports ───
//
// Linux: Unix socket via std.posix.
// Windows: named pipe via CreateFileW + ReadFile/WriteFile.

const Transport = if (builtin.os.tag == .windows) WindowsPipeTransport else UnixSocketTransport;

const UnixSocketTransport = struct {
    fd: posix.fd_t,

    fn connect(socket_path: []const u8, timeout_ms: u32) !UnixSocketTransport {
        const addr = net.makeUnixAddr(socket_path) catch return error.ConnectFailed;
        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return error.ConnectFailed;
        errdefer posix.close(fd);

        posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
            return error.ConnectFailed;
        };

        net.setTimeouts(fd, timeout_ms) catch return error.ConnectFailed;

        return .{ .fd = fd };
    }

    fn disconnect(self: *UnixSocketTransport) void {
        posix.close(self.fd);
    }

    fn writeAll(self: *UnixSocketTransport, data: []const u8) !void {
        return net.writeAll(self.fd, data);
    }

    fn read(self: *UnixSocketTransport, buf: []u8) !usize {
        return posix.read(self.fd, buf);
    }
};

const WindowsPipeTransport = struct {
    handle: if (builtin.os.tag == .windows) std.os.windows.HANDLE else void,

    const w = std.os.windows;
    const GENERIC_READ: u32 = 0x80000000;
    const GENERIC_WRITE: u32 = 0x40000000;
    const OPEN_EXISTING: u32 = 3;
    const INVALID_HANDLE_VALUE: w.HANDLE = @ptrFromInt(@as(usize, std.math.maxInt(usize)));

    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?w.HANDLE,
    ) callconv(.winapi) w.HANDLE;

    extern "kernel32" fn ReadFile(
        hFile: w.HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: u32,
        lpNumberOfBytesRead: *u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) w.BOOL;

    extern "kernel32" fn WriteFile(
        hFile: w.HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: u32,
        lpNumberOfBytesWritten: *u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) w.BOOL;

    extern "kernel32" fn CloseHandle(hObject: w.HANDLE) callconv(.winapi) w.BOOL;

    fn connect(pipe_path: []const u8, timeout_ms: u32) !WindowsPipeTransport {
        // Read timeouts on named pipes can be set via SetNamedPipeHandleState,
        // but a non-responsive nvim hangs us anyway; for the common case
        // (nvim alive and responsive) the OS round-trip is sub-millisecond.
        _ = timeout_ms;

        if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;

        // Convert pipe_path to WTF-16 NUL-terminated.
        var wide: [512]u16 = undefined;
        const wide_len = std.unicode.wtf8ToWtf16Le(&wide, pipe_path) catch return error.ConnectFailed;
        if (wide_len + 1 > wide.len) return error.ConnectFailed;
        wide[wide_len] = 0;
        const wide_z: [*:0]const u16 = @ptrCast(&wide);

        const handle = CreateFileW(
            wide_z,
            GENERIC_READ | GENERIC_WRITE,
            0,
            null,
            OPEN_EXISTING,
            0,
            null,
        );
        if (handle == INVALID_HANDLE_VALUE) return error.ConnectFailed;

        return .{ .handle = handle };
    }

    fn disconnect(self: *WindowsPipeTransport) void {
        if (comptime builtin.os.tag != .windows) return;
        _ = CloseHandle(self.handle);
    }

    fn writeAll(self: *WindowsPipeTransport, data: []const u8) !void {
        if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
        var written_total: usize = 0;
        while (written_total < data.len) {
            var n: u32 = 0;
            const remaining = data[written_total..];
            const chunk: u32 = if (remaining.len > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(remaining.len);
            const ok = WriteFile(self.handle, remaining.ptr, chunk, &n, null);
            if (ok == 0 or n == 0) return error.WriteFailed;
            written_total += n;
        }
    }

    fn read(self: *WindowsPipeTransport, buf: []u8) !usize {
        if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
        var n: u32 = 0;
        const chunk: u32 = if (buf.len > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(buf.len);
        const ok = ReadFile(self.handle, buf.ptr, chunk, &n, null);
        if (ok == 0) return error.ReadFailed;
        return n;
    }
};

/// Read a complete msgpack-RPC response from the transport.
/// Reads in a loop to handle fragmented responses.
fn readResponse(transport: *Transport, buf: []u8) ?[]const u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = transport.read(buf[total..]) catch return null;
        if (n == 0) return null;
        total += n;

        // A valid msgpack-RPC response starts with fixarray(4) = 0x94.
        // Try to decode what we have — if it's a complete message, return it.
        // If decoding fails due to truncation, read more data.
        if (total >= 5 and buf[0] == 0x94) {
            if (msgpack.decodeResponse(buf[0..total], 0)) |_| {
                return buf[0..total];
            } else |err| {
                if (err == msgpack.Error.ResponseTooShort) continue;
                // For other errors (wrong msgid, nvim error, etc.) we still
                // have the complete response — let the caller handle the error.
                return buf[0..total];
            }
        }
    }
    if (total > 0) return buf[0..total];
    return null;
}

fn connectToNvim(pid: i32, timeout_ms: u32) ?NvimClient {
    var socket_buf: [256]u8 = undefined;
    const socket_path = nvimSocketPath(&socket_buf, pid) orelse return null;
    return NvimClient.connect(socket_path, timeout_ms) catch null;
}

/// Construct the nvim RPC socket/pipe path for a given PID.
///
/// Linux: $XDG_RUNTIME_DIR/nvim.<pid>.0 (fallback $TMPDIR/nvim.$USER/nvim.<pid>.0).
/// Windows: \\.\pipe\nvim.<pid>.0 — the default Nvim listen address when
/// started without --listen.
fn nvimSocketPath(buf: []u8, pid: i32) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) {
        return std.fmt.bufPrint(buf, "\\\\.\\pipe\\nvim.{d}.0", .{pid}) catch null;
    }

    if (platform.getenv("XDG_RUNTIME_DIR")) |xdg_dir| {
        return std.fmt.bufPrint(buf, "{s}/nvim.{d}.0", .{ xdg_dir, pid }) catch null;
    }

    const tmp_dir = platform.getenv("TMPDIR") orelse "/tmp";
    const user = platform.getenv("USER") orelse "unknown";
    return std.fmt.bufPrint(buf, "{s}/nvim.{s}/nvim.{d}.0", .{ tmp_dir, user, pid }) catch null;
}

// ─── Tests ───

test "detect matches nvim" {
    try std.testing.expectEqual(@as(?i32, 42), detect(42, "nvim", "", ""));
    try std.testing.expectEqual(@as(?i32, 42), detect(42, "nvim", "", "--embed"));
    try std.testing.expectEqual(@as(?i32, 42), detect(42, "vi", "/usr/bin/nvim", "--embed"));
    try std.testing.expectEqual(@as(?i32, 42), detect(42, "nvim", "", "file.txt"));
    try std.testing.expectEqual(@as(?i32, 42), detect(42, "vi", "/usr/bin/nvim", ""));
}

test "detect rejects non-nvim" {
    try std.testing.expectEqual(@as(?i32, null), detect(42, "bash", "/usr/bin/bash", ""));
    try std.testing.expectEqual(@as(?i32, null), detect(42, "vim", "/usr/bin/vim", ""));
}

test "nvimSocketPath returns path with pid" {
    var buf: [256]u8 = undefined;
    const path = nvimSocketPath(&buf, 12345).?;

    if (comptime builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("\\\\.\\pipe\\nvim.12345.0", path);
        return;
    }

    try std.testing.expect(std.mem.endsWith(u8, path, "/nvim.12345.0"));
    if (platform.getenv("XDG_RUNTIME_DIR")) |xdg_dir| {
        try std.testing.expect(std.mem.startsWith(u8, path, xdg_dir));
    } else {
        const user = platform.getenv("USER") orelse "unknown";
        var expected_buf: [128]u8 = undefined;
        const suffix = std.fmt.bufPrint(&expected_buf, "/nvim.{s}/nvim.12345.0", .{user}) catch unreachable;
        try std.testing.expect(std.mem.endsWith(u8, path, suffix));
    }
}

test "nvimSocketPath returns null for buffer too small" {
    var tiny_buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), nvimSocketPath(&tiny_buf, 12345));
}

test "readResponse reads complete response from pipe" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    // Write a valid msgpack-RPC response: [1, 0, nil, 3]
    const response = [_]u8{ 0x94, 0x01, 0x00, 0xc0, 0x03 };
    _ = try posix.write(fds[1], &response);
    posix.close(fds[1]);

    var transport = UnixSocketTransport{ .fd = fds[0] };
    var buf: [2048]u8 = undefined;
    const result = readResponse(&transport, &buf).?;
    try std.testing.expectEqualSlices(u8, &response, result);
}

test "readResponse returns null on closed pipe" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try posix.pipe();
    posix.close(fds[1]); // close write end immediately
    defer posix.close(fds[0]);

    var transport = UnixSocketTransport{ .fd = fds[0] };
    var buf: [2048]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), readResponse(&transport, &buf));
}

test "readResponse returns data for non-truncation error" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    // Write a response with wrong msgid — decodeResponse will return UnexpectedMsgId
    // which is not a truncation error, so readResponse should still return the data
    const response = [_]u8{ 0x94, 0x01, 0x05, 0xc0, 0x03 };
    _ = try posix.write(fds[1], &response);
    posix.close(fds[1]);

    var transport = UnixSocketTransport{ .fd = fds[0] };
    var buf: [2048]u8 = undefined;
    const result = readResponse(&transport, &buf).?;
    try std.testing.expectEqualSlices(u8, &response, result);
}
