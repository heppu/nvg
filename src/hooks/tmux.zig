/// Tmux hook — detect tmux client processes and navigate panes.
///
/// Detection: matches processes where argv[0] or /proc/<pid>/exe contains "tmux".
/// The detected PID is the tmux client process (child of the terminal's shell).
///
/// Navigation: forks/execs the `tmux` CLI binary to query pane edge status and
/// send select-pane commands. The tmux socket path is discovered from the
/// client's /proc/<pid>/cmdline (-S/-L flags) or defaults to /tmp/tmux-$UID/default.
const std = @import("std");
const posix = std.posix;

const Hook = @import("../hook.zig").Hook;
const DetectedList = @import("../hook.zig").DetectedList;
const Direction = @import("../main.zig").Direction;
const process = @import("../process.zig");
const log = @import("../log.zig");

pub const hook = Hook{
    .name = "tmux",
    .detectFn = &detect,
    .canMoveFn = &canMove,
    .moveFocusFn = &moveFocus,
    .moveToEdgeFn = &moveToEdge,
    .discoverInnerFn = &discoverInner,
};

fn detect(child_pid: i32, cmd: []const u8, exe: []const u8, _: []const u8) ?i32 {
    if (std.mem.indexOf(u8, cmd, "tmux") != null or
        std.mem.indexOf(u8, exe, "tmux") != null)
    {
        return child_pid;
    }
    return null;
}

/// Check if the active tmux pane can move focus in the given direction.
/// Returns true if not at edge, false if at edge, null on error.
fn canMove(pid: i32, dir: Direction, _: u32) ?bool {
    var socket_buf: [256]u8 = undefined;
    const socket_path = tmuxSocketPath(&socket_buf, pid) orelse return null;

    var target_buf: [256]u8 = undefined;
    const target = getClientTarget(socket_path, pid, &target_buf) orelse return null;

    // Query pane edge status using the client's active pane ID.
    // display-message -t <pane_id> -p '#{pane_at_left}#{pane_at_right}#{pane_at_top}#{pane_at_bottom}'
    // Returns 4 chars like "0100" (at_left=0, at_right=1, at_top=0, at_bottom=0)
    const fmt = "#{pane_at_left}#{pane_at_right}#{pane_at_top}#{pane_at_bottom}";
    const argv = [_][]const u8{ "tmux", "-S", socket_path, "display-message", "-t", target.pane_id, "-p", fmt };

    var out_buf: [64]u8 = undefined;
    const output = runTmux(&argv, &out_buf) orelse return null;
    log.log("tmux pane edges: '{s}' (LRTB)", .{output});

    if (output.len < 4) return null;

    const at_edge = switch (dir) {
        .left => output[0] == '1',
        .right => output[1] == '1',
        .up => output[2] == '1',
        .down => output[3] == '1',
    };

    return !at_edge;
}

/// Move tmux pane focus one step in the given direction.
fn moveFocus(pid: i32, dir: Direction, _: u32) void {
    var socket_buf: [256]u8 = undefined;
    const socket_path = tmuxSocketPath(&socket_buf, pid) orelse return;

    var target_buf: [256]u8 = undefined;
    const target = getClientTarget(socket_path, pid, &target_buf) orelse return;

    const dir_flag = directionFlag(dir);
    const argv = [_][]const u8{ "tmux", "-S", socket_path, "select-pane", "-t", target.pane_id, dir_flag };

    var out_buf: [64]u8 = undefined;
    _ = runTmux(&argv, &out_buf);
    log.log("tmux select-pane {s}", .{dir_flag});
}

/// Move tmux focus to the edge pane in the given direction.
/// Finds panes at the target edge and selects the first one.
fn moveToEdge(pid: i32, dir: Direction, _: u32) void {
    var socket_buf: [256]u8 = undefined;
    const socket_path = tmuxSocketPath(&socket_buf, pid) orelse return;

    var target_buf: [256]u8 = undefined;
    const target = getClientTarget(socket_path, pid, &target_buf) orelse return;

    // Build filter: '#{pane_at_left}' etc.
    const edge_var = switch (dir) {
        .left => "#{pane_at_left}",
        .right => "#{pane_at_right}",
        .up => "#{pane_at_top}",
        .down => "#{pane_at_bottom}",
    };

    // list-panes -t <session:window> -f '<edge_var>' -F '#{pane_id}'
    const list_argv = [_][]const u8{ "tmux", "-S", socket_path, "list-panes", "-t", target.session_window, "-f", edge_var, "-F", "#{pane_id}" };

    var list_buf: [512]u8 = undefined;
    const list_output = runTmux(&list_argv, &list_buf) orelse return;

    // First line is the first edge pane ID (e.g., "%3")
    const pane_id = firstLine(list_output);
    if (pane_id.len == 0) return;

    log.log("tmux moveToEdge: selecting pane {s}", .{pane_id});

    // select-pane -t <pane_id>
    const select_argv = [_][]const u8{ "tmux", "-S", socket_path, "select-pane", "-t", pane_id };

    var select_buf: [64]u8 = undefined;
    _ = runTmux(&select_argv, &select_buf);
}

