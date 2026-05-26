/// Small cross-platform helpers.
///
/// Only contains the few things that the rest of the codebase can't reach
/// for directly via std.posix or std.os.windows.
const std = @import("std");
const builtin = @import("builtin");

/// Cross-platform getenv.
///
/// On POSIX systems this is a zero-copy lookup into the program's environ
/// block. On Windows, environment strings live in WTF-16, so the value is
/// converted to UTF-8 and stored in a small static cache; the returned
/// slice is valid for the lifetime of the process.
///
/// Returns null if the variable is not set, is empty, or (on Windows) is
/// longer than `max_value_len`.
const max_value_len = 1024;
const max_name_len = 64;
const max_cache_entries = 16;

const CacheEntry = struct {
    name_buf: [max_name_len]u8 = undefined,
    name_len: usize = 0,
    value_buf: [max_value_len]u8 = undefined,
    value_len: usize = 0,
    /// false = not in env, true = value_buf[0..value_len] holds value
    present: bool = false,
};

var cache: [max_cache_entries]CacheEntry = [_]CacheEntry{.{}} ** max_cache_entries;
var cache_len: usize = 0;

pub fn getenv(name: []const u8) ?[]const u8 {
    if (comptime builtin.os.tag != .windows) {
        return std.posix.getenv(name);
    }
    return getenvWindowsCached(name);
}

fn getenvWindowsCached(name: []const u8) ?[]const u8 {
    if (name.len == 0 or name.len > max_name_len) return null;

    // Reuse cached entry if present.
    for (cache[0..cache_len]) |*e| {
        if (e.name_len == name.len and std.mem.eql(u8, e.name_buf[0..e.name_len], name)) {
            return if (e.present) e.value_buf[0..e.value_len] else null;
        }
    }

    if (cache_len >= cache.len) {
        // Cache full — fall back to no-cache lookup. nvg reads a handful of
        // env vars per invocation, so this should never trigger in practice.
        var tmp: [max_value_len]u8 = undefined;
        if (lookupWindows(name, &tmp)) |len| {
            // We can't safely return a pointer into a stack buffer, so use
            // the page allocator. Leaks, but nvg is a short-lived CLI.
            const copy = std.heap.page_allocator.alloc(u8, len) catch return null;
            @memcpy(copy, tmp[0..len]);
            return copy;
        }
        return null;
    }

    const slot = &cache[cache_len];
    @memcpy(slot.name_buf[0..name.len], name);
    slot.name_len = name.len;

    if (lookupWindows(name, &slot.value_buf)) |len| {
        slot.value_len = len;
        slot.present = true;
        cache_len += 1;
        return slot.value_buf[0..len];
    }

    slot.present = false;
    cache_len += 1;
    return null;
}

/// Look up `name` in the Windows environment block and write the UTF-8
/// value into `out`. Returns the number of bytes written, or null if the
/// variable is not set, empty, or wider than the output buffer.
fn lookupWindows(name: []const u8, out: []u8) ?usize {
    // Delegate to std.process.getEnvVarOwned, which knows how to talk to
    // the Windows environment block (WTF-16) and returns UTF-8.
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return null;
    defer std.heap.page_allocator.free(value);
    if (value.len == 0 or value.len > out.len) return null;
    @memcpy(out[0..value.len], value);
    return value.len;
}

test "getenv returns null for unset variable" {
    // Use a name very unlikely to be set.
    try std.testing.expectEqual(@as(?[]const u8, null), getenv("NVG_DOES_NOT_EXIST_XYZ"));
}
