const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("snag.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "snag",
        .root_module = root_module,
    });
    root_module.linkSystemLibrary("curl", .{});
    root_module.linkSystemLibrary("c", .{});

    // macOS 交叉编译需显式指定 SDK 路径
    if (target.result.os.tag == .macos) {
        const sdk = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr";
        root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{sdk}) });
        root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{sdk}) });
    }

    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run snag");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
