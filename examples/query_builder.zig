// Example: query builder conditions with the MongrelDB Zig client.
//
// Run from the repo root (after wiring the mongreldb dependency into your
// build.zig):
//
//   zig build run
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a table, inserts five rows with varying scores, then uses the native
// query builder to fetch rows by a range condition and by an exact primary-key
// match. Cleans up by dropping the table.

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
    const table = try std.fmt.allocPrint(allocator, "example_query_{d}", .{std.time.timestamp()});

    // Always drop the table on exit, even if an earlier step errored.
    defer {
        db.dropTable(allocator, table) catch {};
        std.debug.print("Dropped table {s}\n", .{table});
    }

    _ = try db.createTable(allocator, table, &.{
        .{ .id = 1, .name = "id", .ty = "int64", .primary_key = true },
        .{ .id = 2, .name = "name", .ty = "varchar" },
        .{ .id = 3, .name = "score", .ty = "float64" },
    });
    std.debug.print("Created table {s}\n", .{table});

    // Five rows with varying scores.
    _ = try db.put(allocator, table, &.{
        .{ .id = 1, .value = mongreldb.intValue(1) },
        .{ .id = 2, .value = mongreldb.stringValue("Alice") },
        .{ .id = 3, .value = mongreldb.floatValue(40.0) },
    }, "");
    _ = try db.put(allocator, table, &.{
        .{ .id = 1, .value = mongreldb.intValue(2) },
        .{ .id = 2, .value = mongreldb.stringValue("Bob") },
        .{ .id = 3, .value = mongreldb.floatValue(65.0) },
    }, "");
    _ = try db.put(allocator, table, &.{
        .{ .id = 1, .value = mongreldb.intValue(3) },
        .{ .id = 2, .value = mongreldb.stringValue("Carol") },
        .{ .id = 3, .value = mongreldb.floatValue(82.0) },
    }, "");
    _ = try db.put(allocator, table, &.{
        .{ .id = 1, .value = mongreldb.intValue(4) },
        .{ .id = 2, .value = mongreldb.stringValue("Dave") },
        .{ .id = 3, .value = mongreldb.floatValue(91.0) },
    }, "");
    _ = try db.put(allocator, table, &.{
        .{ .id = 1, .value = mongreldb.intValue(5) },
        .{ .id = 2, .value = mongreldb.stringValue("Eve") },
        .{ .id = 3, .value = mongreldb.floatValue(12.5) },
    }, "");
    std.debug.print("Inserted 5 rows\n", .{});

    // Range condition: scores in [60.0, 90.0]. The "column" alias maps to the
    // server's column_id; pass the numeric column id (3), not the name.
    // Use range_f64 because the score column is float64 (plain range expects i64).
    var range_params = mongreldb.ObjectMap.init(allocator);
    try range_params.put("column", mongreldb.intValue(3));
    try range_params.put("min", mongreldb.floatValue(60.0));
    try range_params.put("max", mongreldb.floatValue(90.0));
    try range_params.put("min_inclusive", mongreldb.boolValue(true));
    try range_params.put("max_inclusive", mongreldb.boolValue(true));

    var range_q = db.query(allocator, table);
    _ = try range_q.where("range_f64", range_params);
    const range_rows = try range_q.execute();
    std.debug.print("Range query (score in [60,90]) returned {d} rows:\n", .{range_rows.items.len});
    printRows(range_rows);

    // Primary-key condition: fetch the single row with id == 4.
    var pk_params = mongreldb.ObjectMap.init(allocator);
    try pk_params.put("value", mongreldb.intValue(4));

    var pk_q = db.query(allocator, table);
    _ = try pk_q.where("pk", pk_params);
    const pk_rows = try pk_q.execute();
    std.debug.print("PK query (id == 4) returned {d} rows:\n", .{pk_rows.items.len});
    printRows(pk_rows);
}

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
