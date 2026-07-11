# Quickstart

Zero to a running MongrelDB Zig program in fifteen minutes. This guide assumes
a fresh machine and walks through installing the prerequisites, starting the
daemon, and writing, running, and understanding a complete program.

---

## 1. Prerequisites

You need two things installed: the Zig toolchain and a `mongreldb-server`
daemon.

### Install Zig 0.13.0 or newer

MongrelDB Zig is standard-library only, so any recent Zig works. Verify it:

```sh
zig version
# 0.13.0 ...
```

If you do not have it, install from <https://ziglang.org/download/> or your
package manager (e.g. `pacman -S zig`, `brew install zig`).

### Install mongreldb-server

Fetch a prebuilt server binary from the
[MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.48.0/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

Verify it runs:

```sh
./bin/mongreldb-server --version
```

## 2. Start the daemon

By default `mongreldb-server` listens on `http://127.0.0.1:8453` and stores
data in the current working directory.

```sh
mkdir -p /tmp/mdb-data && cd /tmp/mdb-data
/path/to/mongreldb-server
```

In another terminal, sanity-check it:

```sh
curl http://127.0.0.1:8453/health
# ok
```

Leave the daemon running for the rest of this guide.

## 3. Create a project and pull in the client

Add the package to your `build.zig.zon`:

```zig
.dependencies = .{
    .mongreldb = .{
        .url = "https://github.com/visorcraft/MongrelDB-Zig/archive/refs/heads/master.tar.gz",
        // .hash = "...",  // zig fetch will print the required hash
    },
},
```

Then expose the module in your `build.zig`:

```zig
const mongreldb_dep = b.dependency("mongreldb", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("mongreldb", mongreldb_dep.module("mongreldb"));
```

Resolve the dependency with `zig fetch`.

## 4. Write your first program

Create `src/main.zig`:

```zig
const std = @import("std");
const mongreldb = @import("mongreldb");

pub fn main() !void {
    // Use an arena so every allocation from the client is freed in one go.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 1. Connect to the daemon. Empty URL falls back to http://127.0.0.1:8453.
    var db = mongreldb.Client.init(allocator, "http://127.0.0.1:8453", .{});
    defer db.deinit();

    // 2. Health check before doing anything else.
    const ok = db.health(allocator) catch false;
    if (!ok) return error.DaemonUnreachable;

    // 3. Create a table. Each column has a stable numeric id, a name, a type,
    //    and optional constraint-style fields (`enum_variants`, `default_value`).
    //    The primary_key column is the row identity.
    const tid = try db.createTable(allocator, "orders", &.{
        .{ .id = 1, .name = "id", .ty = "int64", .primary_key = true },
        .{ .id = 2, .name = "customer", .ty = "varchar" },
        .{ .id = 3, .name = "amount", .ty = "float64" },
        // Enum column: only the four listed values are accepted.
        .{ .id = 4, .name = "status", .ty = "varchar",
           .enum_variants = &.{ "pending", "shipped", "delivered", "cancelled" } },
        // Enum column with a default applied when the cell is omitted.
        .{ .id = 5, .name = "currency", .ty = "varchar",
           .enum_variants = &.{ "USD", "EUR", "GBP" },
           .default_value = "USD" },
    });
    std.debug.print("created table id: {d}\n", .{tid});

    // 4. Insert rows. Cells pair column id -> value. The `status` cell is
    //    required because it has no default; `currency` is supplied here but
    //    can be omitted on subsequent inserts and the engine will fill it in.
    _ = try db.put(allocator, "orders", &.{
        .{ .id = 1, .value = mongreldb.intValue(1) },
        .{ .id = 2, .value = mongreldb.stringValue("Alice") },
        .{ .id = 3, .value = mongreldb.floatValue(99.5) },
        .{ .id = 4, .value = mongreldb.stringValue("pending") },
        .{ .id = 5, .value = mongreldb.stringValue("USD") },
    }, "");
    _ = try db.put(allocator, "orders", &.{
        .{ .id = 1, .value = mongreldb.intValue(2) },
        .{ .id = 2, .value = mongreldb.stringValue("Bob") },
        .{ .id = 3, .value = mongreldb.floatValue(150.0) },
        .{ .id = 4, .value = mongreldb.stringValue("shipped") },
    }, "");

    // 5. Query with a native index condition. The range index serves this in
    //    sub-millisecond. Projection selects only column ids 1 and 2.
    var range = mongreldb.ObjectMap.init(allocator);
    try range.put("column", mongreldb.intValue(3));
    try range.put("min", mongreldb.floatValue(100.0));

    var q = db.query(allocator, "orders");
    _ = try q.where("range", range);
    _ = try q.projection(&.{ 1, 2 });
    _ = try q.limit(100);
    const rows = try q.execute();
    std.debug.print("rows: {d}\n", .{rows.items.len});

    // 6. Count the rows.
    const n = try db.count(allocator, "orders");
    std.debug.print("total rows: {d}\n", .{n});
}
```

Build and run it:

```sh
zig build run
```

You should see:

```
created table id: 1
rows: 1
total rows: 2
```

## 5. What each part does

| Code | What it does |
|------|--------------|
| `mongreldb.Client.init(allocator, url, .{})` | Builds an HTTP client targeting one daemon. Backed by the std HTTP client. |
| `db.health(allocator)` | GET `/health`; returns `true` when the daemon answers. |
| `db.createTable(allocator, name, columns)` | POST `/kit/create_table`. Column `id`s are the on-wire identifiers; use them everywhere else. `Column.enum_variants` and `Column.default_value` are optional and emitted only when set. |
| `db.put(allocator, table, cells, key)` | Single-op transaction: POST `/kit/txn` with one `put` op. `cells` is flattened to `[col_id, val, ...]`. |
| `db.query(allocator, table).where(...)` | Builds a `/kit/query` body. `where` pushes a condition down to a native index. |
| `.projection(&.{1, 2})` | Server returns only those column ids, saving bandwidth. |
| `.limit(100)` | Caps the result; check `q.truncatedResult()` afterward to detect overflow. |
| `q.execute()` | Sends the query and decodes the `rows` array. |
| `db.count(allocator, table)` | GET `/tables/{name}/count`. |

## 6. Constrained columns

`Column` accepts two optional constraint-style fields that are forwarded to the
daemon verbatim. They are omitted from the JSON body when null, so existing
schemas that don't set them produce an identical payload.

| Field | Type | Effect |
|-------|------|--------|
| `enum_variants` | `?[]const []const u8` | Restrict the column to one of the listed string values. The engine rejects writes outside the set with `error.Conflict`. |
| `default_value` | `?[]const u8` | String default applied when the cell is omitted on a `put`. |
| `default_scalar` | `?std.json.Value` | Non-string JSON scalar default. Caller must supply the scalar type expected by the column. Sent as `default_value` and takes precedence over the string field. |
| `default_expr` | `?[]const u8` | Dynamic `now` or `uuid`. Takes precedence over both static fields. |

Both fields compose. A column can be a plain string, an enum-only string, a
string with a default, or an enum with a default:

```zig
// Plain string - no constraints, no extra keys on the wire.
.{ .id = 2, .name = "customer", .ty = "varchar" },

// Enum only - writes outside the set are rejected at commit time.
.{ .id = 4, .name = "status", .ty = "varchar",
   .enum_variants = &.{ "pending", "shipped", "delivered", "cancelled" } },

// Enum with a default - the engine fills in "USD" when the cell is omitted.
.{ .id = 5, .name = "currency", .ty = "varchar",
   .enum_variants = &.{ "USD", "EUR", "GBP" },
   .default_value = "USD" },
```

An empty `enum_variants` slice is also omitted, so `null` and `&[_][]const u8{}`
produce identical wire shapes. See `examples/constrained_columns.zig` for a
runnable walkthrough that exercises both fields end-to-end.

## 7. Common pitfalls

**Using the column name instead of the column id.** Every on-wire API uses the
numeric `id` from `createTable`, never the `name`. The query builder's `column`
alias maps to the server's `column_id` - pass the integer id, not the string
name:

```zig
// Wrong:
try range.put("column", mongreldb.stringValue("amount"));
// Right:
try range.put("column", mongreldb.intValue(3));
```

**Leaking allocations.** The client allocates request bodies and parsed
responses from the `allocator` you pass. Use an `ArenaAllocator` and reset/deinit
it when you are done with the results.

**Treating a single `put` as non-transactional.** `put` is a one-op
transaction. A unique constraint violation surfaces as `error.Conflict` (HTTP
409), not as a silent no-op.

**Calling `commit` twice on the same `Transaction`.** The second call returns
`error.AlreadyCommitted`. Create a fresh `db.begin(allocator)` for each logical
unit of work.

**Expecting `sql` to always return rows.** The `/sql` endpoint streams Arrow
IPC for `SELECT` in most builds, so `sql` returns an empty slice (not an error)
for result sets. Use it for DDL/DML and statements whose success is the
signal; use the native query builder for typed row retrieval.

**Pointing at a daemon that requires auth.** If the daemon was started with
`--auth-token` or `--auth-users`, every call returns `error.Auth` unless you
set `token` or `username`/`password` in `Options`. See [auth.md](auth.md).

## Next steps

- [transactions.md](transactions.md) - atomic batches, idempotency, retries
- [queries.md](queries.md) - every native index condition
- [sql.md](sql.md) - recursive CTEs, window functions, `CREATE TABLE AS SELECT`
- [auth.md](auth.md) - bearer tokens, basic auth, user/role management
- [errors.md](errors.md) - the full typed error set and recovery patterns
