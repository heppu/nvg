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
    const result = try encodeRequest(&buf, 1, "nvim_eval", "winnr()");

    var pos: usize = 0;

    // fixarray(4)
    try std.testing.expectEqual(@as(u8, 0x94), result[pos]);
    pos += 1;

    // type = 0 (request)
    try std.testing.expectEqual(@as(u8, 0x00), result[pos]);
    pos += 1;

    // msgid = 1 as uint32: 0xce 0x00 0x00 0x00 0x01
    try std.testing.expectEqual(@as(u8, 0xce), result[pos]);
    pos += 1;
    try std.testing.expectEqual(@as(u8, 0x00), result[pos]);
    pos += 1;
    try std.testing.expectEqual(@as(u8, 0x00), result[pos]);
    pos += 1;
    try std.testing.expectEqual(@as(u8, 0x00), result[pos]);
    pos += 1;
    try std.testing.expectEqual(@as(u8, 0x01), result[pos]);
    pos += 1;

    // method "nvim_eval" as fixstr: 0xa0 | 9 = 0xa9, then 9 bytes
    try std.testing.expectEqual(@as(u8, 0xa9), result[pos]);
    pos += 1;
    try std.testing.expectEqualStrings("nvim_eval", result[pos .. pos + 9]);
    pos += 9;

    // fixarray(1) for params
    try std.testing.expectEqual(@as(u8, 0x91), result[pos]);
    pos += 1;

    // arg "winnr()" as fixstr: 0xa0 | 7 = 0xa7, then 7 bytes
    try std.testing.expectEqual(@as(u8, 0xa7), result[pos]);
    pos += 1;
    try std.testing.expectEqualStrings("winnr()", result[pos .. pos + 7]);
    pos += 7;

    // Total length should match
    try std.testing.expectEqual(pos, result.len);
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

// ─── readUint tests ───

test "readUint parses positive fixint" {
    const data = [_]u8{0x42};
    var pos: usize = 0;
    try std.testing.expectEqual(@as(?u64, 0x42), readUint(&data, &pos));
    try std.testing.expectEqual(@as(usize, 1), pos);
}

test "readUint parses uint8" {
    const data = [_]u8{ 0xcc, 0xff };
    var pos: usize = 0;
    try std.testing.expectEqual(@as(?u64, 255), readUint(&data, &pos));
    try std.testing.expectEqual(@as(usize, 2), pos);
}

test "readUint parses uint16" {
    const data = [_]u8{ 0xcd, 0x01, 0x00 };
    var pos: usize = 0;
    try std.testing.expectEqual(@as(?u64, 256), readUint(&data, &pos));
    try std.testing.expectEqual(@as(usize, 3), pos);
}

test "readUint parses uint32" {
    const data = [_]u8{ 0xce, 0x00, 0x01, 0x00, 0x00 };
    var pos: usize = 0;
    try std.testing.expectEqual(@as(?u64, 65536), readUint(&data, &pos));
    try std.testing.expectEqual(@as(usize, 5), pos);
}

test "readUint parses uint64" {
    const data = [_]u8{ 0xcf, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00 };
    var pos: usize = 0;
    try std.testing.expectEqual(@as(?u64, 0x100000000), readUint(&data, &pos));
    try std.testing.expectEqual(@as(usize, 9), pos);
}

test "readUint returns null for truncated uint8" {
    const data = [_]u8{0xcc}; // missing value byte
    var pos: usize = 0;
    try std.testing.expectEqual(@as(?u64, null), readUint(&data, &pos));
}

test "readUint returns null for truncated uint16" {
    const data = [_]u8{ 0xcd, 0x01 }; // missing second byte
    var pos: usize = 0;
    try std.testing.expectEqual(@as(?u64, null), readUint(&data, &pos));
}

test "readUint returns null for truncated uint32" {
    const data = [_]u8{ 0xce, 0x00, 0x01 }; // missing bytes
    var pos: usize = 0;
    try std.testing.expectEqual(@as(?u64, null), readUint(&data, &pos));
}

