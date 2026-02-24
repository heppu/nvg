/// Core focus navigation algorithm.
///
/// Extracted from main.zig so the algorithm can be tested in isolation
/// with mock WindowManager and Hook implementations — no real WM, no
/// real /proc filesystem needed.
///
/// The public entry point is `navigate()`. Production code passes
/// `hook_mod.detectAll` as the `DetectAllFn`; tests pass a mock.
const std = @import("std");

const hook_mod = @import("hook.zig");
const wm_mod = @import("wm.zig");
const log = @import("log.zig");

const Direction = @import("main.zig").Direction;
const Hook = hook_mod.Hook;
const DetectedList = hook_mod.DetectedList;
const WindowManager = wm_mod.WindowManager;

/// Signature matching `hook_mod.detectAll`.
pub const DetectAllFn = *const fn (i32, []const *const Hook) DetectedList;

/// Generic focus navigation.
///
/// 1. Get the focused window PID from the WM.
/// 2. Walk the process tree and detect all matching hooks.
/// 3. Iterate detected hooks in reverse (innermost first):
///    - If hook.canMove() returns true -> hook.moveFocus() and return.
///    - If false or null -> at edge, bubble up to next outer hook.
/// 4. If all hooks are at edge (or none detected) -> WM moveWindowFocus().
pub fn navigate(
    wm_inst: *WindowManager,
    direction: Direction,
    timeout_ms: u32,
    hooks: []const *const Hook,
    detectAllFn: DetectAllFn,
) void {
    const focused_pid = wm_inst.getFocusedPid() orelse {
        log.log("no focused window found, moving wm focus", .{});
        moveWindowFocus(wm_inst, direction, timeout_ms, hooks, detectAllFn);
        return;
    };
    log.log("focused window PID: {d}", .{focused_pid});

    // Detect all hooks in the process tree
    const detected = detectAllFn(focused_pid, hooks);
    log.log("detected {d} hook(s)", .{detected.len});

    if (detected.len == 0) {
        moveWindowFocus(wm_inst, direction, timeout_ms, hooks, detectAllFn);
        return;
    }

    // Iterate in reverse (innermost first)
    const items = detected.slice();
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        const d = items[i];
        log.log("trying hook '{s}' (pid={d}, depth={d})", .{ d.hook.name, d.pid, d.depth });
        const can = d.hook.canMoveFn(d.pid, direction, timeout_ms);
        if (can) |can_move| {
            if (can_move) {
                // Not at edge — move within this application
                log.log("hook '{s}' can move, executing", .{d.hook.name});
                d.hook.moveFocusFn(d.pid, direction, timeout_ms);
                return;
            }
            log.log("hook '{s}' at edge, bubbling up", .{d.hook.name});
            // At edge — bubble up to next outer hook
        } else {
            log.log("hook '{s}' returned null (error/timeout), bubbling up", .{d.hook.name});
        }
        // null (error/timeout) — treat as at edge, bubble up
    }

    // All hooks at edge or returned null — move window manager focus
    log.log("all hooks at edge, moving wm focus", .{});
    moveWindowFocus(wm_inst, direction, timeout_ms, hooks, detectAllFn);
}

/// Move window manager focus, then check if the newly focused window has
/// any detected hooks. If so, call moveToEdge on the innermost hook
/// with the opposite direction (so the user lands on the split closest
/// to where they came from).
fn moveWindowFocus(
    wm_inst: *WindowManager,
    direction: Direction,
    timeout_ms: u32,
    hooks: []const *const Hook,
    detectAllFn: DetectAllFn,
) void {
    wm_inst.moveFocus(direction);

    const next_pid = wm_inst.getFocusedPid() orelse return;
    log.log("new focused window PID: {d}", .{next_pid});

    const detected = detectAllFn(next_pid, hooks);
    if (detected.len == 0) return;

    // Innermost hook — last item in the shallowest-first list
    const innermost = detected.items[detected.len - 1];
    log.log("moving to edge in '{s}' (pid={d})", .{ innermost.hook.name, innermost.pid });
    innermost.hook.moveToEdgeFn(innermost.pid, direction.opposite(), timeout_ms);
}

// ─── Test infrastructure ───

const testing = std.testing;

