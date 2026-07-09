// Example: basic CRUD operations with the MongrelDB Zig client.
//
// Run from the repo root (after wiring the mongreldb dependency into your
// build.zig):
//
//   zig build run
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a table, inserts three rows, counts them, queries all rows, "updates"
// one row by overwriting it at its primary key, deletes one row, then drops
// the table. Progress is printed at every step.

const std = @import("std");
const mongreldb = @import("mongreldb");

const url = "http://127.0.0.1:8453";
const table = "example_crud";

pub fn main() !void {
    // An arena allocator frees every client allocation in one go at the end.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var db = mongreldb.Client.init(allocator, url, .{});
    defer db.deinit();

    // Health check; bail out if the daemon is unreachable.
    const ok = db.health(allocator) catch false;
    if (!ok) {
        std.debug.print("daemon not reachable at {s}\n", .{url});
        std.process.exit(1);
    }
    std.debug.print("Connected to MongrelDB\n", .{});

    // Create the table. Schema: id (int64 PK), name (varchar), score (float64).
    const tid = try db.createTable(allocator, table, &.{
        .{ .id = 1, .name = "id", .ty = "int64", .primary_key = true },
        .{ .id = 2, .name = "name", .ty = "varchar" },
        .{ .id = 3, .name = "score", .ty = "float64" },
    });
    std.debug.print("Created table {s} (id {d})\n", .{ table, tid });

    // Insert three rows. Cells pair column id -> value.
    _ = try db.put(allocator, table, &.{
        .{ .id = 1, .value = mongreldb.intValue(1) },
        .{ .id = 2, .value = mongreldb.stringValue("Alice") },
        .{ .id = 3, .value = mongreldb.floatValue(95.5) },
    }, "");
    _ = try db.put(allocator, table, &.{
        .{ .id = 1, .value = mongreldb.intValue(2) },
        .{ .id = 2, .value = mongreldb.stringValue("Bob") },
        .{ .id = 3, .value = mongreldb.floatValue(82.0) },
    }, "");
    _ = try db.put(allocator, table, &.{
        .{ .id = 1, .value = mongreldb.intValue(3) },
        .{ .id = 2, .value = mongreldb.stringValue("Carol") },
        .{ .id = 3, .value = mongreldb.floatValue(78.3) },
    }, "");
    std.debug.print("Inserted 3 rows\n", .{});

    const total = try db.count(allocator, table);
    std.debug.print("Total rows: {d}\n", .{total});

    // Query all rows (no conditions).
    var all_q = db.query(allocator, table);
    const all = try all_q.execute();
    std.debug.print("Query returned {d} rows:\n", .{all.items.len});
    printRows(all);

    // Update Alice's score by re-putting the same primary key with new values.
    // The PK is the row identity, so a put to an existing PK overwrites it.
    _ = try db.put(allocator, table, &.{
        .{ .id = 1, .value = mongreldb.intValue(1) },
        .{ .id = 2, .value = mongreldb.stringValue("Alice") },
        .{ .id = 3, .value = mongreldb.floatValue(100.0) },
    }, "");
    std.debug.print("Updated Alice's score to 100.0\n", .{});

    const after_update = try db.count(allocator, table);
    std.debug.print("Total rows after update: {d}\n", .{after_update});

    // Delete Carol (primary key 3).
    try db.deleteByPk(allocator, table, mongreldb.intValue(3));
    const after_delete = try db.count(allocator, table);
    std.debug.print("Deleted Carol; remaining rows: {d}\n", .{after_delete});

    // Cleanup.
    db.dropTable(allocator, table) catch {};
    std.debug.print("Dropped table {s}\n", .{table});
}

// Print each row object from a query result array. Rows are JSON objects keyed
// by column id (string keys like "1", "2", "3").
fn printRows(rows: mongreldb.Array) void {
    for (rows.items) |row_val| {
        const obj = switch (row_val) {
            .object => |o| o,
            else => continue,
        };
        var it = obj.iterator();
        var first = true;
        std.debug.print("  {{ ", .{});
        while (it.next()) |entry| {
            if (!first) std.debug.print(", ", .{});
            std.debug.print("{s}={s}", .{ entry.key_ptr.*, formatValue(entry.value_ptr.*) });
            first = false;
        }
        std.debug.print(" }}\n", .{});
    }
}

fn formatValue(v: mongreldb.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        else => "<value>",
    };
}
