/// dwm IPC client using the dwmfifo patch.
///
/// Uses a named FIFO (pipe) for sending commands to dwm:
///   FIFO path: $DWM_FIFO (default: /tmp/dwm.fifo)
///   Commands are written as newline-terminated strings.
///
/// The dwmfifo patch (https://dwm.suckless.org/patches/dwmfifo/) adds a
/// command FIFO that maps 1-1 with dwm's keybind actions. This backend
/// uses the "focusstack" command for focus movement.
///
/// Since dwm is an X11 window manager, the focused window PID is obtained
/// by speaking the X11 protocol directly over the display socket:
///   1. InternAtom to resolve _NET_ACTIVE_WINDOW and _NET_WM_PID
///   2. GetProperty on the root window to read _NET_ACTIVE_WINDOW
///   3. GetProperty on the active window to read _NET_WM_PID
///
/// No external tools (xdotool, xprop, etc.) are required.
///
/// This backend implements the WindowManager interface, so it can be used
/// interchangeably with other window manager backends.
const std = @import("std");
const posix = std.posix;

const Direction = @import("main.zig").Direction;
const wm = @import("wm.zig");
const net = @import("net.zig");
const log = @import("log.zig");

pub const DwmError = error{
    ConnectFailed,
    WriteFailed,
    NoFifoPath,
    FifoPathTooLong,
};

const default_fifo_path = "/tmp/dwm.fifo";

pub const Dwm = struct {
    /// WindowManager vtable — must be the first field so that
    /// @fieldParentPtr can recover the Dwm from a *WindowManager.
    wm: wm.WindowManager = .{
        .getFocusedPidFn = wmGetFocusedPid,
        .moveFocusFn = wmMoveFocus,
        .disconnectFn = wmDisconnect,
    },
    fifo_path: [posix.PATH_MAX]u8,
    fifo_path_len: usize,

    /// Build a Dwm backend from the environment.
    /// Reads the FIFO path from $DWM_FIFO, defaulting to /tmp/dwm.fifo.
    pub fn connect() !Dwm {
        const path = posix.getenv("DWM_FIFO") orelse default_fifo_path;
        if (path.len >= posix.PATH_MAX) return DwmError.FifoPathTooLong;

        var result = Dwm{
            .fifo_path = undefined,
            .fifo_path_len = path.len,
        };
        @memcpy(result.fifo_path[0..path.len], path);
        return result;
    }

    pub fn disconnect(_: *Dwm) void {
        // No persistent connection to close.
    }

    /// Query the focused window PID using the X11 protocol.
    /// Opens a fresh X11 connection, resolves _NET_ACTIVE_WINDOW and
    /// _NET_WM_PID atoms, reads properties, and closes the connection.
    /// Returns null if no window is focused or on any error.
    pub fn getFocusedPid(_: *Dwm) ?i32 {
        return x11.getFocusedPid();
    }

    /// Write a focus command to the dwm FIFO.
    ///
    /// dwm's tiling model uses a window stack rather than spatial positions,
    /// so left/up map to focusstack- (previous) and right/down map to
    /// focusstack+ (next).
    pub fn moveFocus(self: *Dwm, direction: Direction) void {
        const cmd = switch (direction) {
            .left => "focusstack-\n",
            .right => "focusstack+\n",
            .up => "focusstack-\n",
            .down => "focusstack+\n",
        };
        self.writeFifo(cmd);
    }

    /// Open the FIFO, write the command, and close.
    fn writeFifo(self: *Dwm, cmd: []const u8) void {
        const path = self.fifo_path[0..self.fifo_path_len];
        const path_z = posix.toPosixPath(path) catch {
            log.log("dwm: fifo path too long", .{});
            return;
        };
        const fd = posix.openatZ(posix.AT.FDCWD, &path_z, .{ .ACCMODE = .WRONLY, .NONBLOCK = true }, 0) catch {
            log.log("dwm: failed to open fifo {s}", .{path});
            return;
        };
        defer posix.close(fd);

        _ = posix.write(fd, cmd) catch {
            log.log("dwm: failed to write to fifo", .{});
            return;
        };
    }

    // ─── WindowManager vtable functions ───

    fn wmGetFocusedPid(wm_ptr: *wm.WindowManager) ?i32 {
        const self: *Dwm = @fieldParentPtr("wm", wm_ptr);
        return self.getFocusedPid();
    }

    fn wmMoveFocus(wm_ptr: *wm.WindowManager, direction: Direction) void {
        const self: *Dwm = @fieldParentPtr("wm", wm_ptr);
        self.moveFocus(direction);
    }

    fn wmDisconnect(wm_ptr: *wm.WindowManager) void {
        const self: *Dwm = @fieldParentPtr("wm", wm_ptr);
        self.disconnect();
    }
};

