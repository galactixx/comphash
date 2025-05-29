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

    const zh_pkg = b.dependency("zighash", .{ .target = target, .optimize = optimize });
    const zh_mod = zh_pkg.module("zighash");
    lib_mod.addImport("zighash", zh_mod);

    const hash_tests = b.addTest(.{
        .root_source_file = b.path("src/comphash.zig"),
        .target = target,
        .optimize = optimize,
    });
    hash_tests.root_module.addImport("zighash", zh_mod);

    const run_tests = b.addRunArtifact(hash_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