/// Mock window manager that records calls and returns configurable values.
const MockWm = struct {
    wm: WindowManager = .{
        .getFocusedPidFn = wmGetFocusedPid,
        .moveFocusFn = wmMoveFocus,
        .disconnectFn = wmDisconnect,
    },
    /// PID to return from getFocusedPid. null = no focused window.
    focused_pid: ?i32 = null,
    /// PID to switch to after moveFocus is called (simulates WM focus change).
    next_focused_pid: ?i32 = null,
    /// Counts how many times moveFocus was called.
    move_focus_count: u32 = 0,
    /// Last direction passed to moveFocus.
    last_direction: ?Direction = null,
    /// Counts how many times getFocusedPid was called.
    get_focused_count: u32 = 0,

    fn wmGetFocusedPid(wm_ptr: *WindowManager) ?i32 {
        const self: *MockWm = @fieldParentPtr("wm", wm_ptr);
        self.get_focused_count += 1;
        return self.focused_pid;
    }

    fn wmMoveFocus(wm_ptr: *WindowManager, dir: Direction) void {
        const self: *MockWm = @fieldParentPtr("wm", wm_ptr);
        self.move_focus_count += 1;
        self.last_direction = dir;
        // Simulate WM switching focus to a different window
        self.focused_pid = self.next_focused_pid;
    }

    fn wmDisconnect(_: *WindowManager) void {}
};

// ─── Mock hook call recording ───

/// A recorded mock hook function call.
const CallRecord = struct {
    name: []const u8, // e.g. "inner.canMove", "outer.moveFocus"
    pid: i32,
    direction: Direction,
};

const max_call_log = 32;

/// File-level mutable state for recording mock hook calls.
/// Safe because tests run single-threaded.
var call_log_buf: [max_call_log]CallRecord = undefined;
var call_log_len: usize = 0;

fn recordCall(name: []const u8, pid: i32, dir: Direction) void {
    if (call_log_len < max_call_log) {
        call_log_buf[call_log_len] = .{ .name = name, .pid = pid, .direction = dir };
        call_log_len += 1;
    }
}

fn callLog() []const CallRecord {
    return call_log_buf[0..call_log_len];
}

fn hasCall(name: []const u8) bool {
    for (callLog()) |c| {
        if (std.mem.eql(u8, c.name, name)) return true;
    }
    return false;
}

fn resetCallLog() void {
    call_log_len = 0;
}

// ─── Mock hook: "inner" ───

/// What the inner hook's canMove should return. Set per-test.
var inner_can_move_result: ?bool = null;

fn innerDetect(_: i32, _: []const u8, _: []const u8, _: []const u8) ?i32 {
    return null; // detection handled by mock detectAll
}

fn innerCanMove(pid: i32, dir: Direction, _: u32) ?bool {
    recordCall("inner.canMove", pid, dir);
    return inner_can_move_result;
}

fn innerMoveFocus(pid: i32, dir: Direction, _: u32) void {
    recordCall("inner.moveFocus", pid, dir);
}

fn innerMoveToEdge(pid: i32, dir: Direction, _: u32) void {
    recordCall("inner.moveToEdge", pid, dir);
}

const mock_hook_inner = Hook{
    .name = "inner",
    .detectFn = &innerDetect,
    .canMoveFn = &innerCanMove,
    .moveFocusFn = &innerMoveFocus,
    .moveToEdgeFn = &innerMoveToEdge,
};

// ─── Mock hook: "outer" ───

var outer_can_move_result: ?bool = null;

fn outerDetect(_: i32, _: []const u8, _: []const u8, _: []const u8) ?i32 {
    return null;
}

fn outerCanMove(pid: i32, dir: Direction, _: u32) ?bool {
    recordCall("outer.canMove", pid, dir);
    return outer_can_move_result;
}

fn outerMoveFocus(pid: i32, dir: Direction, _: u32) void {
    recordCall("outer.moveFocus", pid, dir);
}

fn outerMoveToEdge(pid: i32, dir: Direction, _: u32) void {
    recordCall("outer.moveToEdge", pid, dir);
}

const mock_hook_outer = Hook{
    .name = "outer",
    .detectFn = &outerDetect,
    .canMoveFn = &outerCanMove,
    .moveFocusFn = &outerMoveFocus,
    .moveToEdgeFn = &outerMoveToEdge,
};

// ─── Mock detectAll ───

