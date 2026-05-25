/// GlazeWM IPC client (Windows).
///
/// GlazeWM runs a WebSocket IPC server on `ws://127.0.0.1:6123` by default.
/// Wire format:
///   - Client → server: WebSocket text frame containing a plain command
///     string, e.g. `query focused` or `command focus --direction left`.
///   - Server → client: WebSocket text frame containing a JSON envelope
///     `{success: bool, messageType: "client_response", data: {...},
///       error: string|null, clientMessage: string}`.
///
/// The Window container in a `query focused` response has a `handle` field
/// (the HWND as a number) but no `processId` — so we convert HWND → PID via
/// `GetWindowThreadProcessId`.
///
/// Each operation opens a fresh WebSocket connection. GlazeWM IPC is fast
/// and there's no benefit to keeping a long-lived socket for the typical
/// "one request per keypress" use.
const std = @import("std");
const builtin = @import("builtin");

const Direction = @import("direction.zig").Direction;
const wm = @import("wm.zig");
const log = @import("log.zig");
const platform = @import("platform.zig");

const default_port: u16 = 6123;
const default_host = "127.0.0.1";

pub const GlazeWm = struct {
    /// WindowManager vtable — must be the first field so that
    /// @fieldParentPtr can recover the GlazeWm from a *WindowManager.
    wm: wm.WindowManager = wm.vtable(GlazeWm),
    port: u16,

    pub fn connect() !GlazeWm {
        if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;

        const port = readPortFromEnv() orelse default_port;
        return .{ .port = port };
    }

    pub fn disconnect(_: *GlazeWm) void {}

    /// Query the focused window/workspace and return the focused window's PID.
    /// Returns null if the focused container is a workspace with no windows,
    /// or on any IPC/decoding error.
    pub fn getFocusedPid(self: *GlazeWm) ?i32 {
        var buf: [16384]u8 = undefined;
        const payload = ipcRequest(self.port, "query focused", &buf) orelse return null;
        const handle = parseFocusedHandle(payload) orelse return null;
        return hwndToPid(handle);
    }

    /// Dispatch a focus movement command.
    pub fn moveFocus(self: *GlazeWm, direction: Direction) void {
        const cmd = switch (direction) {
            .left => "command focus --direction left",
            .right => "command focus --direction right",
            .up => "command focus --direction up",
            .down => "command focus --direction down",
        };
        var buf: [4096]u8 = undefined;
        _ = ipcRequest(self.port, cmd, &buf);
    }
};

/// Optional GLAZEWM_PORT override for non-default IPC ports.
fn readPortFromEnv() ?u16 {
    const raw = platform.getenv("GLAZEWM_PORT") orelse return null;
    return std.fmt.parseInt(u16, raw, 10) catch null;
}

// ─── IPC ───

/// Open a TCP connection, perform the WebSocket handshake, send `request`
/// as a text frame, read one response text frame, and return its payload
/// in the caller's buffer. Returns null on any error.
fn ipcRequest(port: u16, request: []const u8, buf: []u8) ?[]const u8 {
    var stream = std.net.tcpConnectToHost(std.heap.page_allocator, default_host, port) catch {
        log.log("glazewm: tcp connect to {s}:{d} failed", .{ default_host, port });
        return null;
    };
    defer stream.close();

    handshake(stream, port) catch |err| {
        log.log("glazewm: websocket handshake failed: {s}", .{@errorName(err)});
        return null;
    };

    sendTextFrame(stream, request) catch {
        log.log("glazewm: send text frame failed", .{});
        return null;
    };

    return recvTextFrame(stream, buf) catch |err| {
        log.log("glazewm: recv text frame failed: {s}", .{@errorName(err)});
        return null;
    };
}

