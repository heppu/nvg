/// Generic process tree walker.
///
/// On Linux, walks /proc/<pid>/task/*/children recursively, reading cmdline
/// and exe for each child process, and calls hook detectors to find matching
/// applications.
///
/// On Windows, enumerates all processes via Toolhelp32Snapshot and walks the
/// parent-child relationships in memory, resolving the full executable path
/// via QueryFullProcessImageNameW for each candidate.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const hook_mod = @import("hook.zig");
const Hook = hook_mod.Hook;
const DetectedList = hook_mod.DetectedList;

const max_depth = 5;

/// Walk the process tree rooted at parent_pid, checking each child against
/// the enabled hooks. Appends matches to result with their depth.
pub fn walkTree(parent_pid: i32, enabled_hooks: []const *const Hook, result: *DetectedList, depth: u32) void {
    if (comptime builtin.os.tag == .windows) {
        return walkTreeWindows(parent_pid, enabled_hooks, result, depth);
    }
    return walkTreeLinux(parent_pid, enabled_hooks, result, depth);
}

// ─── Linux ───

fn walkTreeLinux(parent_pid: i32, enabled_hooks: []const *const Hook, result: *DetectedList, depth: u32) void {
    if (depth > max_depth) return;
    if (result.len >= hook_mod.max_detected) return;

    var path_buf: [64]u8 = undefined;
    const task_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/task", .{parent_pid}) catch return;

    var task_dir = std.fs.cwd().openDir(task_path, .{ .iterate = true }) catch return;
    defer task_dir.close();

    var task_iter = task_dir.iterate();
    while (task_iter.next() catch null) |task_entry| {
        if (task_entry.kind != .directory) continue;

        const task_pid = std.fmt.parseInt(i32, task_entry.name, 10) catch continue;

        var children_path_buf: [128]u8 = undefined;
        const children_path = std.fmt.bufPrint(&children_path_buf, "/proc/{d}/task/{d}/children", .{ parent_pid, task_pid }) catch continue;

        var children_buf: [4096]u8 = undefined;
        const children_content = readFileToBuffer(children_path, &children_buf) orelse continue;

        var it = std.mem.splitScalar(u8, children_content, ' ');
        while (it.next()) |child_str| {
            if (child_str.len == 0) continue;
            const child_pid = std.fmt.parseInt(i32, child_str, 10) catch continue;

            // Read /proc/<child>/cmdline (null-separated)
            var cmdline_path_buf: [64]u8 = undefined;
            const cmdline_path = std.fmt.bufPrint(&cmdline_path_buf, "/proc/{d}/cmdline", .{child_pid}) catch continue;

            var cmdline_buf: [4096]u8 = undefined;
            const cmdline_content = readFileToBuffer(cmdline_path, &cmdline_buf) orelse continue;
            if (cmdline_content.len == 0) continue;

            // argv[0]
            const cmd = nullTermStr(cmdline_content);

            // argv[1]
            const arg = blk: {
                const null_pos = std.mem.indexOfScalar(u8, cmdline_content, 0) orelse break :blk "";
                if (null_pos + 1 < cmdline_content.len) {
                    break :blk nullTermStr(cmdline_content[null_pos + 1 ..]);
                }
                break :blk "";
            };

            // Resolve /proc/<child>/exe
            var exe_link_buf: [64]u8 = undefined;
            const exe_link_path = std.fmt.bufPrint(&exe_link_buf, "/proc/{d}/exe", .{child_pid}) catch continue;
            var exe_target_buf: [1024]u8 = undefined;
            const exe = std.posix.readlinkat(std.posix.AT.FDCWD, exe_link_path, &exe_target_buf) catch "";

            // Check all enabled hooks against this child
            for (enabled_hooks) |h| {
                if (h.detectFn(child_pid, cmd, exe, arg)) |matched_pid| {
                    result.append(.{ .hook = h, .pid = matched_pid, .depth = depth });
                    break; // One hook per process
                }
            }

            // Recurse into child's subtree
            if (result.len < hook_mod.max_detected) {
                walkTreeLinux(child_pid, enabled_hooks, result, depth + 1);
            }
        }
    }
}

