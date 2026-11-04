/// Herdr hook — detect the herdr TUI client and navigate its panes and workspaces.
///
/// Detection: matches processes whose argv[0] or /proc/<pid>/exe basename is
/// "herdr", excluding the server daemon (`herdr server`), remote attach
/// (`herdr --remote`, `herdr --machine`) and one-shot CLI subcommands.
///
/// Navigation: talks newline-delimited JSON to the herdr server socket
/// (pane.edges, pane.focus_direction, workspace.list, workspace.focus,
/// pane.process_info). Splits inside the active tab are navigated first.
/// At a vertical edge, up/down step to the previous/next workspace, which is
/// how herdr lists agent sessions in its sidebar. Left/right at the edge and
/// the first/last workspace bubble up to the window manager.
///
/// Socket path resolution mirrors herdr: `--session <name>` from the client's
/// cmdline, then HERDR_SOCKET_PATH and HERDR_SESSION from the client's
/// /proc/<pid>/environ, then `<config>/herdr.sock` where `<config>` is
/// $XDG_CONFIG_HOME/herdr or ~/.config/herdr.
const std = @import("std");
const posix = std.posix;

const Hook = @import("../hook.zig").Hook;
const DetectedList = @import("../hook.zig").DetectedList;
const Direction = @import("../direction.zig").Direction;
const process = @import("../process.zig");
const net = @import("../net.zig");
const log = @import("../log.zig");

pub const hook = Hook{
    .name = "herdr",
    .detectFn = &detect,
    .canMoveFn = &canMove,
    .moveFocusFn = &moveFocus,
    .moveToEdgeFn = &moveToEdge,
    .discoverInnerFn = &discoverInner,
};

/// discoverInner has no timeout parameter, so inner discovery uses its own.
const discover_timeout_ms: u32 = 250;

/// Safety limit for moveToEdge loops.
const max_edge_moves: u32 = 50;

fn detect(child_pid: i32, cmd: []const u8, exe: []const u8, arg: []const u8) ?i32 {
    if (!isHerdrBinary(cmd) and !isHerdrBinary(exe)) return null;
    if (!isClientArg(arg)) return null;
    if (isRemoteAttach(child_pid)) return null;
    return child_pid;
}

fn isHerdrBinary(s: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(s), "herdr");
}

/// The TUI client runs as `herdr`, `herdr --session <name>` or
/// `herdr session attach <name>`. Everything else is the server, the thin
/// client spawned by remote attach (`herdr client`) or a one-shot CLI call.
fn isClientArg(arg: []const u8) bool {
    if (arg.len == 0) return true;
    if (std.mem.eql(u8, arg, "session")) return true;
    if (isRemoteFlag(arg)) return false;
    return arg[0] == '-';
}

fn isRemoteFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--remote") or std.mem.startsWith(u8, arg, "--remote=") or
        std.mem.eql(u8, arg, "--machine") or std.mem.startsWith(u8, arg, "--machine=");
}

/// `herdr --remote <host>` attaches to a server on another machine and only
/// forwards the client protocol, so its JSON API is unreachable from here.
/// The flag can follow `--session`, so the whole command line is checked.
fn isRemoteAttach(pid: i32) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pid}) catch return false;
    var buf: [4096]u8 = undefined;
    const cmdline = process.readFileToBuffer(path, &buf) orelse return false;
    return cmdlineIsRemote(cmdline);
}

fn cmdlineIsRemote(cmdline: []const u8) bool {
    var it = std.mem.splitScalar(u8, cmdline, 0);
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--")) return false;
        if (isRemoteFlag(arg)) return true;
    }
    return false;
}

/// Check if herdr can move focus in the given direction.
/// Returns true if a neighboring pane exists, or for up/down if a
/// previous/next workspace exists. Returns false at the edge, null on error.
fn canMove(pid: i32, dir: Direction, timeout_ms: u32) ?bool {
    const ep = resolveEndpoint(pid) orelse return null;
    var buf: [16384]u8 = undefined;
    const edges = queryEdges(&ep, timeout_ms, &buf) orelse return null;
    if (!edges.atEdge(dir)) return true;
    if (dir == .left or dir == .right) return false;

    var id_buf: [64]u8 = undefined;
    return workspaceNeighbor(&ep, dir, timeout_ms, &id_buf) != null;
}

