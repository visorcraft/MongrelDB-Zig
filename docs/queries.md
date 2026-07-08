# Queries

The fluent `QueryBuilder` pushes conditions down to MongrelDB's native indexes
for sub-millisecond lookups — bitmap, learned-range, FM-index full text, HNSW
vector similarity, and more. Each condition type maps to one specialized
index; conditions are AND-ed together.

```zig
var range = mongreldb.ObjectMap.init(allocator);
try range.put("column", mongreldb.intValue(3));
try range.put("min", mongreldb.floatValue(100.0));
try range.put("max", mongreldb.floatValue(500.0));

var q = db.query(allocator, "orders");
_ = try q.where("range", range);
_ = try q.projection(&.{ 1, 2 });
_ = try q.limit(100);
const rows = try q.execute();
```

This guide covers every condition type, projection, limits and truncation,
combining conditions, and the friendly aliases the builder translates for you.

---

## The basics

Every query starts with `db.query(allocator, table)` and ends with `execute`:

| Method | Purpose |
|--------|---------|
| `where(type, params)` | Add a native condition. Multiple `where` calls are AND-ed. |
| `projection(columnIDs)` | Return only these column ids (omit for all columns). |
| `limit(n)` | Cap the number of rows. |
| `execute()` | Send and decode. Records the `truncated` flag. |
| `truncatedResult()` | Whether the last `execute` hit the limit. |

The request body produced by the builder matches the daemon's `/kit/query`
shape:

```json
{
  "table": "orders",
  "conditions": [{"range": {"column_id": 3, "lo": 100.0, "hi": 500.0}}],
  "projection": [1, 2],
  "limit": 100
}
```

## Condition types

`params` is an `ObjectMap`. Column references use the numeric **column id**,
never the column name.

### `pk` — exact primary-key match

The fastest lookup. `value` is the primary-key value.

```zig
var p = mongreldb.ObjectMap.init(allocator);
try p.put("value", mongreldb.intValue(42));
_ = try db.query(allocator, "orders").where("pk", p).execute();
```

### `range` — integer range (learned-range index)

Inclusive bounds. Omit `lo` or `hi` for an open range.

```zig
var r = mongreldb.ObjectMap.init(allocator);
try r.put("column", mongreldb.intValue(3));
try r.put("min", mongreldb.intValue(100));
try r.put("max", mongreldb.intValue(500));
_ = try db.query(allocator, "orders").where("range", r).execute();

// Open-ended: amount >= 100
var r2 = mongreldb.ObjectMap.init(allocator);
try r2.put("column", mongreldb.intValue(3));
try r2.put("min", mongreldb.intValue(100));
_ = try db.query(allocator, "orders").where("range", r2).execute();
```

### `range_f64` — float range with inclusive/exclusive control

Adds `lo_inclusive` / `hi_inclusive` flags (default inclusive).

```zig
var r = mongreldb.ObjectMap.init(allocator);
try r.put("column", mongreldb.intValue(3));
try r.put("min", mongreldb.floatValue(100.0));
try r.put("max", mongreldb.floatValue(500.0));
try r.put("min_inclusive", mongreldb.boolValue(true));
try r.put("max_inclusive", mongreldb.boolValue(false)); // (100.0, 500.0]
_ = try db.query(allocator, "orders").where("range_f64", r).execute();
```

### `bitmap_eq` — equality on a bitmap-indexed column

Best for low-cardinality columns (status, category, booleans).

```zig
var b = mongreldb.ObjectMap.init(allocator);
try b.put("column", mongreldb.intValue(2));
try b.put("value", mongreldb.stringValue("Alice"));
_ = try db.query(allocator, "orders").where("bitmap_eq", b).execute();
```

### `bitmap_in` — IN predicate on a bitmap-indexed column

Match any of a set of values.

```zig
var b = mongreldb.ObjectMap.init(allocator);
try b.put("column", mongreldb.intValue(2));
// values is an array of strings
var vals = mongreldb.Array.init(allocator);
try vals.append(.{ .string = "Alice" });
try vals.append(.{ .string = "Bob" });
try vals.append(.{ .string = "Carol" });
try b.put("values", .{ .array = vals });
_ = try db.query(allocator, "orders").where("bitmap_in", b).execute();
```

### `is_null` / `is_not_null` — null checks

```zig
var n = mongreldb.ObjectMap.init(allocator);
try n.put("column", mongreldb.intValue(3));
_ = try db.query(allocator, "orders").where("is_null", n).execute();
```

### `fm_contains` — full-text substring search (FM-index)

Substring match within a column. Use `pattern` (the server key) or the
friendly `value` alias — both translate to `pattern` on the wire for FTS
conditions.

```zig
var f = mongreldb.ObjectMap.init(allocator);
try f.put("column", mongreldb.intValue(2));
try f.put("pattern", mongreldb.stringValue("database performance"));
_ = try db.query(allocator, "documents").where("fm_contains", f).limit(10).execute();

// Friendly alias: "value" -> "pattern" for fm_contains only.
var f2 = mongreldb.ObjectMap.init(allocator);
try f2.put("column", mongreldb.intValue(2));
try f2.put("value", mongreldb.stringValue("database"));
_ = try db.query(allocator, "documents").where("fm_contains", f2).execute();
```