// ─── Windows ───

const w = std.os.windows;
const TH32CS_SNAPPROCESS: u32 = 0x00000002;
const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;

const PROCESSENTRY32W = extern struct {
    dwSize: u32,
    cntUsage: u32,
    th32ProcessID: u32,
    th32DefaultHeapID: usize,
    th32ModuleID: u32,
    cntThreads: u32,
    th32ParentProcessID: u32,
    pcPriClassBase: i32,
    dwFlags: u32,
    szExeFile: [260]u16,
};

extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: u32, th32ProcessID: u32) callconv(.winapi) w.HANDLE;
extern "kernel32" fn Process32FirstW(hSnapshot: w.HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) w.BOOL;
extern "kernel32" fn Process32NextW(hSnapshot: w.HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) w.BOOL;
extern "kernel32" fn CloseHandle(hObject: w.HANDLE) callconv(.winapi) w.BOOL;
extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: w.BOOL, dwProcessId: u32) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn QueryFullProcessImageNameW(
    hProcess: w.HANDLE,
    dwFlags: u32,
    lpExeName: [*]u16,
    lpdwSize: *u32,
) callconv(.winapi) w.BOOL;

const max_proc_entries = 1024;

const ProcEntry = struct {
    pid: u32,
    parent: u32,
    /// argv[0]-equivalent: just the executable filename, no path.
    name_utf8: [512]u8 = undefined,
    name_len: usize = 0,
};

/// Process snapshot — populated once per top-level walkTree call.
threadlocal var snapshot_buf: [max_proc_entries]ProcEntry = undefined;
threadlocal var snapshot_len: usize = 0;
threadlocal var snapshot_valid: bool = false;

fn walkTreeWindows(parent_pid: i32, enabled_hooks: []const *const Hook, result: *DetectedList, depth: u32) void {
    // Build the snapshot once per detection cycle. We invalidate it before
    // returning at depth 0 so subsequent invocations re-snapshot.
    const root = depth == 0;
    if (root) {
        snapshot_valid = false;
        snapshot_len = 0;
        takeSnapshot();
        snapshot_valid = true;
    }
    defer if (root) {
        snapshot_valid = false;
        snapshot_len = 0;
    };

    walkInnerWindows(parent_pid, enabled_hooks, result, depth);
}

fn walkInnerWindows(parent_pid: i32, enabled_hooks: []const *const Hook, result: *DetectedList, depth: u32) void {
    if (depth > max_depth) return;
    if (result.len >= hook_mod.max_detected) return;
    if (!snapshot_valid) return;

    for (snapshot_buf[0..snapshot_len]) |*entry| {
        if (@as(i32, @intCast(entry.parent)) != parent_pid) continue;
        const child_pid: i32 = @intCast(entry.pid);

        const cmd = entry.name_utf8[0..entry.name_len];

        // Resolve the full executable path. Treat failure as empty.
        var exe_buf: [1024]u8 = undefined;
        const exe = queryFullPath(entry.pid, &exe_buf) orelse "";

        for (enabled_hooks) |h| {
            if (h.detectFn(child_pid, cmd, exe, "")) |matched_pid| {
                result.append(.{ .hook = h, .pid = matched_pid, .depth = depth });
                break;
            }
        }

        if (result.len < hook_mod.max_detected) {
            walkInnerWindows(child_pid, enabled_hooks, result, depth + 1);
        }
        if (result.len >= hook_mod.max_detected) return;
    }
}