// ─── X11 protocol helpers ───
//
// Minimal X11 protocol implementation for reading window properties.
// Only implements the subset needed: connection setup, InternAtom,
// and GetProperty. All multi-byte values use native (little-endian)
// byte order as declared in the connection setup.

const x11 = struct {
    const XAUTH_FAMILY_LOCAL = 256;

    /// Parse $DISPLAY to extract host, display number, and screen number.
    /// Supports formats: ":N", ":N.S", "host:N", "host:N.S"
    const DisplayAddr = struct {
        host: []const u8,
        display: u32,
        screen: u32,
    };

    fn parseDisplay(display_str: []const u8) ?DisplayAddr {
        const colon = std.mem.indexOfScalar(u8, display_str, ':') orelse return null;
        const host = display_str[0..colon];
        const rest = display_str[colon + 1 ..];
        if (rest.len == 0) return null;

        if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
            const display = std.fmt.parseInt(u32, rest[0..dot], 10) catch return null;
            const screen = std.fmt.parseInt(u32, rest[dot + 1 ..], 10) catch return null;
            return .{ .host = host, .display = display, .screen = screen };
        } else {
            const display = std.fmt.parseInt(u32, rest, 10) catch return null;
            return .{ .host = host, .display = display, .screen = 0 };
        }
    }

    /// Read and parse Xauthority data for the given display.
    /// Returns the auth name and data as slices into the provided buffer.
    const AuthData = struct {
        name: []const u8,
        data: []const u8,
    };

    fn readAuth(buf: []u8, display_num: u32) ?AuthData {
        const xauth_path = posix.getenv("XAUTHORITY") orelse blk: {
            const home = posix.getenv("HOME") orelse return null;
            var path_buf: [posix.PATH_MAX]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/.Xauthority", .{home}) catch return null;
            break :blk path;
        };

        const xauth_z = posix.toPosixPath(xauth_path) catch return null;
        const fd = posix.openatZ(posix.AT.FDCWD, &xauth_z, .{}, 0) catch return null;
        defer posix.close(fd);

        // Get hostname for matching
        var hostname_buf: [256]u8 = undefined;
        const hostname = getHostname(&hostname_buf);

        var total: usize = 0;
        while (total < buf.len) {
            const n = posix.read(fd, buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }

        const data = buf[0..total];
        return parseXauthEntry(data, display_num, hostname);
    }

    fn getHostname(buf: []u8) []const u8 {
        var uname = posix.uname();
        const nodename: [*:0]const u8 = @ptrCast(&uname.nodename);
        const len = std.mem.len(nodename);
        if (len > buf.len) return buf[0..0];
        @memcpy(buf[0..len], nodename[0..len]);
        return buf[0..len];
    }

    /// Parse Xauthority entries to find a matching one.
    /// Xauthority format: each entry is:
    ///   2 bytes: family (big-endian)
    ///   2 bytes: address length (big-endian), then address bytes
    ///   2 bytes: number length (big-endian), then number bytes (ASCII display number)
    ///   2 bytes: name length (big-endian), then name bytes (e.g. "MIT-MAGIC-COOKIE-1")
    ///   2 bytes: data length (big-endian), then data bytes
    fn parseXauthEntry(data: []const u8, display_num: u32, hostname: []const u8) ?AuthData {
        var display_str_buf: [16]u8 = undefined;
        const display_str = std.fmt.bufPrint(&display_str_buf, "{d}", .{display_num}) catch return null;

        var pos: usize = 0;
        while (pos + 2 <= data.len) {
            const family = readBE16(data, pos) orelse return null;
            pos += 2;

            const addr = readXauthString(data, pos) orelse return null;
            pos = addr.next;

            const number = readXauthString(data, pos) orelse return null;
            pos = number.next;

            const name = readXauthString(data, pos) orelse return null;
            pos = name.next;

            const auth_data = readXauthString(data, pos) orelse return null;
            pos = auth_data.next;

            // Match: display number must match, and family/address must be local
            if (!std.mem.eql(u8, number.str, display_str)) continue;

            if (family == XAUTH_FAMILY_LOCAL and std.mem.eql(u8, addr.str, hostname)) {
                return .{ .name = name.str, .data = auth_data.str };
            }

            // Also accept family=0 (Internet) with empty or matching address
            if (family == 0) {
                return .{ .name = name.str, .data = auth_data.str };
            }
        }
        return null;
    }

    const XauthStr = struct { str: []const u8, next: usize };

    fn readXauthString(data: []const u8, pos: usize) ?XauthStr {
        if (pos + 2 > data.len) return null;
        const len: usize = readBE16(data, pos) orelse return null;
        const start = pos + 2;
        if (start + len > data.len) return null;
        return .{ .str = data[start .. start + len], .next = start + len };
    }

    fn readBE16(data: []const u8, pos: usize) ?u16 {
        if (pos + 2 > data.len) return null;
        return @as(u16, data[pos]) << 8 | @as(u16, data[pos + 1]);
    }

    /// Connect to the X11 display, perform connection setup, and return
    /// the fd and root window ID. Caller must close the fd.
    const X11Conn = struct {
        fd: posix.fd_t,
        root: u32,
    };

    fn connectDisplay() ?X11Conn {
        const display_str = posix.getenv("DISPLAY") orelse return null;
        const daddr = parseDisplay(display_str) orelse return null;

        // Build socket path: /tmp/.X11-unix/X<display>
        var sock_path_buf: [128]u8 = undefined;
        const sock_path = std.fmt.bufPrint(&sock_path_buf, "/tmp/.X11-unix/X{d}", .{daddr.display}) catch return null;

        const addr = net.makeUnixAddr(sock_path) catch return null;
        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return null;
        errdefer posix.close(fd);

        posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
            posix.close(fd);
            return null;
        };

        // Read Xauthority
        var xauth_buf: [4096]u8 = undefined;
        const auth = readAuth(&xauth_buf, daddr.display);

        // X11 connection setup request (little-endian)
        var setup_buf: [1024]u8 = undefined;
        var pos: usize = 0;

        // Byte order: 'l' = little-endian
        setup_buf[pos] = 'l';
        pos += 1;
        // Unused padding
        setup_buf[pos] = 0;
        pos += 1;
        // Protocol major version = 11
        writeLE16(&setup_buf, pos, 11);
        pos += 2;
        // Protocol minor version = 0
        writeLE16(&setup_buf, pos, 0);
        pos += 2;

        if (auth) |a| {
            // Auth protocol name length
            const name_len: u16 = @intCast(a.name.len);
            writeLE16(&setup_buf, pos, name_len);
            pos += 2;
            // Auth protocol data length
            const data_len: u16 = @intCast(a.data.len);
            writeLE16(&setup_buf, pos, data_len);
            pos += 2;
            // Unused padding
            writeLE16(&setup_buf, pos, 0);
            pos += 2;
            // Auth name + padding to 4-byte boundary
            @memcpy(setup_buf[pos .. pos + a.name.len], a.name);
            pos += a.name.len;
            pos = pad4(pos);
            // Auth data + padding
            @memcpy(setup_buf[pos .. pos + a.data.len], a.data);
            pos += a.data.len;
            pos = pad4(pos);
        } else {
            // No auth: zero-length name and data
            writeLE16(&setup_buf, pos, 0);
            pos += 2;
            writeLE16(&setup_buf, pos, 0);
            pos += 2;
            writeLE16(&setup_buf, pos, 0);
            pos += 2;
        }

        net.writeAll(fd, setup_buf[0..pos]) catch {
            posix.close(fd);
            return null;
        };

        // Read response header (8 bytes: status + lengths)
        var resp_header: [8]u8 = undefined;
        net.readExact(fd, &resp_header) catch {
            posix.close(fd);
            return null;
        };

        const status = resp_header[0];
        if (status != 1) {
            // 0 = Failed, 2 = Authenticate; both mean we can't proceed
            log.log("dwm/x11: connection refused (status={d})", .{status});
            posix.close(fd);
            return null;
        }

        // Success. Read the rest of the setup data.
        // Bytes 6-7: additional data length in 4-byte units
        const additional_len = readLE16(&resp_header, 6);
        const additional_bytes = @as(usize, additional_len) * 4;
        if (additional_bytes == 0 or additional_bytes > 65536) {
            posix.close(fd);
            return null;
        }

        var setup_data_buf: [65536]u8 = undefined;
        net.readExact(fd, setup_data_buf[0..additional_bytes]) catch {
            posix.close(fd);
            return null;
        };

        // Parse root window from setup data.
        // The setup response structure after the 8-byte header:
        //   Bytes 0-3: release number
        //   4-7: resource-id-base
        //   8-11: resource-id-mask
        //   12-15: motion-buffer-size
        //   16-17: vendor length (v)
        //   18-19: maximum-request-length
        //   20: number of screens
        //   21: number of formats (f)
        //   ... then vendor string (padded), then formats, then screens
        const setup_data = setup_data_buf[0..additional_bytes];
        const root = parseRootWindow(setup_data, daddr.screen) orelse {
            posix.close(fd);
            return null;
        };

        return .{ .fd = fd, .root = root };
    }

    /// Parse the root window ID for the given screen from X11 setup data.
    fn parseRootWindow(data: []const u8, screen: u32) ?u32 {
        if (data.len < 24) return null;

        const vendor_len: usize = readLE16(data, 16);
        const num_screens = data[20];
        const num_formats = data[21];

        if (screen >= num_screens) return null;

        // Skip to after fixed header (24 bytes), vendor (padded), and formats
        var pos: usize = 24;
        // Vendor string, padded to 4 bytes
        pos += pad4(vendor_len);
        // Each format is 8 bytes (depth, bpp, scanline-pad, 5 unused)
        pos += @as(usize, num_formats) * 8;

        // Now we're at the first SCREEN structure.
        // Iterate to the requested screen.
        var s: u32 = 0;
        while (s <= screen) : (s += 1) {
            if (pos + 40 > data.len) return null;

            const root_wid = readLE32(data, pos);
            // Bytes 36: number of depths allowed
            const num_depths = data[pos + 39];

            if (s == screen) return root_wid;

            // Skip this screen's fixed part (40 bytes) + depth structures
            pos += 40;
            for (0..num_depths) |_| {
                if (pos + 8 > data.len) return null;
                // Depth: 1 byte depth, 1 pad, 2 bytes num_visuals, 4 pad
                const num_visuals: usize = readLE16(data, pos + 2);
                pos += 8 + num_visuals * 24; // each VISUAL is 24 bytes
            }
        }
        return null;
    }

    /// Send an InternAtom request and read the response.
    /// Returns the atom ID, or null on error.
    fn internAtom(fd: posix.fd_t, name: []const u8) ?u32 {
        // InternAtom request: opcode 16
        // 1 byte opcode, 1 byte only-if-exists, 2 byte request length,
        // 2 byte name length, 2 unused, then name + padding
        const name_len: u16 = @intCast(name.len);
        const request_len: u16 = @intCast((8 + name.len + 3) / 4); // in 4-byte units
        var req_buf: [256]u8 = undefined;
        req_buf[0] = 16; // opcode: InternAtom
        req_buf[1] = 0; // only_if_exists = false
        writeLE16(&req_buf, 2, request_len);
        writeLE16(&req_buf, 4, name_len);
        writeLE16(&req_buf, 6, 0); // unused
        @memcpy(req_buf[8 .. 8 + name.len], name);
        // Zero padding
        const total = @as(usize, request_len) * 4;
        @memset(req_buf[8 + name.len .. total], 0);

        net.writeAll(fd, req_buf[0..total]) catch return null;

        // Read 32-byte reply
        var reply: [32]u8 = undefined;
        net.readExact(fd, &reply) catch return null;

        if (reply[0] != 1) return null; // not a reply
        return readLE32(&reply, 8); // atom at bytes 8-11
    }

    /// Send a GetProperty request and return the first u32 value.
    /// Suitable for CARDINAL and WINDOW type properties with a single value.
    fn getPropertyU32(fd: posix.fd_t, window: u32, property: u32) ?u32 {
        // GetProperty request: opcode 20
        // 1 opcode, 1 delete, 2 request_length(6), 4 window,
        // 4 property, 4 type(0=AnyPropertyType), 4 long_offset(0), 4 long_length(1)
        var req: [24]u8 = undefined;
        req[0] = 20; // opcode: GetProperty
        req[1] = 0; // delete = false
        writeLE16(&req, 2, 6); // request length in 4-byte units
        writeLE32(&req, 4, window);
        writeLE32(&req, 8, property);
        writeLE32(&req, 12, 0); // type = AnyPropertyType
        writeLE32(&req, 16, 0); // long_offset
        writeLE32(&req, 20, 1); // long_length (1 = we want 1 CARD32)

        net.writeAll(fd, &req) catch return null;

        // Read 32-byte reply header
        var reply: [32]u8 = undefined;
        net.readExact(fd, &reply) catch return null;

        if (reply[0] != 1) return null; // not a reply

        const format = reply[1]; // 0, 8, 16, or 32
        const value_len = readLE32(&reply, 16); // number of items

        // Read trailing data (length in reply bytes 4-7, in 4-byte units)
        const trailing = @as(usize, readLE32(&reply, 4)) * 4;
        if (trailing > 0 and trailing <= 4096) {
            var trail_buf: [4096]u8 = undefined;
            net.readExact(fd, trail_buf[0..trailing]) catch return null;

            if (format == 32 and value_len >= 1) {
                return readLE32(&trail_buf, 0);
            }
        }

        return null;
    }

    /// Main entry point: connect to X11, resolve atoms, and read the focused PID.
    fn getFocusedPid() ?i32 {
        const conn = connectDisplay() orelse return null;
        defer posix.close(conn.fd);

        // Intern atoms
        const net_active_window = internAtom(conn.fd, "_NET_ACTIVE_WINDOW") orelse return null;
        const net_wm_pid = internAtom(conn.fd, "_NET_WM_PID") orelse return null;

        // Get focused window ID from root
        const active_wid = getPropertyU32(conn.fd, conn.root, net_active_window) orelse return null;
        if (active_wid == 0) return null; // no focused window

        // Get PID from focused window
        const pid_u32 = getPropertyU32(conn.fd, active_wid, net_wm_pid) orelse return null;
        if (pid_u32 == 0) return null;

        const pid: i32 = @intCast(pid_u32);
        if (pid <= 0) return null;
        return pid;
    }

    // ─── Wire encoding helpers ───

    fn writeLE16(buf: []u8, pos: usize, val: u16) void {
        buf[pos] = @truncate(val);
        buf[pos + 1] = @truncate(val >> 8);
    }

    fn writeLE32(buf: []u8, pos: usize, val: u32) void {
        buf[pos] = @truncate(val);
        buf[pos + 1] = @truncate(val >> 8);
        buf[pos + 2] = @truncate(val >> 16);
        buf[pos + 3] = @truncate(val >> 24);
    }

    fn readLE16(buf: []const u8, pos: usize) u16 {
        return @as(u16, buf[pos]) | @as(u16, buf[pos + 1]) << 8;
    }

    fn readLE32(buf: []const u8, pos: usize) u32 {
        return @as(u32, buf[pos]) |
            @as(u32, buf[pos + 1]) << 8 |
            @as(u32, buf[pos + 2]) << 16 |
            @as(u32, buf[pos + 3]) << 24;
    }

    fn pad4(n: usize) usize {
        return (n + 3) & ~@as(usize, 3);
    }
};

