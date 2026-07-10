const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The "mongreldb" module exposes the client library to other Zig packages.
    const mongreldb_mod = b.addModule("mongreldb", .{
        .root_source_file = b.path("src/mongreldb.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The live test step boots a mongreldb-server daemon (when a binary is
    // available) and exercises the client against it. `zig build test` runs
    // it; without a daemon every live test self-skips, so the live suite
    // still validates every offline code path.
    const live_tests = b.addTest(.{
        .root_source_file = b.path("tests/live_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    live_tests.root_module.addImport("mongreldb", mongreldb_mod);

    const run_live_tests = b.addRunArtifact(live_tests);
    if (b.args) |args| {
        run_live_tests.addArgs(args);
    }

    // The wire-shape test step runs pure unit tests that serialize Column
    // structs to JSON and assert the produced wire shape. No daemon is
    // required; these guard the T5.ZIG ergonomic extensions
    // (enum_variants, default_value) against silent regressions.
    const wire_tests = b.addTest(.{
        .root_source_file = b.path("tests/wire_shape.zig"),
        .target = target,
        .optimize = optimize,
    });
    wire_tests.root_module.addImport("mongreldb", mongreldb_mod);

    const run_wire_tests = b.addRunArtifact(wire_tests);

    const test_step = b.step("test", "Run the live integration tests and wire-shape conformance tests");
    test_step.dependOn(&run_live_tests.step);
    test_step.dependOn(&run_wire_tests.step);
}
