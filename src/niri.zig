/// Niri IPC client.
///
/// Uses the niri JSON-over-Unix-socket protocol:
///   Socket: $NIRI_SOCKET
///   Request: JSON string terminated by newline
///   Response: JSON string terminated by newline
///
/// Responses are wrapped in a Result envelope:
///   Success: {"Ok": <response_variant>}
///   Error:   {"Err": "error message"}
///
/// Each IPC call opens a fresh connection to avoid stale connection issues.
///
/// This backend implements the WindowManager interface, so it can be used
/// interchangeably with other window manager backends.
const std = @import("std");
const posix = std.posix;

const Direction = @import("main.zig").Direction;
const wm = @import("wm.zig");
const net = @import("net.zig");
const log = @import("log.zig");

pub const NiriError = error{
    ConnectFailed,
    WriteFailed,
    ReadFailed,
    ParseFailed,
    SocketPathTooLong,
    NoSocketPath,
};

pub const Niri = struct {
    /// WindowManager vtable — must be the first field so that
    /// @fieldParentPtr can recover the Niri from a *WindowManager.
    wm: wm.WindowManager = .{
        .getFocusedPidFn = wmGetFocusedPid,
        .moveFocusFn = wmMoveFocus,
        .disconnectFn = wmDisconnect,
    },
    socket_path: [posix.PATH_MAX]u8,
    socket_path_len: usize,

    /// Build a Niri backend from the environment.
    /// Does not open a persistent connection — each IPC call connects anew.
    pub fn connect() !Niri {
        const path = posix.getenv("NIRI_SOCKET") orelse return NiriError.NoSocketPath;
        if (path.len >= posix.PATH_MAX) return NiriError.SocketPathTooLong;

        var result = Niri{
            .socket_path = undefined,
            .socket_path_len = path.len,
        };
        @memcpy(result.socket_path[0..path.len], path);
        return result;
    }

    pub fn disconnect(_: *Niri) void {
        // No persistent connection to close.
    }

    /// Query the focused window and return its PID.
    /// Returns null if no window is focused or on any error.
    pub fn getFocusedPid(self: *Niri) ?i32 {
        var buf: [8192]u8 = undefined;
        const response = self.ipcRequest("\"FocusedWindow\"\n", &buf) orelse return null;
        return parsePidFromFocusedWindow(response);
    }

    /// Dispatch a focus movement action in the given direction.
    /// Uses the cross-monitor variants for better multi-monitor behavior.
    pub fn moveFocus(self: *Niri, direction: Direction) void {
        const cmd = switch (direction) {
            .left => "{\"Action\":{\"FocusColumnOrMonitorLeft\":{}}}\n",
            .right => "{\"Action\":{\"FocusColumnOrMonitorRight\":{}}}\n",
            .up => "{\"Action\":{\"FocusWindowOrMonitorUp\":{}}}\n",
            .down => "{\"Action\":{\"FocusWindowOrMonitorDown\":{}}}\n",
        };
        var discard: [256]u8 = undefined;
        _ = self.ipcRequest(cmd, &discard);
    }

    /// Open a fresh connection, send a JSON request line, read the response line, close.
    fn ipcRequest(self: *Niri, request: []const u8, buf: []u8) ?[]const u8 {
        const path = self.socket_path[0..self.socket_path_len];
        const addr = net.makeUnixAddr(path) catch return null;
        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return null;
        defer posix.close(fd);

        posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch return null;

        net.writeAll(fd, request) catch return null;

        // Read response into buffer.
        var total: usize = 0;
        while (total < buf.len) {
            const n = posix.read(fd, buf[total..]) catch return null;
            if (n == 0) break;
            total += n;
            // Niri terminates responses with newline — stop if we see one.
            if (std.mem.indexOfScalar(u8, buf[total - n .. total], '\n')) |_| break;
        }

        if (total == 0) return null;

        // Trim trailing newline if present.
        const end = if (total > 0 and buf[total - 1] == '\n') total - 1 else total;
        if (end == 0) return null;
        return buf[0..end];
    }

    // ─── WindowManager vtable functions ───

    fn wmGetFocusedPid(wm_ptr: *wm.WindowManager) ?i32 {
        const self: *Niri = @fieldParentPtr("wm", wm_ptr);
        return self.getFocusedPid();
    }

    fn wmMoveFocus(wm_ptr: *wm.WindowManager, direction: Direction) void {
        const self: *Niri = @fieldParentPtr("wm", wm_ptr);
        self.moveFocus(direction);
    }

    fn wmDisconnect(wm_ptr: *wm.WindowManager) void {
        const self: *Niri = @fieldParentPtr("wm", wm_ptr);
        self.disconnect();
    }
};