test "readUint returns null for truncated uint64" {
    const data = [_]u8{ 0xcf, 0x00, 0x00, 0x00 }; // missing bytes
    var pos: usize = 0;
    try std.testing.expectEqual(@as(?u64, null), readUint(&data, &pos));
}

test "readUint returns null for unknown type" {
    const data = [_]u8{0xc0}; // nil marker, not a uint
    var pos: usize = 0;
    try std.testing.expectEqual(@as(?u64, null), readUint(&data, &pos));
}

test "readUint returns null for empty data" {
    const data = [_]u8{};
    var pos: usize = 0;
    try std.testing.expectEqual(@as(?u64, null), readUint(&data, &pos));
}

// ─── encodeStr str8 path test ───

test "encodeRequest handles str8 method (32-255 bytes)" {
    var buf: [512]u8 = undefined;
    // Method name > 31 chars triggers str8 encoding
    const long_method = "a]" ** 16; // 32 chars
    const result = try encodeRequest(&buf, 0, long_method, "x");

    // After fixarray(4) + type(1) + uint32 msgid(5) = 7 bytes
    // str8 header: 0xd9, then length byte, then string
    try std.testing.expectEqual(@as(u8, 0xd9), result[7]);
    try std.testing.expectEqual(@as(u8, 32), result[8]);
    try std.testing.expectEqualStrings(long_method, result[9 .. 9 + 32]);
}

test "encodeRequest returns error for string > 255 bytes" {
    var buf: [1024]u8 = undefined;
    const huge = "x" ** 256;
    try std.testing.expectError(Error.InvalidMsgpackFormat, encodeRequest(&buf, 0, huge, "y"));
}

// ─── decodeResponse error path tests ───

test "decodeResponse returns ResponseTooShort for tiny data" {
    const data = [_]u8{ 0x94, 0x01, 0x00, 0xc0 }; // 4 bytes < 5
    try std.testing.expectError(Error.ResponseTooShort, decodeResponse(&data, 0));
}

test "decodeResponse returns InvalidMsgpackFormat for bad header" {
    // Not a fixarray(4) header
    const data = [_]u8{ 0x93, 0x01, 0x00, 0xc0, 0x03 };
    try std.testing.expectError(Error.InvalidMsgpackFormat, decodeResponse(&data, 0));
}

test "decodeResponse returns InvalidResponseType for non-response" {
    // type = 0 (request) instead of 1 (response)
    const data = [_]u8{ 0x94, 0x00, 0x00, 0xc0, 0x03 };
    try std.testing.expectError(Error.InvalidResponseType, decodeResponse(&data, 0));
}

test "decodeResponse returns InvalidResultType for non-uint result" {
    // result is nil (0xc0) instead of a uint
    const data = [_]u8{ 0x94, 0x01, 0x00, 0xc0, 0xc0 };
    try std.testing.expectError(Error.InvalidResultType, decodeResponse(&data, 0));
}

test "decodeResponse parses uint8 result" {
    // [1, 0, nil, uint8(200)]
    const data = [_]u8{ 0x94, 0x01, 0x00, 0xc0, 0xcc, 0xc8 };
    const result = try decodeResponse(&data, 0);
    try std.testing.expectEqual(@as(u64, 200), result);
}

test "decodeResponse parses uint16 result" {
    // [1, 0, nil, uint16(1000)]
    const data = [_]u8{ 0x94, 0x01, 0x00, 0xc0, 0xcd, 0x03, 0xe8 };
    const result = try decodeResponse(&data, 0);
    try std.testing.expectEqual(@as(u64, 1000), result);
}

test "decodeResponse parses uint32 msgid" {
    // [1, uint32(1), nil, 5]
    const data = [_]u8{ 0x94, 0x01, 0xce, 0x00, 0x00, 0x00, 0x01, 0xc0, 0x05 };
    const result = try decodeResponse(&data, 1);
    try std.testing.expectEqual(@as(u64, 5), result);
}
