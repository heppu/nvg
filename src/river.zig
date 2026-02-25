/// River window manager backend.
///
/// River has no JSON/text IPC socket like sway, hyprland, or niri. Instead,
/// it uses native Wayland protocols:
///
///   - `zriver_control_v1`                       — execute commands (focus-view)
///   - `zwlr_foreign_toplevel_manager_v1`        — list toplevels with state
///
/// This module implements a minimal Wayland wire-protocol client that speaks
/// just enough of the protocol to:
///
///   1. Bind the required globals from wl_registry
///   2. Send `focus-view <direction>` via zriver_control_v1
///   3. Enumerate toplevels and find the activated one's app_id
///   4. Match the app_id against /proc to resolve the focused PID
///
/// Each public operation opens a fresh Wayland connection and closes it when
/// done, matching the pattern used by the Hyprland and Niri backends.
///
/// Detection: River sets XDG_CURRENT_DESKTOP=river (and WAYLAND_DISPLAY).
const std = @import("std");
const posix = std.posix;

const Direction = @import("main.zig").Direction;
const wm = @import("wm.zig");
const net = @import("net.zig");
const process = @import("process.zig");
const log = @import("log.zig");

pub const RiverError = error{
    ConnectFailed,
    WriteFailed,
    ReadFailed,
    ParseFailed,
    SocketPathTooLong,
    NoSocketPath,
    ProtocolError,
};

pub const River = struct {
    /// WindowManager vtable — must be the first field so that
    /// @fieldParentPtr can recover the River from a *WindowManager.
    wm: wm.WindowManager = .{
        .getFocusedPidFn = wmGetFocusedPid,
        .moveFocusFn = wmMoveFocus,
        .disconnectFn = wmDisconnect,
    },
    socket_path: [posix.PATH_MAX]u8,
    socket_path_len: usize,

    /// Build a River backend from the environment.
    /// The Wayland display socket is at $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY.
    pub fn connect() !River {
        const wayland_display = posix.getenv("WAYLAND_DISPLAY") orelse return RiverError.NoSocketPath;
        const xdg = posix.getenv("XDG_RUNTIME_DIR") orelse return RiverError.NoSocketPath;

        var path_buf: [posix.PATH_MAX]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ xdg, wayland_display }) catch {
            return RiverError.SocketPathTooLong;
        };

        var result = River{
            .socket_path = undefined,
            .socket_path_len = path.len,
        };
        @memcpy(result.socket_path[0..path.len], path);
        return result;
    }

    pub fn disconnect(_: *River) void {}

    /// Get the PID of the focused window by querying the
    /// zwlr_foreign_toplevel_manager_v1 protocol for the activated
    /// toplevel's app_id, then scanning /proc to resolve the PID.
    pub fn getFocusedPid(self: *River) ?i32 {
        var wl = WaylandConn.init(self.socket_path[0..self.socket_path_len]) orelse return null;
        defer wl.deinit();

        // Step 1: bind wl_registry and discover globals
        wl.sendGetRegistry() orelse return null;
        wl.sendSync() orelse return null;
        wl.processEvents() orelse return null;

        if (wl.toplevel_mgr_name == 0) {
            log.log("river: zwlr_foreign_toplevel_manager_v1 not available", .{});
            return null;
        }

        // Step 2: bind the toplevel manager
        wl.bindToplevelMgr() orelse return null;

        // Step 3: roundtrip to collect all toplevels and their state
        wl.sendSync() orelse return null;
        wl.processEvents() orelse return null;

        // Step 4: find the activated toplevel's app_id
        const app_id = wl.getActivatedAppId() orelse {
            log.log("river: no activated toplevel found", .{});
            return null;
        };

        log.log("river: focused app_id={s}", .{app_id});

        // Step 5: scan /proc to find matching PID
        return findPidByAppId(app_id);
    }

    /// Move focus in the given direction using zriver_control_v1.
    pub fn moveFocus(self: *River, direction: Direction) void {
        var wl = WaylandConn.init(self.socket_path[0..self.socket_path_len]) orelse return;
        defer wl.deinit();

        wl.sendGetRegistry() orelse return;
        wl.sendSync() orelse return;
        wl.processEvents() orelse return;

        if (wl.control_name == 0 or wl.seat_name == 0) {
            log.log("river: zriver_control_v1 or wl_seat not available", .{});
            return;
        }

        wl.bindControl() orelse return;
        wl.bindSeat() orelse return;

        // Send: add_argument("focus-view"), add_argument(<dir>), run_command
        const dir_str = switch (direction) {
            .left => "left",
            .right => "right",
            .up => "up",
            .down => "down",
        };

        wl.sendControlAddArg("focus-view") orelse return;
        wl.sendControlAddArg(dir_str) orelse return;
        wl.sendControlRunCommand() orelse return;

        // Roundtrip to ensure the command is processed
        wl.sendSync() orelse return;
        wl.processEvents() orelse return;
    }

    // ─── WindowManager vtable functions ───

    fn wmGetFocusedPid(wm_ptr: *wm.WindowManager) ?i32 {
        const self: *River = @fieldParentPtr("wm", wm_ptr);
        return self.getFocusedPid();
    }

    fn wmMoveFocus(wm_ptr: *wm.WindowManager, direction: Direction) void {
        const self: *River = @fieldParentPtr("wm", wm_ptr);
        self.moveFocus(direction);
    }

    fn wmDisconnect(wm_ptr: *wm.WindowManager) void {
        const self: *River = @fieldParentPtr("wm", wm_ptr);
        self.disconnect();
    }
};