/// What detectAll returns for the initial focused PID.
var detect_initial: DetectedList = .{};
/// What detectAll returns for the post-WM-move PID.
var detect_next: DetectedList = .{};
/// The PID that triggers `detect_initial` (everything else gets `detect_next`).
var detect_initial_pid: i32 = 0;

fn mockDetectAll(pid: i32, _: []const *const Hook) DetectedList {
    if (pid == detect_initial_pid) return detect_initial;
    return detect_next;
}

/// Reset all mock state between tests.
fn resetMocks() void {
    resetCallLog();
    inner_can_move_result = null;
    outer_can_move_result = null;
    detect_initial = .{};
    detect_next = .{};
    detect_initial_pid = 0;
}

// ─── Tests ───

const test_hooks = &[_]*const Hook{ &mock_hook_outer, &mock_hook_inner };

// 1. No focused window → WM moveFocus called
test "navigate: no focused window moves wm focus" {
    resetMocks();
    var mock = MockWm{ .focused_pid = null, .next_focused_pid = null };
    navigate(&mock.wm, .left, 100, test_hooks, &mockDetectAll);

    try testing.expectEqual(@as(u32, 1), mock.move_focus_count);
    try testing.expectEqual(Direction.left, mock.last_direction.?);
    try testing.expect(!hasCall("inner.canMove"));
    try testing.expect(!hasCall("outer.canMove"));
}

// 2. No hooks detected → WM moveFocus called
test "navigate: no hooks detected moves wm focus" {
    resetMocks();
    detect_initial_pid = 100;
    detect_initial = .{}; // empty — no hooks

    var mock = MockWm{ .focused_pid = 100, .next_focused_pid = null };
    navigate(&mock.wm, .right, 100, test_hooks, &mockDetectAll);

    try testing.expectEqual(@as(u32, 1), mock.move_focus_count);
    try testing.expect(!hasCall("inner.canMove"));
}

// 3. One hook, canMove true → hook.moveFocus called, WM not called
test "navigate: single hook canMove true calls hook moveFocus" {
    resetMocks();
    detect_initial_pid = 100;
    detect_initial = .{};
    detect_initial.append(.{ .hook = &mock_hook_inner, .pid = 200, .depth = 1 });
    inner_can_move_result = true;

    var mock = MockWm{ .focused_pid = 100 };
    navigate(&mock.wm, .up, 100, test_hooks, &mockDetectAll);

    try testing.expectEqual(@as(u32, 0), mock.move_focus_count);
    try testing.expect(hasCall("inner.canMove"));
    try testing.expect(hasCall("inner.moveFocus"));
}

// 4. One hook, canMove false → WM moveFocus called
test "navigate: single hook canMove false moves wm focus" {
    resetMocks();
    detect_initial_pid = 100;
    detect_initial = .{};
    detect_initial.append(.{ .hook = &mock_hook_inner, .pid = 200, .depth = 1 });
    inner_can_move_result = false;

    var mock = MockWm{ .focused_pid = 100, .next_focused_pid = null };
    navigate(&mock.wm, .down, 100, test_hooks, &mockDetectAll);

    try testing.expectEqual(@as(u32, 1), mock.move_focus_count);
    try testing.expect(hasCall("inner.canMove"));
    try testing.expect(!hasCall("inner.moveFocus"));
}

// 5. One hook, canMove null (timeout) → WM moveFocus called
test "navigate: single hook canMove null (timeout) moves wm focus" {
    resetMocks();
    detect_initial_pid = 100;
    detect_initial = .{};
    detect_initial.append(.{ .hook = &mock_hook_inner, .pid = 200, .depth = 1 });
    inner_can_move_result = null;

    var mock = MockWm{ .focused_pid = 100, .next_focused_pid = null };
    navigate(&mock.wm, .left, 100, test_hooks, &mockDetectAll);

    try testing.expectEqual(@as(u32, 1), mock.move_focus_count);
    try testing.expect(hasCall("inner.canMove"));
    try testing.expect(!hasCall("inner.moveFocus"));
}

