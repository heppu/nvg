/// WezTerm hook — detect WezTerm terminal processes and navigate panes.
///
/// Detection: matches processes where argv[0] or /proc/<pid>/exe contains "wezterm".
/// The detected PID is a wezterm-related process in the terminal's process tree.
///
/// Navigation: forks/execs the `wezterm` CLI binary to query pane adjacency
/// and activate pane direction commands. The pane ID and socket path are
/// discovered from the process's /proc/<pid>/environ (WEZTERM_PANE and
/// WEZTERM_UNIX_SOCKET environment variables), falling back to the current
/// process's environment when invoked from within a WezTerm pane.
const std = @import("std");
const posix = std.posix;

const Hook = @import("../hook.zig").Hook;
const Direction = @import("../main.zig").Direction;
const process = @import("../process.zig");
const log = @import("../log.zig");

pub const hook = Hook{
    .name = "wezterm",
    .detectFn = &detect,
    .canMoveFn = &canMove,
    .moveFocusFn = &moveFocus,
    .moveToEdgeFn = &moveToEdge,
};

fn detect(child_pid: i32, cmd: []const u8, exe: []const u8, _: []const u8) ?i32 {
    if (std.mem.indexOf(u8, cmd, "wezterm") != null or
        std.mem.indexOf(u8, exe, "wezterm") != null)
    {
        return child_pid;
    }
    return null;
}

/// Check if the active WezTerm pane can move focus in the given direction.
/// Uses `wezterm cli get-pane-direction <dir> --pane-id <id>` which returns
/// a pane ID if there is an adjacent pane, or empty output if at the edge.
/// Returns true if not at edge, false if at edge, null on error.
fn canMove(pid: i32, dir: Direction, _: u32) ?bool {
    const env = resolveEnv(pid) orelse return null;
    const dir_str = directionStr(dir);
    const pane_id = env.paneId();

    var out_buf: [64]u8 = undefined;
    const output = if (env.socketPath()) |sock|
        runWezterm(&.{ "wezterm", "cli", "--unix-socket", sock, "get-pane-direction", "--pane-id", pane_id, dir_str }, &out_buf)
    else
        runWezterm(&.{ "wezterm", "cli", "get-pane-direction", "--pane-id", pane_id, dir_str }, &out_buf);

    // get-pane-direction returns a pane_id if there's an adjacent pane,
    // or exits successfully with empty stdout if at the edge.
    // runWezterm returns null for empty output (after trimming).
    if (output) |out| {
        log.log("wezterm get-pane-direction {s}: '{s}'", .{ dir_str, out });
        return true; // Non-empty output means there's a neighbor pane
    }

    log.log("wezterm get-pane-direction {s}: at edge", .{dir_str});
    return false;
}

/// Move WezTerm pane focus one step in the given direction.
fn moveFocus(pid: i32, dir: Direction, _: u32) void {
    const env = resolveEnv(pid) orelse return;
    const dir_str = directionStr(dir);
    const pane_id = env.paneId();

    var out_buf: [64]u8 = undefined;
    if (env.socketPath()) |sock| {
        _ = runWezterm(&.{ "wezterm", "cli", "--unix-socket", sock, "activate-pane-direction", "--pane-id", pane_id, dir_str }, &out_buf);
    } else {
        _ = runWezterm(&.{ "wezterm", "cli", "activate-pane-direction", "--pane-id", pane_id, dir_str }, &out_buf);
    }
    log.log("wezterm activate-pane-direction {s}", .{dir_str});
}

