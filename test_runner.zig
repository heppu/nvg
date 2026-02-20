// Custom test runner for nvg.
// Based on https://gist.github.com/karlseguin/c6bea5b35e4e8d26af6f81c22cb5d76b
// with JUnit XML output support via --junit <path>.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const BORDER = "=" ** 80;

// Used in custom panic handler to identify which test panicked.
var current_test: ?[]const u8 = null;

pub fn main() !void {
    var mem: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);
    const allocator = fba.allocator();

    const env = Env.init(allocator);
    defer env.deinit(allocator);

    var slowest = SlowTracker.init(allocator, 5);
    defer slowest.deinit();

    // Parse --junit <path> from CLI args.
    var junit_path: ?[]const u8 = null;
    var args = std.process.args();
    _ = args.next(); // skip argv[0]
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--junit")) {
            junit_path = args.next();
        }
    }

    // Allocate results array for JUnit XML generation.
    const test_functions = builtin.test_functions;
    const results: ?[]Result = if (junit_path != null)
        std.heap.page_allocator.alloc(Result, test_functions.len) catch null
    else
        null;

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;

    Printer.fmt("\r\x1b[0K", .{}); // beginning of line and clear to end of line

    for (test_functions) |t| {
        if (isSetup(t)) {
            t.func() catch |err| {
                Printer.status(.fail, "\nsetup \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
        }
    }

    var test_idx: usize = 0;
    for (test_functions) |t| {
        if (isSetup(t) or isTeardown(t)) {
            continue;
        }

        var status = Status.pass;
        slowest.startTiming();

        const is_unnamed_test = isUnnamed(t);
        if (env.filter) |f| {
            if (!is_unnamed_test and std.mem.indexOf(u8, t.name, f) == null) {
                continue;
            }
        }

        const friendly_name = extractName(t.name);

        current_test = friendly_name;
        std.testing.allocator_instance = .{};
        const result = t.func();
        current_test = null;

        const ns_taken = slowest.endTiming(friendly_name);

        if (std.testing.allocator_instance.deinit() == .leak) {
            leak += 1;
            Printer.status(.fail, "\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, friendly_name, BORDER });
        }

        if (result) |_| {
            pass += 1;
            if (results) |r| {
                r[test_idx] = .{ .name = friendly_name, .status = .pass, .duration_ns = ns_taken };
            }
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                status = .skip;
                if (results) |r| {
                    r[test_idx] = .{ .name = friendly_name, .status = .skip, .duration_ns = ns_taken };
                }
            },
            else => {
                status = .fail;
                fail += 1;
                Printer.status(.fail, "\n{s}\n\"{s}\" - {s}\n{s}\n", .{ BORDER, friendly_name, @errorName(err), BORDER });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
                if (results) |r| {
                    r[test_idx] = .{ .name = friendly_name, .status = .fail, .duration_ns = ns_taken, .err_name = @errorName(err) };
                }
                if (env.fail_first) {
                    test_idx += 1;
                    break;
                }
            },
        }

        if (env.verbose) {
            const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
            Printer.status(status, "{s} ({d:.2}ms)\n", .{ friendly_name, ms });
        } else {
            Printer.status(status, ".", .{});
        }

        test_idx += 1;
    }

    for (test_functions) |t| {
        if (isTeardown(t)) {
            t.func() catch |err| {
                Printer.status(.fail, "\nteardown \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
        }
    }

    const total_tests = pass + fail;
    const total_status: Status = if (fail == 0) .pass else .fail;
    Printer.status(total_status, "\n{d} of {d} test{s} passed\n", .{ pass, total_tests, if (total_tests != 1) "s" else "" });
    if (skip > 0) {
        Printer.status(.skip, "{d} test{s} skipped\n", .{ skip, if (skip != 1) "s" else "" });
    }
    if (leak > 0) {
        Printer.status(.fail, "{d} test{s} leaked\n", .{ leak, if (leak != 1) "s" else "" });
    }
    Printer.fmt("\n", .{});
    try slowest.display();
    Printer.fmt("\n", .{});

    // Write JUnit XML if requested.
    if (junit_path) |path| {
        if (results) |r| {
            writeJUnit(path, r[0..test_idx]) catch |err| {
                Printer.status(.fail, "Failed to write JUnit XML: {s}\n", .{@errorName(err)});
            };
        }
    }

    std.posix.exit(if (fail == 0 and leak == 0) 0 else 1);
}

fn writeJUnit(path: []const u8, results: []const Result) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var buf: [8192]u8 = undefined;
    var file_writer = file.writer(&buf);
    const w = &file_writer.interface;

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var total_ns: u64 = 0;
    for (results) |r| {
        total_ns += r.duration_ns;
        switch (r.status) {
            .pass => pass += 1,
            .fail => fail += 1,
            .skip => skip += 1,
            .text => {},
        }
    }

    try w.print(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<testsuites>
        \\  <testsuite name="nvg" tests="{d}" failures="{d}" skipped="{d}" time="{d:.3}">
        \\
    , .{ pass + fail + skip, fail, skip, @as(f64, @floatFromInt(total_ns)) / 1e9 });

    for (results) |r| {
        const secs = @as(f64, @floatFromInt(r.duration_ns)) / 1e9;
        switch (r.status) {
            .pass => try w.print(
                "    <testcase name=\"{s}\" classname=\"nvg\" time=\"{d:.6}\"/>\n",
                .{ r.name, secs },
            ),
            .fail => try w.print(
                "    <testcase name=\"{s}\" classname=\"nvg\" time=\"{d:.6}\"><failure message=\"{s}\"/></testcase>\n",
                .{ r.name, secs, r.err_name orelse "unknown" },
            ),
            .skip => try w.print(
                "    <testcase name=\"{s}\" classname=\"nvg\" time=\"{d:.6}\"><skipped/></testcase>\n",
                .{ r.name, secs },
            ),
            .text => {},
        }
    }

    try w.print(
        \\  </testsuite>
        \\</testsuites>
        \\
    , .{});

    try w.flush();
}

const Printer = struct {
    fn fmt(comptime format: []const u8, args_: anytype) void {
        std.debug.print(format, args_);
    }

    fn status(s: Status, comptime format: []const u8, args_: anytype) void {
        switch (s) {
            .pass => std.debug.print("\x1b[32m", .{}),
            .fail => std.debug.print("\x1b[31m", .{}),
            .skip => std.debug.print("\x1b[33m", .{}),
            else => {},
        }
        std.debug.print(format ++ "\x1b[0m", args_);
    }
};

const Status = enum {
    pass,
    fail,
    skip,
    text,
};

const Result = struct {
    name: []const u8,
    status: Status,
    duration_ns: u64,
    err_name: ?[]const u8 = null,
};

const SlowTracker = struct {
    const SlowestQueue = std.PriorityDequeue(TestInfo, void, compareTiming);
    max: usize,
    slowest: SlowestQueue,
    timer: std.time.Timer,

    const TestInfo = struct {
        ns: u64,
        name: []const u8,
    };

    fn init(allocator: Allocator, count: u32) SlowTracker {
        const timer = std.time.Timer.start() catch @panic("failed to start timer");
        var slow = SlowestQueue.init(allocator, {});
        slow.ensureTotalCapacity(count) catch @panic("OOM");
        return .{
            .max = count,
            .timer = timer,
            .slowest = slow,
        };
    }

    fn deinit(self: SlowTracker) void {
        self.slowest.deinit();
    }

    fn startTiming(self: *SlowTracker) void {
        self.timer.reset();
    }

    fn endTiming(self: *SlowTracker, test_name: []const u8) u64 {
        var timer = self.timer;
        const ns = timer.lap();

        var slow = &self.slowest;

        if (slow.count() < self.max) {
            slow.add(TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
            return ns;
        }

        {
            const fastest_of_the_slow = slow.peekMin() orelse unreachable;
            if (fastest_of_the_slow.ns > ns) {
                return ns;
            }
        }

        _ = slow.removeMin();
        slow.add(TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
        return ns;
    }

    fn display(self: *SlowTracker) !void {
        var slow = self.slowest;
        const count = slow.count();
        Printer.fmt("Slowest {d} test{s}: \n", .{ count, if (count != 1) "s" else "" });
        while (slow.removeMinOrNull()) |info| {
            const ms = @as(f64, @floatFromInt(info.ns)) / 1_000_000.0;
            Printer.fmt("  {d:.2}ms\t{s}\n", .{ ms, info.name });
        }
    }

    fn compareTiming(context: void, a: TestInfo, b: TestInfo) std.math.Order {
        _ = context;
        return std.math.order(a.ns, b.ns);
    }
};

const Env = struct {
    verbose: bool,
    fail_first: bool,
    filter: ?[]const u8,

    fn init(allocator: Allocator) Env {
        return .{
            .verbose = readEnvBool(allocator, "TEST_VERBOSE", true),
            .fail_first = readEnvBool(allocator, "TEST_FAIL_FIRST", false),
            .filter = readEnv(allocator, "TEST_FILTER"),
        };
    }

    fn deinit(self: Env, allocator: Allocator) void {
        if (self.filter) |f| {
            allocator.free(f);
        }
    }

    fn readEnv(allocator: Allocator, key: []const u8) ?[]const u8 {
        const v = std.process.getEnvVarOwned(allocator, key) catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                return null;
            }
            std.log.warn("failed to get env var {s} due to err {}", .{ key, err });
            return null;
        };
        return v;
    }

    fn readEnvBool(allocator: Allocator, key: []const u8, deflt: bool) bool {
        const value = readEnv(allocator, key) orelse return deflt;
        defer allocator.free(value);
        return std.ascii.eqlIgnoreCase(value, "true");
    }
};

pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (current_test) |ct| {
            std.debug.print("\x1b[31m{s}\npanic running \"{s}\"\n{s}\x1b[0m\n", .{ BORDER, ct, BORDER });
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);

fn extractName(full: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, full, '.');
    while (it.next()) |value| {
        if (std.mem.eql(u8, value, "test")) {
            const rest = it.rest();
            return if (rest.len > 0) rest else full;
        }
    }
    return full;
}

fn isUnnamed(t: std.builtin.TestFn) bool {
    const marker = ".test_";
    const test_name = t.name;
    const index = std.mem.indexOf(u8, test_name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, test_name[index + marker.len ..], 10) catch return false;
    return true;
}

fn isSetup(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:beforeAll");
}

fn isTeardown(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:afterAll");
}