// ─── Minimal Wayland wire protocol client ───
//
// The Wayland wire protocol is simple:
//   Message: object_id:u32 + size_opcode:u32 + args...
//   size_opcode: upper 16 bits = total message size, lower 16 bits = opcode
//   Strings: u32 length (incl NUL) + bytes + NUL + padding to 4-byte boundary
//   Arrays:  u32 byte-length + bytes + padding to 4-byte boundary
//
// Object ID 1 is always wl_display. We allocate new IDs starting from 2.

const WL_DISPLAY_ID: u32 = 1;

// Opcodes for wl_display requests
const WL_DISPLAY_SYNC: u16 = 0;
const WL_DISPLAY_GET_REGISTRY: u16 = 1;

// Opcodes for wl_display events
const WL_DISPLAY_ERROR: u16 = 0;

// Opcodes for wl_registry events
const WL_REGISTRY_GLOBAL: u16 = 0;

// Opcodes for wl_registry requests
const WL_REGISTRY_BIND: u16 = 0;

// Opcodes for wl_callback events
const WL_CALLBACK_DONE: u16 = 0;

// Opcodes for zwlr_foreign_toplevel_handle_v1 events
const TOPLEVEL_HANDLE_TITLE: u16 = 0;
const TOPLEVEL_HANDLE_APP_ID: u16 = 1;
const TOPLEVEL_HANDLE_STATE: u16 = 4;
const TOPLEVEL_HANDLE_DONE: u16 = 5;
const TOPLEVEL_HANDLE_CLOSED: u16 = 6;

// Opcodes for zwlr_foreign_toplevel_manager_v1 events
const TOPLEVEL_MGR_TOPLEVEL: u16 = 0;
const TOPLEVEL_MGR_FINISHED: u16 = 1;

// State values in zwlr_foreign_toplevel_handle_v1.state array
const TOPLEVEL_STATE_ACTIVATED: u32 = 2;

// Opcodes for zriver_control_v1 requests
const CONTROL_DESTROY: u16 = 0;
const CONTROL_ADD_ARGUMENT: u16 = 1;
const CONTROL_RUN_COMMAND: u16 = 2;

// Interface names we look for in the registry
const IFACE_WL_SEAT = "wl_seat";
const IFACE_TOPLEVEL_MGR = "zwlr_foreign_toplevel_manager_v1";
const IFACE_RIVER_CONTROL = "zriver_control_v1";

const max_toplevels = 64;
const app_id_max = 128;

const Toplevel = struct {
    object_id: u32,
    app_id: [app_id_max]u8,
    app_id_len: usize,
    activated: bool,
    closed: bool,
};

