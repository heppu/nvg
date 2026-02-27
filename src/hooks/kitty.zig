/// Kitty hook — detect Kitty terminal processes and navigate windows (splits).
///
/// Detection: matches processes where argv[0] or /proc/<pid>/exe contains "kitty"
/// but rejects "kitten" (the CLI helper binary).
///
/// Navigation: forks/execs the `kitten @` CLI to query window layout via JSON
/// and activate neighboring windows. The socket path and window ID are
/// discovered from the process's /proc/<pid>/environ (KITTY_LISTEN_ON and
/// KITTY_WINDOW_ID environment variables), falling back to the current
/// process's environment when invoked from within a Kitty window.
///
/// Requires `allow_remote_control yes` (or `remote_control_password`) in kitty.conf.
const std = @import("std");
const posix = std.posix;

const Hook = @import("../hook.zig").Hook;
const Direction = @import("../main.zig").Direction;
const process = @import("../process.zig");
const log = @import("../log.zig");

pub const hook = Hook{
    .name = "kitty",
    .detectFn = &detect,
    .canMoveFn = &canMove,
    .moveFocusFn = &moveFocus,
    .moveToEdgeFn = &moveToEdge,
};

fn detect(child_pid: i32, cmd: []const u8, exe: []const u8, _: []const u8) ?i32 {
    // Match "kitty" but reject "kitten" (the CLI helper binary).
    if (containsKitty(cmd) or containsKitty(exe)) {
        return child_pid;
    }
    return null;
}

/// Check if a string contains "kitty" but not "kitten".
fn containsKitty(s: []const u8) bool {
    if (std.mem.indexOf(u8, s, "kitty") == null) return false;
    if (std.mem.indexOf(u8, s, "kitten") != null) return false;
    return true;
}

/// Check if the active Kitty window can move focus in the given direction.
/// Runs `kitten @ ls` to get the full window layout as JSON, finds the
/// focused window, and checks if there's a neighbor in the requested direction.
/// Returns true if movement is possible, false if at edge, null on error.
fn canMove(pid: i32, dir: Direction, _: u32) ?bool {
    const env = resolveEnv(pid) orelse return null;
    const socket = env.socketPath() orelse return null;
    const window_id_str = env.windowId();

    // Parse the target window ID
    const window_id = std.fmt.parseInt(i64, window_id_str, 10) catch return null;

    // Run kitten @ ls to get window layout
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "kitten", "@", "ls", "--to", socket },
    }) catch return null;

    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) return null;

    // Parse JSON and check for neighbor
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        result.stdout,
        .{ .allocate = .alloc_always },
    ) catch return null;
    defer parsed.deinit();

    return hasNeighbor(parsed.value, window_id, dir);
}

/// Move Kitty window focus one step in the given direction.
fn moveFocus(pid: i32, dir: Direction, _: u32) void {
    const env = resolveEnv(pid) orelse return;
    const socket = env.socketPath() orelse return;
    const dir_str = directionStr(dir);

    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "kitten", "@", "action", "--to", socket, "neighboring_window", dir_str },
    }) catch return;

    std.heap.page_allocator.free(result.stdout);
    std.heap.page_allocator.free(result.stderr);

    log.log("kitty neighboring_window {s}", .{dir_str});
}

/// Move Kitty focus to the edge window in the given direction.
/// Repeatedly activates neighboring window until at edge.
fn moveToEdge(pid: i32, dir: Direction, timeout_ms: u32) void {
    const max_moves = 50; // Safety limit

    var i: u32 = 0;
    while (i < max_moves) : (i += 1) {
        const can = canMove(pid, dir, timeout_ms) orelse break;
        if (!can) break;
        moveFocus(pid, dir, timeout_ms);
    }

    log.log("kitty moveToEdge {s}: moved {d} windows", .{ directionStr(dir), i });
}

// ─── JSON neighbor detection ───

