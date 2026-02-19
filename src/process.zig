/// Generic process tree walker.
///
/// Walks /proc/<pid>/task/*/children recursively, reading cmdline and exe
/// for each child process, and calls hook detectors to find matching applications.
const std = @import("std");
const posix = std.posix;

const hook_mod = @import("hook.zig");
const Hook = hook_mod.Hook;
const DetectedList = hook_mod.DetectedList;

const max_depth = 5;

/// Walk the process tree rooted at parent_pid, checking each child against
/// the enabled hooks. Appends matches to result with their depth.
pub fn walkTree(parent_pid: i32, enabled_hooks: []const *const Hook, result: *DetectedList, depth: u32) void {
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
                walkTree(child_pid, enabled_hooks, result, depth + 1);
            }
        }
    }
}

/// Read a file into the provided buffer, returning the slice of content read.
/// Reads in a loop to handle cases where a single read() doesn't return all
/// data (e.g., /proc files with many entries).
pub fn readFileToBuffer(path: []const u8, buf: []u8) ?[]const u8 {
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
    var buf: [4096]u8 = undefined;
    const content = readFileToBuffer("/proc/self/cmdline", &buf);
    try std.testing.expect(content != null);
    try std.testing.expect(content.?.len > 0);
}

test "readFileToBuffer returns null for nonexistent path" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), readFileToBuffer("/nonexistent/path/file", &buf));
}
