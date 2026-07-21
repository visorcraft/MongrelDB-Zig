<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB Zig Client</h1>

<p align="center">
  <b>Pure Zig client for MongrelDB - embedded+server database with SQL, vector search, full-text search, and AI-native retrieval.</b>
  <br />
  No external dependencies - built on the standard library <code>std.http.Client</code>. The API mirrors the MongrelDB PHP and Go clients.
</p>

<p align="center">
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
  <a href="https://github.com/visorcraft/MongrelDB-Zig/actions/workflows/ci.yml"><img src="https://github.com/visorcraft/MongrelDB-Zig/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.13.0-orange.svg" alt="Zig" /></a>
</p>

## Package

| Surface | Module | Install |
|---|---|---|
| Zig client | `mongreldb` | `zig fetch` / `build.zig.zon` dep |

## Requirements

- **Zig 0.13.0 or newer**
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `put` (with optional idempotency keys for safe retries) and `deleteByPk`, plus batched `put`/`delete`/`deleteByPk` and `upsert`-style insert-or-update via `sql` when needed.
- **Fluent query builder** that pushes conditions down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality/IN, learned-range, null checks, FM-index full-text search, HNSW vector similarity (`ann`), and sparse vector match. Friendly aliases (`column` → `column_id`, `min`/`max` → `lo`/`hi`) are translated to the server's on-wire keys.
- **Idempotent batch transactions** - operations staged locally and committed atomically, with the engine enforcing unique, foreign-key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint: recursive CTEs, window functions, `CREATE TABLE AS SELECT`, materialized views, and multi-statement execution.
- **Schema management**: typed table creation, full schema catalog, and per-table descriptors.
- **User/role/credentials management** via SQL: Argon2id-hashed catalog users, roles, and `GRANT`/`REVOKE` table-level permissions, all executed through `sql`.
- **Maintenance**: compaction (all tables or per-table) is available via the low-level `doPost` helper.
- **Typed errors**: `error.Auth` (401/403), `error.NotFound` (404), `error.Conflict` (409), `error.Query` (everything else non-2xx), `error.Http` (transport), and `error.Json` (malformed response) - a single typed error set you match with Zig's `catch`/`|err| switch (err)`.

## Examples

Task-focused, commented guides live in [`docs/`](docs):

- [Quickstart](docs/quickstart.md) - install, start the daemon, write and run a complete program.
- [Transactions](docs/transactions.md) - batch commits, idempotency keys, constraint handling.
- [Queries](docs/queries.md) - every native condition type and the index it pushes down to.
- [SQL](docs/sql.md) - recursive CTEs, window functions, advanced SQL.
- [Authentication](docs/auth.md) - Bearer token, HTTP Basic, and open modes.
- [Errors](docs/errors.md) - the typed error set and recovery patterns.

## Quick Example

```zig
const std = @import("std");
const mongreldb = @import("mongreldb");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Connect to a running mongreldb-server daemon.
    var db = mongreldb.Client.init(allocator, "http://127.0.0.1:8453", .{});
    defer db.deinit();

    // Create a table. Column ids are stable on-wire identifiers.
    _ = try db.createTable(allocator, "orders", &.{
        .{ .id = 1, .name = "id", .ty = "int64", .primary_key = true },
        .{ .id = 2, .name = "customer", .ty = "varchar" },
        .{ .id = 3, .name = "amount", .ty = "float64" },
        // Enum column: only the four listed values are accepted.
        .{ .id = 4, .name = "status", .ty = "enum",
           .enum_variants = &.{ "pending", "shipped", "delivered", "cancelled" } },
        // Enum column with a default applied when the cell is omitted.
        .{ .id = 5, .name = "currency", .ty = "enum",
           .enum_variants = &.{ "USD", "EUR", "GBP" },
           .default_value = "USD" },
    });

    // Insert rows (cells pair column id -> value).
    _ = try db.put(allocator, "orders", &.{
        .{ .id = 1, .value = mongreldb.intValue(1) },
        .{ .id = 2, .value = mongreldb.stringValue("Alice") },
        .{ .id = 3, .value = mongreldb.floatValue(99.50) },
        .{ .id = 4, .value = mongreldb.stringValue("pending") },
        .{ .id = 5, .value = mongreldb.stringValue("USD") },
    }, "");

    // Query with a native index condition (learned-range index).
    var range = mongreldb.ObjectMap.init(allocator);
    try range.put("column", mongreldb.intValue(3));
    try range.put("min", mongreldb.floatValue(100.0));

    var q = db.query(allocator, "orders");
    _ = try q.where("range", range);
    _ = try q.projection(&.{ 1, 2 });
    _ = try q.limit(100);
    const rows = try q.execute();
    std.debug.print("rows: {d}\n", .{rows.items.len});

    const n = try db.count(allocator, "orders");
    std.debug.print("count: {d}\n", .{n}); // 1

    // Run SQL.
    _ = try db.sql(allocator, "UPDATE orders SET amount = 200.0 WHERE customer = 'Alice'");
}
```