/// Given the `kitten @ ls` JSON output, find the focused window and check
/// if there's a neighbor in the requested direction.
///
/// The JSON structure is:
///   [ { "tabs": [ { "windows": [ { "id": N, "is_focused": bool,
///       "at_left": bool, "at_top": bool, "at_right": bool, "at_bottom": bool,
///       ... }, ... ], "is_focused": bool }, ... ], "is_focused": bool }, ... ]
///
/// We find the focused OS window → focused tab → then check the target window's
/// edge flags to determine if movement is possible.
fn hasNeighbor(root: std.json.Value, window_id: i64, dir: Direction) ?bool {
    // root is an array of OS windows
    const os_windows = switch (root) {
        .array => |a| a.items,
        else => return null,
    };

    for (os_windows) |os_win| {
        const os_obj = switch (os_win) {
            .object => |o| o,
            else => continue,
        };

        // Only look in the focused OS window
        const os_focused = os_obj.get("is_focused") orelse continue;
        if (os_focused != .bool or !os_focused.bool) continue;

        const tabs = switch (os_obj.get("tabs") orelse continue) {
            .array => |a| a.items,
            else => continue,
        };

        for (tabs) |tab| {
            const tab_obj = switch (tab) {
                .object => |o| o,
                else => continue,
            };

            // Only look in the focused tab
            const tab_focused = tab_obj.get("is_focused") orelse continue;
            if (tab_focused != .bool or !tab_focused.bool) continue;

            const windows = switch (tab_obj.get("windows") orelse continue) {
                .array => |a| a.items,
                else => continue,
            };

            // Find our target window
            for (windows) |win| {
                const win_obj = switch (win) {
                    .object => |o| o,
                    else => continue,
                };

                const id_val = win_obj.get("id") orelse continue;
                const id = switch (id_val) {
                    .integer => |i| i,
                    else => continue,
                };

                if (id != window_id) continue;

                // Found our window — check edge flags.
                // Kitty's at_left/at_right/at_top/at_bottom are true when
                // the window is at that edge (i.e., no neighbor in that direction).
                const edge_key = switch (dir) {
                    .left => "at_left",
                    .right => "at_right",
                    .up => "at_top",
                    .down => "at_bottom",
                };

                const edge_val = win_obj.get(edge_key) orelse return null;
                if (edge_val != .bool) return null;

                // at_<edge> == true means AT the edge (no neighbor), so invert
                return !edge_val.bool;
            }
        }
    }

    return null; // Window not found
}

// ─── Helpers ───

/// Map direction to Kitty direction string.
/// Kitty uses "left", "right", "top", "bottom" (not "up"/"down").
fn directionStr(dir: Direction) []const u8 {
    return switch (dir) {
        .left => "left",
        .right => "right",
        .up => "top",
        .down => "bottom",
    };
}

/// Resolved Kitty environment for CLI commands.
const KittyEnv = struct {
    socket_buf: [256]u8 = undefined,
    socket_len: usize = 0,

    window_id_buf: [32]u8 = undefined,
    window_id_len: usize = 0,

    fn socketPath(self: *const KittyEnv) ?[]const u8 {
        if (self.socket_len > 0) return self.socket_buf[0..self.socket_len];
        return null;
    }

    fn windowId(self: *const KittyEnv) []const u8 {
        return self.window_id_buf[0..self.window_id_len];
    }
};

/// Resolve Kitty environment (socket path and window ID) from a process's
/// /proc/<pid>/environ, falling back to the current process's environment.
fn resolveEnv(pid: i32) ?KittyEnv {
    var env = KittyEnv{};

    // Try reading from /proc/<pid>/environ first
    if (readEnvFromProc(pid, &env)) return env;

    // Fall back to current process environment (works when nvg is invoked
    // from within a Kitty window — the shell inherits KITTY_LISTEN_ON).
    if (posix.getenv("KITTY_LISTEN_ON")) |socket| {
        if (socket.len > 0 and socket.len <= env.socket_buf.len) {
            @memcpy(env.socket_buf[0..socket.len], socket);
            env.socket_len = socket.len;

            if (posix.getenv("KITTY_WINDOW_ID")) |wid| {
                if (wid.len > 0 and wid.len <= env.window_id_buf.len) {
                    @memcpy(env.window_id_buf[0..wid.len], wid);
                    env.window_id_len = wid.len;
                }
            }

            log.log("kitty: resolved from current env: socket={s}", .{socket});
            return env;
        }
    }

    log.log("kitty: failed to resolve env for pid {d}", .{pid});
    return null;
}

/// Try to read KITTY_LISTEN_ON and KITTY_WINDOW_ID from /proc/<pid>/environ.
/// Returns true if KITTY_LISTEN_ON was found.
fn readEnvFromProc(pid: i32, env: *KittyEnv) bool {
    var path_buf: [64]u8 = undefined;
    const environ_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/environ", .{pid}) catch return false;

    var environ_buf: [8192]u8 = undefined;
    const content = process.readFileToBuffer(environ_path, &environ_buf) orelse return false;

    var found_socket = false;

    // /proc/<pid>/environ is null-separated KEY=VALUE pairs
    var it = std.mem.splitScalar(u8, content, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;

        if (std.mem.startsWith(u8, entry, "KITTY_LISTEN_ON=")) {
            const val = entry["KITTY_LISTEN_ON=".len..];
            if (val.len > 0 and val.len <= env.socket_buf.len) {
                @memcpy(env.socket_buf[0..val.len], val);
                env.socket_len = val.len;
                found_socket = true;
                log.log("kitty: found KITTY_LISTEN_ON={s} in /proc/{d}/environ", .{ val, pid });
            }
        } else if (std.mem.startsWith(u8, entry, "KITTY_WINDOW_ID=")) {
            const val = entry["KITTY_WINDOW_ID=".len..];
            if (val.len > 0 and val.len <= env.window_id_buf.len) {
                @memcpy(env.window_id_buf[0..val.len], val);
                env.window_id_len = val.len;
                log.log("kitty: found KITTY_WINDOW_ID={s} in /proc/{d}/environ", .{ val, pid });
            }
        }
    }

    return found_socket;
}