// ─── Inner process discovery ───

/// Discover hooks running inside this tmux client's active pane.
/// Queries the pane's foreground process PID and walks its process tree
/// to find inner applications (e.g., nvim running inside a tmux pane).
fn discoverInner(pid: i32, enabled_hooks: []const *const Hook, result: *DetectedList, depth: u32) void {
    var socket_buf: [256]u8 = undefined;
    const socket_path = tmuxSocketPath(&socket_buf, pid) orelse return;

    var target_buf: [256]u8 = undefined;
    const target = getClientTarget(socket_path, pid, &target_buf) orelse return;

    // Query the PID of the process running in the active pane.
    // tmux display-message -t <pane_id> -p '#{pane_pid}'
    const argv = [_][]const u8{ "tmux", "-S", socket_path, "display-message", "-t", target.pane_id, "-p", "#{pane_pid}" };

    var out_buf: [64]u8 = undefined;
    const output = runTmux(&argv, &out_buf) orelse return;

    const pane_pid = parsePanePid(output) orelse return;
    log.log("tmux: pane {s} has PID {d}, walking inner tree", .{ target.pane_id, pane_pid });

    process.walkTree(pane_pid, enabled_hooks, result, depth);
}

/// Parse a numeric PID from tmux display-message output (e.g., "12345").
fn parsePanePid(output: []const u8) ?i32 {
    const trimmed = std.mem.trimRight(u8, output, "\n\r \t");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i32, trimmed, 10) catch null;
}

// ─── Helpers ───

/// Map direction to tmux select-pane flag.
fn directionFlag(dir: Direction) []const u8 {
    return switch (dir) {
        .left => "-L",
        .right => "-R",
        .up => "-U",
        .down => "-D",
    };
}

/// Get the first line from output (up to newline or end).
fn firstLine(output: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, output, '\n')) |pos| {
        return output[0..pos];
    }
    return output;
}

/// Result of resolving a tmux client's active target.
const ClientTarget = struct {
    /// Pane ID (e.g. "%3") — used as -t target for display-message and select-pane.
    pane_id: []const u8,
    /// Session and window (e.g. "0:1") — used as -t target for list-panes.
    session_window: []const u8,
};

/// Get the active pane ID and session:window for a tmux client PID.
/// Runs: tmux -S <socket> list-clients -f '#{==:#{client_pid},<PID>}' -F '#{pane_id}|#{session_name}:#{window_index}'
fn getClientTarget(socket_path: []const u8, client_pid: i32, target_buf: []u8) ?ClientTarget {
    var filter_buf: [64]u8 = undefined;
    const filter = std.fmt.bufPrint(&filter_buf, "#{{==:#{{client_pid}},{d}}}", .{client_pid}) catch return null;

    const argv = [_][]const u8{ "tmux", "-S", socket_path, "list-clients", "-f", filter, "-F", "#{pane_id}|#{session_name}:#{window_index}" };

    var out_buf: [256]u8 = undefined;
    const output = runTmux(&argv, &out_buf) orelse return null;

    const line = firstLine(output);
    const result = parseClientTarget(line, target_buf) orelse {
        log.log("tmux: no target found for client PID {d}", .{client_pid});
        return null;
    };
    log.log("tmux: client PID {d} -> pane={s} session:window={s}", .{ client_pid, result.pane_id, result.session_window });
    return result;
}

/// Parse "pane_id|session_name:window_index" (e.g. "%3|myses:1") into a ClientTarget.
/// Copies the data into target_buf so it outlives the source.
fn parseClientTarget(line: []const u8, target_buf: []u8) ?ClientTarget {
    if (line.len == 0) return null;

    const sep = std.mem.indexOfScalar(u8, line, '|') orelse return null;
    const pane_id_src = line[0..sep];
    const session_window_src = line[sep + 1 ..];

    if (pane_id_src.len == 0 or session_window_src.len == 0) return null;

    const total = pane_id_src.len + session_window_src.len;
    if (total > target_buf.len) return null;

    // Copy pane_id then session_window contiguously into target_buf.
    @memcpy(target_buf[0..pane_id_src.len], pane_id_src);
    @memcpy(target_buf[pane_id_src.len .. pane_id_src.len + session_window_src.len], session_window_src);

    return .{
        .pane_id = target_buf[0..pane_id_src.len],
        .session_window = target_buf[pane_id_src.len .. pane_id_src.len + session_window_src.len],
    };
}