## Authentication

```zig
// Bearer token (--auth-token mode)
var db = mongreldb.Client.init(allocator, "http://127.0.0.1:8453", .{
    .token = "my-secret-token",
});
defer db.deinit();

// HTTP Basic (--auth-users mode)
var db = mongreldb.Client.init(allocator, "http://127.0.0.1:8453", .{
    .username = "admin",
    .password = "s3cret",
});
defer db.deinit();
```

A Bearer token takes precedence over Basic credentials when both are supplied.

## Batch transactions

Operations are staged locally and committed atomically. The engine enforces
unique, foreign-key, and check constraints at commit time.

```zig
var txn = db.begin(allocator);
_ = try txn.put("orders", &.{.{ .id = 1, .value = mongreldb.intValue(10) }}, false);
_ = try txn.put("orders", &.{.{ .id = 1, .value = mongreldb.intValue(11) }}, false);
_ = try txn.deleteByPk("orders", mongreldb.intValue(2));

// atomic - all or nothing
const results = txn.commit("") catch |err| switch (err) {
    // A constraint violation rolls back every op.
    error.Conflict => {
        try txn.rollback(); // discard locally as well
        return;
    },
    else => return err,
};
_ = results;

// Idempotent commit - safe to retry; the daemon returns the original response.
var txn2 = db.begin(allocator);
_ = try txn2.put("orders", &.{.{ .id = 1, .value = mongreldb.intValue(20) }}, false);
_ = try txn2.commit("order-20-create");
```

## Native query builder

Conditions push down to the engine's specialized indexes. The builder accepts
friendly aliases that are translated to the server's on-wire keys: `column`
(→ `column_id`), `min`/`max` (→ `lo`/`hi`). The canonical keys are also
accepted directly.

```zig
// Bitmap equality (low-cardinality columns).
var b = mongreldb.ObjectMap.init(allocator);
try b.put("column", mongreldb.intValue(2));
try b.put("value", mongreldb.stringValue("Alice"));
_ = try db.query(allocator, "orders").where("bitmap_eq", b).execute();

// Range query (learned-range index).
var r = mongreldb.ObjectMap.init(allocator);
try r.put("column", mongreldb.intValue(3));
try r.put("min", mongreldb.floatValue(50.0));
try r.put("max", mongreldb.floatValue(150.0));
_ = try db.query(allocator, "orders").where("range", r).limit(100).execute();

// Check whether a result was capped by the limit.
var q = db.query(allocator, "orders");
_ = try q.where("range", r);
_ = try q.limit(100);
const rows = try q.execute();
if (q.truncatedResult()) {
    // result set hit the limit; more matches exist on the server
}
_ = rows;
```

## SQL

```zig
_ = try db.sql(allocator, "INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)");
_ = try db.sql(allocator, "CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500");

// Recursive CTEs and window functions
_ = try db.sql(allocator,
    \\WITH RECURSIVE r(n) AS (
    \\  SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10
    \\) SELECT n FROM r
);
```

The `/sql` endpoint streams Arrow IPC for SELECTs. `sql` therefore returns
decoded rows only when the body is JSON; for IPC-streaming or non-row
statements it returns an empty slice and no error.

## ANN index backends

The engine's `ann` index is swappable across three backends - `hnsw` (the default), `diskann`, and `ivf` - selected with the `algorithm` option. Quantization is independently configurable: `dense`, `binary_sign`, or `product` (product quantization, with `num_subvectors`, `bits_per_subvector`, `pq_training_samples`, `pq_seed`, and `pq_rerank_factor`). These are ordinary DDL strings run through `sql`, so no client changes are needed.