// ─── Tests ───

test "detect matches kitty" {
    try std.testing.expectEqual(@as(?i32, 10), detect(10, "kitty", "", ""));
    try std.testing.expectEqual(@as(?i32, 10), detect(10, "bash", "/usr/bin/kitty", ""));
    try std.testing.expectEqual(@as(?i32, 10), detect(10, "/usr/bin/kitty", "", ""));
}

test "detect rejects kitten" {
    try std.testing.expectEqual(@as(?i32, null), detect(10, "kitten", "", ""));
    try std.testing.expectEqual(@as(?i32, null), detect(10, "bash", "/usr/bin/kitten", ""));
    try std.testing.expectEqual(@as(?i32, null), detect(10, "kitten @", "/usr/lib/kitty/kitten", ""));
}

test "detect rejects non-kitty" {
    try std.testing.expectEqual(@as(?i32, null), detect(10, "bash", "/usr/bin/bash", ""));
    try std.testing.expectEqual(@as(?i32, null), detect(10, "alacritty", "/usr/bin/alacritty", ""));
}

test "containsKitty" {
    try std.testing.expect(containsKitty("kitty"));
    try std.testing.expect(containsKitty("/usr/bin/kitty"));
    try std.testing.expect(!containsKitty("kitten"));
    try std.testing.expect(!containsKitty("/usr/bin/kitten"));
    try std.testing.expect(!containsKitty("bash"));
    try std.testing.expect(!containsKitty(""));
}

test "directionStr" {
    try std.testing.expectEqualStrings("left", directionStr(.left));
    try std.testing.expectEqualStrings("right", directionStr(.right));
    try std.testing.expectEqualStrings("top", directionStr(.up));
    try std.testing.expectEqualStrings("bottom", directionStr(.down));
}

test "KittyEnv socketPath returns null when not set" {
    const env = KittyEnv{};
    try std.testing.expectEqual(@as(?[]const u8, null), env.socketPath());
}

test "KittyEnv socketPath returns path when set" {
    var env = KittyEnv{};
    const path = "unix:/tmp/kitty-socket";
    @memcpy(env.socket_buf[0..path.len], path);
    env.socket_len = path.len;
    try std.testing.expectEqualStrings("unix:/tmp/kitty-socket", env.socketPath().?);
}

test "KittyEnv windowId returns correct slice" {
    var env = KittyEnv{};
    const id = "42";
    @memcpy(env.window_id_buf[0..id.len], id);
    env.window_id_len = id.len;
    try std.testing.expectEqualStrings("42", env.windowId());
}

test "readEnvFromProc returns false for nonexistent pid" {
    var env = KittyEnv{};
    try std.testing.expect(!readEnvFromProc(4194304, &env));
}

test "hasNeighbor returns null for non-array root" {
    try std.testing.expectEqual(@as(?bool, null), hasNeighbor(.null, 1, .left));
}

test "hasNeighbor finds neighbor from JSON" {
    // Minimal kitty ls JSON: one OS window, one tab, one window at left edge
    const json =
        \\[{"is_focused": true, "tabs": [{"is_focused": true, "windows": [
        \\  {"id": 1, "is_focused": true, "at_left": true, "at_right": false, "at_top": true, "at_bottom": true}
        \\]}]}]
    ;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    // at_left=true means AT the edge, so no neighbor to the left
    try std.testing.expectEqual(@as(?bool, false), hasNeighbor(parsed.value, 1, .left));
    // at_right=false means NOT at edge, so there IS a neighbor to the right
    try std.testing.expectEqual(@as(?bool, true), hasNeighbor(parsed.value, 1, .right));
    // at_top=true means AT the edge
    try std.testing.expectEqual(@as(?bool, false), hasNeighbor(parsed.value, 1, .up));
    // at_bottom=true means AT the edge
    try std.testing.expectEqual(@as(?bool, false), hasNeighbor(parsed.value, 1, .down));
}

test "hasNeighbor returns null for unknown window id" {
    const json =
        \\[{"is_focused": true, "tabs": [{"is_focused": true, "windows": [
        \\  {"id": 1, "is_focused": true, "at_left": false, "at_right": false, "at_top": false, "at_bottom": false}
        \\]}]}]
    ;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(?bool, null), hasNeighbor(parsed.value, 999, .left));
}