/// Move herdr focus one step: to the neighboring pane, or at a vertical
/// edge to the previous/next workspace.
fn moveFocus(pid: i32, dir: Direction, timeout_ms: u32) void {
    const ep = resolveEndpoint(pid) orelse return;
    var buf: [16384]u8 = undefined;
    const edges = queryEdges(&ep, timeout_ms, &buf) orelse return;
    if (!edges.atEdge(dir)) {
        _ = focusDirection(&ep, dir, timeout_ms, &buf);
        log.log("herdr: pane focus {s}", .{@tagName(dir)});
        return;
    }
    if (dir == .left or dir == .right) return;

    var id_buf: [64]u8 = undefined;
    const workspace_id = workspaceNeighbor(&ep, dir, timeout_ms, &id_buf) orelse return;
    focusWorkspace(&ep, workspace_id, timeout_ms, &buf);
    log.log("herdr: workspace focus {s}", .{workspace_id});
}

/// Move pane focus within the active tab until the edge is reached.
/// Never switches workspace: landing in a herdr window from the WM should
/// not change which agent session is shown.
fn moveToEdge(pid: i32, dir: Direction, timeout_ms: u32) void {
    const ep = resolveEndpoint(pid) orelse return;
    var buf: [16384]u8 = undefined;

    var i: u32 = 0;
    while (i < max_edge_moves) : (i += 1) {
        const changed = focusDirection(&ep, dir, timeout_ms, &buf) orelse break;
        if (!changed) break;
    }
    log.log("herdr moveToEdge {s}: moved {d} panes", .{ @tagName(dir), i });
}

/// Discover hooks running inside the focused herdr pane. Pane processes are
/// children of the herdr server, not of the terminal, so the client's process
/// tree never reaches them.
fn discoverInner(pid: i32, enabled_hooks: []const *const Hook, result: *DetectedList, depth: u32) void {
    const ep = resolveEndpoint(pid) orelse return;
    var buf: [32768]u8 = undefined;
    const response = request(&ep, "pane.process_info", "{}", discover_timeout_ms, &buf) orelse return;
    const shell_pid = parseShellPid(response) orelse return;
    log.log("herdr: focused pane shell PID {d}, walking inner tree", .{shell_pid});
    process.walkTree(shell_pid, enabled_hooks, result, depth);
}

// ─── RPC ───

const Endpoint = struct {
    path_buf: [net.max_socket_path]u8 = undefined,
    path_len: usize = 0,

    fn path(self: *const Endpoint) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

/// Open a fresh connection, send one request line, read one response line.
fn request(ep: *const Endpoint, method: []const u8, params: []const u8, timeout_ms: u32, buf: []u8) ?[]const u8 {
    const addr = net.makeUnixAddr(ep.path()) catch return null;
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return null;
    defer posix.close(fd);

    posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch return null;
    net.setTimeouts(fd, timeout_ms) catch return null;

    var req_buf: [512]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "{{\"id\":\"nvg\",\"method\":\"{s}\",\"params\":{s}}}\n", .{ method, params }) catch return null;
    net.writeAll(fd, req) catch return null;

    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(fd, buf[total..]) catch return null;
        if (n == 0) break;
        const start = total;
        total += n;
        if (std.mem.indexOfScalarPos(u8, buf[0..total], start, '\n')) |end| {
            return buf[0..end];
        }
    }
    if (total == 0) return null;
    return buf[0..total];
}

fn queryEdges(ep: *const Endpoint, timeout_ms: u32, buf: []u8) ?Edges {
    const response = request(ep, "pane.edges", "{}", timeout_ms, buf) orelse return null;
    const edges = parseEdges(response) orelse return null;
    log.log("herdr pane edges: L={} R={} U={} D={}", .{ edges.left, edges.right, edges.up, edges.down });
    return edges;
}

/// Returns whether focus changed, null on error.
fn focusDirection(ep: *const Endpoint, dir: Direction, timeout_ms: u32, buf: []u8) ?bool {
    var params_buf: [64]u8 = undefined;
    const params = std.fmt.bufPrint(&params_buf, "{{\"direction\":\"{s}\"}}", .{@tagName(dir)}) catch return null;
    const response = request(ep, "pane.focus_direction", params, timeout_ms, buf) orelse return null;
    return parseFocusChanged(response);
}