const WaylandConn = struct {
    fd: posix.fd_t,
    next_id: u32,

    // Object IDs we've allocated
    registry_id: u32,
    callback_id: u32,
    toplevel_mgr_id: u32,
    control_id: u32,
    seat_id: u32,
    cmd_callback_id: u32,

    // Registry globals (name = the uint from wl_registry.global)
    seat_name: u32,
    seat_version: u32,
    toplevel_mgr_name: u32,
    toplevel_mgr_version: u32,
    control_name: u32,
    control_version: u32,

    // Collected toplevels
    toplevels: [max_toplevels]Toplevel,
    toplevel_count: usize,

    // Whether we've seen the callback.done for our sync
    sync_done: bool,

    fn init(path: []const u8) ?*WaylandConn {
        // We use a static instance since this is single-threaded and short-lived.
        const S = struct {
            var instance: WaylandConn = undefined;
        };

        const addr = net.makeUnixAddr(path) catch return null;
        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return null;
        posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
            posix.close(fd);
            return null;
        };

        S.instance = WaylandConn{
            .fd = fd,
            .next_id = 2,
            .registry_id = 0,
            .callback_id = 0,
            .toplevel_mgr_id = 0,
            .control_id = 0,
            .seat_id = 0,
            .cmd_callback_id = 0,
            .seat_name = 0,
            .seat_version = 0,
            .toplevel_mgr_name = 0,
            .toplevel_mgr_version = 0,
            .control_name = 0,
            .control_version = 0,
            .toplevels = undefined,
            .toplevel_count = 0,
            .sync_done = false,
        };

        return &S.instance;
    }

    fn deinit(self: *WaylandConn) void {
        posix.close(self.fd);
    }

    fn allocId(self: *WaylandConn) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    // ─── Send helpers ───

    fn sendMsg(self: *WaylandConn, object_id: u32, opcode: u16, payload: []const u8) ?void {
        const total_size: u16 = @intCast(8 + payload.len);
        var hdr: [8]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], object_id, .little);
        std.mem.writeInt(u16, hdr[4..6], opcode, .little);
        std.mem.writeInt(u16, hdr[6..8], total_size, .little);

        net.writeAll(self.fd, &hdr) catch return null;
        if (payload.len > 0) {
            net.writeAll(self.fd, payload) catch return null;
        }
    }

    fn sendGetRegistry(self: *WaylandConn) ?void {
        self.registry_id = self.allocId();
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], self.registry_id, .little);
        return self.sendMsg(WL_DISPLAY_ID, WL_DISPLAY_GET_REGISTRY, &payload);
    }

    fn sendSync(self: *WaylandConn) ?void {
        self.callback_id = self.allocId();
        self.sync_done = false;
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], self.callback_id, .little);
        return self.sendMsg(WL_DISPLAY_ID, WL_DISPLAY_SYNC, &payload);
    }

    /// wl_registry.bind for zwlr_foreign_toplevel_manager_v1
    fn bindToplevelMgr(self: *WaylandConn) ?void {
        self.toplevel_mgr_id = self.allocId();
        return self.sendRegistryBind(
            self.toplevel_mgr_name,
            IFACE_TOPLEVEL_MGR,
            @min(self.toplevel_mgr_version, 3),
            self.toplevel_mgr_id,
        );
    }

    /// wl_registry.bind for zriver_control_v1
    fn bindControl(self: *WaylandConn) ?void {
        self.control_id = self.allocId();
        return self.sendRegistryBind(
            self.control_name,
            IFACE_RIVER_CONTROL,
            @min(self.control_version, 1),
            self.control_id,
        );
    }

    /// wl_registry.bind for wl_seat
    fn bindSeat(self: *WaylandConn) ?void {
        self.seat_id = self.allocId();
        return self.sendRegistryBind(
            self.seat_name,
            IFACE_WL_SEAT,
            @min(self.seat_version, 1),
            self.seat_id,
        );
    }

    /// wl_registry.bind wire format:
    ///   name: uint, interface: string, version: uint, new_id: uint
    fn sendRegistryBind(self: *WaylandConn, name: u32, iface: []const u8, version: u32, new_id: u32) ?void {
        // Payload: name(4) + string_len(4) + string_data(padded) + version(4) + new_id(4)
        const str_len: u32 = @intCast(iface.len + 1); // including NUL
        const padded_len = (str_len + 3) & ~@as(u32, 3);
        const payload_size = 4 + 4 + padded_len + 4 + 4;

        var buf: [256]u8 = undefined;
        if (payload_size > buf.len) return null;

        var off: usize = 0;
        std.mem.writeInt(u32, buf[off..][0..4], name, .little);
        off += 4;
        std.mem.writeInt(u32, buf[off..][0..4], str_len, .little);
        off += 4;
        @memcpy(buf[off..][0..iface.len], iface);
        buf[off + iface.len] = 0;
        off += iface.len + 1;
        // Pad to 4-byte boundary
        while (off % 4 != 0) : (off += 1) {
            buf[off] = 0;
        }
        std.mem.writeInt(u32, buf[off..][0..4], version, .little);
        off += 4;
        std.mem.writeInt(u32, buf[off..][0..4], new_id, .little);
        off += 4;

        return self.sendMsg(self.registry_id, WL_REGISTRY_BIND, buf[0..off]);
    }

    /// zriver_control_v1.add_argument(argument: string)
    fn sendControlAddArg(self: *WaylandConn, arg: []const u8) ?void {
        const str_len: u32 = @intCast(arg.len + 1);
        const padded_len = (str_len + 3) & ~@as(u32, 3);
        const payload_size = 4 + padded_len;

        var buf: [256]u8 = undefined;
        if (payload_size > buf.len) return null;

        var off: usize = 0;
        std.mem.writeInt(u32, buf[off..][0..4], str_len, .little);
        off += 4;
        @memcpy(buf[off..][0..arg.len], arg);
        buf[off + arg.len] = 0;
        off += arg.len + 1;
        while (off % 4 != 0) : (off += 1) {
            buf[off] = 0;
        }

        return self.sendMsg(self.control_id, CONTROL_ADD_ARGUMENT, buf[0..off]);
    }

    /// zriver_control_v1.run_command(seat: object, callback: new_id)
    fn sendControlRunCommand(self: *WaylandConn) ?void {
        self.cmd_callback_id = self.allocId();
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], self.seat_id, .little);
        std.mem.writeInt(u32, payload[4..8], self.cmd_callback_id, .little);
        return self.sendMsg(self.control_id, CONTROL_RUN_COMMAND, &payload);
    }

    // ─── Event processing ───

    fn processEvents(self: *WaylandConn) ?void {
        var buf: [16384]u8 = undefined;
        var buffered: usize = 0;

        // Read events until we see our sync callback done
        while (!self.sync_done) {
            if (buffered < 8) {
                const n = posix.read(self.fd, buf[buffered..]) catch return null;
                if (n == 0) return null;
                buffered += n;
            }

            while (buffered >= 8) {
                const object_id = std.mem.readInt(u32, buf[0..4], .little);
                const opcode = std.mem.readInt(u16, buf[4..6], .little);
                const msg_size = std.mem.readInt(u16, buf[6..8], .little);

                if (msg_size < 8) return null; // invalid
                if (buffered < msg_size) break; // need more data

                const payload = buf[8..msg_size];
                self.handleEvent(object_id, opcode, payload);

                // Shift remaining data
                const remaining = buffered - msg_size;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, buf[0..remaining], buf[msg_size..buffered]);
                }
                buffered = remaining;
            }
        }
    }

    fn handleEvent(self: *WaylandConn, object_id: u32, opcode: u16, payload: []const u8) void {
        // wl_display.error
        if (object_id == WL_DISPLAY_ID and opcode == WL_DISPLAY_ERROR) {
            log.log("river: wl_display error", .{});
            return;
        }

        // wl_registry.global
        if (object_id == self.registry_id and opcode == WL_REGISTRY_GLOBAL) {
            self.handleRegistryGlobal(payload);
            return;
        }

        // wl_callback.done (our sync callback)
        if (object_id == self.callback_id and opcode == WL_CALLBACK_DONE) {
            self.sync_done = true;
            return;
        }

        // zwlr_foreign_toplevel_manager_v1.toplevel
        if (object_id == self.toplevel_mgr_id and opcode == TOPLEVEL_MGR_TOPLEVEL) {
            if (payload.len >= 4) {
                const toplevel_id = std.mem.readInt(u32, payload[0..4], .little);
                self.addToplevel(toplevel_id);
            }
            return;
        }

        // Events for toplevel handles
        if (self.findToplevel(object_id)) |tl| {
            switch (opcode) {
                TOPLEVEL_HANDLE_APP_ID => {
                    if (readWlString(payload)) |s| {
                        const copy_len = @min(s.len, app_id_max);
                        @memcpy(tl.app_id[0..copy_len], s[0..copy_len]);
                        tl.app_id_len = copy_len;
                    }
                },
                TOPLEVEL_HANDLE_STATE => {
                    // state is an array of u32 values
                    tl.activated = false;
                    if (payload.len >= 4) {
                        const array_len = std.mem.readInt(u32, payload[0..4], .little);
                        const data = payload[4..];
                        var i: usize = 0;
                        while (i + 4 <= array_len and i + 4 <= data.len) : (i += 4) {
                            const val = std.mem.readInt(u32, data[i..][0..4], .little);
                            if (val == TOPLEVEL_STATE_ACTIVATED) {
                                tl.activated = true;
                            }
                        }
                    }
                },
                TOPLEVEL_HANDLE_CLOSED => {
                    tl.closed = true;
                },
                else => {},
            }
            return;
        }

        // Command callback events (success/failure) — just ignore
        if (object_id == self.cmd_callback_id) {
            return;
        }
    }

    fn handleRegistryGlobal(self: *WaylandConn, payload: []const u8) void {
        // wl_registry.global: name(uint) + interface(string) + version(uint)
        if (payload.len < 12) return;

        const name = std.mem.readInt(u32, payload[0..4], .little);
        const str_len = std.mem.readInt(u32, payload[4..8], .little);
        if (str_len == 0) return;

        const padded = (str_len + 3) & ~@as(u32, 3);
        if (8 + padded + 4 > payload.len) return;

        // interface string (without NUL)
        const iface_len = str_len - 1; // exclude NUL
        const iface = payload[8..][0..iface_len];
        const version = std.mem.readInt(u32, payload[8 + padded ..][0..4], .little);

        if (std.mem.eql(u8, iface, IFACE_WL_SEAT)) {
            self.seat_name = name;
            self.seat_version = version;
        } else if (std.mem.eql(u8, iface, IFACE_TOPLEVEL_MGR)) {
            self.toplevel_mgr_name = name;
            self.toplevel_mgr_version = version;
        } else if (std.mem.eql(u8, iface, IFACE_RIVER_CONTROL)) {
            self.control_name = name;
            self.control_version = version;
        }
    }

    fn addToplevel(self: *WaylandConn, object_id: u32) void {
        if (self.toplevel_count >= max_toplevels) return;
        self.toplevels[self.toplevel_count] = Toplevel{
            .object_id = object_id,
            .app_id = undefined,
            .app_id_len = 0,
            .activated = false,
            .closed = false,
        };
        self.toplevel_count += 1;
    }

    fn findToplevel(self: *WaylandConn, object_id: u32) ?*Toplevel {
        for (self.toplevels[0..self.toplevel_count]) |*tl| {
            if (tl.object_id == object_id) return tl;
        }
        return null;
    }

    fn getActivatedAppId(self: *WaylandConn) ?[]const u8 {
        for (self.toplevels[0..self.toplevel_count]) |*tl| {
            if (tl.activated and !tl.closed and tl.app_id_len > 0) {
                return tl.app_id[0..tl.app_id_len];
            }
        }
        return null;
    }
};

