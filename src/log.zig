/// Debug logging for sway-focus.
///
/// Enabled by setting the SWAY_FOCUS_DEBUG=1 environment variable.
/// Logs to stderr to avoid interfering with normal operation.
const std = @import("std");
const posix = std.posix;

var debug_enabled: ?bool = null;

pub fn isEnabled() bool {
    if (debug_enabled) |enabled| return enabled;
    const val = posix.getenv("SWAY_FOCUS_DEBUG") orelse {
        debug_enabled = false;
        return false;
    };
    debug_enabled = std.mem.eql(u8, val, "1");
    return debug_enabled.?;
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (!isEnabled()) return;
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[sway-focus] " ++ fmt ++ "\n", args) catch return;
    std.fs.File.stderr().writeAll(msg) catch {};
}

test "log does not crash when disabled" {
    debug_enabled = false;
    log("test {s}", .{"message"});
}

test "isEnabled returns cached false" {
    debug_enabled = false;
    try std.testing.expect(!isEnabled());
}

test "isEnabled returns cached true" {
    debug_enabled = true;
    defer debug_enabled = false;
    try std.testing.expect(isEnabled());
}

test "log does not crash when enabled" {
    debug_enabled = true;
    defer debug_enabled = false;
    // This writes to stderr but should not crash
    log("test {s} {d}", .{ "enabled", @as(u32, 42) });
}
