# Error Handling

The Zig client surfaces failures as values from a single, small error set
rather than as exception objects. Each member maps to a category of HTTP or
transport failure, so you discriminate with a `switch` and recover precisely.

```zig
const mongreldb = @import("mongreldb");
```

## The error set

Every public method on `Client`, `Transaction`, and `QueryBuilder` returns
`Error!T`, where `Error` is this set:

| Member             | Meaning                                                          |
|--------------------|------------------------------------------------------------------|
| `OutOfMemory`      | An allocation failed. Retry with more memory or a smaller batch. |
| `Http`             | A transport error or a server status we do not map more narrowly (3xx and most 5xx). |
| `Json`             | The server returned a malformed or unexpected JSON body.         |
| `Auth`             | Authentication or authorization failed (HTTP 401 or 403).       |
| `NotFound`         | The table or row does not exist (HTTP 404).                      |
| `Conflict`         | A constraint violation rolled back a transaction, or a payment-required response (HTTP 402 or 409). |
| `Query`            | The request was malformed: a bad condition, projection, or SQL statement (HTTP 400 and other 4xx). |
| `AlreadyCommitted` | A `Transaction` method was called after `commit` or `rollback`. |

Because Zig error sets are checked at compile time, you cannot accidentally
forget a case once you write a `switch` over them.

## How HTTP status maps to an error

`Client.mapStatus` converts the daemon's response into a member of the set:

| HTTP status            | Error              |
|------------------------|--------------------|
| 200 / 2xx              | (success, no error)|
| 401, 403               | `Auth`             |
| 404                    | `NotFound`         |
| 402, 409               | `Conflict`         |
| 400 and other 4xx      | `Query`            |
| 3xx, 5xx, and transport failures | `Http`   |
| Body that is not valid JSON | `Json`         |

Malformed JSON (a truncated body, a missing field the decoder expects) is
reported as `Json` regardless of the HTTP status.

## Matching errors

Use `catch |err| switch (err)` to handle each case:

```zig
const rows = db.query(arena.allocator(), "users")
    .where("bitmap_eq", .{ .column_id = 1, .value = mongreldb.intValue(7) }) catch |err| switch (err) {
        error.Auth => {
            std.debug.print("invalid credentials\n", .{});
            return;
        },
        error.NotFound => {
            std.debug.print("table missing\n", .{});
            return;
        },
        error.Query => {
            std.debug.print("malformed query\n", .{});
            return;
        },
        else => return err, // Http, Json, OutOfMemory, etc.
    };
```

For the common "log and propagate" shape, a plain `try` is enough:

```zig
const rows = try db.query(arena.allocator(), "users").execute();
```

## Transaction conflicts

A `Transaction.commit` runs all staged ops in a single atomic batch. If any
op violates a unique, foreign-key, check, or trigger constraint, the daemon
rolls back the entire batch and returns HTTP 409, which the client surfaces
as `error.Conflict`.

```zig
var txn = db.begin(arena.allocator());
_ = try txn.put("orders", &.{ .{ .id = 1, .value = .{ .integer = 10 } } }, false);

const results = txn.commit("order-batch-001") catch |err| switch (err) {
    error.Conflict => {
        std.debug.print("batch rolled back - fix the data and retry\n", .{});
        return;
    },
    else => return err,
};
```

The idempotency key makes a safe retry possible: re-stage the same ops on a
fresh transaction and commit with the same key. The daemon returns the
original response on duplicate commits.

## Single-use transactions

`Transaction.commit` and `Transaction.rollback` both flip an internal flag.
Calling any method on the transaction afterward returns
`error.AlreadyCommitted`. Start a new transaction for each batch:

```zig
var txn = db.begin(arena.allocator());
_ = try txn.commit("key-1");

// reuse is an error:
// _ = txn.put("orders", &.{...}, false) catch unreachable;
//        -> error.AlreadyCommitted

var next = db.begin(arena.allocator());
_ = try next.commit("key-2");
```

## Retries and idempotency

Network glitches and daemon restarts happen. Pair an idempotency key with a
retry loop for commit:

```zig
fn commitWithRetry(txn: *mongreldb.Transaction, key: []const u8) !mongreldb.Array {
    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        return txn.commit(key) catch |err| switch (err) {
            error.Http => {
                // transport error - safe to retry with the same key
                std.time.sleep(100 * std.time.ns_per_ms);
                continue;
            },
            else => return err, // Auth, Conflict, Query, etc. are not retried here
        };
    }
    return error.Http;
}
```

Only retry on `error.Http` (transport) with the same idempotency key.
`Conflict` and `Query` indicate a problem with the request itself and must be
fixed before retrying.

## Common pitfalls

**Swallowing errors with `catch`.** A bare `catch` discards the category and
hides bugs. Match with `switch` so each branch is explicit.

**Retrying `Conflict`.** A conflict means the batch violated a constraint;
replaying the same ops will fail the same way. Fix the offending op, then
retry.

**Forgetting `AlreadyCommitted`.** A transaction is single-use. If you share
one across function boundaries, make it obvious who calls `commit` or
`rollback`.

## Next steps

- [transactions.md](transactions.md) - atomic batches and idempotency
- [auth.md](auth.md) - where `error.Auth` comes from