/// Discover the tmux socket path from the client process's cmdline.
///
/// Parses /proc/<pid>/cmdline for:
///   -S <path>     → use literal path
///   -L <name>     → $TMUX_TMPDIR/tmux-$UID/<name> (TMUX_TMPDIR defaults to /tmp)
///   (neither)     → $TMUX_TMPDIR/tmux-$UID/default
///
/// The UID is read from /proc/<pid>/status to avoid depending on environment variables.
fn tmuxSocketPath(buf: []u8, client_pid: i32) ?[]const u8 {
    // Read the client's cmdline
    var cmdline_path_buf: [64]u8 = undefined;
    const cmdline_path = std.fmt.bufPrint(&cmdline_path_buf, "/proc/{d}/cmdline", .{client_pid}) catch return null;

    var cmdline_buf: [4096]u8 = undefined;
    const cmdline = process.readFileToBuffer(cmdline_path, &cmdline_buf) orelse return null;

    // Parse null-separated argv for -S or -L flags
    var socket_flag: ?[]const u8 = null; // value after -S
    var name_flag: ?[]const u8 = null; // value after -L

    var it = CmdlineIterator{ .data = cmdline };
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-S")) {
            socket_flag = it.next();
        } else if (std.mem.eql(u8, arg, "-L")) {
            name_flag = it.next();
        } else if (arg.len > 2 and arg[0] == '-' and arg[1] == 'S') {
            // -S<path> (no space)
            socket_flag = arg[2..];
        } else if (arg.len > 2 and arg[0] == '-' and arg[1] == 'L') {
            // -L<name> (no space)
            name_flag = arg[2..];
        }
    }

    if (socket_flag) |path| {
        log.log("tmux: socket from -S flag: {s}", .{path});
        if (path.len >= buf.len) return null;
        @memcpy(buf[0..path.len], path);
        return buf[0..path.len];
    }

    // Need UID and tmpdir for -L and default cases
    const uid = getProcessUid(client_pid) orelse return null;
    const tmpdir = posix.getenv("TMUX_TMPDIR") orelse "/tmp";

    if (name_flag) |name| {
        log.log("tmux: socket from -L flag: name={s}", .{name});
        return std.fmt.bufPrint(buf, "{s}/tmux-{d}/{s}", .{ tmpdir, uid, name }) catch null;
    }

    // Default socket path
    return std.fmt.bufPrint(buf, "{s}/tmux-{d}/default", .{ tmpdir, uid }) catch null;
}

/// Read the real UID of a process from /proc/<pid>/status.
fn getProcessUid(pid: i32) ?u32 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid}) catch return null;

    var status_buf: [4096]u8 = undefined;
    const content = process.readFileToBuffer(path, &status_buf) orelse return null;

    // Find "Uid:\t<real_uid>\t..."
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Uid:\t")) {
            const uid_start = line["Uid:\t".len..];
            // Real UID is the first field (tab-separated)
            const uid_str = blk: {
                if (std.mem.indexOfScalar(u8, uid_start, '\t')) |end| {
                    break :blk uid_start[0..end];
                }
                break :blk uid_start;
            };
            return std.fmt.parseInt(u32, uid_str, 10) catch null;
        }
    }
    return null;
}

/// Iterator over null-separated cmdline entries from /proc/<pid>/cmdline.
const CmdlineIterator = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *CmdlineIterator) ?[]const u8 {
        if (self.pos >= self.data.len) return null;

        const start = self.pos;
        if (std.mem.indexOfScalarPos(u8, self.data, start, 0)) |end| {
            self.pos = end + 1;
            if (start == end) return self.next(); // skip empty
            return self.data[start..end];
        }
        // No null terminator found — return rest
        if (start < self.data.len) {
            self.pos = self.data.len;
            return self.data[start..];
        }
        return null;
    }
};