const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Minimal RFC 6455 client opening handshake.
///
/// Sends a fixed `Sec-WebSocket-Key` so we can predict the expected
/// `Sec-WebSocket-Accept` without pulling in std.crypto.random. GlazeWM
/// doesn't verify origin or subprotocols, so this is enough.
fn handshake(stream: std.net.Stream, port: u16) !void {
    // Use a fixed nonce — the spec requires it to be random per request,
    // but the server has no way to detect or enforce that. We compute the
    // matching Accept once and compare.
    const fixed_key_b64 = "dGhlIHNhbXBsZSBub25jZQ=="; // "the sample nonce"
    const expected_accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";

    var req_buf: [512]u8 = undefined;
    const req = std.fmt.bufPrint(
        &req_buf,
        "GET / HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:{d}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
        .{ port, fixed_key_b64 },
    ) catch return error.HandshakeRequestTooLong;

    try streamWriteAll(stream, req);

    // Read response until "\r\n\r\n".
    var resp_buf: [2048]u8 = undefined;
    var total: usize = 0;
    while (total < resp_buf.len) {
        const n = try streamRead(stream, resp_buf[total..]);
        if (n == 0) return error.HandshakeClosed;
        total += n;
        if (std.mem.indexOf(u8, resp_buf[0..total], "\r\n\r\n")) |_| break;
    }
    const header = resp_buf[0..total];

    // First line must be "HTTP/1.1 101 ...".
    if (!std.mem.startsWith(u8, header, "HTTP/1.1 101")) return error.HandshakeNot101;

    // Look for `Sec-WebSocket-Accept: <value>` (case-insensitive header name).
    const accept = findHeader(header, "sec-websocket-accept") orelse return error.MissingAccept;
    if (!std.mem.eql(u8, accept, expected_accept)) return error.AcceptMismatch;
}

/// Case-insensitive header lookup. Returns the trimmed value, or null if
/// the header isn't present.
fn findHeader(header: []const u8, name_lower: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, header, "\r\n");
    _ = it.next(); // skip status line
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const k = line[0..colon];
        if (k.len != name_lower.len) continue;
        var match = true;
        for (k, name_lower) |a, b| {
            const al = std.ascii.toLower(a);
            if (al != b) {
                match = false;
                break;
            }
        }
        if (!match) continue;
        const v = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return v;
    }
    return null;
}

/// Send a single masked text frame (opcode 0x1, FIN=1).
fn sendTextFrame(stream: std.net.Stream, payload: []const u8) !void {
    // Frame: FIN|opcode(1) + MASK|len + [ext len 2/8] + 4-byte mask + masked payload
    var hdr: [14]u8 = undefined;
    var pos: usize = 0;
    hdr[pos] = 0x80 | 0x1; // FIN=1, opcode=text
    pos += 1;

    const plen = payload.len;
    if (plen < 126) {
        hdr[pos] = 0x80 | @as(u8, @intCast(plen));
        pos += 1;
    } else if (plen <= std.math.maxInt(u16)) {
        hdr[pos] = 0x80 | 126;
        pos += 1;
        std.mem.writeInt(u16, hdr[pos..][0..2], @intCast(plen), .big);
        pos += 2;
    } else {
        hdr[pos] = 0x80 | 127;
        pos += 1;
        std.mem.writeInt(u64, hdr[pos..][0..8], plen, .big);
        pos += 8;
    }

    // Mask key — fixed (the spec allows any 32-bit value).
    const mask = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };
    @memcpy(hdr[pos..][0..4], &mask);
    pos += 4;

    try streamWriteAll(stream, hdr[0..pos]);

    // Mask & write payload in chunks to avoid a giant temp allocation.
    var masked: [1024]u8 = undefined;
    var sent: usize = 0;
    while (sent < payload.len) {
        const chunk = @min(masked.len, payload.len - sent);
        for (0..chunk) |i| {
            masked[i] = payload[sent + i] ^ mask[(sent + i) & 3];
        }
        try streamWriteAll(stream, masked[0..chunk]);
        sent += chunk;
    }
}

