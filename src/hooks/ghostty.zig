/// Ghostty hook — stub implementation.
///
/// Detects ghostty terminal processes but does not yet implement split navigation.
/// canMove returns null (treated as "at edge"), so focus bubbles up harmlessly.
const std = @import("std");

const Hook = @import("../hook.zig").Hook;
const Direction = @import("../main.zig").Direction;

pub const hook = Hook{
    .name = "ghostty",
    .detectFn = &detect,
    .canMoveFn = &canMove,
    .moveFocusFn = &moveFocus,
    .moveToEdgeFn = &moveToEdge,
};

fn detect(child_pid: i32, cmd: []const u8, exe: []const u8, _: []const u8) ?i32 {
    if (std.mem.indexOf(u8, cmd, "ghostty") != null or
        std.mem.indexOf(u8, exe, "ghostty") != null)
    {
        return child_pid;
    }
    return null;
}

fn canMove(_: i32, _: Direction, _: u32) ?bool {
    return null; // Not implemented — bubble up
}

fn moveFocus(_: i32, _: Direction, _: u32) void {}

fn moveToEdge(_: i32, _: Direction, _: u32) void {}

test "detect matches ghostty" {
    try std.testing.expectEqual(@as(?i32, 10), detect(10, "ghostty", "", ""));
    try std.testing.expectEqual(@as(?i32, 10), detect(10, "bash", "/usr/bin/ghostty", ""));
}

test "detect rejects non-ghostty" {
    try std.testing.expectEqual(@as(?i32, null), detect(10, "bash", "/usr/bin/bash", ""));
}

test "canMove returns null (stub)" {
    try std.testing.expectEqual(@as(?bool, null), canMove(10, .left, 100));
}