### `ann` — dense vector similarity (HNSW)

Approximate nearest-neighbors over a vector column. `k` is the result count.

```zig
var vec = mongreldb.Array.init(allocator);
try vec.append(.{ .float = 0.1 });
try vec.append(.{ .float = 0.2 });
try vec.append(.{ .float = 0.3 });
try vec.append(.{ .float = 0.4 });

var a = mongreldb.ObjectMap.init(allocator);
try a.put("column", mongreldb.intValue(2));
try a.put("query", .{ .array = vec });
try a.put("k", mongreldb.intValue(10));
_ = try db.query(allocator, "embeddings").where("ann", a).execute();
```

### `sparse_match` and `min_hash_similar`

`sparse_match` covers sparse/bag-of-words vectors; `min_hash_similar` does
near-duplicate detection via MinHash signatures. Both follow the same
`column` + `query` + `k` shape as `ann`.

## Projection (column selection)

`projection(&.{1, 2, ...})` restricts the columns in each returned row. Omit
the call for all columns. Projecting to only the columns you need cuts
bandwidth and decode cost.

```zig
var r = mongreldb.ObjectMap.init(allocator);
try r.put("column", mongreldb.intValue(3));
try r.put("min", mongreldb.intValue(100));
_ = try db.query(allocator, "orders").where("range", r).projection(&.{ 1, 2 }).execute();
```

Returned rows are JSON objects keyed by the column id as a string. Access
accordingly:

```zig
const rows = try db.query(allocator, "orders").projection(&.{ 1, 2 }).execute();
for (rows.items) |row| {
    const customer = row.object.get("2"); // column id 2 as a string key
    std.debug.print("{any}\n", .{customer});
}
```

## Limit and the truncated flag

`limit(n)` caps the result. When the server has more matches than the limit
allows, it returns the first `n` and sets `truncated: true`. Read it with
`truncatedResult()` **after** `execute`.

```zig
var q = db.query(allocator, "orders");
_ = try q.where("range", r);
_ = try q.limit(100);
const rows = try q.execute();
if (q.truncatedResult()) {
    // 100 rows came back but more exist on the server. Either raise the
    // limit, page with a range predicate on the PK, or accept the cap.
    std.debug.print("result capped at {d}; more rows available\n", .{rows.items.len});
}
```

`truncatedResult()` returns `false` until `execute` has run, so build a fresh
query for each independent lookup.

## Multiple AND conditions

Chain `where` calls. Every condition must match; the server intersects the
index results.

```zig
var b = mongreldb.ObjectMap.init(allocator);
try b.put("column", mongreldb.intValue(2));
try b.put("value", mongreldb.stringValue("Alice"));

var r = mongreldb.ObjectMap.init(allocator);
try r.put("column", mongreldb.intValue(3));
try r.put("min", mongreldb.intValue(100));
try r.put("max", mongreldb.intValue(500));

var q = db.query(allocator, "orders");
_ = try q.where("bitmap_eq", b);
_ = try q.where("range", r);
_ = try q.projection(&.{ 1, 3 });
_ = try q.limit(50);
_ = try q.execute();
```

Because each `where` targets a different specialized index, the engine can
pick the most selective one to drive the lookup and intersect the rest.

## Friendly alias translation

The builder accepts readable parameter names and translates them to the
server's canonical on-wire keys. Both spellings work, so use whichever is
clearer in context.

| You write | Sent as | Applies to |
|-----------|---------|------------|
| `column` | `column_id` | all condition types |
| `min` | `lo` | `range`, `range_f64` |
| `max` | `hi` | `range`, `range_f64` |
| `min_inclusive` | `lo_inclusive` | `range_f64` |
| `max_inclusive` | `hi_inclusive` | `range_f64` |
| `value` | `pattern` | `fm_contains`, `fm_contains_all` only |

The `value` → `pattern` alias applies **only** to FTS conditions, because
`pk` and `bitmap_eq` use `value` as their canonical key. For those, write
`value` directly.

## Putting it together

A realistic combined lookup — bitmap equality + range + projection + limit +
truncation check:

```zig
fn topSpenders(db: *mongreldb.Client, customer: []const u8) !mongreldb.Array {
    var b = mongreldb.ObjectMap.init(allocator);
    try b.put("column", mongreldb.intValue(2));
    try b.put("value", mongreldb.stringValue(customer));

    var r = mongreldb.ObjectMap.init(allocator);
    try r.put("column", mongreldb.intValue(3));
    try r.put("min", mongreldb.intValue(100));

    var q = db.query(allocator, "orders");
    _ = try q.where("bitmap_eq", b);
    _ = try q.where("range", r);
    _ = try q.projection(&.{ 1, 3 });
    _ = try q.limit(50);
    const rows = try q.execute();
    if (q.truncatedResult()) {
        std.debug.print("warning: topSpenders result capped at 50\n", .{});
    }
    return rows;
}
```

For arbitrary predicates, joins, and aggregations that the native indexes do
not cover, use SQL instead — see [sql.md](sql.md).