fn takeSnapshot() void {
    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == w.INVALID_HANDLE_VALUE) return;
    defer _ = CloseHandle(snap);

    var entry: PROCESSENTRY32W = undefined;
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    if (Process32FirstW(snap, &entry) == 0) return;

    while (true) {
        if (snapshot_len >= snapshot_buf.len) break;
        const slot = &snapshot_buf[snapshot_len];
        slot.pid = entry.th32ProcessID;
        slot.parent = entry.th32ParentProcessID;

        // Convert szExeFile (NUL-terminated WTF-16) to UTF-8.
        // Max source: 260 u16 → max 3*260 = 780 UTF-8 bytes for BMP, but
        // realistic process names fit well under our 512-byte buffer. If
        // the conversion would overflow, truncate at the WTF-16 level.
        var name_len: usize = 0;
        while (name_len < entry.szExeFile.len and entry.szExeFile[name_len] != 0) : (name_len += 1) {}
        // Conservatively bound the source length: 512 / 3 ≈ 170 BMP chars
        // is more than enough for any executable filename.
        const max_src = slot.name_utf8.len / 3;
        const src_len = if (name_len < max_src) name_len else max_src;
        const wide = entry.szExeFile[0..src_len];
        slot.name_len = std.unicode.wtf16LeToWtf8(&slot.name_utf8, wide);

        snapshot_len += 1;

        entry.dwSize = @sizeOf(PROCESSENTRY32W);
        if (Process32NextW(snap, &entry) == 0) break;
    }
}

fn queryFullPath(pid: u32, out: []u8) ?[]const u8 {
    const handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer _ = CloseHandle(handle);

    // Size the WTF-16 buffer so that 3x its length fits in `out`.
    const max_wide = @min(out.len / 3, 1024);
    var wide_buf: [1024]u16 = undefined;
    var size: u32 = @intCast(max_wide);
    if (QueryFullProcessImageNameW(handle, 0, &wide_buf, &size) == 0) return null;
    if (size == 0) return null;
    const utf8_len = std.unicode.wtf16LeToWtf8(out, wide_buf[0..size]);
    if (utf8_len == 0) return null;
    return out[0..utf8_len];
}

/// Read a file into the provided buffer, returning the slice of content read.
/// Reads in a loop to handle cases where a single read() doesn't return all
/// data (e.g., /proc files with many entries).
///
/// Linux only. Not used on Windows.
pub fn readFileToBuffer(path: []const u8, buf: []u8) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) return null;
    return readFileToBufferPosix(path, buf);
}

fn readFileToBufferPosix(path: []const u8, buf: []u8) ?[]const u8 {
    const path_z = posix.toPosixPath(path) catch return null;
    const fd = posix.openatZ(posix.AT.FDCWD, &path_z, .{}, 0) catch return null;
    defer posix.close(fd);

    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(fd, buf[total..]) catch return null;
        if (n == 0) break;
        total += n;
    }
    if (total == 0) return null;
    return buf[0..total];
}

/// A target environment variable to extract via readProcEnviron.
/// `buf` and `len` are written when a matching `KEY=VALUE` pair is found
/// in /proc/<pid>/environ. `len` is set to 0 when not found (callers
/// should initialise it that way too if they care about the post-condition).
pub const EnvSlot = struct {
    key: []const u8,
    buf: []u8,
    len: *usize,
};

/// Read /proc/<pid>/environ and copy any matching KEY values into the
/// provided slots. Each slot is filled in-place at most once. Returns
/// true if any slot was filled.
///
/// Linux only — Windows has no equivalent way to read another process's
/// environment block without diving into the PEB via NtQueryInformationProcess.
/// On Windows this always returns false.
pub fn readProcEnviron(pid: i32, slots: []const EnvSlot) bool {
    if (comptime builtin.os.tag == .windows) return false;
    return readProcEnvironPosix(pid, slots);
}

