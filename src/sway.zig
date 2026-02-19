/// Sway/i3 IPC client.
///
/// Implements the i3-ipc binary protocol:
///   Header: "i3-ipc" (6 bytes) + uint32le payload_length + uint32le message_type
///   Payload: JSON (for GET_TREE) or command string (for RUN_COMMAND)
const std = @import("std");
const posix = std.posix;

const Direction = @import("main.zig").Direction;
const net = @import("net.zig");

const ipc_magic = "i3-ipc";
const header_size = 14; // 6 (magic) + 4 (length) + 4 (type)

const MsgType = enum(u32) {
    run_command = 0,
    get_tree = 4,
};

const IpcHeader = extern struct {
    magic: [6]u8 align(1),
    length: u32 align(1),
    msg_type: u32 align(1),
};

pub const SwayError = error{
    ConnectFailed,
    WriteFailed,
    ReadFailed,
    InvalidHeader,
    ParseFailed,
    SocketPathTooLong,
};

pub const Sway = struct {
    fd: posix.fd_t,

    pub fn connect(socket_path: []const u8) !Sway {
        const addr = try net.makeUnixAddr(socket_path);
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);
        posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
            return SwayError.ConnectFailed;
        };
        return .{ .fd = fd };
    }

    pub fn disconnect(self: *Sway) void {
        posix.close(self.fd);
    }

    /// Send GET_TREE and find the PID of the focused window.
    /// Returns null if no focused window found or on parse error.
    pub fn getFocusedPid(self: *Sway) ?i32 {
        const tree_json = self.getTree() orelse return null;
        defer std.heap.page_allocator.free(tree_json);

        // Use an arena allocator wrapping page_allocator to reduce syscall
        // overhead from the many small allocations during JSON parsing.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), tree_json, .{ .allocate = .alloc_always }) catch return null;
        defer parsed.deinit();

        return findFocusedPidInTree(parsed.value);
    }

    /// Send a focus command in the given direction.
    pub fn moveFocus(self: *Sway, direction: Direction) void {
        const cmd = switch (direction) {
            .left => "focus left",
            .right => "focus right",
            .up => "focus up",
            .down => "focus down",
        };
        self.runCommand(cmd);
    }

    fn getTree(self: *Sway) ?[]u8 {
        var hdr = IpcHeader{
            .magic = ipc_magic.*,
            .length = 0,
            .msg_type = @intFromEnum(MsgType.get_tree),
        };
        const hdr_bytes: *[header_size]u8 = @ptrCast(&hdr);
        _ = net.writeAll(self.fd, hdr_bytes) catch return null;

        var resp_hdr_bytes: [header_size]u8 = undefined;
        net.readExact(self.fd, &resp_hdr_bytes) catch return null;

        const resp_hdr: *const IpcHeader = @ptrCast(@alignCast(&resp_hdr_bytes));
        if (!std.mem.eql(u8, &resp_hdr.magic, ipc_magic)) return null;

        const payload_len = resp_hdr.length;
        if (payload_len == 0) return null;

        const payload = std.heap.page_allocator.alloc(u8, payload_len) catch return null;

        net.readExact(self.fd, payload) catch {
            std.heap.page_allocator.free(payload);
            return null;
        };

        return payload;
    }

    fn runCommand(self: *Sway, cmd: []const u8) void {
        var hdr = IpcHeader{
            .magic = ipc_magic.*,
            .length = @intCast(cmd.len),
            .msg_type = @intFromEnum(MsgType.run_command),
        };
        const hdr_bytes: *[header_size]u8 = @ptrCast(&hdr);
        _ = net.writeAll(self.fd, hdr_bytes) catch return;
        _ = net.writeAll(self.fd, cmd) catch return;

        var resp_hdr_bytes: [header_size]u8 = undefined;
        net.readExact(self.fd, &resp_hdr_bytes) catch return;

        const resp_hdr: *const IpcHeader = @ptrCast(@alignCast(&resp_hdr_bytes));
        const payload_len = resp_hdr.length;
        if (payload_len > 0) {
            var discard_buf: [4096]u8 = undefined;
            var remaining: usize = payload_len;
            while (remaining > 0) {
                const to_read = @min(remaining, discard_buf.len);
                const n = posix.read(self.fd, discard_buf[0..to_read]) catch return;
                if (n == 0) return;
                remaining -= n;
            }
        }
    }
};