// ─── Tests ───

const testing = std.testing;

test "x11.parseDisplay parses :0" {
    const d = x11.parseDisplay(":0").?;
    try testing.expectEqualStrings("", d.host);
    try testing.expectEqual(@as(u32, 0), d.display);
    try testing.expectEqual(@as(u32, 0), d.screen);
}

test "x11.parseDisplay parses :1.2" {
    const d = x11.parseDisplay(":1.2").?;
    try testing.expectEqualStrings("", d.host);
    try testing.expectEqual(@as(u32, 1), d.display);
    try testing.expectEqual(@as(u32, 2), d.screen);
}

test "x11.parseDisplay parses host:0" {
    const d = x11.parseDisplay("myhost:0").?;
    try testing.expectEqualStrings("myhost", d.host);
    try testing.expectEqual(@as(u32, 0), d.display);
    try testing.expectEqual(@as(u32, 0), d.screen);
}

test "x11.parseDisplay returns null for invalid" {
    try testing.expectEqual(@as(?x11.DisplayAddr, null), x11.parseDisplay(""));
    try testing.expectEqual(@as(?x11.DisplayAddr, null), x11.parseDisplay("nocolon"));
    try testing.expectEqual(@as(?x11.DisplayAddr, null), x11.parseDisplay(":"));
    try testing.expectEqual(@as(?x11.DisplayAddr, null), x11.parseDisplay(":abc"));
}