/// Receive a single (unfragmented) text frame from the server. Control
/// frames (ping/pong/close) are skipped silently if they arrive first.
fn recvTextFrame(stream: std.net.Stream, out: []u8) ![]const u8 {
    while (true) {
        var hdr: [2]u8 = undefined;
        try streamReadExact(stream, &hdr);
        const fin = (hdr[0] & 0x80) != 0;
        const opcode = hdr[0] & 0x0f;
        const masked = (hdr[1] & 0x80) != 0;
        var len: u64 = hdr[1] & 0x7f;

        if (len == 126) {
            var ext: [2]u8 = undefined;
            try streamReadExact(stream, &ext);
            len = std.mem.readInt(u16, &ext, .big);
        } else if (len == 127) {
            var ext: [8]u8 = undefined;
            try streamReadExact(stream, &ext);
            len = std.mem.readInt(u64, &ext, .big);
        }

        // Server frames should not be masked (RFC 6455 §5.1).
        if (masked) return error.UnexpectedMask;
        if (!fin) return error.FragmentedFrameUnsupported;

        if (opcode == 0x1) {
            // Text frame — copy payload into caller's buffer.
            if (len > out.len) return error.PayloadTooLarge;
            try streamReadExact(stream, out[0..@intCast(len)]);
            return out[0..@intCast(len)];
        }

        // Control frames (ping=0x9, pong=0xa, close=0x8) and unknowns:
        // drain the payload and continue. If close, also fail.
        var discard_buf: [256]u8 = undefined;
        var remaining: u64 = len;
        while (remaining > 0) {
            const chunk: usize = @intCast(@min(@as(u64, discard_buf.len), remaining));
            try streamReadExact(stream, discard_buf[0..chunk]);
            remaining -= chunk;
        }
        if (opcode == 0x8) return error.ServerClosedFrame;
        // ping/pong: keep looping until we see a text frame.
    }
}

// Stream.read in Zig 0.15 calls ReadFile on Windows, which fails on
// overlapped Winsock SOCKETs with ERROR_INVALID_PARAMETER. Use recv()
// directly instead. Stream.write goes through the buffered Writer, which
// already uses send() under the hood, but we keep a thin wrapper so the
// loop here mirrors the read side.

const ws2 = if (builtin.os.tag == .windows) std.os.windows.ws2_32 else void;

fn streamWriteAll(stream: std.net.Stream, data: []const u8) !void {
    if (comptime builtin.os.tag == .windows) {
        var written: c_int = 0;
        var remaining: c_int = @intCast(data.len);
        while (remaining > 0) {
            const n = ws2.send(@ptrCast(stream.handle), data.ptr + @as(usize, @intCast(written)), remaining, 0);
            if (n == ws2.SOCKET_ERROR or n == 0) return error.WriteFailed;
            written += n;
            remaining -= n;
        }
        return;
    }
    var written: usize = 0;
    while (written < data.len) {
        const n = stream.write(data[written..]) catch return error.WriteFailed;
        if (n == 0) return error.WriteFailed;
        written += n;
    }
}

fn streamRead(stream: std.net.Stream, buf: []u8) !usize {
    if (comptime builtin.os.tag == .windows) {
        const len: c_int = @intCast(buf.len);
        const n = ws2.recv(@ptrCast(stream.handle), buf.ptr, len, 0);
        if (n == ws2.SOCKET_ERROR) return error.ReadFailed;
        return @intCast(n);
    }
    return stream.read(buf) catch error.ReadFailed;
}

fn streamReadExact(stream: std.net.Stream, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try streamRead(stream, buf[total..]);
        if (n == 0) return error.ReadFailed;
        total += n;
    }
}

// ─── Parsing ───

