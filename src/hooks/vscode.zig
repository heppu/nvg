/// VS Code hook — stub implementation.
///
/// Detects VS Code processes but does not yet implement editor group navigation.
/// canMove returns null (treated as "at edge"), so focus bubbles up harmlessly.
const std = @import("std");

const Hook = @import("../hook.zig").Hook;
const Direction = @import("../main.zig").Direction;

pub const hook = Hook{
    .name = "vscode",
    .detectFn = &detect,
    .canMoveFn = &canMove,
    .moveFocusFn = &moveFocus,
    .moveToEdgeFn = &moveToEdge,
};

fn detect(child_pid: i32, cmd: []const u8, exe: []const u8, _: []const u8) ?i32 {
    // VS Code binary is typically "code" or "code-oss".
    // Use basename matching to avoid false positives from substrings
    // like "barcode", "encode", "unicode", etc.
    if (isVsCodeBinary(cmd) or isVsCodeBinary(exe) or
        isVsCodeBinary(basename(cmd)) or isVsCodeBinary(basename(exe)))
    {
        return child_pid;
    }
    return null;
}

fn isVsCodeBinary(name: []const u8) bool {
    return std.mem.eql(u8, name, "code") or
        std.mem.eql(u8, name, "code-oss");
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| {
        return path[pos + 1 ..];
    }
    return path;
}

fn canMove(_: i32, _: Direction, _: u32) ?bool {
    return null; // Not implemented — bubble up
}

fn moveFocus(_: i32, _: Direction, _: u32) void {}

fn moveToEdge(_: i32, _: Direction, _: u32) void {}

test "detect matches code" {
    try std.testing.expectEqual(@as(?i32, 10), detect(10, "code", "", ""));
    try std.testing.expectEqual(@as(?i32, 10), detect(10, "code-oss", "", ""));
    try std.testing.expectEqual(@as(?i32, 10), detect(10, "bash", "/usr/bin/code", ""));
    try std.testing.expectEqual(@as(?i32, 10), detect(10, "bash", "/usr/bin/code-oss", ""));
}

test "detect rejects non-vscode" {
    try std.testing.expectEqual(@as(?i32, null), detect(10, "bash", "/usr/bin/bash", ""));
}

test "detect rejects substring matches" {
    try std.testing.expectEqual(@as(?i32, null), detect(10, "barcode", "", ""));
    try std.testing.expectEqual(@as(?i32, null), detect(10, "encode", "", ""));
    try std.testing.expectEqual(@as(?i32, null), detect(10, "bash", "/usr/bin/unicode", ""));
}

test "canMove returns null (stub)" {
    try std.testing.expectEqual(@as(?bool, null), canMove(10, .left, 100));
}
