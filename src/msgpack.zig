/// Minimal msgpack encoder/decoder for neovim RPC.
///
/// Only supports the subset needed for nvim msgpack-RPC:
///   Encode: fixarray, positive fixint, uint32, fixstr, nil
///   Decode: parse response [1, msgid, nil/error, result]
const std = @import("std");

pub const Error = error{
    ResponseTooShort,
    InvalidResponseType,
    UnexpectedMsgId,
    NvimError,
    InvalidResultType,
    InvalidMsgpackFormat,
};

/// Encode a msgpack-RPC request into a fixed buffer.
/// Format: [type=0, msgid, method_str, [arg_str]]
/// Returns the slice of the buffer that was written.
pub fn encodeRequest(buf: []u8, msgid: u32, method: []const u8, arg: []const u8) Error![]u8 {
    var pos: usize = 0;

    // fixarray(4)
    buf[pos] = 0x94;
    pos += 1;

    // type = 0 (request)
    buf[pos] = 0x00;
    pos += 1;

    // msgid as uint32
    buf[pos] = 0xce; // uint32 marker
    pos += 1;
    buf[pos] = @intCast(msgid >> 24);
    pos += 1;
    buf[pos] = @intCast((msgid >> 16) & 0xff);
    pos += 1;
    buf[pos] = @intCast((msgid >> 8) & 0xff);
    pos += 1;
    buf[pos] = @intCast(msgid & 0xff);
    pos += 1;

    // method as str
    pos = encodeStr(buf, pos, method) orelse return Error.InvalidMsgpackFormat;

    // fixarray(1) for params
    buf[pos] = 0x91;
    pos += 1;

    // arg as str
    pos = encodeStr(buf, pos, arg) orelse return Error.InvalidMsgpackFormat;

    return buf[0..pos];
}

/// Encode a string into msgpack format at the given position.
/// Uses fixstr for len <= 31, str8 for len <= 255.
/// Returns the new position, or null if the string is too long.
fn encodeStr(buf: []u8, pos: usize, s: []const u8) ?usize {
    var p = pos;
    if (s.len <= 31) {
        // fixstr
        buf[p] = @as(u8, @intCast(0xa0 | s.len));
        p += 1;
    } else if (s.len <= 255) {
        // str8
        buf[p] = 0xd9;
        p += 1;
        buf[p] = @intCast(s.len);
        p += 1;
    } else {
        return null;
    }
    @memcpy(buf[p..][0..s.len], s);
    p += s.len;
    return p;
}

/// Decode a msgpack-RPC response and extract the result as u64.
/// Expected format: [1, msgid, nil, result]
/// result must be a positive fixint (0x00-0x7f) or uint variants.
pub fn decodeResponse(data: []const u8, expected_msgid: u32) Error!u64 {
    if (data.len < 5) return Error.ResponseTooShort;

    var pos: usize = 0;

    // Element 0: fixarray header
    if (data[pos] != 0x94) return Error.InvalidMsgpackFormat;
    pos += 1;

    // Element 1: type = 1 (response)
    const resp_type = readUint(data, &pos) orelse return Error.InvalidResponseType;
    if (resp_type != 1) return Error.InvalidResponseType;

    // Element 2: msgid
    const msgid = readUint(data, &pos) orelse return Error.InvalidMsgpackFormat;
    if (msgid != expected_msgid) return Error.UnexpectedMsgId;

    // Element 3: error (should be nil)
    if (pos >= data.len) return Error.ResponseTooShort;
    if (data[pos] != 0xc0) return Error.NvimError;
    pos += 1;

    // Element 4: result
    if (pos >= data.len) return Error.ResponseTooShort;
    const result = readUint(data, &pos) orelse return Error.InvalidResultType;
    return result;
}

/// Read an unsigned integer from msgpack data.
/// Supports positive fixint, uint8, uint16, uint32, uint64.
fn readUint(data: []const u8, pos: *usize) ?u64 {
    if (pos.* >= data.len) return null;
    const b = data[pos.*];

    if (b <= 0x7f) {
        // positive fixint
        pos.* += 1;
        return b;
    }

    switch (b) {
        0xcc => { // uint8
            if (pos.* + 1 >= data.len) return null;
            pos.* += 1;
            const val: u64 = data[pos.*];
            pos.* += 1;
            return val;
        },
        0xcd => { // uint16
            if (pos.* + 2 >= data.len) return null;
            pos.* += 1;
            const val: u64 = (@as(u64, data[pos.*]) << 8) | data[pos.* + 1];
            pos.* += 2;
            return val;
        },
        0xce => { // uint32
            if (pos.* + 4 >= data.len) return null;
            pos.* += 1;
            const val: u64 = (@as(u64, data[pos.*]) << 24) |
                (@as(u64, data[pos.* + 1]) << 16) |
                (@as(u64, data[pos.* + 2]) << 8) |
                data[pos.* + 3];
            pos.* += 4;
            return val;
        },
        0xcf => { // uint64
            if (pos.* + 8 >= data.len) return null;
            pos.* += 1;
            var val: u64 = 0;
            for (0..8) |i| {
                val = (val << 8) | data[pos.* + i];
            }
            pos.* += 8;
            return val;
        },
        else => return null,
    }
}

test "encodeRequest produces valid msgpack" {
    var buf: [256]u8 = undefined;
    const result = try encodeRequest(&buf, 0, "nvim_eval", "winnr()");
    // Should start with fixarray(4), type=0, uint32 msgid=0
    try std.testing.expectEqual(@as(u8, 0x94), result[0]);
    try std.testing.expectEqual(@as(u8, 0x00), result[1]);
    try std.testing.expectEqual(@as(u8, 0xce), result[2]); // uint32 marker
}

test "decodeResponse parses fixint result" {
    // [1, 0, nil, 3]
    const data = [_]u8{ 0x94, 0x01, 0x00, 0xc0, 0x03 };
    const result = try decodeResponse(&data, 0);
    try std.testing.expectEqual(@as(u64, 3), result);
}

test "decodeResponse detects wrong msgid" {
    const data = [_]u8{ 0x94, 0x01, 0x01, 0xc0, 0x03 };
    try std.testing.expectError(Error.UnexpectedMsgId, decodeResponse(&data, 0));
}

test "decodeResponse detects nvim error" {
    // error field is not nil (e.g. fixstr "err")
    const data = [_]u8{ 0x94, 0x01, 0x00, 0xa3, 0x65, 0x72, 0x72, 0x03 };
    try std.testing.expectError(Error.NvimError, decodeResponse(&data, 0));
}