```zig
// DiskANN (in-memory Vamana graph)
_ = try db.sql(allocator, "CREATE INDEX orders_emb_diskann ON orders USING ann (embedding) WITH (algorithm = 'diskann', quantization = 'dense', diskann_l = 50, diskann_r = 64, beam_width = 8)");

// IVF with dense vectors (clustered)
_ = try db.sql(allocator, "CREATE INDEX orders_emb_ivf ON orders USING ann (embedding) WITH (algorithm = 'ivf', quantization = 'dense', nlist = 1024, nprobe = 16)");

// HNSW with product quantization (recall-tuned)
_ = try db.sql(allocator, "CREATE INDEX orders_emb_hnsw_pq ON orders USING ann (embedding) WITH (algorithm = 'hnsw', quantization = 'product', m = 16, ef_construction = 200, ef_search = 50, num_subvectors = 32, pq_training_samples = 50000, pq_rerank_factor = 8)");
```


## Constrained columns

`Column` carries two optional constraint-style fields that are emitted on the
wire only when set, so existing call sites that omit them keep producing an
identical payload.

```zig
// Enum: only the listed values are accepted. The engine rejects writes
// outside the set with a 409 Conflict at commit time.
.{ .id = 4, .name = "status", .ty = "enum",
   .enum_variants = &.{ "pending", "shipped", "delivered", "cancelled" } },

// String default. Use default_scalar for typed static values, or default_expr
// for dynamic "now"/"uuid" values. Expression wins, then scalar, then string.
// `ty`. Omit the cell on a `put` and the engine fills it in.
.{ .id = 5, .name = "currency", .ty = "enum",
   .enum_variants = &.{ "USD", "EUR", "GBP" },
   .default_value = "USD" },
```

Both fields are `null` by default. An empty `enum_variants` slice is also
omitted, so a column with no constraint is byte-identical to a pre-T5.1
schema. Use `createTableWithConstraints` when the table also needs
`constraints.checks`, unique constraints, or foreign keys. See
`examples/constrained_columns.zig` for a runnable walkthrough.

## User & role management

User, role, and permission management is performed through SQL against the
daemon's catalog. Passwords are Argon2id-hashed server-side.

```zig
_ = try db.sql(allocator, "CREATE USER admin WITH PASSWORD 's3cret-pw'");
_ = try db.sql(allocator, "ALTER USER admin SET ADMIN TRUE");

_ = try db.sql(allocator, "CREATE ROLE analyst");
_ = try db.sql(allocator, "GRANT select ON orders TO analyst"); // table-level permission
_ = try db.sql(allocator, "GRANT analyst TO alice");

_ = try db.sql(allocator, "SELECT username FROM catalog.users"); // list users
_ = try db.sql(allocator, "SELECT name FROM catalog.roles");     // list roles
```

## Error handling

Every non-2xx response is mapped to a typed error. Match on the error value
with a `switch`.

```zig
const result = db.schemaFor(allocator, "missing_table");
switch (result) {
    .object => |_| { /* ... */ },
    else => |_| {},
}
// or, for an error-aware call site:
const desc = db.schemaFor(allocator, "missing_table") catch |err| switch (err) {
    error.NotFound => std.debug.print("not found\n", .{}),
    error.Conflict => std.debug.print("constraint violation\n", .{}),
    error.Auth => std.debug.print("not authorized\n", .{}),
    error.Query => std.debug.print("query/server error\n", .{}),
    else => return err,
};
_ = desc;
```

| HTTP status | Error |
|-------------|-------|
| 401, 403 | `error.Auth` |
| 404 | `error.NotFound` |
| 409 | `error.Conflict` |
| other non-2xx | `error.Query` |
| transport failure | `error.Http` |
| malformed JSON | `error.Json` |

## API reference

### `Client`

| Method | Description |
|--------|-------------|
| `init(allocator, url, options) Client` | Construct a client (url defaults to `http://127.0.0.1:8453`) |
| `deinit() void` | Release the HTTP connection pool |
| `health(allocator) bool` | Check daemon health |
| `tableNames(allocator) [][]const u8` | List table names |
| `createTable(allocator, name, columns) i64` | Create a table; returns the table id |
| `createTableWithConstraints(allocator, name, columns, constraints) i64` | Create a table with table constraints |
| `createTableWithSchema(allocator, name, columns, constraints, indexes) i64` | Create a table with all six index kinds and options |
| `dropTable(allocator, name) void` | Drop a table |
| `count(allocator, table) i64` | Row count |
| `put(allocator, table, cells, key) Value` | Insert a row |
| `deleteByPk(allocator, table, pk) void` | Delete by primary key |
| `commitTxn(allocator, ops, key) Array` | Commit a batch of operations (used by `Transaction`) |
| `query(allocator, table) QueryBuilder` | Start a native query |
| `begin(allocator) Transaction` | Start a batch |
| `sql(allocator, sql) []Value` | Execute SQL |
| `schema(allocator) ObjectMap` | Full schema catalog |
| `schemaFor(allocator, table) Value` | Single-table descriptor |
| `historyRetention(allocator) HistoryRetention` | Current retention window and earliest retained epoch |
| `historyRetentionEpochs(allocator) u64` | Current durable MVCC window size |
| `earliestRetainedEpoch(allocator) u64` | Oldest epoch still readable via `AS OF EPOCH` |
| `setHistoryRetentionEpochs(allocator, epochs) HistoryRetention` | Set the durable MVCC window |
| `lastEpoch` (field) | Commit epoch of the most recent `/kit/txn` |
| `doGet(allocator, path) Value` | Low-level GET returning a decoded JSON value |
| `doPost(allocator, path, payload) Value` | Low-level POST with a JSON value body |

