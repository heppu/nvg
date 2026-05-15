/// Cardinal direction shared across the codebase.
///
/// Lives in its own module to break the implicit dependency where every
/// other module imports it from main.zig.
const std = @import("std");

pub const Direction = enum {
    left,
    right,
    up,
    down,

    pub fn toVimKey(self: Direction) u8 {
        return switch (self) {
            .left => 'h',
            .right => 'l',
            .up => 'k',
            .down => 'j',
        };
    }

    pub fn opposite(self: Direction) Direction {
        return switch (self) {
            .left => .right,
            .right => .left,
            .up => .down,
            .down => .up,
        };
    }

    pub fn fromString(s: []const u8) ?Direction {
        if (std.mem.eql(u8, s, "left")) return .left;
        if (std.mem.eql(u8, s, "right")) return .right;
        if (std.mem.eql(u8, s, "up")) return .up;
        if (std.mem.eql(u8, s, "down")) return .down;
        return null;
    }
};

test "Direction.toVimKey" {
    try std.testing.expectEqual(@as(u8, 'h'), Direction.left.toVimKey());
    try std.testing.expectEqual(@as(u8, 'l'), Direction.right.toVimKey());
    try std.testing.expectEqual(@as(u8, 'k'), Direction.up.toVimKey());
    try std.testing.expectEqual(@as(u8, 'j'), Direction.down.toVimKey());
}

test "Direction.opposite" {
    try std.testing.expectEqual(Direction.right, Direction.left.opposite());
    try std.testing.expectEqual(Direction.left, Direction.right.opposite());
    try std.testing.expectEqual(Direction.down, Direction.up.opposite());
    try std.testing.expectEqual(Direction.up, Direction.down.opposite());
}

test "Direction.fromString" {
    try std.testing.expectEqual(Direction.left, Direction.fromString("left").?);
    try std.testing.expectEqual(Direction.right, Direction.fromString("right").?);
    try std.testing.expectEqual(Direction.up, Direction.fromString("up").?);
    try std.testing.expectEqual(Direction.down, Direction.fromString("down").?);
    try std.testing.expectEqual(@as(?Direction, null), Direction.fromString("invalid"));
}
