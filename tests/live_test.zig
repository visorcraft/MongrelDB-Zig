//! Live integration tests for the mongreldb Zig client.
//!
//! These boot a real mongreldb-server daemon and exercise the client end to
//! end. The daemon binary is resolved in this order:
//!   1. MONGRELDB_SERVER env var (path to the server binary).
//!   2. ./bin/mongreldb-server relative to the current working directory.
//!   3. mongreldb-server on PATH.
//!
//! If no binary is available, every live test self-skips. Set MONGRELDB_URL to
//! point at an already-running daemon to skip the boot and connect directly.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const mongreldb = @import("mongreldb");

const Client = mongreldb.Client;
const Cell = mongreldb.Cell;
const Value = mongreldb.Value;
const ObjectMap = mongreldb.ObjectMap;

// Shared harness state, populated by setupDaemon.
//
// All harness allocations (the daemon `Child`, the shared `Client` and its
// HTTP connection pool, env-owned strings, etc.) are routed through a single
// `test_arena` backed by `testing.allocator`. `teardownDaemon` deinit's the
// arena, which returns every byte to the backing GPA so the leak-detecting
// `testing.allocator` reports a clean balance at process exit.
var harness_client: ?*Client = null;
var test_arena: std.heap.ArenaAllocator = undefined;
var test_arena_inited: bool = false;
var harness_alloc: Allocator = undefined;
var server_child: ?*std.process.Child = null;

/// `ensureArena` lazily initializes the global test arena on first use and
/// points `harness_alloc` at it. Called from `setupDaemon` (via every test's
/// `skipIfNoClient`) before any harness allocation, so `harness_alloc` is
/// always valid by the time tests use it.
fn ensureArena() void {
    if (test_arena_inited) return;
    test_arena = std.heap.ArenaAllocator.init(testing.allocator);
    harness_alloc = test_arena.allocator();
    test_arena_inited = true;
}

// ── Daemon lifecycle ─────────────────────────────────────────────────────

pub fn setupDaemon() void {
    if (harness_client != null) return;
    ensureArena();

    // If a daemon is already running, connect to it directly.
    if (std.process.getEnvVarOwned(harness_alloc, "MONGRELDB_URL")) |existing| {
        var c = harness_alloc.create(Client) catch return;
        c.* = Client.init(harness_alloc, existing, .{
            .token = std.process.getEnvVarOwned(harness_alloc, "MONGRELDB_TOKEN") catch "",
        });
        if (c.health(harness_alloc)) |_| {
            harness_client = c;
            return;
        } else |_| {
            std.debug.print("mongreldb: MONGRELDB_URL={s} is not reachable\n", .{existing});
            std.process.exit(1);
        }
    } else |_| {}

    const bin = resolveServerBinary() catch {
        // No daemon available; live tests self-skip.
        return;
    };

    const port = freePort() catch {
        std.debug.print("mongreldb: no free port\n", .{});
        std.process.exit(1);
    };

    const a = harness_alloc;

    const url = std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{port}) catch return;
    const port_str = std.fmt.allocPrint(a, "{d}", .{port}) catch return;
    const data_path = std.fmt.allocPrint(a, "/tmp/mongreldb-zig-test-{d}", .{std.time.nanoTimestamp()}) catch return;

    // Create the data dir fresh on disk for the daemon's --data path.
    std.fs.cwd().makePath(data_path) catch {};

    var child = a.create(std.process.Child) catch return;
    child.* = std.process.Child.init(&.{ bin, data_path, "--port", port_str }, a);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch {
        std.debug.print("mongreldb: failed to start server\n", .{});
        return;
    };
    server_child = child;

    if (!waitForHealth(a, url, 40 * std.time.ns_per_s)) {
        const stderr = if (child.stderr) |f| readAll(a, f) catch "" else "";
        std.debug.print("mongreldb: server did not become healthy. stderr:\n{s}\n", .{stderr});
        _ = child.kill() catch {};
        std.process.exit(1);
    }

    const c = a.create(Client) catch return;
    c.* = Client.init(harness_alloc, url, .{});
    harness_client = c;
}

fn teardownDaemon() void {
    if (server_child) |child| {
        _ = child.kill() catch {};
        server_child = null;
    }
    // Reclaim every harness allocation (shared Client + its HTTP connection
    // pool, daemon Child, env strings, etc.) back to the backing GPA.
    if (test_arena_inited) {
        test_arena.deinit();
        test_arena_inited = false;
        harness_client = null;
    }
}

fn resolveServerBinary() ![]const u8 {
    if (std.process.getEnvVarOwned(harness_alloc, "MONGRELDB_SERVER")) |env| {
        if (isExecutable(env)) return env;
        return error.NotFound;
    } else |_| {}

    const local = "bin/mongreldb-server";
    if (isExecutable(local)) {
        const cwd = try std.process.getCwdAlloc(harness_alloc);
        defer harness_alloc.free(cwd);
        return try std.fs.path.join(harness_alloc, &.{ cwd, local });
    }

    return error.NotFound;
}