/// Read a Wayland string argument from a payload slice.
/// Format: u32 length (including NUL) + bytes + NUL + padding
fn readWlString(data: []const u8) ?[]const u8 {
    if (data.len < 4) return null;
    const str_len = std.mem.readInt(u32, data[0..4], .little);
    if (str_len == 0) return null;
    if (4 + str_len > data.len) return null;
    // Exclude the NUL terminator
    return data[4..][0 .. str_len - 1];
}

/// Scan /proc to find a PID whose comm or cmdline basename matches the given app_id.
///
/// River toplevels expose an app_id (e.g. "foot", "Alacritty", "firefox").
/// We walk /proc/*/comm looking for a case-insensitive match.
fn findPidByAppId(app_id: []const u8) ?i32 {
    var proc_dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return null;
    defer proc_dir.close();

    var iter = proc_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
        if (pid <= 0) continue;

        // Try /proc/<pid>/comm first (short process name)
        var comm_path_buf: [64]u8 = undefined;
        const comm_path = std.fmt.bufPrint(&comm_path_buf, "/proc/{d}/comm", .{pid}) catch continue;

        var comm_buf: [256]u8 = undefined;
        if (process.readFileToBuffer(comm_path, &comm_buf)) |content| {
            // comm has trailing newline
            const comm = std.mem.trimRight(u8, content, "\n");
            if (eqlIgnoreCase(comm, app_id)) return pid;
        }

        // Try basename of /proc/<pid>/cmdline argv[0]
        var cmdline_path_buf: [64]u8 = undefined;
        const cmdline_path = std.fmt.bufPrint(&cmdline_path_buf, "/proc/{d}/cmdline", .{pid}) catch continue;

        var cmdline_buf: [4096]u8 = undefined;
        if (process.readFileToBuffer(cmdline_path, &cmdline_buf)) |content| {
            if (content.len == 0) continue;
            const argv0 = process.nullTermStr(content);
            const basename = std.fs.path.basename(argv0);
            if (eqlIgnoreCase(basename, app_id)) return pid;
        }
    }

    return null;
}

