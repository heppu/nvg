const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "sway-focus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run sway-focus");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    if (b.args) |args| {
        run_exe_tests.addArgs(args);
    }
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);

    // Coverage step: run tests under kcov via Docker.
    // Usage: zig build coverage -- --junit <path>
    // Requires Docker to be installed and the kcov/kcov image available.
    const install_tests = b.addInstallArtifact(exe_tests, .{});
    const root = b.build_root.path orelse @panic("build root path is required for coverage");
    const uid = std.os.linux.getuid();
    const gid = std.os.linux.getgid();
    const coverage_cmd = b.addSystemCommand(&.{
        "docker",         "run",                "--rm",
        "--security-opt", "seccomp=unconfined", "-v",
    });
    coverage_cmd.addArg(b.fmt("{s}:{s}", .{ root, root }));
    coverage_cmd.addArgs(&.{ "--user", b.fmt("{d}:{d}", .{ uid, gid }) });
    coverage_cmd.addArgs(&.{
        "-w",
        root,
        "kcov/kcov",
        "kcov",
        "--include-pattern=src/",
        b.fmt("{s}/zig-out/coverage", .{root}),
        b.fmt("{s}/zig-out/bin/test", .{root}),
    });
    if (b.args) |args| {
        coverage_cmd.addArgs(args);
    }
    coverage_cmd.step.dependOn(&install_tests.step);
    const coverage_step = b.step("coverage", "Generate test coverage (requires Docker)");
    coverage_step.dependOn(&coverage_cmd.step);

    // Release step: build a ReleaseSafe binary and generate a SHA256 checksum.
    // Usage: zig build release
    // Output: zig-out/bin/sway-focus-linux-amd64 and sway-focus-linux-amd64.sha256
    const release_exe = b.addExecutable(.{
        .name = "sway-focus-linux-amd64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    const install_release = b.addInstallArtifact(release_exe, .{});
    const checksum = ChecksumStep.create(b, release_exe);
    checksum.step.dependOn(&install_release.step);
    const release_step = b.step("release", "Build release binary with checksum");
    release_step.dependOn(&checksum.step);
}

const ChecksumStep = struct {
    step: std.Build.Step,
    artifact: *std.Build.Step.Compile,

    fn create(owner: *std.Build, artifact: *std.Build.Step.Compile) *ChecksumStep {
        const self = owner.allocator.create(ChecksumStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "generate sha256 checksum",
                .owner = owner,
                .makeFn = make,
            }),
            .artifact = artifact,
        };
        return self;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const self: *ChecksumStep = @fieldParentPtr("step", step);
        const bin_name = self.artifact.name;
        const bin_dir = step.owner.getInstallPath(.bin, "");

        var dir = std.fs.openDirAbsolute(bin_dir, .{}) catch |err|
            return step.fail("failed to open bin dir '{s}': {s}", .{ bin_dir, @errorName(err) });
        defer dir.close();

        const bin_contents = dir.readFileAlloc(step.owner.allocator, bin_name, std.math.maxInt(usize)) catch |err|
            return step.fail("failed to read '{s}': {s}", .{ bin_name, @errorName(err) });

        var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bin_contents, &hash, .{});

        const checksum_name = std.fmt.allocPrint(step.owner.allocator, "{s}.sha256", .{bin_name}) catch @panic("OOM");
        const hex = std.fmt.bytesToHex(hash, .lower);
        const line = std.fmt.allocPrint(step.owner.allocator, "{s}  {s}\n", .{ hex, bin_name }) catch @panic("OOM");
        dir.writeFile(.{ .sub_path = checksum_name, .data = line }) catch |err|
            return step.fail("failed to write '{s}': {s}", .{ checksum_name, @errorName(err) });
    }
};