/// Resolve the workspace before (up) or after (down) the focused one.
fn workspaceNeighbor(ep: *const Endpoint, dir: Direction, timeout_ms: u32, id_buf: []u8) ?[]const u8 {
    var buf: [16384]u8 = undefined;
    const response = request(ep, "workspace.list", "{}", timeout_ms, &buf) orelse return null;
    return parseWorkspaceNeighbor(response, dir, id_buf);
}

fn focusWorkspace(ep: *const Endpoint, workspace_id: []const u8, timeout_ms: u32, buf: []u8) void {
    var params_buf: [128]u8 = undefined;
    const params = std.fmt.bufPrint(&params_buf, "{{\"workspace_id\":\"{s}\"}}", .{workspace_id}) catch return;
    _ = request(ep, "workspace.focus", params, timeout_ms, buf);
}

// ─── Response parsing ───

const Edges = struct {
    left: bool,
    right: bool,
    up: bool,
    down: bool,

    fn atEdge(self: Edges, dir: Direction) bool {
        return switch (dir) {
            .left => self.left,
            .right => self.right,
            .up => self.up,
            .down => self.down,
        };
    }
};

fn parseJson(data: []const u8) ?std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{}) catch null;
}

/// Look up `result.<name>` in a response.
fn resultField(root: std.json.Value, name: []const u8) ?std.json.Value {
    const obj = asObject(root) orelse return null;
    const result = obj.get("result") orelse return null;
    const result_obj = asObject(result) orelse return null;
    return result_obj.get(name);
}

fn asObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |o| o,
        else => null,
    };
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

/// Parse a `pane.edges` response. In herdr, `true` means the pane touches
/// that edge, so no neighbor exists in that direction.
fn parseEdges(data: []const u8) ?Edges {
    const parsed = parseJson(data) orelse return null;
    defer parsed.deinit();

    const edges = asObject(resultField(parsed.value, "edges") orelse return null) orelse return null;
    return .{
        .left = getBool(edges, "left") orelse return null,
        .right = getBool(edges, "right") orelse return null,
        .up = getBool(edges, "up") orelse return null,
        .down = getBool(edges, "down") orelse return null,
    };
}

/// Parse `result.focus.changed` from a `pane.focus_direction` response.
fn parseFocusChanged(data: []const u8) ?bool {
    const parsed = parseJson(data) orelse return null;
    defer parsed.deinit();

    const focus = asObject(resultField(parsed.value, "focus") orelse return null) orelse return null;
    return getBool(focus, "changed");
}

/// Parse `result.process_info.shell_pid` from a `pane.process_info` response.
fn parseShellPid(data: []const u8) ?i32 {
    const parsed = parseJson(data) orelse return null;
    defer parsed.deinit();

    const info = asObject(resultField(parsed.value, "process_info") orelse return null) orelse return null;
    const pid = info.get("shell_pid") orelse return null;
    return switch (pid) {
        .integer => |i| std.math.cast(i32, i),
        else => null,
    };
}

