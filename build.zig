const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const toon_mod = b.addModule("toon", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_unit_tests = b.addTest(.{
        .root_module = toon_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const conformance_mod = b.createModule(.{
        .root_source_file = b.path("tests/conformance.zig"),
        .target = target,
        .optimize = optimize,
    });
    conformance_mod.addImport("toon", toon_mod);

    const conformance_tests = b.addTest(.{
        .root_module = conformance_mod,
    });
    const run_conformance_tests = b.addRunArtifact(conformance_tests);

    const test_step = b.step("test", "Run unit and conformance tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_conformance_tests.step);
}