/// Parse the focused container's `handle` (HWND) from a `query focused`
/// response. Returns null when the focused container is not a window
/// (workspace with no windows) or the response shape is unexpected.
///
/// Example response:
///   {"success":true,"messageType":"client_response",
///    "data":{"focused":{"type":"window","handle":1182238,...}},
///    "clientMessage":"query focused","error":null}
pub fn parseFocusedHandle(json_text: []const u8) ?u64 {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        std.heap.page_allocator,
        json_text,
        .{ .allocate = .alloc_always },
    ) catch return null;
    defer parsed.deinit();

    const envelope = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };

    const success_v = envelope.get("success") orelse return null;
    switch (success_v) {
        .bool => |b| if (!b) return null,
        else => return null,
    }

    const data_v = envelope.get("data") orelse return null;
    const data = switch (data_v) {
        .object => |o| o,
        else => return null,
    };

    const focused_v = data.get("focused") orelse return null;
    const focused = switch (focused_v) {
        .object => |o| o,
        .null => return null,
        else => return null,
    };

    const handle_v = focused.get("handle") orelse return null;
    return switch (handle_v) {
        .integer => |i| if (i > 0) @intCast(i) else null,
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

// ─── HWND → PID ───

const windows = struct {
    const w = std.os.windows;
    extern "user32" fn GetWindowThreadProcessId(hWnd: w.HWND, lpdwProcessId: *u32) callconv(.winapi) u32;
};

fn hwndToPid(handle_u64: u64) ?i32 {
    if (comptime builtin.os.tag != .windows) return null;
    const hwnd: std.os.windows.HWND = @ptrFromInt(@as(usize, @intCast(handle_u64)));
    var pid: u32 = 0;
    const thread_id = windows.GetWindowThreadProcessId(hwnd, &pid);
    if (thread_id == 0) return null;
    if (pid == 0) return null;
    return @intCast(pid);
}

// ─── Tests ───

const testing = std.testing;

test "parseFocusedHandle extracts handle from window response" {
    const json =
        \\{"success":true,"messageType":"client_response","data":{"focused":{"id":"abc","type":"window","handle":1182238,"title":"x","processName":"nvim.exe"}},"clientMessage":"query focused","error":null}
    ;
    try testing.expectEqual(@as(?u64, 1182238), parseFocusedHandle(json));
}

test "parseFocusedHandle returns null for workspace (no handle)" {
    const json =
        \\{"success":true,"messageType":"client_response","data":{"focused":{"id":"abc","type":"workspace","name":"1"}},"clientMessage":"query focused","error":null}
    ;
    try testing.expectEqual(@as(?u64, null), parseFocusedHandle(json));
}

test "parseFocusedHandle returns null for error response" {
    const json =
        \\{"success":false,"messageType":"client_response","data":null,"clientMessage":"query focused","error":"some error"}
    ;
    try testing.expectEqual(@as(?u64, null), parseFocusedHandle(json));
}

test "parseFocusedHandle returns null for null focused" {
    const json =
        \\{"success":true,"messageType":"client_response","data":{"focused":null},"clientMessage":"query focused","error":null}
    ;
    try testing.expectEqual(@as(?u64, null), parseFocusedHandle(json));
}

test "parseFocusedHandle returns null for invalid json" {
    try testing.expectEqual(@as(?u64, null), parseFocusedHandle("not json"));
}

test "parseFocusedHandle returns null for missing data" {
    const json =
        \\{"success":true,"messageType":"client_response","clientMessage":"x","error":null}
    ;
    try testing.expectEqual(@as(?u64, null), parseFocusedHandle(json));
}

test "findHeader is case-insensitive" {
    const resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: abc123\r\n\r\n";
    try testing.expectEqualStrings("abc123", findHeader(resp, "sec-websocket-accept").?);
    try testing.expectEqualStrings("websocket", findHeader(resp, "upgrade").?);
    try testing.expectEqual(@as(?[]const u8, null), findHeader(resp, "missing-header"));
}

test "expected_accept matches RFC 6455 example" {
    // The RFC's example: key "dGhlIHNhbXBsZSBub25jZQ==", accept "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=".
    // This test cross-checks the constant against std.crypto so any future
    // refactor that switches to dynamic keys still gets the right value.
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update("dGhlIHNhbXBsZSBub25jZQ==");
    hasher.update(ws_guid);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);

    var b64_buf: [32]u8 = undefined;
    const encoder = std.base64.standard.Encoder;
    const encoded = encoder.encode(&b64_buf, &digest);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", encoded);
}