/// Move WezTerm focus to the edge pane in the given direction.
/// Repeatedly activates pane direction until at edge.
fn moveToEdge(pid: i32, dir: Direction, _: u32) void {
    var env = resolveEnv(pid) orelse return;
    const dir_str = directionStr(dir);
    const max_moves = 50; // Safety limit

    var i: u32 = 0;
    while (i < max_moves) : (i += 1) {
        const pane_id = env.paneId();

        // Check if there's a pane in the target direction
        var check_buf: [64]u8 = undefined;
        const neighbor = if (env.socketPath()) |sock|
            runWezterm(&.{ "wezterm", "cli", "--unix-socket", sock, "get-pane-direction", "--pane-id", pane_id, dir_str }, &check_buf)
        else
            runWezterm(&.{ "wezterm", "cli", "get-pane-direction", "--pane-id", pane_id, dir_str }, &check_buf);

        if (neighbor == null) break; // At edge (empty output) or error

        // Move one step
        var move_buf: [64]u8 = undefined;
        if (env.socketPath()) |sock| {
            _ = runWezterm(&.{ "wezterm", "cli", "--unix-socket", sock, "activate-pane-direction", "--pane-id", pane_id, dir_str }, &move_buf);
        } else {
            _ = runWezterm(&.{ "wezterm", "cli", "activate-pane-direction", "--pane-id", pane_id, dir_str }, &move_buf);
        }

        // Update pane ID for next iteration — the neighbor pane_id is now active
        if (neighbor) |n| {
            if (n.len <= env.pane_id_buf.len) {
                @memcpy(env.pane_id_buf[0..n.len], n);
                env.pane_id_len = n.len;
            }
        }
    }

    log.log("wezterm moveToEdge {s}: moved {d} panes", .{ dir_str, i });
}

// ─── Helpers ───

/// Map direction to WezTerm direction string.
fn directionStr(dir: Direction) []const u8 {
    return switch (dir) {
        .left => "Left",
        .right => "Right",
        .up => "Up",
        .down => "Down",
    };
}

/// Resolved WezTerm environment for CLI commands.
const WeztermEnv = struct {
    socket_buf: [256]u8 = undefined,
    socket_len: ?usize = null,

    pane_id_buf: [32]u8 = undefined,
    pane_id_len: usize = 0,

    fn socketPath(self: *const WeztermEnv) ?[]const u8 {
        if (self.socket_len) |len| return self.socket_buf[0..len];
        return null;
    }

    fn paneId(self: *const WeztermEnv) []const u8 {
        return self.pane_id_buf[0..self.pane_id_len];
    }
};

/// Resolve WezTerm environment (pane ID and socket path) from a process's
/// /proc/<pid>/environ, falling back to the current process's environment.
fn resolveEnv(pid: i32) ?WeztermEnv {
    var env = WeztermEnv{};

    // Try reading from /proc/<pid>/environ first
    if (readEnvFromProc(pid, &env)) return env;

    // Fall back to current process environment (works when nvg is invoked
    // from within a WezTerm pane — the shell inherits WEZTERM_PANE).
    if (posix.getenv("WEZTERM_PANE")) |pane_id| {
        if (pane_id.len > 0 and pane_id.len <= env.pane_id_buf.len) {
            @memcpy(env.pane_id_buf[0..pane_id.len], pane_id);
            env.pane_id_len = pane_id.len;

            if (posix.getenv("WEZTERM_UNIX_SOCKET")) |sock| {
                if (sock.len <= env.socket_buf.len) {
                    @memcpy(env.socket_buf[0..sock.len], sock);
                    env.socket_len = sock.len;
                }
            }

            log.log("wezterm: resolved from current env: pane={s}", .{pane_id});
            return env;
        }
    }

    log.log("wezterm: failed to resolve env for pid {d}", .{pid});
    return null;
}

