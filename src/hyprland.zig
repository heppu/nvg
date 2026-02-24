/// Hyprland IPC client.
///
/// Uses the hyprctl-style socket protocol:
///   Socket: $XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock
///   Request: UTF-8 string, e.g. "j/activewindow" or "dispatch movefocus l"
///   Response: JSON (with j/ prefix) or plain text
///
/// Each IPC call opens a fresh connection because Hyprland processes socket1
/// requests synchronously — an unclosed connection freezes the compositor.
///
/// This backend implements the WindowManager interface, so it can be used
/// interchangeably with other window manager backends.
const std = @import("std");
const posix = std.posix;

const Direction = @import("main.zig").Direction;
const wm = @import("wm.zig");
const net = @import("net.zig");
const log = @import("log.zig");

pub const HyprlandError = error{
    ConnectFailed,
    WriteFailed,
    ReadFailed,
    ParseFailed,
    SocketPathTooLong,
    NoSocketPath,
};

pub const Hyprland = struct {
    /// WindowManager vtable — must be the first field so that
    /// @fieldParentPtr can recover the Hyprland from a *WindowManager.
    wm: wm.WindowManager = .{
        .getFocusedPidFn = wmGetFocusedPid,
        .moveFocusFn = wmMoveFocus,
        .disconnectFn = wmDisconnect,
    },
    socket_path: [posix.PATH_MAX]u8,
    socket_path_len: usize,

    /// Build a Hyprland backend from the environment.
    /// Does not open a persistent connection — each IPC call connects anew.
    pub fn connect() !Hyprland {
        const his = posix.getenv("HYPRLAND_INSTANCE_SIGNATURE") orelse return HyprlandError.NoSocketPath;
        const xdg = posix.getenv("XDG_RUNTIME_DIR") orelse return HyprlandError.NoSocketPath;

        var path_buf: [posix.PATH_MAX]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/hypr/{s}/.socket.sock", .{ xdg, his }) catch {
            return HyprlandError.SocketPathTooLong;
        };

        var result = Hyprland{
            .socket_path = undefined,
            .socket_path_len = path.len,
        };
        @memcpy(result.socket_path[0..path.len], path);
        return result;
    }

    pub fn disconnect(_: *Hyprland) void {
        // No persistent connection to close.
    }

    /// Query the active window and return its PID.
    /// Returns null if no window is focused or on any error.
    pub fn getFocusedPid(self: *Hyprland) ?i32 {
        var buf: [4096]u8 = undefined;
        const response = self.ipcRequest("j/activewindow", &buf) orelse return null;
        return parsePidFromActiveWindow(response);
    }

    /// Dispatch a movefocus command in the given direction.
    pub fn moveFocus(self: *Hyprland, direction: Direction) void {
        const cmd = switch (direction) {
            .left => "dispatch movefocus l",
            .right => "dispatch movefocus r",
            .up => "dispatch movefocus u",
            .down => "dispatch movefocus d",
        };
        var discard: [256]u8 = undefined;
        _ = self.ipcRequest(cmd, &discard);
    }

    /// Open a fresh connection, send a request, read the response, close.
    fn ipcRequest(self: *Hyprland, request: []const u8, buf: []u8) ?[]const u8 {
        const path = self.socket_path[0..self.socket_path_len];
        const addr = net.makeUnixAddr(path) catch return null;
        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return null;
        defer posix.close(fd);

        posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch return null;

        net.writeAll(fd, request) catch return null;

        // Shut down the write side so Hyprland knows the request is complete.
        posix.shutdown(fd, .send) catch return null;

        // Read response into buffer.
        var total: usize = 0;
        while (total < buf.len) {
            const n = posix.read(fd, buf[total..]) catch return null;
            if (n == 0) break;
            total += n;
        }

        if (total == 0) return null;
        return buf[0..total];
    }

    // ─── WindowManager vtable functions ───

    fn wmGetFocusedPid(wm_ptr: *wm.WindowManager) ?i32 {
        const self: *Hyprland = @fieldParentPtr("wm", wm_ptr);
        return self.getFocusedPid();
    }

    fn wmMoveFocus(wm_ptr: *wm.WindowManager, direction: Direction) void {
        const self: *Hyprland = @fieldParentPtr("wm", wm_ptr);
        self.moveFocus(direction);
    }

    fn wmDisconnect(wm_ptr: *wm.WindowManager) void {
        const self: *Hyprland = @fieldParentPtr("wm", wm_ptr);
        self.disconnect();
    }
};

/// Parse the "pid" field from a Hyprland `j/activewindow` JSON response.
/// Returns null if the response cannot be parsed or pid is missing/zero.
///
/// Hyprland returns pid:0 when no window is focused (e.g. on an empty
/// workspace), so we treat 0 as "no focused window".
fn parsePidFromActiveWindow(data: []const u8) ?i32 {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        std.heap.page_allocator,
        data,
        .{ .allocate = .alloc_always },
    ) catch return null;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };

    const pid_val = obj.get("pid") orelse return null;
    const pid: i32 = switch (pid_val) {
        .integer => |i| @intCast(i),
        else => return null,
    };

    // Hyprland returns pid:0 when no window is focused.
    if (pid <= 0) return null;
    return pid;
}

// ─── Tests ───

const testing = std.testing;

test "parsePidFromActiveWindow extracts pid" {
    const json =
        \\{"address":"0x1234","mapped":true,"hidden":false,"at":[0,0],"size":[100,100],"workspace":{"id":1,"name":"1"},"floating":false,"pseudo":false,"monitor":0,"class":"kitty","title":"~","initialClass":"kitty","initialTitle":"~","pid":12345,"xwayland":false,"pinned":false,"fullscreen":0,"fullscreenClient":0,"grouped":[],"tags":[],"swallowing":"0x0","focusHistoryID":0}
    ;
    try testing.expectEqual(@as(?i32, 12345), parsePidFromActiveWindow(json));
}

test "parsePidFromActiveWindow returns null for pid zero" {
    const json =
        \\{"address":"0x0","pid":0,"class":"","title":""}
    ;
    try testing.expectEqual(@as(?i32, null), parsePidFromActiveWindow(json));
}

test "parsePidFromActiveWindow returns null for empty object" {
    try testing.expectEqual(@as(?i32, null), parsePidFromActiveWindow("{}"));
}

test "parsePidFromActiveWindow returns null for invalid json" {
    try testing.expectEqual(@as(?i32, null), parsePidFromActiveWindow("not json"));
}

test "parsePidFromActiveWindow returns null for non-object json" {
    try testing.expectEqual(@as(?i32, null), parsePidFromActiveWindow("42"));
    try testing.expectEqual(@as(?i32, null), parsePidFromActiveWindow("[]"));
}

test "parsePidFromActiveWindow returns null for pid as string" {
    const json =
        \\{"pid":"12345"}
    ;
    try testing.expectEqual(@as(?i32, null), parsePidFromActiveWindow(json));
}
