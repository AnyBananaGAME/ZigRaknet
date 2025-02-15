const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addSharedLibrary(.{
        .name = "ZigRaknet",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    lib.defineCMacro("NAPI_VERSION", "8");

    if (target.result.os.tag == .windows) {
        lib.addObjectFile(b.path("deps/node.lib"));
    }

    lib.linker_allow_shlib_undefined = true;
    const napigen = b.createModule(.{
        .root_source_file = b.path("deps/napi/napigen.zig"),
    });
    lib.root_module.addImport("napigen", napigen);

    b.installArtifact(lib);
    const copy_node_step = b.addInstallLibFile(lib.getEmittedBin(), "example.node");
    b.getInstallStep().dependOn(&copy_node_step.step);

    const exe = b.addExecutable(.{ .name = "ZigRaknet", .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    b.installArtifact(exe);
    exe.linkLibC();

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