/// Try to read WEZTERM_PANE and WEZTERM_UNIX_SOCKET from /proc/<pid>/environ.
/// Returns true if WEZTERM_PANE was found.
fn readEnvFromProc(pid: i32, env: *WeztermEnv) bool {
    var path_buf: [64]u8 = undefined;
    const environ_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/environ", .{pid}) catch return false;

    var environ_buf: [8192]u8 = undefined;
    const content = process.readFileToBuffer(environ_path, &environ_buf) orelse return false;

    var found_pane = false;

    // /proc/<pid>/environ is null-separated KEY=VALUE pairs
    var it = std.mem.splitScalar(u8, content, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;

        if (std.mem.startsWith(u8, entry, "WEZTERM_PANE=")) {
            const val = entry["WEZTERM_PANE=".len..];
            if (val.len > 0 and val.len <= env.pane_id_buf.len) {
                @memcpy(env.pane_id_buf[0..val.len], val);
                env.pane_id_len = val.len;
                found_pane = true;
                log.log("wezterm: found WEZTERM_PANE={s} in /proc/{d}/environ", .{ val, pid });
            }
        } else if (std.mem.startsWith(u8, entry, "WEZTERM_UNIX_SOCKET=")) {
            const val = entry["WEZTERM_UNIX_SOCKET=".len..];
            if (val.len <= env.socket_buf.len) {
                @memcpy(env.socket_buf[0..val.len], val);
                env.socket_len = val.len;
                log.log("wezterm: found WEZTERM_UNIX_SOCKET={s} in /proc/{d}/environ", .{ val, pid });
            }
        }
    }

    return found_pane;
}

/// Fork/exec the wezterm CLI and capture stdout into the provided buffer.
/// Returns the trimmed stdout content, or null on failure/empty output.
fn runWezterm(argv: []const []const u8, out_buf: []u8) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = argv,
    }) catch return null;

    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) return null;

    const trimmed = std.mem.trimRight(u8, result.stdout, "\n\r \t");
    if (trimmed.len == 0) return null;
    if (trimmed.len > out_buf.len) return null;

    @memcpy(out_buf[0..trimmed.len], trimmed);
    return out_buf[0..trimmed.len];
}

// ─── Tests ───

test "detect matches wezterm" {
    try std.testing.expectEqual(@as(?i32, 10), detect(10, "wezterm", "", ""));
    try std.testing.expectEqual(@as(?i32, 10), detect(10, "wezterm-gui", "", ""));
    try std.testing.expectEqual(@as(?i32, 10), detect(10, "bash", "/usr/bin/wezterm-gui", ""));
    try std.testing.expectEqual(@as(?i32, 10), detect(10, "wezterm-mux-server", "", ""));
}

test "detect rejects non-wezterm" {
    try std.testing.expectEqual(@as(?i32, null), detect(10, "bash", "/usr/bin/bash", ""));
    try std.testing.expectEqual(@as(?i32, null), detect(10, "alacritty", "/usr/bin/alacritty", ""));
}

test "directionStr" {
    try std.testing.expectEqualStrings("Left", directionStr(.left));
    try std.testing.expectEqualStrings("Right", directionStr(.right));
    try std.testing.expectEqualStrings("Up", directionStr(.up));
    try std.testing.expectEqualStrings("Down", directionStr(.down));
}

test "readEnvFromProc reads current process environ" {
    // This test works because the test runner IS a process with /proc/self/environ.
    // It won't find WEZTERM_PANE unless running inside WezTerm, so we just
    // verify it doesn't crash. If WEZTERM_PANE happens to be set, it should succeed.
    var env = WeztermEnv{};
    const pid: i32 = @intCast(std.os.linux.getpid());
    _ = readEnvFromProc(pid, &env);
    // No assertion — just verify no crash
}

test "readEnvFromProc returns false for nonexistent pid" {
    var env = WeztermEnv{};
    try std.testing.expect(!readEnvFromProc(4194304, &env));
}

test "WeztermEnv paneId returns correct slice" {
    var env = WeztermEnv{};
    const id = "42";
    @memcpy(env.pane_id_buf[0..id.len], id);
    env.pane_id_len = id.len;
    try std.testing.expectEqualStrings("42", env.paneId());
}

test "WeztermEnv socketPath returns null when not set" {
    const env = WeztermEnv{};
    try std.testing.expectEqual(@as(?[]const u8, null), env.socketPath());
}

test "WeztermEnv socketPath returns path when set" {
    var env = WeztermEnv{};
    const path = "/tmp/wezterm.sock";
    @memcpy(env.socket_buf[0..path.len], path);
    env.socket_len = path.len;
    try std.testing.expectEqualStrings("/tmp/wezterm.sock", env.socketPath().?);
}
