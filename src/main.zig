/// nvg — Generic directional focus navigation between window manager
/// windows and focus-aware applications (nvim, tmux, vscode).
///
/// Supports multiple window managers through the WindowManager interface:
///   - sway / i3 (i3-ipc protocol)
///   - More backends can be added by implementing the WindowManager trait.
///
/// Usage: nvg <left|right|up|down> [options]
const std = @import("std");

const hook_mod = @import("hook.zig");
const wm_mod = @import("wm.zig");
const focus_mod = @import("focus.zig");
const log = @import("log.zig");

const Hook = hook_mod.Hook;
const Backend = wm_mod.Backend;

const version = @import("config").version;

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

const Args = struct {
    direction: Direction,
    timeout_ms: u32,
    enabled_hooks: [hook_mod.all_hooks.len]*const Hook,
    enabled_hooks_len: usize,
    wm_backend: ?Backend,
};

fn parseArgs() ?Args {
    var args_iter = std.process.args();
    _ = args_iter.next(); // skip argv[0]

    var direction: ?Direction = null;
    var timeout_ms: u32 = 100;
    var wm_backend: ?Backend = null;

    // Default: all hooks enabled
    var enabled_hooks: [hook_mod.all_hooks.len]*const Hook = undefined;
    var enabled_hooks_len: usize = hook_mod.all_hooks.len;
    for (hook_mod.all_hooks, 0..) |h, i| {
        enabled_hooks[i] = h;
    }
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "nvg {s}\n", .{version}) catch "nvg\n";
            std.fs.File.stdout().writeAll(msg) catch {};
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--timeout")) {
            const val = args_iter.next() orelse {
                printErr("Error: --timeout requires a value\n");
                return null;
            };
            timeout_ms = std.fmt.parseInt(u32, val, 10) catch {
                printErr("Error: invalid timeout value\n");
                return null;
            };
        } else if (std.mem.eql(u8, arg, "--wm")) {
            const val = args_iter.next() orelse {
                printErr("Error: --wm requires a value\n");
                return null;
            };
            wm_backend = Backend.fromString(val) orelse {
                var err_buf: [128]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "Error: unknown window manager '{s}'\n", .{val}) catch "Error: unknown window manager\n";
                printErr(err_msg);
                return null;
            };
        } else if (std.mem.eql(u8, arg, "--hooks")) {
            const val = args_iter.next() orelse {
                printErr("Error: --hooks requires a value\n");
                return null;
            };
            // Parse comma-separated hook names
            enabled_hooks_len = 0;
            var it = std.mem.splitScalar(u8, val, ',');
            while (it.next()) |name| {
                if (name.len == 0) continue;
                if (hook_mod.findHookByName(name)) |h| {
                    if (enabled_hooks_len < enabled_hooks.len) {
                        enabled_hooks[enabled_hooks_len] = h;
                        enabled_hooks_len += 1;
                    }
                } else {
                    var err_buf: [128]u8 = undefined;
                    const err_msg = std.fmt.bufPrint(&err_buf, "Error: unknown hook '{s}'\n", .{name}) catch "Error: unknown hook\n";
                    printErr(err_msg);
                    return null;
                }
            }
            if (enabled_hooks_len == 0) {
                printErr("Error: --hooks requires at least one valid hook name\n");
                return null;
            }
        } else if (direction == null) {
            direction = Direction.fromString(arg) orelse {
                printErr("Error: invalid direction. Expected left, right, up, or down\n");
                return null;
            };
        } else {
            printErr("Error: unexpected argument\n");
            return null;
        }
    }

    if (direction == null) {
        printErr("Error: direction argument required\n");
        printUsage();
        return null;
    }

    return .{
        .direction = direction orelse unreachable,
        .timeout_ms = timeout_ms,
        .enabled_hooks = enabled_hooks,
        .enabled_hooks_len = enabled_hooks_len,
        .wm_backend = wm_backend,
    };
}

fn printUsage() void {
    std.fs.File.stderr().writeAll(
        \\Usage: nvg <left|right|up|down> [options]
        \\
        \\Generic focus navigation between window manager windows and applications.
        \\
        \\Options:
        \\  -t, --timeout <ms>      IPC timeout in milliseconds (default: 100)
        \\  --hooks <hook,hook,...>  Comma-separated hooks to enable (default: all)
        \\                           Available: nvim, tmux, vscode
        \\  --wm <name>             Window manager backend (default: auto-detect)
        \\                           Available: sway, i3, hyprland, niri, dwm
        \\  -v, --version            Print version
        \\  -h, --help               Print this help
        \\
        \\Environment:
        \\  NVG_DEBUG=1              Enable debug logging to stderr
        \\  SWAYSOCK                 Sway IPC socket path (set automatically by sway)
        \\  I3SOCK                   i3 IPC socket path (set automatically by i3)
        \\  HYPRLAND_INSTANCE_SIGNATURE  Hyprland instance ID (set automatically by Hyprland)
        \\  NIRI_SOCKET              Niri IPC socket path (set automatically by niri)
        \\  DWM_FIFO                 dwm FIFO path for dwmfifo patch (default: /tmp/dwm.fifo)
        \\  XDG_RUNTIME_DIR          Used to locate Hyprland and Neovim sockets
        \\
    ) catch {};
}

fn printErr(msg: []const u8) void {
    std.fs.File.stderr().writeAll(msg) catch {};
}

pub fn main() void {
    const args = parseArgs() orelse std.process.exit(1);
    log.log("direction={s} timeout={d}ms hooks={d} wm={s}", .{
        @tagName(args.direction),
        args.timeout_ms,
        args.enabled_hooks_len,
        if (args.wm_backend) |b| @tagName(b) else "auto",
    });

    var conn = wm_mod.connect(args.wm_backend) catch |err| {
        switch (err) {
            wm_mod.Error.NoWmDetected => printErr("Error: no supported window manager detected. Use --wm to specify one.\n"),
            else => printErr("Error: failed to connect to window manager\n"),
        }
        std.process.exit(1);
    };
    defer conn.deinit();

    focus_mod.navigate(
        conn.wm(),
        args.direction,
        args.timeout_ms,
        args.enabled_hooks[0..args.enabled_hooks_len],
        &hook_mod.detectAll,
    );
}

// ─── Tests ───

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

// Import all sub-module tests so they're run with `zig build test`.
test {
    _ = @import("focus.zig");
    _ = @import("wm.zig");
    _ = @import("sway.zig");
    _ = @import("hyprland.zig");
    _ = @import("niri.zig");
    _ = @import("dwm.zig");
    _ = @import("msgpack.zig");
    _ = @import("process.zig");
    _ = @import("hook.zig");
    _ = @import("net.zig");
    _ = @import("log.zig");
    _ = @import("hooks/nvim.zig");
    _ = @import("hooks/tmux.zig");
    _ = @import("hooks/vscode.zig");
}
