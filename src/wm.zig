/// Window manager abstraction layer.
///
/// Provides a common interface for interacting with different window managers
/// (sway/i3, hyprland, dwm, awesome, etc.). Each backend implements the
/// WindowManager vtable to provide getFocusedPid and moveFocus operations.
///
/// Backend selection is either explicit (--wm flag) or auto-detected from
/// environment variables (SWAYSOCK, I3SOCK, HYPRLAND_INSTANCE_SIGNATURE, etc.).
const std = @import("std");
const posix = std.posix;

const Direction = @import("main.zig").Direction;
const Sway = @import("sway.zig").Sway;
const log = @import("log.zig");

pub const Error = error{
    ConnectFailed,
    WriteFailed,
    ReadFailed,
    InvalidHeader,
    ParseFailed,
    SocketPathTooLong,
    NoWmDetected,
    UnknownBackend,
};

/// A window manager backend identifier.
pub const Backend = enum {
    sway,
    // Future backends:
    // hyprland,
    // dwm,
    // awesome,

    pub fn fromString(s: []const u8) ?Backend {
        if (std.mem.eql(u8, s, "sway")) return .sway;
        if (std.mem.eql(u8, s, "i3")) return .sway; // i3 uses the same protocol
        // if (std.mem.eql(u8, s, "hyprland")) return .hyprland;
        // if (std.mem.eql(u8, s, "dwm")) return .dwm;
        // if (std.mem.eql(u8, s, "awesome")) return .awesome;
        return null;
    }
};

/// Common interface for window manager operations.
///
/// Each backend (sway, hyprland, etc.) embeds a WindowManager as its first
/// field and populates the vtable function pointers. Callers use the
/// WindowManager methods which dispatch through the vtable to the concrete
/// backend via @fieldParentPtr.
///
/// This follows the same pattern as Hook in hook.zig.
pub const WindowManager = struct {
    getFocusedPidFn: *const fn (*WindowManager) ?i32,
    moveFocusFn: *const fn (*WindowManager, Direction) void,
    disconnectFn: *const fn (*WindowManager) void,

    pub fn getFocusedPid(self: *WindowManager) ?i32 {
        return self.getFocusedPidFn(self);
    }

    pub fn moveFocus(self: *WindowManager, direction: Direction) void {
        self.moveFocusFn(self, direction);
    }

    pub fn disconnect(self: *WindowManager) void {
        self.disconnectFn(self);
    }
};

/// A connection to a window manager backend.
///
/// Holds the concrete backend struct in a tagged union, avoiding heap
/// allocation. The caller owns this struct on the stack and accesses
/// the common WindowManager interface via the wm() method.
pub const Connection = union(Backend) {
    sway: Sway,
    // Future backends:
    // hyprland: Hyprland,

    pub fn wm(self: *Connection) *WindowManager {
        return switch (self.*) {
            inline else => |*backend| &backend.wm,
        };
    }

    pub fn deinit(self: *Connection) void {
        self.wm().disconnect();
    }
};

/// Auto-detect the running window manager from environment variables.
/// Returns the detected backend, or null if no supported WM is detected.
pub fn detectBackend() ?Backend {
    // Check sway first (SWAYSOCK is set by sway)
    if (posix.getenv("SWAYSOCK")) |_| {
        log.log("auto-detected sway (SWAYSOCK set)", .{});
        return .sway;
    }

    // Check i3 (I3SOCK is set by i3)
    if (posix.getenv("I3SOCK")) |_| {
        log.log("auto-detected i3 (I3SOCK set)", .{});
        return .sway; // i3 uses the same IPC protocol
    }

    // Future: check HYPRLAND_INSTANCE_SIGNATURE for hyprland
    // if (posix.getenv("HYPRLAND_INSTANCE_SIGNATURE")) |_| {
    //     log.log("auto-detected hyprland", .{});
    //     return .hyprland;
    // }

    return null;
}

/// Connect to the appropriate window manager backend.
/// If `explicit_backend` is provided, use that. Otherwise, auto-detect.
/// Returns a Connection that owns the backend and provides a WindowManager
/// interface via its wm() method.
pub fn connect(explicit_backend: ?Backend) Error!Connection {
    const backend = explicit_backend orelse detectBackend() orelse {
        return Error.NoWmDetected;
    };

    switch (backend) {
        .sway => {
            // Try SWAYSOCK first, fall back to I3SOCK
            const socket_path = posix.getenv("SWAYSOCK") orelse
                posix.getenv("I3SOCK") orelse return Error.ConnectFailed;
            const sway = Sway.connect(socket_path) catch return Error.ConnectFailed;
            return .{ .sway = sway };
        },
        // Future backends would be handled here:
        // .hyprland => { ... },
    }
}

/// Return the list of supported backend names for help/error messages.
pub fn backendNames() []const []const u8 {
    return &.{ "sway", "i3" };
}

// ─── Tests ───

const testing = std.testing;

test "Backend.fromString valid names" {
    try testing.expectEqual(Backend.sway, Backend.fromString("sway").?);
    try testing.expectEqual(Backend.sway, Backend.fromString("i3").?);
}

test "Backend.fromString unknown returns null" {
    try testing.expectEqual(@as(?Backend, null), Backend.fromString("unknown"));
    try testing.expectEqual(@as(?Backend, null), Backend.fromString(""));
}

test "backendNames returns non-empty list" {
    const names = backendNames();
    try testing.expect(names.len > 0);
    try testing.expectEqualStrings("sway", names[0]);
    try testing.expectEqualStrings("i3", names[1]);
}