test "x11.pad4" {
    try testing.expectEqual(@as(usize, 0), x11.pad4(0));
    try testing.expectEqual(@as(usize, 4), x11.pad4(1));
    try testing.expectEqual(@as(usize, 4), x11.pad4(2));
    try testing.expectEqual(@as(usize, 4), x11.pad4(3));
    try testing.expectEqual(@as(usize, 4), x11.pad4(4));
    try testing.expectEqual(@as(usize, 8), x11.pad4(5));
}

test "x11.writeLE16 and readLE16 round-trip" {
    var buf: [2]u8 = undefined;
    x11.writeLE16(&buf, 0, 0x1234);
    try testing.expectEqual(@as(u16, 0x1234), x11.readLE16(&buf, 0));
}

test "x11.writeLE32 and readLE32 round-trip" {
    var buf: [4]u8 = undefined;
    x11.writeLE32(&buf, 0, 0xDEADBEEF);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), x11.readLE32(&buf, 0));
}

test "x11.readBE16" {
    const data = [_]u8{ 0x12, 0x34 };
    try testing.expectEqual(@as(?u16, 0x1234), x11.readBE16(&data, 0));
}

test "x11.parseXauthEntry matches local family" {
    // Build a minimal Xauthority entry for display :0, family=256 (local),
    // hostname "testhost", auth name "MIT-MAGIC-COOKIE-1", 16 bytes of data.
    var buf: [256]u8 = undefined;
    var pos: usize = 0;

    // Family: 256 (0x0100) = FamilyLocal (big-endian)
    buf[pos] = 0x01;
    buf[pos + 1] = 0x00;
    pos += 2;

    // Address: "testhost"
    const addr = "testhost";
    buf[pos] = 0;
    buf[pos + 1] = @intCast(addr.len);
    pos += 2;
    @memcpy(buf[pos .. pos + addr.len], addr);
    pos += addr.len;

    // Display number: "0"
    const num = "0";
    buf[pos] = 0;
    buf[pos + 1] = @intCast(num.len);
    pos += 2;
    @memcpy(buf[pos .. pos + num.len], num);
    pos += num.len;

    // Auth name: "MIT-MAGIC-COOKIE-1"
    const name = "MIT-MAGIC-COOKIE-1";
    buf[pos] = 0;
    buf[pos + 1] = @intCast(name.len);
    pos += 2;
    @memcpy(buf[pos .. pos + name.len], name);
    pos += name.len;

    // Auth data: 16 bytes of 0xAA
    buf[pos] = 0;
    buf[pos + 1] = 16;
    pos += 2;
    @memset(buf[pos .. pos + 16], 0xAA);
    pos += 16;

    const result = x11.parseXauthEntry(buf[0..pos], 0, "testhost");
    try testing.expect(result != null);
    try testing.expectEqualStrings("MIT-MAGIC-COOKIE-1", result.?.name);
    try testing.expectEqual(@as(usize, 16), result.?.data.len);
}