fn isExecutable(path: []const u8) bool {
    const file = std.fs.cwd().statFile(path) catch return false;
    if (file.kind != .file) return false;
    // Best-effort exec bit check on POSIX; ignore on other platforms.
    // Zig 0.13's File.Stat dropped `.permission`, so use access(2) instead.
    if (builtin.os.tag != .windows) {
        std.posix.access(path, std.posix.X_OK) catch return false;
    }
    return true;
}

fn freePort() !u16 {
    // Bind to port 0 to let the OS pick a free port, then close and return it.
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    const port = server.listen_address.in.getPort();
    server.deinit();
    return port;
}

fn waitForHealth(a: Allocator, url: []const u8, max_ns: u64) bool {
    const deadline = @as(u64, @intCast(std.time.nanoTimestamp())) + max_ns;
    while (@as(u64, @intCast(std.time.nanoTimestamp())) < deadline) {
        var c = Client.init(a, url, .{});
        defer c.deinit();
        if (c.health(a)) |_| return true else |_| {}
        std.time.sleep(500 * std.time.ns_per_ms);
    }
    return false;
}

fn readAll(a: Allocator, file: std.fs.File) ![]u8 {
    var list = std.ArrayList(u8).init(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch break;
        if (n == 0) break;
        try list.appendSlice(buf[0..n]);
    }
    return list.toOwnedSlice();
}

// ── Test helpers ─────────────────────────────────────────────────────────

fn skipIfNoClient() !void {
    setupDaemon();
    if (harness_client == null) return error.SkipZigTest;
}

fn uniqueTable(a: Allocator, prefix: []const u8) ![]const u8 {
    var bytes: [6]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    var hex: [12]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.fmtSliceHexLower(&bytes)}) catch unreachable;
    return std.fmt.allocPrint(a, "{s}_{s}", .{ prefix, hex });
}

fn intCol(id: i64, name: []const u8, primary_key: bool) mongreldb.Column {
    return .{ .id = id, .name = name, .ty = "int64", .primary_key = primary_key, .nullable = false };
}

fn floatCol(id: i64, name: []const u8) mongreldb.Column {
    return .{ .id = id, .name = name, .ty = "float64", .primary_key = false, .nullable = false };
}

fn freshTable(a: Allocator, name: []const u8, columns: []const mongreldb.Column) !void {
    const c = harness_client.?;
    _ = c.dropTable(a, name) catch {};
    _ = try c.createTable(a, name, columns);
}

fn mustPut(a: Allocator, table: []const u8, cells: []const Cell) !void {
    _ = try harness_client.?.put(a, table, cells, "");
}

// ── Tests ────────────────────────────────────────────────────────────────

test "health" {
    try skipIfNoClient();
    const a = harness_alloc;
    const c = harness_client.?;
    try testing.expect(try c.health(a));
}

test "createTableAndCount" {
    try skipIfNoClient();
    const a = harness_alloc;
    const c = harness_client.?;

    const name = try uniqueTable(a, "zig_tbl");
    try freshTable(a, name, &.{ intCol(1, "id", true), floatCol(2, "amount") });

    try testing.expectEqual(@as(i64, 0), try c.count(a, name));
}

test "putAndCountRoundTrip" {
    try skipIfNoClient();
    const a = harness_alloc;
    const c = harness_client.?;

    const name = try uniqueTable(a, "zig_put");
    try freshTable(a, name, &.{ intCol(1, "id", true), floatCol(2, "amount") });

    _ = try c.put(a, name, &.{
        .{ .id = 1, .value = mongreldb.intValue(1) },
        .{ .id = 2, .value = mongreldb.floatValue(99.5) },
    }, "");
    _ = try c.put(a, name, &.{
        .{ .id = 1, .value = mongreldb.intValue(2) },
        .{ .id = 2, .value = mongreldb.floatValue(150.0) },
    }, "");

    try testing.expectEqual(@as(i64, 2), try c.count(a, name));
}

test "queryByPK" {
    try skipIfNoClient();
    const a = harness_alloc;
    const c = harness_client.?;

    const name = try uniqueTable(a, "zig_pk");
    try freshTable(a, name, &.{intCol(1, "id", true)});

    try mustPut(a, name, &.{.{ .id = 1, .value = mongreldb.intValue(42) }});
    try mustPut(a, name, &.{.{ .id = 1, .value = mongreldb.intValue(43) }});

    var pk_params = ObjectMap.init(a);
    try pk_params.put("value", mongreldb.intValue(42));

    var q = c.query(a, name);
    _ = try q.where("pk", pk_params);
    const rows = try q.execute();

    try testing.expectEqual(@as(usize, 1), rows.items.len);
}

