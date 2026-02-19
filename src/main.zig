/// sway-focus — Generic directional focus navigation between sway/i3
/// windows and focus-aware applications (nvim, tmux, vscode).
///
/// Usage: sway-focus <left|right|up|down> [options]
const std = @import("std");
const posix = std.posix;

const hook_mod = @import("hook.zig");
const process = @import("process.zig");
const sway_mod = @import("sway.zig");
const log = @import("log.zig");

const Hook = hook_mod.Hook;
const Sway = sway_mod.Sway;

const version = "0.0.1";

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
};

fn parseArgs() ?Args {
    var args_iter = std.process.args();
    _ = args_iter.next(); // skip argv[0]

    var direction: ?Direction = null;
    var timeout_ms: u32 = 100;

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
            const msg = std.fmt.bufPrint(&buf, "sway-focus {s}\n", .{version}) catch "sway-focus\n";
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
    };
}

fn printUsage() void {
    std.fs.File.stderr().writeAll(
        \\Usage: sway-focus <left|right|up|down> [options]
        \\
        \\Generic focus navigation between sway windows and applications.
        \\
        \\Options:
        \\  -t, --timeout <ms>      IPC timeout in milliseconds (default: 100)
        \\  --hooks <hook,hook,...>  Comma-separated hooks to enable (default: all)
        \\                           Available: nvim, tmux, vscode
        \\  -v, --version            Print version
        \\  -h, --help               Print this help
        \\
        \\Environment:
        \\  SWAY_FOCUS_DEBUG=1       Enable debug logging to stderr
        \\
    ) catch {};
}

fn printErr(msg: []const u8) void {
    std.fs.File.stderr().writeAll(msg) catch {};
}

pub fn main() void {
    const args = parseArgs() orelse std.process.exit(1);
    log.log("direction={s} timeout={d}ms hooks={d}", .{ @tagName(args.direction), args.timeout_ms, args.enabled_hooks_len });
    focus(args.direction, args.timeout_ms, args.enabled_hooks[0..args.enabled_hooks_len]);
}

/// Generic focus navigation.
///
/// 1. Get the focused window PID from sway.
/// 2. Walk the process tree and detect all matching hooks.
/// 3. Iterate detected hooks in reverse (innermost first):
///    - If hook.canMove() returns true -> hook.moveFocus() and return.
///    - If false or null -> at edge, bubble up to next outer hook.
/// 4. If all hooks are at edge (or none detected) -> sway moveWindowFocus().
fn focus(direction: Direction, timeout_ms: u32, enabled_hooks: []const *const Hook) void {
    const sway_socket = posix.getenv("SWAYSOCK") orelse {
        printErr("Error: SWAYSOCK not set\n");
        std.process.exit(1);
    };

    var sway = Sway.connect(sway_socket) catch {
        printErr("Error: failed to connect to sway\n");
        std.process.exit(1);
    };
    defer sway.disconnect();

    const focused_pid = sway.getFocusedPid() orelse {
        log.log("no focused window found, moving sway focus", .{});
        moveWindowFocus(&sway, direction, timeout_ms, enabled_hooks);
        return;
    };
    log.log("focused window PID: {d}", .{focused_pid});

    // Detect all hooks in the process tree
    const detected = hook_mod.detectAll(focused_pid, enabled_hooks);
    log.log("detected {d} hook(s)", .{detected.len});

    if (detected.len == 0) {
        moveWindowFocus(&sway, direction, timeout_ms, enabled_hooks);
        return;
    }

    // Iterate in reverse (innermost first)
    const items = detected.slice();
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        const d = items[i];
        log.log("trying hook '{s}' (pid={d}, depth={d})", .{ d.hook.name, d.pid, d.depth });
        const can = d.hook.canMoveFn(d.pid, direction, timeout_ms);
        if (can) |can_move| {
            if (can_move) {
                // Not at edge — move within this application
                log.log("hook '{s}' can move, executing", .{d.hook.name});
                d.hook.moveFocusFn(d.pid, direction, timeout_ms);
                return;
            }
            log.log("hook '{s}' at edge, bubbling up", .{d.hook.name});
            // At edge — bubble up to next outer hook
        } else {
            log.log("hook '{s}' returned null (error/timeout), bubbling up", .{d.hook.name});
        }
        // null (error/timeout) — treat as at edge, bubble up
    }

    // All hooks at edge or returned null — move sway focus
    log.log("all hooks at edge, moving sway focus", .{});
    moveWindowFocus(&sway, direction, timeout_ms, enabled_hooks);
}

/// Move sway window focus, then check if the newly focused window has
/// any detected hooks. If so, call moveToEdge on the innermost hook
/// with the opposite direction (so the user lands on the split closest
/// to where they came from).
fn moveWindowFocus(sway: *Sway, direction: Direction, timeout_ms: u32, enabled_hooks: []const *const Hook) void {
    sway.moveFocus(direction);

    const next_pid = sway.getFocusedPid() orelse return;
    log.log("new focused window PID: {d}", .{next_pid});

    const detected = hook_mod.detectAll(next_pid, enabled_hooks);
    if (detected.len == 0) return;

    // Innermost hook — last item in the shallowest-first list
    const innermost = detected.items[detected.len - 1];
    log.log("moving to edge in '{s}' (pid={d})", .{ innermost.hook.name, innermost.pid });
    innermost.hook.moveToEdgeFn(innermost.pid, direction.opposite(), timeout_ms);
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
//
// Note: integration tests for the core focus() algorithm are not included here
// because they require a running sway instance, real /proc filesystem, and
// running application instances. The core algorithm is kept simple enough to
// verify by inspection, while individual components (msgpack, process tree
// walking, hook detection) are unit-tested in isolation.
test {
    _ = @import("sway.zig");
    _ = @import("msgpack.zig");
    _ = @import("process.zig");
    _ = @import("hook.zig");
    _ = @import("net.zig");
    _ = @import("log.zig");
    _ = @import("hooks/nvim.zig");
    _ = @import("hooks/tmux.zig");
    _ = @import("hooks/vscode.zig");
}