/// Case-insensitive ASCII comparison.
fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

// ─── Tests ───

const testing = std.testing;

test "readWlString basic" {
    // "foo" + NUL = length 4
    var data: [8]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 4, .little); // length = 4 (3 chars + NUL)
    data[4] = 'f';
    data[5] = 'o';
    data[6] = 'o';
    data[7] = 0;
    const result = readWlString(&data).?;
    try testing.expectEqualStrings("foo", result);
}

test "readWlString empty returns null" {
    var data: [4]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 0, .little);
    try testing.expectEqual(@as(?[]const u8, null), readWlString(&data));
}

test "readWlString truncated returns null" {
    try testing.expectEqual(@as(?[]const u8, null), readWlString(&[_]u8{ 0, 0 }));
}

test "readWlString oversized length returns null" {
    var data: [8]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 100, .little); // length exceeds buffer
    try testing.expectEqual(@as(?[]const u8, null), readWlString(&data));
}

test "eqlIgnoreCase matching" {
    try testing.expect(eqlIgnoreCase("foot", "foot"));
    try testing.expect(eqlIgnoreCase("Foot", "foot"));
    try testing.expect(eqlIgnoreCase("FOOT", "foot"));
    try testing.expect(eqlIgnoreCase("Firefox", "firefox"));
}

test "eqlIgnoreCase non-matching" {
    try testing.expect(!eqlIgnoreCase("foot", "foo"));
    try testing.expect(!eqlIgnoreCase("foot", "feet"));
    try testing.expect(!eqlIgnoreCase("", "foot"));
}

test "eqlIgnoreCase empty" {
    try testing.expect(eqlIgnoreCase("", ""));
}

test "findPidByAppId finds own process" {
    // Our own process should be findable by its comm name.
    // Read our own comm to get the name to search for.
    var buf: [256]u8 = undefined;
    const comm_content = process.readFileToBuffer("/proc/self/comm", &buf) orelse {
        // Can't read our own comm — skip this test.
        return;
    };
    const comm = std.mem.trimRight(u8, comm_content, "\n");
    if (comm.len == 0) return;

    const result = findPidByAppId(comm);
    // We should find at least one PID matching our comm.
    try testing.expect(result != null);
}