test "x11.parseXauthEntry returns null for wrong display" {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;

    buf[pos] = 0x01;
    buf[pos + 1] = 0x00;
    pos += 2;
    const addr = "testhost";
    buf[pos] = 0;
    buf[pos + 1] = @intCast(addr.len);
    pos += 2;
    @memcpy(buf[pos .. pos + addr.len], addr);
    pos += addr.len;
    const num = "0";
    buf[pos] = 0;
    buf[pos + 1] = @intCast(num.len);
    pos += 2;
    @memcpy(buf[pos .. pos + num.len], num);
    pos += num.len;
    const name = "MIT-MAGIC-COOKIE-1";
    buf[pos] = 0;
    buf[pos + 1] = @intCast(name.len);
    pos += 2;
    @memcpy(buf[pos .. pos + name.len], name);
    pos += name.len;
    buf[pos] = 0;
    buf[pos + 1] = 16;
    pos += 2;
    @memset(buf[pos .. pos + 16], 0xAA);
    pos += 16;

    // Ask for display 5 — should not match
    const result = x11.parseXauthEntry(buf[0..pos], 5, "testhost");
    try testing.expectEqual(@as(?x11.AuthData, null), result);
}

test "x11.parseRootWindow extracts root from minimal setup" {
    // Build minimal X11 setup response data (after 8-byte header).
    // We need: 24 bytes fixed, 0-byte vendor, 0 formats, 1 screen of 40 bytes.
    var data: [64]u8 = undefined;
    @memset(&data, 0);

    // vendor_len = 0 at offset 16
    x11.writeLE16(&data, 16, 0);
    // num_screens = 1 at offset 20
    data[20] = 1;
    // num_formats = 0 at offset 21
    data[21] = 0;

    // Screen starts at offset 24 (24 fixed + 0 vendor + 0 formats)
    // Root window at offset 0 of screen (offset 24 total)
    x11.writeLE32(&data, 24, 0x12345678);
    // num_depths at offset 39 of screen (offset 24+39=63)
    data[63] = 0;

    const root = x11.parseRootWindow(&data, 0);
    try testing.expectEqual(@as(?u32, 0x12345678), root);
}

test "x11.parseRootWindow returns null for bad screen" {
    var data: [64]u8 = undefined;
    @memset(&data, 0);
    x11.writeLE16(&data, 16, 0);
    data[20] = 1;
    data[21] = 0;
    x11.writeLE32(&data, 24, 0x12345678);
    data[63] = 0;

    // Ask for screen 1 — only 1 screen exists (index 0)
    try testing.expectEqual(@as(?u32, null), x11.parseRootWindow(&data, 1));
}

test "Dwm.connect uses default fifo path" {
    const dwm = Dwm.connect() catch unreachable;
    const path = dwm.fifo_path[0..dwm.fifo_path_len];
    try testing.expectEqualStrings(default_fifo_path, path);
}
