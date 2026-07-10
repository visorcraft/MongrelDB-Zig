// Example: constrained columns (`enum_variants` and `default_value`) with the
// MongrelDB Zig client.
//
// Run from the repo root (after wiring the mongreldb dependency into your
// build.zig):
//
//   zig build run
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a `tickets` table with three constrained columns: an enum-only
// `priority`, an enum-with-default `status`, and a default-only `assignee`.
// Inserts one in-set row, then verifies that an out-of-enum value is rejected
// at commit time as `error.Conflict`. Cleans up by dropping the table.

const std = @import("std");
const mongreldb = @import("mongreldb");

const url = "http://127.0.0.1:8453";

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var db = mongreldb.Client.init(allocator, url, .{});
    defer db.deinit();

    const ok = db.health(allocator) catch false;
    if (!ok) {
        std.debug.print("daemon not reachable at {s}\n", .{url});
        std.process.exit(1);
    }
    std.debug.print("Connected to MongrelDB\n", .{});

    // Unique table name per run so concurrent/repeated runs never collide.
    const table = try std.fmt.allocPrint(allocator, "example_constraints_{d}", .{std.time.timestamp()});

    // Always drop the table on exit, even if an earlier step errored.
    defer {
        db.dropTable(allocator, table) catch {};
        std.debug.print("Dropped table {s}\n", .{table});
    }

    // Schema with three constraint-style columns:
    //   - `priority` is enum-only (no default).
    //   - `status`   is an enum with a default.
    //   - `assignee` is a plain string with a default.
    // `enum_variants` and `default_value` are omitted from the wire when null,
    // so columns that don't set them produce an identical payload to a
    // pre-T5.1 schema.
    const tid = try db.createTable(allocator, table, &.{
        .{ .id = 1, .name = "id", .ty = "int64", .primary_key = true },
        .{ .id = 2, .name = "title", .ty = "varchar" },
        // Enum only - writes outside the set are rejected at commit time.
        .{ .id = 3, .name = "priority", .ty = "varchar",
           .enum_variants = &.{ "low", "medium", "high" } },
        // Enum with a default applied when the cell is omitted.
        .{ .id = 4, .name = "status", .ty = "varchar",
           .enum_variants = &.{ "open", "in_progress", "closed" },
           .default_value = "open" },
        // Plain default, no enum constraint. The string is coerced server-side
        // per the column's `ty`.
        .{ .id = 5, .name = "assignee", .ty = "varchar",
           .default_value = "unassigned" },
    });
    std.debug.print("Created table {s} (id {d})\n", .{ table, tid });

    // Insert with every cell supplied. All three enum values are in-set.
    _ = try db.put(allocator, table, &.{
        .{ .id = 1, .value = mongreldb.intValue(1) },
        .{ .id = 2, .value = mongreldb.stringValue("Login broken") },
        .{ .id = 3, .value = mongreldb.stringValue("high") },
        .{ .id = 4, .value = mongreldb.stringValue("open") },
        .{ .id = 5, .value = mongreldb.stringValue("alice") },
    }, "");
    std.debug.print("Inserted row 1 (every cell supplied, all enum values in-set)\n", .{});

    // Try an out-of-enum value for `priority`. The engine rejects the write at
    // commit time, so this surfaces as `error.Conflict` (HTTP 409). The first
    // row remains intact because the rejection rolled back the batch.
    const bad = db.put(allocator, table, &.{
        .{ .id = 1, .value = mongreldb.intValue(2) },
        .{ .id = 2, .value = mongreldb.stringValue("Bogus priority") },
        .{ .id = 3, .value = mongreldb.stringValue("urgent") },
    }, "");
    if (bad) |_| {
        std.debug.print("Unexpected success for out-of-enum value\n", .{});
    } else |err| switch (err) {
        error.Conflict => std.debug.print("Out-of-enum value rejected as expected (error.Conflict)\n", .{}),
        else => std.debug.print("unexpected error: {!}\n", .{err}),
    }

    const total = try db.count(allocator, table);
    std.debug.print("Final row count: {d} (the rejected write did not land)\n", .{total});
}