### `QueryBuilder`

| Method | Description |
|--------|-------------|
| `where(type, params) *QueryBuilder` | Add a native condition (AND-ed) |
| `projection(columnIDs) *QueryBuilder` | Set column projection |
| `limit(rowLimit) *QueryBuilder` | Set row limit |
| `offset(rowOffset) *QueryBuilder` | Skip matching rows before the limit |
| `execute() Array` | Run the query; returns the rows |
| `truncatedResult() bool` | Whether the last `execute` result hit the limit |

### `Transaction`

| Method | Description |
|--------|-------------|
| `put(table, cells, returning) *Transaction` | Stage an insert |
| `delete(table, rowID) *Transaction` | Stage a delete by row id |
| `deleteByPk(table, pk) *Transaction` | Stage a delete by primary key |
| `count() usize` | Number of staged operations |
| `commit(idempotencyKey) Array` | Commit atomically |
| `rollback() void` | Discard all operations |

## Building and testing

The test suite is a live integration suite: it boots a real `mongreldb-server`
daemon and exercises the full client surface against it. It skips
automatically when no daemon is available.

```sh
# Build the module.
zig build

# Run the tests. The harness boots mongreldb-server itself if it can find the
# binary (in this order):
#   1. the MONGRELDB_SERVER env var
#   2. ./bin/mongreldb-server
#   3. mongreldb-server on PATH
# Or point it at an already-running daemon with MONGRELDB_URL.
MONGRELDB_SERVER=./bin/mongreldb-server zig build test
```

Fetch a prebuilt server binary from the [MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.63.0/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

### Using the client in your project

Add the package to your `build.zig.zon`:

```zig
.dependencies = .{
    .mongreldb = .{
        .url = "https://github.com/visorcraft/MongrelDB-Zig/archive/refs/heads/master.tar.gz",
        // .hash = "...",  // zig fetch will print the required hash
    },
},
```

Then in your `build.zig`:

```zig
const mongreldb_dep = b.dependency("mongreldb", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("mongreldb", mongreldb_dep.module("mongreldb"));
```

## Contributing

Contributions are welcome. Please:

1. Open an issue first for non-trivial changes.
2. Add focused tests near your change - the suite must stay green.
3. Keep the client dependency-free (standard library only).

## History retention

Use `historyRetention`, `setHistoryRetentionEpochs`, and `lastEpoch` with
MongrelDB 0.48.0+. The retention window controls how far back `AS OF EPOCH`
time-travel queries can read; increasing it cannot bring back history that has
already been pruned.

```zig
// Inspect the current durable MVCC window.
const ret = try db.historyRetention(allocator);
std.debug.print("window: {d}\n", .{ret.history_retention_epochs});
std.debug.print("earliest: {d}\n", .{ret.earliest_retained_epoch});

// Widen the window. The response contains the updated values.
const updated = try db.setHistoryRetentionEpochs(allocator, 10000);
std.debug.print("window: {d}\n", .{updated.history_retention_epochs});

// After a Kit transaction write, lastEpoch holds the commit epoch.
_ = try db.put(allocator, "orders", &.{.{ .id = 1, .value = mongreldb.intValue(1) }}, "");
const stmt = try std.fmt.allocPrint(allocator, "SELECT id FROM orders AS OF EPOCH {d}", .{db.lastEpoch});
const rows = try db.sql(allocator, stmt);
_ = rows;
```

## License

Dual-licensed under the **MIT License** or the **Apache License, Version 2.0**,
at your option. See [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE) for the full text.

`SPDX-License-Identifier: MIT OR Apache-2.0`