/// Parse the PID from a Niri FocusedWindow response.
///
/// Expected format:
///   {"Ok":{"FocusedWindow":{"id":12,"pid":12345,...}}}
///   {"Ok":{"FocusedWindow":null}}  (no focused window)
///
/// Returns null if the response cannot be parsed, pid is missing, or
/// no window is focused.
fn parsePidFromFocusedWindow(data: []const u8) ?i32 {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        std.heap.page_allocator,
        data,
        .{ .allocate = .alloc_always },
    ) catch return null;
    defer parsed.deinit();

    // Unwrap {"Ok": ...}
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };

    const ok_val = root.get("Ok") orelse return null;

    // Unwrap {"FocusedWindow": ...}
    const fw_wrapper = switch (ok_val) {
        .object => |o| o,
        else => return null,
    };

    const fw_val = fw_wrapper.get("FocusedWindow") orelse return null;

    // null means no focused window
    const window = switch (fw_val) {
        .object => |o| o,
        .null => return null,
        else => return null,
    };

    const pid_val = window.get("pid") orelse return null;
    const pid: i32 = switch (pid_val) {
        .integer => |i| @intCast(i),
        .null => return null, // pid can be null for some windows
        else => return null,
    };

    if (pid <= 0) return null;
    return pid;
}

// ─── Tests ───

const testing = std.testing;

test "parsePidFromFocusedWindow extracts pid" {
    const json =
        \\{"Ok":{"FocusedWindow":{"id":12,"title":"~","app_id":"Alacritty","pid":12345,"workspace_id":6,"is_focused":true}}}
    ;
    try testing.expectEqual(@as(?i32, 12345), parsePidFromFocusedWindow(json));
}

test "parsePidFromFocusedWindow returns null for no focused window" {
    const json =
        \\{"Ok":{"FocusedWindow":null}}
    ;
    try testing.expectEqual(@as(?i32, null), parsePidFromFocusedWindow(json));
}

test "parsePidFromFocusedWindow returns null for null pid" {
    const json =
        \\{"Ok":{"FocusedWindow":{"id":12,"title":"portal","app_id":"xdg-desktop-portal","pid":null}}}
    ;
    try testing.expectEqual(@as(?i32, null), parsePidFromFocusedWindow(json));
}

test "parsePidFromFocusedWindow returns null for error response" {
    const json =
        \\{"Err":"something went wrong"}
    ;
    try testing.expectEqual(@as(?i32, null), parsePidFromFocusedWindow(json));
}

test "parsePidFromFocusedWindow returns null for invalid json" {
    try testing.expectEqual(@as(?i32, null), parsePidFromFocusedWindow("not json"));
}

test "parsePidFromFocusedWindow returns null for empty object" {
    try testing.expectEqual(@as(?i32, null), parsePidFromFocusedWindow("{}"));
}

test "parsePidFromFocusedWindow returns null for pid zero" {
    const json =
        \\{"Ok":{"FocusedWindow":{"id":1,"pid":0}}}
    ;
    try testing.expectEqual(@as(?i32, null), parsePidFromFocusedWindow(json));
}
