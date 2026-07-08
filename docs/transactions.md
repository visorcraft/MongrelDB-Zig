# Transactions

MongrelDB commits every write through a single atomic transaction endpoint
(`POST /kit/txn`). This guide covers the two ways to use it — a one-shot
single op, and a staged batch — plus idempotency keys for safe retries, typed
constraint-violation handling, and rollback.

The engine enforces `UNIQUE`, foreign-key, check, and trigger constraints at
**commit time**. A violation aborts the entire batch: no op in the batch
becomes visible.

---

## Single puts vs. batch transactions

### Single op: `Client.put`

`Client.put` is a convenience wrapper that sends a one-op transaction. Use it
when a write is independent and you do not need atomicity across multiple
rows.

```zig
// One row, one atomic op. The empty string means "no idempotency key".
const res = try db.put(allocator, "orders", &.{
    .{ .id = 1, .value = mongreldb.intValue(1) },
    .{ .id = 2, .value = mongreldb.stringValue("Alice") },
    .{ .id = 3, .value = mongreldb.floatValue(99.5) },
}, "");
```

`Client.deleteByPk` is the same shape: a single-op transaction. (`delete` by
row id is available only on a staged `Transaction`.)

### Batch: `Client.begin` + `Transaction`

When several writes must succeed or fail together, stage them on a
`Transaction` and commit once. All ops go to the server in a single HTTP
request and commit atomically.

```zig
var txn = db.begin(allocator);
_ = try txn.put("orders", &.{
    .{ .id = 1, .value = mongreldb.intValue(10) },
    .{ .id = 2, .value = mongreldb.stringValue("Dave") },
}, false);
_ = try txn.put("orders", &.{
    .{ .id = 1, .value = mongreldb.intValue(11) },
    .{ .id = 2, .value = mongreldb.stringValue("Eve") },
}, false);
_ = try txn.deleteByPk("orders", mongreldb.intValue(2));

const results = try txn.commit("");
std.debug.print("committed {d} ops\n", .{results.items.len});
```

The third argument to `Transaction.put` is `returning`. Set it to `true` to
have the daemon echo the written row back in the result.

```zig
var txn = db.begin(allocator);
_ = try txn.put("orders", &.{
    .{ .id = 1, .value = mongreldb.intValue(42) },
}, true /* returning */);
const res = try txn.commit("");
std.debug.print("server echoed: {any}\n", .{res.items[0]});
```

`Transaction.delete(table, rowId)` stages a delete by the internal row id;
`Transaction.deleteByPk(table, pk)` stages a delete by primary-key value.

## Idempotency keys for safe retries

Networks drop requests and daemons crash after committing but before replying.
An idempotency key makes a commit safe to retry: the daemon remembers the key
and replays the **original** result on a duplicate commit, even across
restarts.

Pass the key as the argument to `commit` (or to `Client.put`):

```zig
// A handler that must not double-charge, even if the client retries or the
// connection drops after the daemon committed.
fn charge(db: *mongreldb.Client, order_id: i64) !void {
    var txn = db.begin(allocator);
    _ = try txn.put("charges", &.{
        .{ .id = 1, .value = mongreldb.intValue(order_id) },
        .{ .id = 2, .value = mongreldb.floatValue(199.0) },
    }, false);

    // Use a stable, business-meaningful key derived from the request. On a
    // retry with the same key the daemon returns the first commit's result
    // instead of inserting a second row.
    const key = try std.fmt.allocPrint(allocator, "charge:{d}", .{order_id});
    _ = try txn.commit(key);
}
```

Rules for keys:

- Any non-empty string works. Prefer content-derived, globally-unique values
  (e.g. `"charge:42"`).
- The empty string disables idempotency — a retry will commit again.
- The key scopes the **entire batch**, not individual ops. Reuse the exact
  same ops and key together when retrying.

A safe retry loop:

```zig
fn commitWithRetry(db: *mongreldb.Client, build: anytype, key: []const u8) !void {
    var attempt: usize = 0;
    while (attempt < 3) : (attempt += 1) {
        // Build a fresh Transaction inside the loop so retries always start clean.
        var txn = build(db);
        txn.commit(key) catch |err| switch (err) {
            error.Conflict, error.Auth => return err, // not transient
            else => {
                // error.Query / error.Http — the idempotency key makes it safe
                // to retry.
                if (attempt == 2) return err;
                std.time.sleep(@as(u64, 1 << attempt) * std.time.ns_per_s);
                continue;
            },
        };
        return;
    }
}
```

Build the transaction inside the retry loop so a failed `commit` (which flips
the `Transaction` to "committed") is replaced by a fresh one carrying the same
ops and the same key.

## Handling constraint violations

Constraint violations arrive as HTTP 409, mapped to `error.Conflict`. Note that
`mapStatus` does not decode the server's structured error envelope, so use the
native query builder to re-check state if you need the offending op index:

```zig
var txn = db.begin(allocator);
_ = try txn.put("orders", &.{.{ .id = 1, .value = mongreldb.intValue(1) }}, false); // duplicate PK

txn.commit("") catch |err| switch (err) {
    error.Conflict => std.debug.print("constraint violation (batch rolled back)\n", .{}),
    else => return err,
};
```

The engine already discarded the entire batch — there is nothing to undo
server-side.

## Rollback after failure

There are two notions of "rollback":

1. **Server-side.** When `commit` returns `error.Conflict`, the engine has
   already discarded the entire batch. Nothing was written; there is no server
   rollback to perform.
2. **Client-side.** `Transaction.rollback()` clears the locally staged ops.
   Call it to release the `Transaction` when you decide not to commit (for
   example, after a validation error in your own code, before ever sending).

```zig
var txn = db.begin(allocator);
_ = try txn.put("orders", &.{.{ .id = 1, .value = mongreldb.intValue(1) }}, false);

if (!businessRuleOk()) {
    // Throw the staged ops away locally. Nothing has been sent to the daemon.
    try txn.rollback();
    return;
}

txn.commit("") catch |err| switch (err) {
    error.Conflict => {}, // server already rolled back
    else => return err,
};
```

`rollback` and `commit` both return `error.AlreadyCommitted` if the
transaction was already committed. Treat that as a programming error to fix
upstream, not a runtime condition to silence.

## Summary

| Goal | Use |
|------|-----|
| One independent write | `Client.put` / `deleteByPk` |
| Several writes that must commit together | `Client.begin` + `Transaction.commit` |
| Retry safely after a network blip | `commit(key)` with a stable key |
| Detect a constraint violation | match `error.Conflict` from `commit` |
| Abort before sending | `Transaction.rollback()` |

See [errors.md](errors.md) for the full error set and [queries.md](queries.md)
for read patterns.
