/// Shared networking utilities for Unix socket communication.
const std = @import("std");
const posix = std.posix;

pub fn makeUnixAddr(path: []const u8) !posix.sockaddr.un {
    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    if (path.len >= addr.path.len) return error.SocketPathTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

pub fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const n = posix.write(fd, data[written..]) catch return error.WriteFailed;
        if (n == 0) return error.WriteFailed;
        written += n;
    }
}

pub fn readExact(fd: posix.fd_t, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(fd, buf[total..]) catch return error.ReadFailed;
        if (n == 0) return error.ReadFailed;
        total += n;
    }
}

/// Set both send and receive timeouts on a socket.
pub fn setTimeouts(fd: posix.fd_t, timeout_ms: u32) !void {
    if (timeout_ms == 0) return;
    const tv = posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    const tv_bytes = std.mem.asBytes(&tv);
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, tv_bytes) catch return error.SetOptFailed;
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, tv_bytes) catch return error.SetOptFailed;
}

test "makeUnixAddr sets path correctly" {
    const addr = try makeUnixAddr("/tmp/test.sock");
    const expected = "/tmp/test.sock";
    try std.testing.expectEqualStrings(expected, addr.path[0..expected.len]);
    try std.testing.expectEqual(@as(u8, 0), addr.path[expected.len]);
}

test "makeUnixAddr rejects too-long path" {
    const long_path = "a" ** 200;
    try std.testing.expectError(error.SocketPathTooLong, makeUnixAddr(long_path));
}
