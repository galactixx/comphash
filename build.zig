const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "comphash",
        .linkage = .static,
        .root_module = lib_mod,
    });
    lib.addIncludePath(b.path("include/"));
    b.installArtifact(lib);

    const zighash_mod = b.dependency("zighash", .{
        .target = target,
        .optimize = optimize,
    }).module("zighash");
    lib_mod.addImport("zighash", zighash_mod);

    const exe = b.addExecutable(.{
        .name = "main",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkLibrary(lib);
    b.installArtifact(exe);

    exe.root_module.addImport("zighash", zighash_mod);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const hash_tests = b.addTest(.{
        .root_source_file = b.path("src/comphash.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_tests = b.addRunArtifact(hash_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
