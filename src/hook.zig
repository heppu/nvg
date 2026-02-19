/// Hook interface for focus-aware applications.
///
/// Each hook represents an application that has internal focus/split navigation
/// (e.g., nvim splits, tmux panes). The focus system tries hooks innermost-first
/// and bubbles up to the next outer layer (or sway) when a hook is at its edge.
const std = @import("std");

const Direction = @import("main.zig").Direction;
const process = @import("process.zig");

pub const max_detected = 8;

/// A hook implementation for a focus-aware application.
pub const Hook = struct {
    name: []const u8,

    /// Check if a child process belongs to this application.
    /// Receives the child PID, argv[0] (cmd), resolved /proc/<pid>/exe path,
    /// and argv[1] (first argument).
    /// Returns the application PID if matched, null otherwise.
    detectFn: *const fn (child_pid: i32, cmd: []const u8, exe: []const u8, arg: []const u8) ?i32,

    /// Query whether the application can move focus in the given direction.
    /// Returns true if internal movement is possible (not at edge).
    /// Returns false if at edge (caller should bubble up).
    /// Returns null on error/timeout (treated as "at edge").
    canMoveFn: *const fn (pid: i32, dir: Direction, timeout_ms: u32) ?bool,

    /// Move focus one step in the given direction within the application.
    moveFocusFn: *const fn (pid: i32, dir: Direction, timeout_ms: u32) void,

    /// Move focus to the edge closest to where the user came from.
    /// Called after sway moves window focus into a window containing this app.
    moveToEdgeFn: *const fn (pid: i32, dir: Direction, timeout_ms: u32) void,

    /// Discover inner hooks that live in a separate process tree.
    /// For example, tmux implements this to find nvim running inside a pane —
    /// the tmux server's process tree is separate from the terminal's tree.
    /// Called by detectAll after the initial process tree walk.
    discoverInnerFn: *const fn (pid: i32, enabled_hooks: []const *const Hook, result: *DetectedList, depth: u32) void = &noopDiscoverInner,
};

/// Default no-op implementation for hooks that don't contain inner processes.
pub fn noopDiscoverInner(_: i32, _: []const *const Hook, _: *DetectedList, _: u32) void {}

/// A detected hook instance with its matched PID and tree depth.
pub const DetectedHook = struct {
    hook: *const Hook,
    pid: i32,
    depth: u32,
};

/// Result of detectAll — fixed-size array of optional detected hooks.
pub const DetectedList = struct {
    items: [max_detected]DetectedHook = undefined,
    len: usize = 0,

    pub fn append(self: *DetectedList, item: DetectedHook) void {
        if (self.len < max_detected) {
            self.items[self.len] = item;
            self.len += 1;
        }
    }

    /// Return a slice of detected hooks ordered shallowest-first.
    /// Callers wanting innermost-first should iterate in reverse.
    pub fn slice(self: *const DetectedList) []const DetectedHook {
        return self.items[0..self.len];
    }
};

/// All registered hooks. Order here doesn't matter — detection order
/// is determined by process tree depth (innermost wins).
pub const all_hooks = [_]*const Hook{
    &@import("hooks/nvim.zig").hook,
    &@import("hooks/tmux.zig").hook,
    &@import("hooks/vscode.zig").hook,
};

/// Walk the process tree from focused_pid and detect all matching hooks.
/// Returns matches ordered by depth (shallowest first).
/// Caller should iterate in reverse for innermost-first behavior.
///
/// Note: multiple instances of the same hook type may be detected if the
/// process tree contains nested instances (e.g., nvim spawning a nested
/// nvim via :terminal). This is intentional — the innermost-first iteration
/// ensures the correct instance handles the focus change.
pub fn detectAll(focused_pid: i32, enabled_hooks: []const *const Hook) DetectedList {
    var result = DetectedList{};
    process.walkTree(focused_pid, enabled_hooks, &result, 0);

    // Ask each detected hook to discover inner hooks in separate process trees.
    // For example, tmux queries its active pane's PID and walks that tree to
    // find nvim or other apps running inside the pane.
    // Snapshot the current length — we only iterate hooks from the initial walk,
    // not any newly discovered inner hooks (which are leaves, not containers).
    const initial_len = result.len;
    for (result.items[0..initial_len]) |detected| {
        detected.hook.discoverInnerFn(detected.pid, enabled_hooks, &result, detected.depth + 1);
    }

    return result;
}

/// Look up a hook by name. Returns null if not found.
pub fn findHookByName(name: []const u8) ?*const Hook {
    for (&all_hooks) |h| {
        if (std.mem.eql(u8, h.name, name)) return h;
    }
    return null;
}

test "findHookByName returns nvim hook" {
    const h = findHookByName("nvim");
    try std.testing.expect(h != null);
    try std.testing.expectEqualStrings("nvim", h.?.name);
}

test "findHookByName returns tmux hook" {
    const h = findHookByName("tmux");
    try std.testing.expect(h != null);
    try std.testing.expectEqualStrings("tmux", h.?.name);
}

test "findHookByName returns vscode hook" {
    const h = findHookByName("vscode");
    try std.testing.expect(h != null);
    try std.testing.expectEqualStrings("vscode", h.?.name);
}

test "findHookByName returns null for unknown" {
    try std.testing.expectEqual(@as(?*const Hook, null), findHookByName("nonexistent"));
}

test "DetectedList append and len" {
    const nvim_hook = &@import("hooks/nvim.zig").hook;
    const tmux_hook = &@import("hooks/tmux.zig").hook;
    var list = DetectedList{};
    try std.testing.expectEqual(@as(usize, 0), list.len);

    list.append(.{ .hook = nvim_hook, .pid = 123, .depth = 1 });
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(i32, 123), list.items[0].pid);

    list.append(.{ .hook = tmux_hook, .pid = 456, .depth = 2 });
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(@as(i32, 456), list.items[1].pid);

    // Verify slice returns correct view
    const s = list.slice();
    try std.testing.expectEqual(@as(usize, 2), s.len);
    try std.testing.expectEqualStrings("nvim", s[0].hook.name);
    try std.testing.expectEqualStrings("tmux", s[1].hook.name);
}

test "DetectedList overflow is silently dropped" {
    const nvim_hook = &@import("hooks/nvim.zig").hook;
    var list = DetectedList{};

    // Fill to max_detected
    for (0..max_detected) |i| {
        list.append(.{ .hook = nvim_hook, .pid = @intCast(i), .depth = 0 });
    }
    try std.testing.expectEqual(max_detected, list.len);

    // One more should be silently dropped
    list.append(.{ .hook = nvim_hook, .pid = 999, .depth = 0 });
    try std.testing.expectEqual(max_detected, list.len);

    // Last item should still be the max_detected-1 item, not 999
    try std.testing.expectEqual(@as(i32, @intCast(max_detected - 1)), list.items[max_detected - 1].pid);
}