fn readProcEnvironPosix(pid: i32, slots: []const EnvSlot) bool {
    var path_buf: [64]u8 = undefined;
    const environ_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/environ", .{pid}) catch return false;

    var environ_buf: [8192]u8 = undefined;
    const content = readFileToBuffer(environ_path, &environ_buf) orelse return false;

    var any_found = false;
    var it = std.mem.splitScalar(u8, content, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        for (slots) |slot| {
            if (slot.len.* != 0) continue; // already filled
            if (!std.mem.startsWith(u8, entry, slot.key)) continue;
            if (entry.len <= slot.key.len or entry[slot.key.len] != '=') continue;
            const val = entry[slot.key.len + 1 ..];
            if (val.len == 0 or val.len > slot.buf.len) continue;
            @memcpy(slot.buf[0..val.len], val);
            slot.len.* = val.len;
            any_found = true;
            break;
        }
    }
    return any_found;
}

/// Extract a null-terminated (or end-of-slice) string from a buffer.
pub fn nullTermStr(buf: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, buf, 0)) |end| {
        return buf[0..end];
    }
    return buf;
}

test "nullTermStr" {
    const buf = "hello\x00world";
    try std.testing.expectEqualStrings("hello", nullTermStr(buf));
}

test "nullTermStr no null" {
    try std.testing.expectEqualStrings("hello", nullTermStr("hello"));
}

test "readFileToBuffer reads /proc/self/cmdline" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var buf: [4096]u8 = undefined;
    const content = readFileToBuffer("/proc/self/cmdline", &buf);
    try std.testing.expect(content != null);
    try std.testing.expect(content.?.len > 0);
}

test "readFileToBuffer returns null for nonexistent path" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), readFileToBuffer("/nonexistent/path/file", &buf));
}

test "readProcEnviron returns false for nonexistent pid" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var dst: [16]u8 = undefined;
    var dst_len: usize = 0;
    const slots = [_]EnvSlot{.{ .key = "FOO", .buf = &dst, .len = &dst_len }};
    try std.testing.expect(!readProcEnviron(4194304, &slots));
    try std.testing.expectEqual(@as(usize, 0), dst_len);
}

test "readProcEnviron reads /proc/self/environ" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    // /proc/self/environ should have at least PATH set in any normal env.
    var path_buf: [4096]u8 = undefined;
    var path_len: usize = 0;
    const slots = [_]EnvSlot{.{ .key = "PATH", .buf = &path_buf, .len = &path_len }};
    const pid: i32 = @intCast(std.os.linux.getpid());
    // Don't assert success — some sandboxed envs may not have PATH — just
    // verify it doesn't crash and that len is consistent with the return.
    if (readProcEnviron(pid, &slots)) {
        try std.testing.expect(path_len > 0);
    } else {
        try std.testing.expectEqual(@as(usize, 0), path_len);
    }
}

test "readProcEnviron skips already-filled slots" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    // Build a synthetic /proc/<pid>/environ scenario by calling against
    // /proc/self with a slot we pre-fill. The function should leave it alone.
    var dst: [16]u8 = undefined;
    @memcpy(dst[0..5], "stale");
    var dst_len: usize = 5;
    const slots = [_]EnvSlot{.{ .key = "PATH", .buf = &dst, .len = &dst_len }};
    const pid: i32 = @intCast(std.os.linux.getpid());
    _ = readProcEnviron(pid, &slots);
    // dst[0..5] should still be "stale" — slot was already filled.
    try std.testing.expectEqual(@as(usize, 5), dst_len);
    try std.testing.expectEqualStrings("stale", dst[0..5]);
}

test "windows.walkTree finds current process via snapshot" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    // Smoke test: the snapshot should at least include this test process,
    // which means walking from PID 4 (System) should produce some result.
    // We don't assert on specific PIDs — just that the call doesn't crash.
    var result = DetectedList{};
    walkTree(4, &[_]*const Hook{}, &result, 0);
    // No detectors registered — result must stay empty but the call must not crash.
    try std.testing.expectEqual(@as(usize, 0), result.len);
}