test "queryRange" {
    try skipIfNoClient();
    const a = harness_alloc;
    const c = harness_client.?;

    const name = try uniqueTable(a, "zig_range");
    try freshTable(a, name, &.{ intCol(1, "id", true), intCol(2, "amount", false) });

    try mustPut(a, name, &.{ .{ .id = 1, .value = mongreldb.intValue(1) }, .{ .id = 2, .value = mongreldb.intValue(50) } });
    try mustPut(a, name, &.{ .{ .id = 1, .value = mongreldb.intValue(2) }, .{ .id = 2, .value = mongreldb.intValue(120) } });
    try mustPut(a, name, &.{ .{ .id = 1, .value = mongreldb.intValue(3) }, .{ .id = 2, .value = mongreldb.intValue(200) } });

    var range_params = ObjectMap.init(a);
    try range_params.put("column", mongreldb.intValue(2));
    try range_params.put("min", mongreldb.intValue(100));
    try range_params.put("max", mongreldb.intValue(150));

    var q = c.query(a, name);
    _ = try q.where("range", range_params);
    const rows = try q.execute();

    try testing.expect(rows.items.len >= 1);
    try testing.expect(!q.truncatedResult());
}

test "transactionPutCommit" {
    try skipIfNoClient();
    const a = harness_alloc;
    const c = harness_client.?;

    const name = try uniqueTable(a, "zig_txn");
    try freshTable(a, name, &.{intCol(1, "id", true)});

    var txn = c.begin(a);
    _ = try txn.put(name, &.{.{ .id = 1, .value = mongreldb.intValue(1) }}, false);
    _ = try txn.put(name, &.{.{ .id = 1, .value = mongreldb.intValue(2) }}, false);
    _ = try txn.put(name, &.{.{ .id = 1, .value = mongreldb.intValue(3) }}, false);
    try testing.expectEqual(@as(usize, 3), txn.count());

    const results = try txn.commit("");
    try testing.expectEqual(@as(usize, 3), results.items.len);

    try testing.expectEqual(@as(i64, 3), try c.count(a, name));
}

test "deleteByPK" {
    try skipIfNoClient();
    const a = harness_alloc;
    const c = harness_client.?;

    const name = try uniqueTable(a, "zig_del");
    try freshTable(a, name, &.{intCol(1, "id", true)});

    try mustPut(a, name, &.{.{ .id = 1, .value = mongreldb.intValue(5) }});
    try testing.expectEqual(@as(i64, 1), try c.count(a, name));

    try c.deleteByPk(a, name, mongreldb.intValue(5));
    try testing.expectEqual(@as(i64, 0), try c.count(a, name));
}

test "sql" {
    try skipIfNoClient();
    const a = harness_alloc;
    const c = harness_client.?;

    // SELECT 1 streams Arrow IPC rather than JSON, so we only assert it runs.
    _ = try c.sql(a, "SELECT 1");
}

test "schema" {
    try skipIfNoClient();
    const a = harness_alloc;
    const c = harness_client.?;

    const name = try uniqueTable(a, "zig_schema");
    try freshTable(a, name, &.{ intCol(1, "id", true), floatCol(2, "amount") });

    const schema = try c.schema(a);
    try testing.expect(schema.contains(name));
}

test "schemaFor" {
    try skipIfNoClient();
    const a = harness_alloc;
    const c = harness_client.?;

    const name = try uniqueTable(a, "zig_schema_for");
    try freshTable(a, name, &.{ intCol(1, "id", true), floatCol(2, "amount") });

    const desc = try c.schemaFor(a, name);
    const obj = switch (desc) {
        .object => |o| o,
        else => return error.Unexpected,
    };
    try testing.expect(obj.contains("schema_id"));
    const cols = obj.get("columns") orelse return error.Unexpected;
    try testing.expectEqual(@as(usize, 2), switch (cols) {
        .array => |arr| arr.items.len,
        else => return error.Unexpected,
    });
}

test "tableNamesListsCreatedTable" {
    try skipIfNoClient();
    const a = harness_alloc;
    const c = harness_client.?;

    const name = try uniqueTable(a, "zig_tables");
    try freshTable(a, name, &.{intCol(1, "id", true)});

    const names = try c.tableNames(a);
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return;
    }
    return error.TableMissing;
}

test "errorOnNonexistentTable" {
    try skipIfNoClient();
    const a = harness_alloc;
    const c = harness_client.?;

    const name = try uniqueTable(a, "zig_missing");
    const result = c.schemaFor(a, name);
    try testing.expectError(error.NotFound, result);
}

test "errorTypeCarriesStatus" {
    try skipIfNoClient();
    const a = harness_alloc;
    const c = harness_client.?;

    const name = try uniqueTable(a, "zig_missing2");
    // SchemaFor maps a 404 to error.NotFound, the typed result of the status.
    const result = c.schemaFor(a, name);
    try testing.expectError(error.NotFound, result);
}

// teardown runs after all tests via the test runner's exit handler. Zig's
// default test runner does not expose an explicit teardown hook, so we rely on
// the OS to reclaim the daemon process when the test process exits. The daemon
// writes to a throwaway data dir under /tmp, so there's nothing to clean up.

pub fn main() !void {
    defer teardownDaemon();
}
