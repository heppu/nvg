/// Window manager abstraction layer.
///
/// Provides a common interface for interacting with different window managers
/// (sway/i3, hyprland, niri, river, dwm on Linux; GlazeWM on Windows). Each
/// backend implements the WindowManager vtable to provide getFocusedPid and
/// moveFocus operations.
///
/// Backend selection is either explicit (--wm flag) or auto-detected from
/// environment variables (SWAYSOCK, I3SOCK, HYPRLAND_INSTANCE_SIGNATURE, …)
/// or, on Windows, by probing the GlazeWM IPC socket.
const std = @import("std");
const builtin = @import("builtin");

const Direction = @import("direction.zig").Direction;
const platform = @import("platform.zig");
const log = @import("log.zig");

// Linux-only backends are imported lazily so they're never compiled when
// targeting Windows (they pull in posix.AF.UNIX, /proc, X11 protocol, etc.).
const Sway = if (builtin.os.tag == .linux) @import("sway.zig").Sway else void;
const Hyprland = if (builtin.os.tag == .linux) @import("hyprland.zig").Hyprland else void;
const Niri = if (builtin.os.tag == .linux) @import("niri.zig").Niri else void;
const River = if (builtin.os.tag == .linux) @import("river.zig").River else void;
const Dwm = if (builtin.os.tag == .linux) @import("dwm.zig").Dwm else void;
const GlazeWm = if (builtin.os.tag == .windows) @import("glazewm.zig").GlazeWm else void;

pub const Error = error{
    NoWmDetected,
    ConnectFailed,
};

