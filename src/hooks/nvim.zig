/// Neovim hook — detect nvim instances and navigate splits.
///
/// Detection: matches processes where argv[0] contains "nvim" or /proc/<pid>/exe
/// resolves to nvim. Works for both embedded (--embed) and terminal nvim.
///
/// Navigation: connects to nvim's Unix socket ($XDG_RUNTIME_DIR/nvim.<pid>.0),
/// uses msgpack-RPC to query winnr() / winnr('<dir>') and send wincmd commands.
const std = @import("std");
const posix = std.posix;

const Hook = @import("../hook.zig").Hook;
const Direction = @import("../main.zig").Direction;
const msgpack = @import("../msgpack.zig");
const net = @import("../net.zig");

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
    fd: posix.fd_t,
    next_msgid: u32,

    fn connect(socket_path: []const u8, timeout_ms: u32) !NvimClient {
        const addr = net.makeUnixAddr(socket_path) catch return error.ConnectFailed;
        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return error.ConnectFailed;
        errdefer posix.close(fd);

        posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
            return error.ConnectFailed;
        };

        net.setTimeouts(fd, timeout_ms) catch return error.ConnectFailed;

        return .{ .fd = fd, .next_msgid = 0 };
    }

    fn disconnect(self: *NvimClient) void {
        posix.close(self.fd);
    }

    /// Evaluate a vimscript expression via nvim_eval and return the result as u64.
    /// Note: this only handles unsigned integer results. winnr() always returns
    /// a positive integer so this is safe for our use case. Expressions that
    /// return strings or other types will be treated as errors (returns null).
    fn eval(self: *NvimClient, expression: []const u8) ?u64 {
        const msgid = self.next_msgid;
        var req_buf: [256]u8 = undefined;
        const req = msgpack.encodeRequest(&req_buf, msgid, "nvim_eval", expression) catch return null;

        net.writeAll(self.fd, req) catch return null;
        self.next_msgid += 1;

        var resp_buf: [2048]u8 = undefined;
        const resp = readResponse(self.fd, &resp_buf) orelse return null;

        return msgpack.decodeResponse(resp, msgid) catch null;
    }

    fn command(self: *NvimClient, cmd: []const u8) void {
        const msgid = self.next_msgid;
        var req_buf: [256]u8 = undefined;
        const req = msgpack.encodeRequest(&req_buf, msgid, "nvim_command", cmd) catch return;

        net.writeAll(self.fd, req) catch return;
        self.next_msgid += 1;

        // Read and discard response
        var resp_buf: [2048]u8 = undefined;
        _ = readResponse(self.fd, &resp_buf);
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

/// Read a complete msgpack-RPC response from the socket.
/// Reads in a loop to handle fragmented responses on Unix sockets.
fn readResponse(fd: posix.fd_t, buf: []u8) ?[]const u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(fd, buf[total..]) catch return null;
        if (n == 0) return null;
        total += n;

        // A valid msgpack-RPC response starts with fixarray(4) = 0x94.
        // Try to decode what we have — if it's a complete message, return it.
        // If decoding fails due to truncation, read more data.
        if (total >= 5 and buf[0] == 0x94) {
            // Attempt to decode; if successful or the error is not about
            // truncation, we have enough data.
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
    // Buffer full
    if (total > 0) return buf[0..total];
    return null;
}

fn connectToNvim(pid: i32, timeout_ms: u32) ?NvimClient {
    var socket_buf: [256]u8 = undefined;
    const socket_path = nvimSocketPath(&socket_buf, pid) orelse return null;
    return NvimClient.connect(socket_path, timeout_ms) catch null;
}

/// Construct the nvim socket path for a given PID.
/// Format: $XDG_RUNTIME_DIR/nvim.<pid>.0
/// Fallback: $TMPDIR/nvim.$USER/nvim.<pid>.0
fn nvimSocketPath(buf: []u8, pid: i32) ?[]const u8 {
    if (posix.getenv("XDG_RUNTIME_DIR")) |xdg_dir| {
        return std.fmt.bufPrint(buf, "{s}/nvim.{d}.0", .{ xdg_dir, pid }) catch null;
    }

    const tmp_dir = posix.getenv("TMPDIR") orelse "/tmp";
    const user = posix.getenv("USER") orelse "unknown";
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

    // Path must end with /nvim.12345.0 regardless of which env var prefix is used
    try std.testing.expect(std.mem.endsWith(u8, path, "/nvim.12345.0"));

    // Verify the prefix matches the environment
    if (posix.getenv("XDG_RUNTIME_DIR")) |xdg_dir| {
        try std.testing.expect(std.mem.startsWith(u8, path, xdg_dir));
    } else {
        // Fallback path should contain /nvim.<user>/ before the socket name
        const user = posix.getenv("USER") orelse "unknown";
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
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    // Write a valid msgpack-RPC response: [1, 0, nil, 3]
    const response = [_]u8{ 0x94, 0x01, 0x00, 0xc0, 0x03 };
    _ = try posix.write(fds[1], &response);
    posix.close(fds[1]);

    var buf: [2048]u8 = undefined;
    const result = readResponse(fds[0], &buf).?;
    try std.testing.expectEqualSlices(u8, &response, result);
}

test "readResponse returns null on closed pipe" {
    const fds = try posix.pipe();
    posix.close(fds[1]); // close write end immediately
    defer posix.close(fds[0]);

    var buf: [2048]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), readResponse(fds[0], &buf));
}

test "readResponse returns data for non-truncation error" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    // Write a response with wrong msgid — decodeResponse will return UnexpectedMsgId
    // which is not a truncation error, so readResponse should still return the data
    const response = [_]u8{ 0x94, 0x01, 0x05, 0xc0, 0x03 };
    _ = try posix.write(fds[1], &response);
    posix.close(fds[1]);

    var buf: [2048]u8 = undefined;
    const result = readResponse(fds[0], &buf).?;
    try std.testing.expectEqualSlices(u8, &response, result);
}