// 6. Two hooks, inner canMove true → inner moveFocus called, outer not tried
test "navigate: two hooks inner canMove true skips outer" {
    resetMocks();
    detect_initial_pid = 100;
    detect_initial = .{};
    detect_initial.append(.{ .hook = &mock_hook_outer, .pid = 300, .depth = 0 });
    detect_initial.append(.{ .hook = &mock_hook_inner, .pid = 200, .depth = 1 });
    inner_can_move_result = true;
    outer_can_move_result = true; // should not be reached

    var mock = MockWm{ .focused_pid = 100 };
    navigate(&mock.wm, .right, 100, test_hooks, &mockDetectAll);

    try testing.expectEqual(@as(u32, 0), mock.move_focus_count);
    try testing.expect(hasCall("inner.canMove"));
    try testing.expect(hasCall("inner.moveFocus"));
    try testing.expect(!hasCall("outer.canMove"));
}

// 7. Two hooks, inner at edge, outer canMove true → outer moveFocus called
test "navigate: two hooks inner at edge outer canMove true calls outer" {
    resetMocks();
    detect_initial_pid = 100;
    detect_initial = .{};
    detect_initial.append(.{ .hook = &mock_hook_outer, .pid = 300, .depth = 0 });
    detect_initial.append(.{ .hook = &mock_hook_inner, .pid = 200, .depth = 1 });
    inner_can_move_result = false;
    outer_can_move_result = true;

    var mock = MockWm{ .focused_pid = 100 };
    navigate(&mock.wm, .left, 100, test_hooks, &mockDetectAll);

    try testing.expectEqual(@as(u32, 0), mock.move_focus_count);
    try testing.expect(hasCall("inner.canMove"));
    try testing.expect(!hasCall("inner.moveFocus"));
    try testing.expect(hasCall("outer.canMove"));
    try testing.expect(hasCall("outer.moveFocus"));
}

// 8. Two hooks, both at edge → WM moveFocus called
test "navigate: two hooks both at edge moves wm focus" {
    resetMocks();
    detect_initial_pid = 100;
    detect_initial = .{};
    detect_initial.append(.{ .hook = &mock_hook_outer, .pid = 300, .depth = 0 });
    detect_initial.append(.{ .hook = &mock_hook_inner, .pid = 200, .depth = 1 });
    inner_can_move_result = false;
    outer_can_move_result = false;

    var mock = MockWm{ .focused_pid = 100, .next_focused_pid = null };
    navigate(&mock.wm, .up, 100, test_hooks, &mockDetectAll);

    try testing.expectEqual(@as(u32, 1), mock.move_focus_count);
    try testing.expect(hasCall("inner.canMove"));
    try testing.expect(hasCall("outer.canMove"));
    try testing.expect(!hasCall("inner.moveFocus"));
    try testing.expect(!hasCall("outer.moveFocus"));
}

// 9. After WM focus change, new window has hooks → moveToEdge called with opposite direction
test "navigate: after wm move new window has hook calls moveToEdge" {
    resetMocks();
    detect_initial_pid = 100;
    detect_initial = .{}; // no hooks on initial window

    // After WM moves focus, PID 500 is focused and has inner hook
    detect_next = .{};
    detect_next.append(.{ .hook = &mock_hook_inner, .pid = 600, .depth = 1 });

    var mock = MockWm{ .focused_pid = 100, .next_focused_pid = 500 };
    navigate(&mock.wm, .right, 100, test_hooks, &mockDetectAll);

    try testing.expectEqual(@as(u32, 1), mock.move_focus_count);
    // moveToEdge should be called with opposite direction
    try testing.expect(hasCall("inner.moveToEdge"));
    // Verify the direction is opposite (.right → .left)
    for (callLog()) |c| {
        if (std.mem.eql(u8, c.name, "inner.moveToEdge")) {
            try testing.expectEqual(Direction.left, c.direction);
        }
    }
}

// 10. After WM focus change, no hooks → no moveToEdge
test "navigate: after wm move no hooks no moveToEdge" {
    resetMocks();
    detect_initial_pid = 100;
    detect_initial = .{}; // no hooks on initial window
    detect_next = .{}; // no hooks on next window either

    var mock = MockWm{ .focused_pid = 100, .next_focused_pid = 500 };
    navigate(&mock.wm, .down, 100, test_hooks, &mockDetectAll);

    try testing.expectEqual(@as(u32, 1), mock.move_focus_count);
    try testing.expect(!hasCall("inner.moveToEdge"));
    try testing.expect(!hasCall("outer.moveToEdge"));
}