/// From a `workspace.list` response, find the focused workspace and return
/// the id of the one before it (up) or after it (down). Sidebar order is the
/// array order. No wrapping: returns null at the first/last workspace.
fn parseWorkspaceNeighbor(data: []const u8, dir: Direction, out: []u8) ?[]const u8 {
    const parsed = parseJson(data) orelse return null;
    defer parsed.deinit();

    const list = resultField(parsed.value, "workspaces") orelse return null;
    const items = switch (list) {
        .array => |a| a.items,
        else => return null,
    };

    var focused: ?usize = null;
    for (items, 0..) |item, i| {
        const obj = asObject(item) orelse continue;
        if (getBool(obj, "focused") orelse false) {
            focused = i;
            break;
        }
    }
    const idx = focused orelse return null;

    const target = switch (dir) {
        .up => if (idx == 0) return null else idx - 1,
        .down => if (idx + 1 >= items.len) return null else idx + 1,
        .left, .right => return null,
    };

    const obj = asObject(items[target]) orelse return null;
    const id = switch (obj.get("workspace_id") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (id.len == 0 or id.len > out.len) return null;
    @memcpy(out[0..id.len], id);
    return out[0..id.len];
}

// ─── Socket path resolution ───

const SocketInputs = struct {
    /// `--session <name>` from the client's cmdline.
    cli_session: []const u8 = "",
    /// HERDR_SOCKET_PATH from the client's environment.
    socket_override: []const u8 = "",
    /// HERDR_SESSION from the client's environment.
    env_session: []const u8 = "",
    xdg_config_home: []const u8 = "",
    home: []const u8 = "",
};

/// Build the herdr API socket path following herdr's own precedence:
/// explicit --session, then HERDR_SOCKET_PATH, then HERDR_SESSION, then default.
fn socketPath(buf: []u8, in: SocketInputs) ?[]const u8 {
    if (in.cli_session.len == 0 and in.socket_override.len != 0) {
        if (in.socket_override.len > buf.len) return null;
        @memcpy(buf[0..in.socket_override.len], in.socket_override);
        return buf[0..in.socket_override.len];
    }

    var config_buf: [256]u8 = undefined;
    const config_dir = if (in.xdg_config_home.len != 0)
        std.fmt.bufPrint(&config_buf, "{s}/herdr", .{in.xdg_config_home}) catch return null
    else if (in.home.len != 0)
        std.fmt.bufPrint(&config_buf, "{s}/.config/herdr", .{in.home}) catch return null
    else
        return null;

    const session = if (in.cli_session.len != 0) in.cli_session else in.env_session;
    if (session.len != 0) {
        return std.fmt.bufPrint(buf, "{s}/sessions/{s}/herdr.sock", .{ config_dir, session }) catch null;
    }
    return std.fmt.bufPrint(buf, "{s}/herdr.sock", .{config_dir}) catch null;
}

/// Extract the session name from a null-separated cmdline:
/// `--session <name>`, `--session=<name>` or `session attach <name>`.
fn sessionFromCmdline(cmdline: []const u8, out: []u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, cmdline, 0);
    var prev: []const u8 = "";
    var prev2: []const u8 = "";
    while (it.next()) |arg| {
        if (arg.len == 0) continue;

        var name: ?[]const u8 = null;
        if (std.mem.eql(u8, prev, "--session")) {
            name = arg;
        } else if (std.mem.startsWith(u8, arg, "--session=")) {
            name = arg["--session=".len..];
        } else if (std.mem.eql(u8, prev2, "session") and std.mem.eql(u8, prev, "attach")) {
            name = arg;
        }

        if (name) |n| {
            if (n.len == 0 or n.len > out.len) return null;
            @memcpy(out[0..n.len], n);
            return out[0..n.len];
        }
        prev2 = prev;
        prev = arg;
    }
    return null;
}

fn resolveEndpoint(pid: i32) ?Endpoint {
    var cmdline_path_buf: [64]u8 = undefined;
    const cmdline_path = std.fmt.bufPrint(&cmdline_path_buf, "/proc/{d}/cmdline", .{pid}) catch return null;
    var cmdline_buf: [4096]u8 = undefined;
    const cmdline = process.readFileToBuffer(cmdline_path, &cmdline_buf) orelse return null;

    var cli_session_buf: [128]u8 = undefined;
    const cli_session = sessionFromCmdline(cmdline, &cli_session_buf) orelse "";

    var socket_buf: [net.max_socket_path]u8 = undefined;
    var socket_len: usize = 0;
    var env_session_buf: [128]u8 = undefined;
    var env_session_len: usize = 0;
    var xdg_buf: [256]u8 = undefined;
    var xdg_len: usize = 0;
    var home_buf: [256]u8 = undefined;
    var home_len: usize = 0;
    _ = process.readProcEnviron(pid, &.{
        .{ .key = "HERDR_SOCKET_PATH", .buf = &socket_buf, .len = &socket_len },
        .{ .key = "HERDR_SESSION", .buf = &env_session_buf, .len = &env_session_len },
        .{ .key = "XDG_CONFIG_HOME", .buf = &xdg_buf, .len = &xdg_len },
        .{ .key = "HOME", .buf = &home_buf, .len = &home_len },
    });

    // nvg is usually spawned by the WM as the same user, so its own HOME is a
    // reasonable fallback when the client's environ is unreadable.
    const home = if (home_len != 0) home_buf[0..home_len] else posix.getenv("HOME") orelse "";

    var ep = Endpoint{};
    const path = socketPath(&ep.path_buf, .{
        .cli_session = cli_session,
        .socket_override = socket_buf[0..socket_len],
        .env_session = env_session_buf[0..env_session_len],
        .xdg_config_home = xdg_buf[0..xdg_len],
        .home = home,
    }) orelse {
        log.log("herdr: failed to resolve socket path for pid {d}", .{pid});
        return null;
    };
    ep.path_len = path.len;
    log.log("herdr: socket {s}", .{ep.path()});
    return ep;
}