/// Fork/exec the tmux CLI and capture stdout into the provided buffer.
/// Returns the trimmed stdout content, or null on failure.
fn runTmux(argv: []const []const u8, out_buf: []u8) ?[]const u8 {
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

test "detect matches tmux" {
    try std.testing.expectEqual(@as(?i32, 10), detect(10, "tmux", "", ""));
    try std.testing.expectEqual(@as(?i32, 10), detect(10, "bash", "/usr/bin/tmux", ""));
}

test "detect rejects non-tmux" {
    try std.testing.expectEqual(@as(?i32, null), detect(10, "bash", "/usr/bin/bash", ""));
}

test "directionFlag" {
    try std.testing.expectEqualStrings("-L", directionFlag(.left));
    try std.testing.expectEqualStrings("-R", directionFlag(.right));
    try std.testing.expectEqualStrings("-U", directionFlag(.up));
    try std.testing.expectEqualStrings("-D", directionFlag(.down));
}

test "firstLine" {
    try std.testing.expectEqualStrings("hello", firstLine("hello\nworld"));
    try std.testing.expectEqualStrings("hello", firstLine("hello"));
    try std.testing.expectEqualStrings("", firstLine(""));
}

test "CmdlineIterator parses null-separated cmdline" {
    const data = "tmux\x00new-session\x00-s\x00main\x00";
    var it = CmdlineIterator{ .data = data };
    try std.testing.expectEqualStrings("tmux", it.next().?);
    try std.testing.expectEqualStrings("new-session", it.next().?);
    try std.testing.expectEqualStrings("-s", it.next().?);
    try std.testing.expectEqualStrings("main", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "CmdlineIterator handles -S flag" {
    const data = "tmux\x00-S\x00/tmp/my.sock\x00attach\x00";
    var it = CmdlineIterator{ .data = data };
    try std.testing.expectEqualStrings("tmux", it.next().?);
    try std.testing.expectEqualStrings("-S", it.next().?);
    try std.testing.expectEqualStrings("/tmp/my.sock", it.next().?);
    try std.testing.expectEqualStrings("attach", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "CmdlineIterator handles -L flag" {
    const data = "tmux\x00-L\x00mysock\x00attach\x00";
    var it = CmdlineIterator{ .data = data };
    try std.testing.expectEqualStrings("tmux", it.next().?);
    try std.testing.expectEqualStrings("-L", it.next().?);
    try std.testing.expectEqualStrings("mysock", it.next().?);
    try std.testing.expectEqualStrings("attach", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "CmdlineIterator skips empty entries" {
    const data = "a\x00\x00b\x00";
    var it = CmdlineIterator{ .data = data };
    try std.testing.expectEqualStrings("a", it.next().?);
    try std.testing.expectEqualStrings("b", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "CmdlineIterator handles data without trailing null" {
    const data = "tmux\x00attach";
    var it = CmdlineIterator{ .data = data };
    try std.testing.expectEqualStrings("tmux", it.next().?);
    try std.testing.expectEqualStrings("attach", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "getProcessUid reads current process UID" {
    const pid: i32 = @intCast(std.os.linux.getpid());
    const uid = getProcessUid(pid);
    // Should succeed and match the real UID
    try std.testing.expect(uid != null);
    try std.testing.expectEqual(std.os.linux.getuid(), uid.?);
}

test "getProcessUid returns null for nonexistent pid" {
    // PID 0 is the kernel scheduler, its /proc/0/status doesn't exist
    // Use a very high PID that almost certainly doesn't exist
    try std.testing.expectEqual(@as(?u32, null), getProcessUid(4194304));
}

test "parseClientTarget parses pane_id and session:window" {
    var buf: [64]u8 = undefined;
    const target = parseClientTarget("%3|myses:1", &buf).?;
    try std.testing.expectEqualStrings("%3", target.pane_id);
    try std.testing.expectEqualStrings("myses:1", target.session_window);
}

test "parseClientTarget handles numeric session name" {
    var buf: [64]u8 = undefined;
    const target = parseClientTarget("%0|0:0", &buf).?;
    try std.testing.expectEqualStrings("%0", target.pane_id);
    try std.testing.expectEqualStrings("0:0", target.session_window);
}

test "parseClientTarget returns null for empty input" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?ClientTarget, null), parseClientTarget("", &buf));
}

test "parseClientTarget returns null for missing separator" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?ClientTarget, null), parseClientTarget("%3", &buf));
}

test "parseClientTarget returns null for empty pane_id" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?ClientTarget, null), parseClientTarget("|0:1", &buf));
}

test "parseClientTarget returns null for empty session_window" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?ClientTarget, null), parseClientTarget("%3|", &buf));
}

test "parsePanePid parses valid PID" {
    try std.testing.expectEqual(@as(?i32, 12345), parsePanePid("12345"));
    try std.testing.expectEqual(@as(?i32, 1), parsePanePid("1"));
}

test "parsePanePid handles trailing whitespace" {
    try std.testing.expectEqual(@as(?i32, 12345), parsePanePid("12345\n"));
    try std.testing.expectEqual(@as(?i32, 42), parsePanePid("42\r\n"));
    try std.testing.expectEqual(@as(?i32, 99), parsePanePid("99 "));
}

test "parsePanePid returns null for invalid input" {
    try std.testing.expectEqual(@as(?i32, null), parsePanePid(""));
    try std.testing.expectEqual(@as(?i32, null), parsePanePid("abc"));
    try std.testing.expectEqual(@as(?i32, null), parsePanePid("\n"));
}
