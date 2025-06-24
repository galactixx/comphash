const std = @import("std");

pub fn build(b: *std.Build) void {
    const root_source_file = "src/lib.zig";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ch_mod = b.addModule("comphash", .{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
    });

    _ = b.addLibrary(.{
        .name = "comphash",
        .linkage = .static,
        .root_module = ch_mod,
    });

    // add the zighash dependency for the hash function
    const zh_pkg = b.dependency("zighash", .{ .target = target, .optimize = optimize });
    const zh_mod = zh_pkg.module("zighash");
    ch_mod.addImport("zighash", zh_mod);

    // add the unit tests for the comphash library
    const unit_tests = b.addTest(.{
        .root_source_file = b.path(root_source_file),
    });
    unit_tests.root_module.addImport("zighash", zh_mod);

    // run the unit tests for the comphash library
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