/// Recursively find the PID of the focused node in the sway tree.
/// Traverses both "nodes" and "floating_nodes".
fn findFocusedPidInTree(node: std.json.Value) ?i32 {
    const obj = switch (node) {
        .object => |o| o,
        else => return null,
    };

    if (obj.get("focused")) |focused_val| {
        if (focused_val == .bool and focused_val.bool) {
            if (obj.get("pid")) |pid_val| {
                switch (pid_val) {
                    .integer => |i| return @intCast(i),
                    else => {},
                }
            }
        }
    }

    if (obj.get("nodes")) |nodes_val| {
        if (nodes_val == .array) {
            for (nodes_val.array.items) |child| {
                if (findFocusedPidInTree(child)) |pid| return pid;
            }
        }
    }

    if (obj.get("floating_nodes")) |floating_val| {
        if (floating_val == .array) {
            for (floating_val.array.items) |child| {
                if (findFocusedPidInTree(child)) |pid| return pid;
            }
        }
    }

    return null;
}

// ─── Tests ───

const testing = std.testing;

/// Helper to create a json object with focused/pid/nodes/floating_nodes fields.
fn makeNode(
    alloc: std.mem.Allocator,
    focused: bool,
    pid: ?i64,
    nodes: ?[]const std.json.Value,
    floating_nodes: ?[]const std.json.Value,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(alloc);
    try obj.put("focused", .{ .bool = focused });
    if (pid) |p| {
        try obj.put("pid", .{ .integer = p });
    }
    if (nodes) |n| {
        var arr = std.json.Array.init(alloc);
        for (n) |child| try arr.append(child);
        try obj.put("nodes", .{ .array = arr });
    }
    if (floating_nodes) |n| {
        var arr = std.json.Array.init(alloc);
        for (n) |child| try arr.append(child);
        try obj.put("floating_nodes", .{ .array = arr });
    }
    return .{ .object = obj };
}

test "findFocusedPidInTree returns pid for focused leaf" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const node = try makeNode(alloc, true, 42, null, null);
    try testing.expectEqual(@as(?i32, 42), findFocusedPidInTree(node));
}

test "findFocusedPidInTree returns null for unfocused leaf" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const node = try makeNode(alloc, false, 42, null, null);
    try testing.expectEqual(@as(?i32, null), findFocusedPidInTree(node));
}

test "findFocusedPidInTree returns null for focused node without pid" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const node = try makeNode(alloc, true, null, null, null);
    try testing.expectEqual(@as(?i32, null), findFocusedPidInTree(node));
}

test "findFocusedPidInTree recurses into nodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const child = try makeNode(alloc, true, 99, null, null);
    const unfocused_child = try makeNode(alloc, false, 10, null, null);
    const root = try makeNode(alloc, false, 1, &.{ unfocused_child, child }, null);
    try testing.expectEqual(@as(?i32, 99), findFocusedPidInTree(root));
}

test "findFocusedPidInTree recurses into floating_nodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const floating_child = try makeNode(alloc, true, 77, null, null);
    const root = try makeNode(alloc, false, 1, null, &.{floating_child});
    try testing.expectEqual(@as(?i32, 77), findFocusedPidInTree(root));
}

test "findFocusedPidInTree returns null when no node focused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const child1 = try makeNode(alloc, false, 10, null, null);
    const child2 = try makeNode(alloc, false, 20, null, null);
    const root = try makeNode(alloc, false, 1, &.{ child1, child2 }, null);
    try testing.expectEqual(@as(?i32, null), findFocusedPidInTree(root));
}

test "findFocusedPidInTree returns null for non-object input" {
    try testing.expectEqual(@as(?i32, null), findFocusedPidInTree(.null));
    try testing.expectEqual(@as(?i32, null), findFocusedPidInTree(.{ .integer = 42 }));
    try testing.expectEqual(@as(?i32, null), findFocusedPidInTree(.{ .bool = true }));
}

test "findFocusedPidInTree finds deeply nested focused node" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const deep = try makeNode(alloc, true, 555, null, null);
    const mid = try makeNode(alloc, false, 2, &.{deep}, null);
    const root = try makeNode(alloc, false, 1, &.{mid}, null);
    try testing.expectEqual(@as(?i32, 555), findFocusedPidInTree(root));
}
