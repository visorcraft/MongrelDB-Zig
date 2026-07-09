// Example: atomic batch transactions with the MongrelDB Zig client.
//
// Run from the repo root (after wiring the mongreldb dependency into your
// build.zig):
//
//   zig build run
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a table, stages three inserts in a single transaction, commits them
// atomically, verifies the count, then demonstrates idempotent retries by
// re-committing with the same idempotency key (the daemon returns the original
// result and applies no duplicate rows). Cleans up by dropping the table.

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

    // Unique table name + idempotency key per run so concurrent/repeated runs
    // never collide and retry logic isn't confused with a prior run's batch.
    const ts = std.time.timestamp();
    const table = try std.fmt.allocPrint(allocator, "example_txn_{d}", .{ts});
    const idempotency_key = try std.fmt.allocPrint(allocator, "example-txn-{d}", .{ts});

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

    // Stage three puts and commit them atomically. Either every op lands or
    // none do; a constraint violation rolls back the whole batch.
    var txn = db.begin(allocator);
    _ = try txn.put(table, &.{
        .{ .id = 1, .value = mongreldb.intValue(1) },
        .{ .id = 2, .value = mongreldb.stringValue("Alice") },
        .{ .id = 3, .value = mongreldb.floatValue(95.5) },
    }, false);
    _ = try txn.put(table, &.{
        .{ .id = 1, .value = mongreldb.intValue(2) },
        .{ .id = 2, .value = mongreldb.stringValue("Bob") },
        .{ .id = 3, .value = mongreldb.floatValue(82.0) },
    }, false);
    _ = try txn.put(table, &.{
        .{ .id = 1, .value = mongreldb.intValue(3) },
        .{ .id = 2, .value = mongreldb.stringValue("Carol") },
        .{ .id = 3, .value = mongreldb.floatValue(78.3) },
    }, false);
    std.debug.print("Staged {d} operations\n", .{txn.count()});

    const results = try txn.commit("");
    std.debug.print("Committed atomically: {d} operations applied\n", .{results.items.len});

    const after_commit = try db.count(allocator, table);
    std.debug.print("Verified row count after commit: {d}\n", .{after_commit});

    // Idempotent retry: stage the same batch again with an idempotency key,
    // then commit a second time with the SAME key. The daemon replays the
    // original result and applies no extra rows.
    var retry = db.begin(allocator);
    _ = try retry.put(table, &.{
        .{ .id = 1, .value = mongreldb.intValue(4) },
        .{ .id = 2, .value = mongreldb.stringValue("Dave") },
        .{ .id = 3, .value = mongreldb.floatValue(60.0) },
    }, false);
    _ = try retry.commit(idempotency_key);
    const after_first = try db.count(allocator, table);
    std.debug.print("After first idempotent commit: {d} rows\n", .{after_first});

    var retry2 = db.begin(allocator);
    _ = try retry2.put(table, &.{
        .{ .id = 1, .value = mongreldb.intValue(4) },
        .{ .id = 2, .value = mongreldb.stringValue("Dave") },
        .{ .id = 3, .value = mongreldb.floatValue(60.0) },
    }, false);
    _ = try retry2.commit(idempotency_key);
    const after_dup = try db.count(allocator, table);
    std.debug.print("After duplicate idempotent commit (same key): {d} rows (no double-apply)\n", .{after_dup});
}
