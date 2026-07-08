# Authentication & Authorization

A `mongreldb-server` daemon runs in one of three modes:

1. **Open** (default) - no auth required.
2. **Bearer token** (`--auth-token <TOKEN>`) - every request must carry an
   `Authorization: Bearer <TOKEN>` header.
3. **HTTP Basic** (`--auth-users`) - every request must carry an
   `Authorization: Basic <base64(user:pass)>` header.

The Zig client supports all three through the `Options` struct passed to
`Client.init`. This guide shows each mode and how to manage users and roles
via SQL when the server is in Basic mode.

---

## Bearer token mode

Start the daemon with a token:

```sh
mongreldb-server --auth-token s3cret-token
```

Connect with `.token`. The token is sent as `Authorization: Bearer ...` on
every request.

```zig
var db = mongreldb.Client.init(allocator, "http://127.0.0.1:8453", .{
    .token = "s3cret-token",
});
defer db.deinit();

const ok = db.health(allocator) catch false;
std.debug.print("healthy: {}\n", .{ok});
```

A missing or wrong token surfaces as `error.Auth` (HTTP 401/403).

### Where the token comes from

Hard-coding secrets in source is bad practice. Read it from the environment:

```zig
const token = std.posix.getenv("MONGRELDB_TOKEN") orelse {
    std.debug.print("MONGRELDB_TOKEN not set\n", .{});
    return error.NoToken;
};
var db = mongreldb.Client.init(allocator, "", .{ .token = token });
```

## Basic auth mode

Start the daemon with a users file or inline users:

```sh
mongreldb-server --auth-users
```

Connect with `.username` / `.password`:

```zig
var db = mongreldb.Client.init(allocator, "http://127.0.0.1:8453", .{
    .username = "admin",
    .password = "s3cret",
});
defer db.deinit();
```

The client base64-encodes `username:password` and sets
`Authorization: Basic ...` on every request.

## Token takes precedence

If you supply both, `.token` wins and Basic credentials are ignored. This lets
you layer an override without branching:

```zig
var db = mongreldb.Client.init(allocator, url, .{
    .username = "fallback",
    .password = "user",
    .token = "overrides-everything",
});
```

## User and role management via SQL

When the daemon is in Basic auth mode, users and roles live in the catalog and
are managed with SQL. Run these statements through `Client.sql`.

### Create a user

```zig
_ = try db.sql(allocator, "CREATE USER alice WITH PASSWORD 'hunter2'");
```

### Alter a user

Change a password:

```zig
_ = try db.sql(allocator, "ALTER USER alice WITH PASSWORD 'new-password'");
```

Grant the admin role:

```zig
_ = try db.sql(allocator, "ALTER USER alice ADMIN");
```

`ALTER USER ... ADMIN` is how you promote a user to full administrative
privileges (table creation/drop, compaction, user management). Use it
sparingly.

### Drop a user

```zig
_ = try db.sql(allocator, "DROP USER alice");
```

### Roles and grants

```zig
_ = try db.sql(allocator, "CREATE ROLE analyst");
_ = try db.sql(allocator, "GRANT SELECT ON orders TO analyst");
_ = try db.sql(allocator, "GRANT analyst TO alice");
_ = try db.sql(allocator, "REVOKE SELECT ON orders FROM analyst");
_ = try db.sql(allocator, "DROP ROLE analyst");
```

Exact grant syntax mirrors the server's SQL flavor; consult the server's SQL
reference for the full `GRANT`/`REVOKE` grammar available in your build.

## Common pitfalls

**Auth errors look like other errors without a typed match.** A 401/403 maps
to `error.Auth`; a 404 maps to `error.NotFound`. Always discriminate with a
`switch` rather than string-matching messages.

**Forgetting to set auth in production.** A client built with `Client.init`
and default `Options` sends no credentials. Against an auth-enabled daemon,
every call returns `error.Auth`. Centralize client construction so the auth
option is never accidentally dropped.

**Token in version control.** Put secrets in the environment, a secret
manager, or a file outside the repo. Never commit a real token.

## Next steps

- [errors.md](errors.md) - `error.Auth` and the rest of the typed error set
- [quickstart.md](quickstart.md) - the full end-to-end walkthrough