// ─── Tests ───

const testing = std.testing;

test "detect matches herdr client" {
    try testing.expectEqual(@as(?i32, 10), detect(10, "herdr", "", ""));
    try testing.expectEqual(@as(?i32, 10), detect(10, "herdr", "/usr/local/bin/herdr", ""));
    try testing.expectEqual(@as(?i32, 10), detect(10, "zsh", "/usr/local/bin/herdr", ""));
    try testing.expectEqual(@as(?i32, 10), detect(10, "herdr", "", "--session"));
    try testing.expectEqual(@as(?i32, 10), detect(10, "herdr", "", "session"));
}

test "detect rejects server, remote attach and CLI calls" {
    try testing.expectEqual(@as(?i32, null), detect(10, "herdr", "", "server"));
    try testing.expectEqual(@as(?i32, null), detect(10, "herdr", "", "client"));
    try testing.expectEqual(@as(?i32, null), detect(10, "herdr", "", "--remote"));
    try testing.expectEqual(@as(?i32, null), detect(10, "herdr", "", "--remote=workbox"));
    try testing.expectEqual(@as(?i32, null), detect(10, "herdr", "", "--machine"));
    try testing.expectEqual(@as(?i32, null), detect(10, "herdr", "", "--machine=build"));
    try testing.expectEqual(@as(?i32, null), detect(10, "herdr", "", "pane"));
    try testing.expectEqual(@as(?i32, null), detect(10, "/usr/local/bin/herdr", "", "agent"));
}

test "cmdlineIsRemote finds the remote flag after other options" {
    try testing.expect(cmdlineIsRemote("herdr\x00--remote\x00workbox\x00"));
    try testing.expect(cmdlineIsRemote("herdr\x00--remote=workbox\x00"));
    try testing.expect(cmdlineIsRemote("herdr\x00--session\x00agents\x00--remote\x00workbox\x00"));
    try testing.expect(cmdlineIsRemote("herdr\x00--remote\x00workbox\x00--session\x00agents\x00"));
    try testing.expect(cmdlineIsRemote("herdr\x00--machine\x00build\x00pane\x00list\x00"));
}

test "cmdlineIsRemote ignores local clients and arguments after --" {
    try testing.expect(!cmdlineIsRemote("herdr\x00"));
    try testing.expect(!cmdlineIsRemote("herdr\x00--session\x00agents\x00"));
    try testing.expect(!cmdlineIsRemote("herdr\x00session\x00attach\x00agents\x00"));
    try testing.expect(!cmdlineIsRemote("herdr\x00--\x00--remote\x00"));
    try testing.expect(!cmdlineIsRemote("--remote\x00"));
    try testing.expect(!cmdlineIsRemote(""));
}

test "isRemoteAttach is false for the current process and a missing pid" {
    try testing.expect(!isRemoteAttach(@intCast(std.os.linux.getpid())));
    try testing.expect(!isRemoteAttach(-1));
}

test "detect rejects non-herdr" {
    try testing.expectEqual(@as(?i32, null), detect(10, "bash", "/usr/bin/bash", ""));
    try testing.expectEqual(@as(?i32, null), detect(10, "herdr-app", "/usr/bin/herdr-app", ""));
    try testing.expectEqual(@as(?i32, null), detect(10, "", "/usr/bin/herdrd", ""));
}

test "Edges.atEdge" {
    const e = Edges{ .left = true, .right = false, .up = false, .down = true };
    try testing.expect(e.atEdge(.left));
    try testing.expect(!e.atEdge(.right));
    try testing.expect(!e.atEdge(.up));
    try testing.expect(e.atEdge(.down));
}

const edges_json =
    \\{"id":"nvg","result":{"type":"pane_edges","edges":{"pane_id":"w8:p1","left":true,"right":false,"up":true,"down":false,"layout":{"panes":[]}}}}
;

test "parseEdges reads all four edges" {
    const e = parseEdges(edges_json).?;
    try testing.expect(e.left);
    try testing.expect(!e.right);
    try testing.expect(e.up);
    try testing.expect(!e.down);
}