/// A window manager backend identifier. Different per platform — Linux WMs
/// can't run on Windows and vice versa, so listing them here would only
/// produce confusing error messages.
pub const Backend = if (builtin.os.tag == .windows) enum {
    glazewm,

    pub fn fromString(s: []const u8) ?Backend {
        if (std.mem.eql(u8, s, "glazewm")) return .glazewm;
        return null;
    }
} else enum {
    sway,
    hyprland,
    niri,
    river,
    dwm,

    pub fn fromString(s: []const u8) ?Backend {
        if (std.mem.eql(u8, s, "sway")) return .sway;
        if (std.mem.eql(u8, s, "i3")) return .sway; // i3 uses the same protocol
        if (std.mem.eql(u8, s, "hyprland")) return .hyprland;
        if (std.mem.eql(u8, s, "niri")) return .niri;
        if (std.mem.eql(u8, s, "river")) return .river;
        if (std.mem.eql(u8, s, "dwm")) return .dwm;
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

/// Generate the WindowManager vtable for backend type `T`.
///
/// `T` must have a `wm: WindowManager` field and three methods:
/// `getFocusedPid(*T) ?i32`, `moveFocus(*T, Direction) void`, and
/// `disconnect(*T) void`. Use it as the default for the embedded `wm` field:
///
///     pub const Sway = struct {
///         wm: wm.WindowManager = wm.vtable(Sway),
///         fd: posix.fd_t,
///         pub fn getFocusedPid(self: *Sway) ?i32 { ... }
///         pub fn moveFocus(self: *Sway, dir: Direction) void { ... }
///         pub fn disconnect(self: *Sway) void { ... }
///     };
pub fn vtable(comptime T: type) WindowManager {
    comptime {
        if (!@hasField(T, "wm"))
            @compileError(@typeName(T) ++ ": vtable requires a 'wm' field");
        if (@FieldType(T, "wm") != WindowManager)
            @compileError(@typeName(T) ++ ".wm must be of type WindowManager");
        if (!@hasDecl(T, "getFocusedPid"))
            @compileError(@typeName(T) ++ ": vtable requires a getFocusedPid method");
        if (!@hasDecl(T, "moveFocus"))
            @compileError(@typeName(T) ++ ": vtable requires a moveFocus method");
        if (!@hasDecl(T, "disconnect"))
            @compileError(@typeName(T) ++ ": vtable requires a disconnect method");
    }
    return .{
        .getFocusedPidFn = struct {
            fn f(p: *WindowManager) ?i32 {
                return @as(*T, @fieldParentPtr("wm", p)).getFocusedPid();
            }
        }.f,
        .moveFocusFn = struct {
            fn f(p: *WindowManager, dir: Direction) void {
                @as(*T, @fieldParentPtr("wm", p)).moveFocus(dir);
            }
        }.f,
        .disconnectFn = struct {
            fn f(p: *WindowManager) void {
                @as(*T, @fieldParentPtr("wm", p)).disconnect();
            }
        }.f,
    };
}

/// A connection to a window manager backend.
///
/// Holds the concrete backend struct in a tagged union, avoiding heap
/// allocation. The caller owns this struct on the stack and accesses
/// the common WindowManager interface via the wm() method.
pub const Connection = if (builtin.os.tag == .windows) union(Backend) {
    glazewm: GlazeWm,

    pub fn wm(self: *Connection) *WindowManager {
        return switch (self.*) {
            inline else => |*backend| &backend.wm,
        };
    }

    pub fn deinit(self: *Connection) void {
        self.wm().disconnect();
    }
} else union(Backend) {
    sway: Sway,
    hyprland: Hyprland,
    niri: Niri,
    river: River,
    dwm: Dwm,

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
    if (comptime builtin.os.tag == .windows) {
        // Only one supported backend on Windows — assume it if the user
        // didn't pick something else. The actual probe happens in connect().
        log.log("auto-detected glazewm (windows default)", .{});
        return .glazewm;
    }

    // Check sway first (SWAYSOCK is set by sway)
    if (platform.getenv("SWAYSOCK")) |_| {
        log.log("auto-detected sway (SWAYSOCK set)", .{});
        return .sway;
    }

    // Check i3 (I3SOCK is set by i3)
    if (platform.getenv("I3SOCK")) |_| {
        log.log("auto-detected i3 (I3SOCK set)", .{});
        return .sway; // i3 uses the same IPC protocol
    }

    // Check Hyprland (HYPRLAND_INSTANCE_SIGNATURE is set by Hyprland)
    if (platform.getenv("HYPRLAND_INSTANCE_SIGNATURE")) |_| {
        log.log("auto-detected hyprland (HYPRLAND_INSTANCE_SIGNATURE set)", .{});
        return .hyprland;
    }

    // Check Niri (NIRI_SOCKET is set by niri)
    if (platform.getenv("NIRI_SOCKET")) |_| {
        log.log("auto-detected niri (NIRI_SOCKET set)", .{});
        return .niri;
    }

    // Check River (XDG_CURRENT_DESKTOP=river is set by river)
    if (platform.getenv("XDG_CURRENT_DESKTOP")) |desktop| {
        if (std.mem.eql(u8, desktop, "river")) {
            log.log("auto-detected river (XDG_CURRENT_DESKTOP=river)", .{});
            return .river;
        }
    }

    // Check dwm (DWM_FIFO is set by the user for dwmfifo patch)
    if (platform.getenv("DWM_FIFO")) |_| {
        log.log("auto-detected dwm (DWM_FIFO set)", .{});
        return .dwm;
    }

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

    if (comptime builtin.os.tag == .windows) {
        switch (backend) {
            .glazewm => {
                const g = GlazeWm.connect() catch return Error.ConnectFailed;
                return .{ .glazewm = g };
            },
        }
    } else {
        switch (backend) {
            .sway => {
                // Try SWAYSOCK first, fall back to I3SOCK
                const socket_path = platform.getenv("SWAYSOCK") orelse
                    platform.getenv("I3SOCK") orelse return Error.ConnectFailed;
                const sway = Sway.connect(socket_path) catch return Error.ConnectFailed;
                return .{ .sway = sway };
            },
            .hyprland => {
                const hyprland = Hyprland.connect() catch return Error.ConnectFailed;
                return .{ .hyprland = hyprland };
            },
            .niri => {
                const niri = Niri.connect() catch return Error.ConnectFailed;
                return .{ .niri = niri };
            },
            .river => {
                const river = River.connect() catch return Error.ConnectFailed;
                return .{ .river = river };
            },
            .dwm => {
                const dwm_conn = Dwm.connect() catch return Error.ConnectFailed;
                return .{ .dwm = dwm_conn };
            },
        }
    }
}

/// Return the list of supported backend names for help/error messages.
pub fn backendNames() []const []const u8 {
    if (comptime builtin.os.tag == .windows) {
        return &.{"glazewm"};
    }
    return &.{ "sway", "i3", "hyprland", "niri", "river", "dwm" };
}

// ─── Tests ───

const testing = std.testing;

test "Backend.fromString valid names" {
    if (comptime builtin.os.tag == .windows) {
        try testing.expectEqual(Backend.glazewm, Backend.fromString("glazewm").?);
    } else {
        try testing.expectEqual(Backend.sway, Backend.fromString("sway").?);
        try testing.expectEqual(Backend.sway, Backend.fromString("i3").?);
        try testing.expectEqual(Backend.hyprland, Backend.fromString("hyprland").?);
        try testing.expectEqual(Backend.niri, Backend.fromString("niri").?);
        try testing.expectEqual(Backend.river, Backend.fromString("river").?);
        try testing.expectEqual(Backend.dwm, Backend.fromString("dwm").?);
    }
}

test "Backend.fromString unknown returns null" {
    try testing.expectEqual(@as(?Backend, null), Backend.fromString("unknown"));
    try testing.expectEqual(@as(?Backend, null), Backend.fromString(""));
}

test "backendNames returns non-empty list" {
    const names = backendNames();
    try testing.expect(names.len > 0);
    if (comptime builtin.os.tag == .windows) {
        try testing.expectEqualStrings("glazewm", names[0]);
    } else {
        try testing.expectEqualStrings("sway", names[0]);
        try testing.expectEqualStrings("i3", names[1]);
        try testing.expectEqualStrings("hyprland", names[2]);
        try testing.expectEqualStrings("niri", names[3]);
        try testing.expectEqualStrings("river", names[4]);
        try testing.expectEqualStrings("dwm", names[5]);
    }
}
