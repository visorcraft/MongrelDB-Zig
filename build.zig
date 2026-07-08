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

    // The test step boots a mongreldb-server daemon (when a binary is available)
    // and exercises the client against it. `zig build test` runs it.
    const tests = b.addTest(.{
        .root_source_file = b.path("tests/live_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("mongreldb", mongreldb_mod);

    const run_tests = b.addRunArtifact(tests);
    if (b.args) |args| {
        run_tests.addArgs(args);
    }

    const test_step = b.step("test", "Run the live integration tests against a mongreldb-server daemon");
    test_step.dependOn(&run_tests.step);
}