test "parseEdges returns null on error response or garbage" {
    try testing.expectEqual(@as(?Edges, null), parseEdges("{\"id\":\"nvg\",\"error\":{\"code\":\"not_found\"}}"));
    try testing.expectEqual(@as(?Edges, null), parseEdges("{\"id\":\"nvg\",\"result\":{\"edges\":{\"left\":true}}}"));
    try testing.expectEqual(@as(?Edges, null), parseEdges("not json"));
    try testing.expectEqual(@as(?Edges, null), parseEdges("[]"));
}

test "parseFocusChanged" {
    try testing.expectEqual(@as(?bool, true), parseFocusChanged("{\"id\":\"nvg\",\"result\":{\"type\":\"pane_focus_direction\",\"focus\":{\"changed\":true,\"source_pane_id\":\"w1:p1\"}}}"));
    try testing.expectEqual(@as(?bool, false), parseFocusChanged("{\"id\":\"nvg\",\"result\":{\"focus\":{\"changed\":false,\"reason\":\"no_neighbor\"}}}"));
    try testing.expectEqual(@as(?bool, null), parseFocusChanged("{\"id\":\"nvg\",\"error\":{\"code\":\"invalid_params\"}}"));
}

test "parseShellPid" {
    try testing.expectEqual(@as(?i32, 8670), parseShellPid("{\"id\":\"nvg\",\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w8:p1\",\"shell_pid\":8670,\"foreground_processes\":[]}}}"));
    try testing.expectEqual(@as(?i32, null), parseShellPid("{\"id\":\"nvg\",\"result\":{\"process_info\":{\"shell_pid\":\"8670\"}}}"));
    try testing.expectEqual(@as(?i32, null), parseShellPid("{\"id\":\"nvg\",\"result\":{\"process_info\":{}}}"));
}

const workspaces_json =
    \\{"id":"nvg","result":{"type":"workspace_list","workspaces":[
    \\{"workspace_id":"w4","number":1,"label":"masso","focused":false},
    \\{"workspace_id":"w5","number":2,"label":"apps","focused":true},
    \\{"workspace_id":"w8","number":3,"label":"nvg","focused":false}]}}
;

test "parseWorkspaceNeighbor returns previous and next workspace" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("w4", parseWorkspaceNeighbor(workspaces_json, .up, &buf).?);
    try testing.expectEqualStrings("w8", parseWorkspaceNeighbor(workspaces_json, .down, &buf).?);
}

test "parseWorkspaceNeighbor ignores horizontal directions" {
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), parseWorkspaceNeighbor(workspaces_json, .left, &buf));
    try testing.expectEqual(@as(?[]const u8, null), parseWorkspaceNeighbor(workspaces_json, .right, &buf));
}

test "parseWorkspaceNeighbor does not wrap at first or last workspace" {
    var buf: [64]u8 = undefined;
    const first_focused =
        \\{"id":"nvg","result":{"workspaces":[{"workspace_id":"w1","focused":true},{"workspace_id":"w2","focused":false}]}}
    ;
    try testing.expectEqual(@as(?[]const u8, null), parseWorkspaceNeighbor(first_focused, .up, &buf));
    try testing.expectEqualStrings("w2", parseWorkspaceNeighbor(first_focused, .down, &buf).?);

    const last_focused =
        \\{"id":"nvg","result":{"workspaces":[{"workspace_id":"w1","focused":false},{"workspace_id":"w2","focused":true}]}}
    ;
    try testing.expectEqualStrings("w1", parseWorkspaceNeighbor(last_focused, .up, &buf).?);
    try testing.expectEqual(@as(?[]const u8, null), parseWorkspaceNeighbor(last_focused, .down, &buf));
}

test "parseWorkspaceNeighbor returns null without a focused workspace or on bad input" {
    var buf: [64]u8 = undefined;
    const none_focused =
        \\{"id":"nvg","result":{"workspaces":[{"workspace_id":"w1","focused":false}]}}
    ;
    try testing.expectEqual(@as(?[]const u8, null), parseWorkspaceNeighbor(none_focused, .down, &buf));
    try testing.expectEqual(@as(?[]const u8, null), parseWorkspaceNeighbor("{\"id\":\"nvg\",\"result\":{\"workspaces\":[]}}", .down, &buf));
    try testing.expectEqual(@as(?[]const u8, null), parseWorkspaceNeighbor("{\"id\":\"nvg\",\"result\":{\"workspaces\":{}}}", .down, &buf));
    try testing.expectEqual(@as(?[]const u8, null), parseWorkspaceNeighbor("{\"id\":\"nvg\",\"error\":{\"code\":\"x\"}}", .down, &buf));
}

test "parseWorkspaceNeighbor rejects ids that do not fit the buffer" {
    var buf: [1]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), parseWorkspaceNeighbor(workspaces_json, .up, &buf));
}

test "socketPath default and named session" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/home/u/.config/herdr/herdr.sock", socketPath(&buf, .{ .home = "/home/u" }).?);
    try testing.expectEqualStrings("/home/u/.config/herdr/sessions/work/herdr.sock", socketPath(&buf, .{ .home = "/home/u", .cli_session = "work" }).?);
    try testing.expectEqualStrings("/home/u/.config/herdr/sessions/side/herdr.sock", socketPath(&buf, .{ .home = "/home/u", .env_session = "side" }).?);
}

test "socketPath honors XDG_CONFIG_HOME" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/xdg/herdr/herdr.sock", socketPath(&buf, .{ .home = "/home/u", .xdg_config_home = "/xdg" }).?);
}

test "socketPath precedence: cli session beats socket override beats env session" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/tmp/custom.sock", socketPath(&buf, .{ .home = "/home/u", .socket_override = "/tmp/custom.sock", .env_session = "side" }).?);
    try testing.expectEqualStrings("/home/u/.config/herdr/sessions/work/herdr.sock", socketPath(&buf, .{ .home = "/home/u", .socket_override = "/tmp/custom.sock", .cli_session = "work" }).?);
}

test "socketPath returns null without home or when the buffer is too small" {
    var buf: [256]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), socketPath(&buf, .{}));
    var small: [8]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), socketPath(&small, .{ .home = "/home/u" }));
    try testing.expectEqual(@as(?[]const u8, null), socketPath(&small, .{ .socket_override = "/tmp/custom.sock" }));
}

test "sessionFromCmdline" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("work", sessionFromCmdline("herdr\x00--session\x00work\x00", &buf).?);
    try testing.expectEqualStrings("work", sessionFromCmdline("herdr\x00--session=work\x00", &buf).?);
    try testing.expectEqualStrings("work", sessionFromCmdline("/usr/local/bin/herdr\x00session\x00attach\x00work\x00", &buf).?);
    try testing.expectEqual(@as(?[]const u8, null), sessionFromCmdline("herdr\x00", &buf));
    try testing.expectEqual(@as(?[]const u8, null), sessionFromCmdline("herdr\x00--session\x00", &buf));
    try testing.expectEqual(@as(?[]const u8, null), sessionFromCmdline("herdr\x00session\x00list\x00", &buf));
}

test "sessionFromCmdline rejects names that do not fit the buffer" {
    var buf: [2]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), sessionFromCmdline("herdr\x00--session\x00work\x00", &buf));
}

test "resolveEndpoint returns null for nonexistent pid" {
    try testing.expectEqual(@as(?Endpoint, null), resolveEndpoint(4194304));
}

test "resolveEndpoint resolves the current process" {
    const pid: i32 = @intCast(std.os.linux.getpid());
    const ep = resolveEndpoint(pid).?;
    try testing.expect(std.mem.endsWith(u8, ep.path(), "/herdr.sock"));
}

test "request returns null for a missing socket" {
    var ep = Endpoint{};
    const path = "/nonexistent/herdr.sock";
    @memcpy(ep.path_buf[0..path.len], path);
    ep.path_len = path.len;
    var buf: [256]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), request(&ep, "ping", "{}", 10, &buf));
}

test "canMove returns null for nonexistent pid" {
    try testing.expectEqual(@as(?bool, null), canMove(4194304, .up, 10));
}

test "moveFocus and moveToEdge do not crash for nonexistent pid" {
    moveFocus(4194304, .down, 10);
    moveToEdge(4194304, .left, 10);
}

test "discoverInner does nothing for nonexistent pid" {
    var result = DetectedList{};
    discoverInner(4194304, &.{&hook}, &result, 1);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "hook vtable has correct name" {
    try testing.expectEqualStrings("herdr", hook.name);
}

test "hook detectFn matches herdr via vtable" {
    try testing.expectEqual(@as(?i32, 42), hook.detectFn(42, "herdr", "", ""));
}
