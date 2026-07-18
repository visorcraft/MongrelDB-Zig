//! mongreldb is the pure-Zig HTTP client for [MongrelDB].
//!
//! It talks to a running mongreldb-server daemon's JSON API over the standard
//! library `std.http.Client` - no external dependencies. The surface mirrors
//! the MongrelDB PHP and Go clients: typed CRUD, a fluent query builder that
//! pushes conditions down to the engine's native indexes, idempotent batch
//! transactions, full SQL access, and schema introspection.
//!
//! Connect with `init` and a base URL:
//!
//! ```zig
//! var db = try mongreldb.Client.init(allocator, "http://127.0.0.1:8453", .{});
//! defer db.deinit();
//! const ok = try db.health(allocator);
//! ```
//!
//! [MongrelDB]: https://www.MongrelDB.com

const std = @import("std");
const http = std.http;
const json = std.json;
const mem = std.mem;
const Allocator = std.mem.Allocator;

const query_mod = @import("query.zig");
const transaction_mod = @import("transaction.zig");

pub const QueryBuilder = query_mod.QueryBuilder;
pub const Transaction = transaction_mod.Transaction;

/// `default_base_url` is the daemon address used when none is supplied.
pub const default_base_url = "http://127.0.0.1:8453";

/// `max_response_bytes` caps the size of a response body read from the daemon
/// (256 MB). Bodies larger than this are aborted as a `Query` error.
pub const max_response_bytes: usize = 268435456;

/// `Value` is a dynamic JSON value, used for cells, query parameters, and the
/// untyped payloads returned by the daemon (row data, schema descriptors, etc.).
pub const Value = json.Value;

/// `ObjectMap` is a JSON object (`std.StringArrayHashMap(Value)`).
pub const ObjectMap = json.ObjectMap;

/// `Array` is a JSON array (`std.ArrayList(Value)`).
pub const Array = json.Array;

/// `Cell` pairs a column id with its value. The client flattens a slice of
/// cells to the server's on-wire `[col_id, value, col_id, value, ...]` array
/// before sending. Pair order is irrelevant - each value is preceded by its
/// own column id.
pub const Cell = struct {
    id: i64,
    value: Value,
};

/// `Column` describes one column in a CREATE TABLE request. It is serialized
/// verbatim; the recognized keys are `id`, `name`, `ty`, `primary_key`,
/// `nullable`, `enum_variants`, and `default_value`, matching the daemon's
/// table-create extractor. `enum_variants` and `default_value` are optional
/// and only emitted when set, so existing call sites that omit them keep
/// producing identical wire shapes.
pub const Column = struct {
    id: i64,
    name: []const u8,
    ty: []const u8,
    primary_key: bool = false,
    nullable: bool = false,
    /// Optional list of allowed enum variants for an enum-typed column. Null
    /// (the default) means the column is not an enum. When supplied, the JSON
    /// body includes `"enum_variants": [...]` verbatim.
    enum_variants: ?[]const []const u8 = null,
    /// Optional default value as a raw string (the daemon coerces per the
    /// column's `ty`). Null (the default) means no default. When supplied,
    /// the JSON body includes `"default_value": "..."` verbatim.
    default_value: ?[]const u8 = null,
    /// Optional non-string JSON scalar, emitted as `default_value`. This takes
    /// precedence over the legacy string field when both are supplied.
    default_scalar: ?Value = null,
    /// Dynamic default expression (`"now"` or `"uuid"`). Takes precedence
    /// over both static default fields.
    default_expr: ?[]const u8 = null,
};

/// `Error` is the typed error set returned by every client operation. HTTP
/// status codes are mapped to a category: 401/403 -> `Auth`, 404 -> `NotFound`,
/// 409 -> `Conflict`, any other non-2xx -> `Query`. Transport failures are
/// reported as `Http`, malformed responses as `Json`.
pub const Error = error{
    Http,
    Json,
    Auth,
    NotFound,
    Conflict,
    Query,
    AlreadyCommitted,
    OutOfMemory,
};

/// `Options` configures a `Client`.
pub const Options = struct {
    /// `token` authenticates requests with a Bearer token (--auth-token mode).
    /// When set, it takes precedence over basic-auth credentials.
    token: []const u8 = "",
    /// `username` / `password` authenticate with HTTP Basic credentials
    /// (--auth-users mode). Ignored if `token` is also supplied.
    username: []const u8 = "",
    password: []const u8 = "",
};

/// `Client` is the MongrelDB HTTP client. Create one with `init` and use its
/// methods for health, table management, CRUD, query, SQL, and schema.
///
/// All methods take an `allocator` used for the request body, the parsed
/// response, and any returned data. The returned data is owned by that
/// allocator and is valid until the allocator frees it - pass an
/// `std.heap.ArenaAllocator` and reset it when you are done with the results.
pub const Client = struct {
    allocator: Allocator,
    base_url: []const u8,
    token: []const u8,
    username: []const u8,
    password: []const u8,
    /// Commit epoch of the most recent successful `/kit/txn` call, or 0 before
    /// any such call.
    lastEpoch: u64 = 0,
    http_client: http.Client,

    /// `init` returns a `Client` for the daemon at `base_url`. If `base_url`
    /// is empty, `default_base_url` is used. The base URL has any trailing
    /// slash trimmed. The supplied `allocator` backs the underlying HTTP
    /// connection pool; call `deinit` to release it.
    pub fn init(allocator: Allocator, base_url: []const u8, options: Options) Client {
        const url = if (base_url.len == 0) default_base_url else mem.trimRight(u8, base_url, "/");
        return .{
            .allocator = allocator,
            .base_url = url,
            .token = options.token,
            .username = options.username,
            .password = options.password,
            .http_client = .{ .allocator = allocator },
        };
    }

    /// `deinit` releases the HTTP connection pool. Call when done with the
    /// client.
    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
    }

    // ── Health & tables ───────────────────────────────────────────────────

    /// `health` reports whether the daemon is reachable and healthy. A
    /// transport failure or non-2xx response is surfaced as `error.Http`.
    pub fn health(self: *Client, allocator: Allocator) Error!bool {
        const body = try self.rawRequest(allocator, .GET, "/health", null);
        allocator.free(body);
        return true;
    }

    pub const HistoryRetention = struct {
        history_retention_epochs: u64,
        earliest_retained_epoch: u64,
    };

    pub fn historyRetention(self: *Client, allocator: Allocator) Error!HistoryRetention {
        return self.historyRetentionRequest(allocator, .GET, null);
    }

    pub fn setHistoryRetentionEpochs(self: *Client, allocator: Allocator, epochs: u64) Error!HistoryRetention {
        const payload = try setHistoryRetentionPayload(allocator, epochs);
        return self.historyRetentionRequest(allocator, .PUT, payload);
    }

    fn historyRetentionRequest(self: *Client, allocator: Allocator, method: std.http.Method, payload: ?Value) Error!HistoryRetention {
        defer {
            if (payload) |p| switch (p) {
                .object => |o| {
                    var obj = o;
                    obj.deinit();
                },
                else => {},
            };
        }
        const body = if (payload) |p| blk: {
            var buf = std.ArrayList(u8).init(allocator);
            defer buf.deinit();
            json.stringify(p, .{}, buf.writer()) catch return error.Json;
            break :blk try self.rawRequest(allocator, method, "/history/retention", buf.items);
        } else try self.rawRequest(allocator, method, "/history/retention", null);
        defer allocator.free(body);
        const parsed = parseBody(allocator, body) catch return error.Json;
        if (parsed != .object) return error.Json;
        const h = parsed.object.get("history_retention_epochs") orelse return error.Json;
        const e = parsed.object.get("earliest_retained_epoch") orelse return error.Json;
        const hep = jsonValueToU64(h) orelse return error.Json;
        const eep = jsonValueToU64(e) orelse return error.Json;
        return .{ .history_retention_epochs = hep, .earliest_retained_epoch = eep };
    }

    /// `historyRetentionEpochs` returns the current durable MVCC window size.
    pub fn historyRetentionEpochs(self: *Client, allocator: Allocator) Error!u64 {
        const hr = try self.historyRetention(allocator);
        return hr.history_retention_epochs;
    }

    /// `earliestRetainedEpoch` returns the oldest epoch still readable through
    /// `AS OF EPOCH` queries.
    pub fn earliestRetainedEpoch(self: *Client, allocator: Allocator) Error!u64 {
        const hr = try self.historyRetention(allocator);
        return hr.earliest_retained_epoch;
    }

    /// `tableNames` lists all table names in the database. The endpoint
    /// returns a bare JSON array of strings.
    pub fn tableNames(self: *Client, allocator: Allocator) Error![][]const u8 {
        const body = try self.rawRequest(allocator, .GET, "/tables", null);
        defer allocator.free(body);
        const parsed = parseBody(allocator, body) catch return error.Json;
        if (parsed != .array) return error.Json;
        var out = allocator.alloc([]const u8, parsed.array.items.len) catch return error.OutOfMemory;
        for (parsed.array.items, 0..) |v, i| {
            out[i] = switch (v) {
                .string => |s| s,
                else => return error.Json,
            };
        }
        return out;
    }

    /// `createTable` creates a table named `name` with the given columns and
    /// returns the assigned table id.
    pub fn createTable(self: *Client, allocator: Allocator, name: []const u8, columns: []const Column) Error!i64 {
        const payload = try createTablePayload(allocator, name, columns, null);
        return self.sendCreateTable(allocator, payload);
    }

    /// Creates a table with the daemon's full constraints object, including
    /// `constraints.checks`.
    pub fn createTableWithConstraints(
        self: *Client,
        allocator: Allocator,
        name: []const u8,
        columns: []const Column,
        constraints: Value,
    ) Error!i64 {
        const payload = try createTablePayload(allocator, name, columns, constraints);
        return self.sendCreateTable(allocator, payload);
    }

    fn sendCreateTable(self: *Client, allocator: Allocator, payload: Value) Error!i64 {
        const resp = try self.doPost(allocator, "/kit/create_table", payload);
        const obj = switch (resp) {
            .object => |o| o,
            else => return error.Json,
        };
        const tid = obj.get("table_id") orelse return error.Json;
        return switch (tid) {
            .integer => |i| i,
            else => return error.Json,
        };
    }

    /// `dropTable` drops a table by name.
    pub fn dropTable(self: *Client, allocator: Allocator, name: []const u8) Error!void {
        const path = std.fmt.allocPrint(allocator, "/tables/{s}", .{urlPathEscape(name)}) catch return error.OutOfMemory;
        defer allocator.free(path);
        const body = try self.rawRequest(allocator, .DELETE, path, null);
        allocator.free(body);
    }

    /// `count` returns the row count for a table.
    pub fn count(self: *Client, allocator: Allocator, table: []const u8) Error!i64 {
        const path = std.fmt.allocPrint(allocator, "/tables/{s}/count", .{urlPathEscape(table)}) catch return error.OutOfMemory;
        defer allocator.free(path);
        const body = try self.rawRequest(allocator, .GET, path, null);
        defer allocator.free(body);
        const parsed = parseBody(allocator, body) catch return error.Json;
        const obj = switch (parsed) {
            .object => |o| o,
            else => return error.Json,
        };
        const c = obj.get("count") orelse return error.Json;
        return switch (c) {
            .integer => |i| i,
            else => return error.Json,
        };
    }

    // ── CRUD (via the Kit typed transaction endpoint) ─────────────────────

    /// `put` inserts a row. `idempotency_key`, if non-empty, makes the commit
    /// safe to retry - the daemon returns the original result on duplicate
    /// commits. Returns the per-operation result object (the first element of
    /// the server's results array).
    pub fn put(self: *Client, allocator: Allocator, table: []const u8, cells: []const Cell, idempotency_key: []const u8) Error!Value {
        var inner = ObjectMap.init(allocator);
        inner.put("table", .{ .string = table }) catch return error.OutOfMemory;
        inner.put("cells", .{ .array = try flattenCells(allocator, cells) }) catch return error.OutOfMemory;
        inner.put("returning", .{ .bool = false }) catch return error.OutOfMemory;

        var op = ObjectMap.init(allocator);
        op.put("put", .{ .object = inner }) catch return error.OutOfMemory;

        var ops = Array.init(allocator);
        ops.append(.{ .object = op }) catch return error.OutOfMemory;

        const results = try self.commitTxn(allocator, ops, idempotency_key);
        if (results.items.len == 0) return Value{ .null = {} };
        return results.items[0];
    }

    /// `upsert` inserts a row, or updates it on a primary-key conflict.
    /// `cells` are the insert values; `update_cells`, when non-empty, are the
    /// values to apply on a conflict (an empty slice means DO NOTHING).
    /// `idempotency_key`, if non-empty, makes the commit safe to retry.
    pub fn upsert(self: *Client, allocator: Allocator, table: []const u8, cells: []const Cell, update_cells: []const Cell, idempotency_key: []const u8) Error!Value {
        var inner = ObjectMap.init(allocator);
        inner.put("table", .{ .string = table }) catch return error.OutOfMemory;
        inner.put("cells", .{ .array = try flattenCells(allocator, cells) }) catch return error.OutOfMemory;
        inner.put("returning", .{ .bool = false }) catch return error.OutOfMemory;
        if (update_cells.len > 0) {
            inner.put("update_cells", .{ .array = try flattenCells(allocator, update_cells) }) catch return error.OutOfMemory;
        }

        var op = ObjectMap.init(allocator);
        op.put("upsert", .{ .object = inner }) catch return error.OutOfMemory;

        var ops = Array.init(allocator);
        ops.append(.{ .object = op }) catch return error.OutOfMemory;

        const results = try self.commitTxn(allocator, ops, idempotency_key);
        if (results.items.len == 0) return Value{ .null = {} };
        return results.items[0];
    }

    /// `deleteByPk` removes a row by its primary-key value.
    pub fn deleteByPk(self: *Client, allocator: Allocator, table: []const u8, pk: Value) Error!void {
        var inner = ObjectMap.init(allocator);
        inner.put("table", .{ .string = table }) catch return error.OutOfMemory;
        inner.put("pk", pk) catch return error.OutOfMemory;

        var op = ObjectMap.init(allocator);
        op.put("delete_by_pk", .{ .object = inner }) catch return error.OutOfMemory;

        var ops = Array.init(allocator);
        ops.append(.{ .object = op }) catch return error.OutOfMemory;

        _ = try self.commitTxn(allocator, ops, "");
    }

    /// `commitTxn` sends a batch of staged operations atomically to
    /// `/kit/txn` and returns the per-operation results array. Exposed for the
    /// `Transaction` type.
    pub fn commitTxn(self: *Client, allocator: Allocator, ops: Array, idempotency_key: []const u8) Error!Array {
        var root = ObjectMap.init(allocator);
        root.put("ops", .{ .array = ops }) catch return error.OutOfMemory;
        if (idempotency_key.len > 0) {
            root.put("idempotency_key", .{ .string = idempotency_key }) catch return error.OutOfMemory;
        }

        const resp = try self.doPost(allocator, "/kit/txn", .{ .object = root });
        const obj = switch (resp) {
            .object => |o| o,
            else => return error.Json,
        };

        // Capture the commit epoch when the server reports a committed status.
        // Non-committed responses leave lastEpoch unchanged so a previously
        // valid pinning point is not wiped.
        if (obj.get("status")) |status_val| {
            if (status_val == .string and mem.eql(u8, status_val.string, "committed")) {
                if (obj.get("epoch")) |epoch_val| {
                    if (epoch_val == .integer and epoch_val.integer >= 0) {
                        self.lastEpoch = @intCast(epoch_val.integer);
                    }
                }
            }
        }

        const results_val = obj.get("results") orelse return Array.init(allocator);
        return switch (results_val) {
            .array => |a| a,
            else => Array.init(allocator),
        };
    }

    // ── Query ─────────────────────────────────────────────────────────────

    /// `query` starts a fluent `QueryBuilder` against `table`.
    pub fn query(self: *Client, allocator: Allocator, table: []const u8) QueryBuilder {
        return QueryBuilder.init(self, allocator, table);
    }

    // ── Transactions ──────────────────────────────────────────────────────

    /// `begin` starts a new batch transaction.
    pub fn begin(self: *Client, allocator: Allocator) Transaction {
        return Transaction.init(self, allocator);
    }

    // ── SQL ───────────────────────────────────────────────────────────────

    /// `sql` executes a SQL statement via the `/sql` endpoint, requesting JSON
    /// output. The server returns a JSON array of row objects keyed by column
    /// name, e.g. `[{"id": 1, "name": "Alice", "score": 95.5}]`, when the server
    /// honors JSON format. For statements that yield no rows (DDL/DML), Arrow IPC
    /// streams, or any non-array JSON response, an empty slice is returned.
    pub fn sql(self: *Client, allocator: Allocator, sql_text: []const u8) Error![]Value {
        var root = ObjectMap.init(allocator);
        root.put("sql", .{ .string = sql_text }) catch return error.OutOfMemory;
        root.put("format", .{ .string = "json" }) catch return error.OutOfMemory;

        const body = try self.postRaw(allocator, "/sql", .{ .object = root });
        defer allocator.free(body);

        const trimmed = mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) return &[_]Value{};
        // JSON format requested; a leading '{' is a single object (e.g. an error
        // envelope), not a row set, so return an empty slice. A '[' begins the
        // row array to decode.
        if (trimmed[0] != '[') return &[_]Value{};

        const parsed = json.parseFromSliceLeaky(Value, allocator, body, .{}) catch return error.Json;
        switch (parsed) {
            .array => |a| return a.items,
            else => return &[_]Value{},
        }
    }

    // ── Schema ────────────────────────────────────────────────────────────

    /// `schema` returns the full schema catalog: a table-name-to-descriptor
    /// map.
    pub fn schema(self: *Client, allocator: Allocator) Error!ObjectMap {
        const body = try self.rawRequest(allocator, .GET, "/kit/schema", null);
        defer allocator.free(body);
        const parsed = parseBody(allocator, body) catch return error.Json;
        const obj = switch (parsed) {
            .object => |o| o,
            else => return error.Json,
        };
        const tables_val = obj.get("tables") orelse return ObjectMap.init(allocator);
        return switch (tables_val) {
            .object => |o| o,
            else => error.Json,
        };
    }

    /// `schemaFor` returns the descriptor for a single table.
    pub fn schemaFor(self: *Client, allocator: Allocator, table: []const u8) Error!Value {
        const path = std.fmt.allocPrint(allocator, "/kit/schema/{s}", .{urlPathEscape(table)}) catch return error.OutOfMemory;
        defer allocator.free(path);
        const body = try self.rawRequest(allocator, .GET, path, null);
        defer allocator.free(body);
        const parsed = parseBody(allocator, body) catch return error.Json;
        return switch (parsed) {
            .object => |o| Value{ .object = o },
            else => error.Json,
        };
    }

    // ── HTTP plumbing ─────────────────────────────────────────────────────

    /// `doGet` performs a GET and decodes the JSON body to a `Value` (`.null`
    /// when the body is empty).
    pub fn doGet(self: *Client, allocator: Allocator, path: []const u8) Error!Value {
        const body = try self.rawRequest(allocator, .GET, path, null);
        defer allocator.free(body);
        return try parseBody(allocator, body);
    }

    /// `doPost` performs a POST with a JSON `Value` body (Content-Type:
    /// application/json) and decodes the JSON response to a `Value`.
    pub fn doPost(self: *Client, allocator: Allocator, path: []const u8, payload: Value) Error!Value {
        const body = try self.postRaw(allocator, path, payload);
        defer allocator.free(body);
        return try parseBody(allocator, body);
    }

    /// `postRaw` performs a POST with a JSON `Value` body and returns the raw
    /// response body (owned by `allocator`).
    fn postRaw(self: *Client, allocator: Allocator, path: []const u8, payload: Value) Error![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        json.stringify(payload, .{}, buf.writer()) catch return error.Json;
        return self.rawRequest(allocator, .POST, path, buf.items);
    }

    /// `rawRequest` builds and runs one request. The server's JSON extractors
    /// require an explicit Content-Type header on any request carrying a JSON
    /// body, so one is added whenever `payload` is non-null. Non-2xx responses
    /// are mapped to typed errors via `mapStatus`. The returned body is owned
    /// by `allocator`.
    fn rawRequest(self: *Client, allocator: Allocator, method: http.Method, path: []const u8, payload: ?[]const u8) Error![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const url = std.fmt.allocPrint(a, "{s}/{s}", .{ self.base_url, mem.trimLeft(u8, path, "/") }) catch return error.Http;

        var headers: [3]http.Header = undefined;
        var hc: usize = 0;
        headers[hc] = .{ .name = "Accept", .value = "application/json" };
        hc += 1;
        if (payload != null) {
            headers[hc] = .{ .name = "Content-Type", .value = "application/json" };
            hc += 1;
        }
        // A bearer token takes precedence over basic auth.
        if (self.token.len > 0) {
            const bearer = std.fmt.allocPrint(a, "Bearer {s}", .{self.token}) catch return error.Http;
            headers[hc] = .{ .name = "Authorization", .value = bearer };
            hc += 1;
        } else if (self.username.len > 0) {
            const creds = std.fmt.allocPrint(a, "{s}:{s}", .{ self.username, self.password }) catch return error.Http;
            const enc_len = std.base64.standard.Encoder.calcSize(creds.len);
            const encoded = a.alloc(u8, enc_len) catch return error.Http;
            _ = std.base64.standard.Encoder.encode(encoded, creds);
            const basic = std.fmt.allocPrint(a, "Basic {s}", .{encoded}) catch return error.Http;
            headers[hc] = .{ .name = "Authorization", .value = basic };
            hc += 1;
        }

        var response_body = std.ArrayList(u8).init(a);
        const result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .extra_headers = headers[0..hc],
            .response_storage = .{ .dynamic = &response_body },
            .max_append_size = 64 * 1024 * 1024,
        }) catch return error.Http;

        // Cap the response: a body larger than max_response_bytes is aborted as
        // a Query error rather than buffering unbounded data.
        if (response_body.items.len > max_response_bytes) {
            return error.Query;
        }

        const code: u16 = @intFromEnum(result.status);
        if (code < 200 or code >= 300) {
            if (std.mem.indexOf(u8, response_body.items, "not found:") != null) return error.NotFound;
            return mapStatus(@intCast(code));
        }
        return allocator.dupe(u8, response_body.items) catch error.OutOfMemory;
    }
};

/// `mapStatus` maps an HTTP status code to a typed `Error`.
///
/// Every status code is handled explicitly by category so the client never
/// trips an unreachable/panic on a code the daemon might return (e.g. a 400
/// validation error, a 500 engine error, or a redirect) - the `else` arms map
/// any unmapped code to a sensible category instead of `@panic`-ing.
fn mapStatus(code: u16) Error {
    return switch (code) {
        // 3xx redirections: the client does not follow them for these JSON
        // endpoints, so treat as a transport-level failure.
        300, 301, 302, 303, 304, 307, 308 => error.Http,
        // 4xx client errors.
        400, 405...408, 410...428, 431, 451 => error.Query,
        401, 403 => error.Auth,
        402, 409 => error.Conflict,
        404 => error.NotFound,
        // 5xx server errors.
        500...599 => error.Http,
        // Any other code (1xx informational, unmapped 4xx, etc.).
        else => error.Query,
    };
}

/// `parseBody` decodes a JSON body to a `Value`, returning `.null` for an
/// empty body.
fn parseBody(allocator: Allocator, body: []const u8) Error!Value {
    if (body.len == 0) return Value{ .null = {} };
    return json.parseFromSliceLeaky(Value, allocator, body, .{}) catch error.Json;
}

/// `jsonValueToU64` converts a JSON value to u64, accepting `.integer`,
/// `.float`, and `.number_string` representations (needed for values > i64 max).
fn jsonValueToU64(v: Value) ?u64 {
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .float => |f| if (f >= 0 and f <= @as(f64, @floatFromInt(@as(u64, std.math.maxInt(u64))))) @intFromFloat(f) else null,
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

/// `flattenCells` converts a slice of cells to the server's flat
/// `[col_id, value, ...]` array in ascending column-id order. Stable ordering
/// is required for idempotency keys: the server hashes the request payload,
/// and unordered pair order would make two commits of the same cells look like
/// a reuse mismatch.
pub fn flattenCells(allocator: Allocator, cells: []const Cell) Error!Array {
    const sorted = allocator.alloc(Cell, cells.len) catch return error.OutOfMemory;
    defer allocator.free(sorted);
    @memcpy(sorted, cells);
    std.mem.sort(Cell, sorted, {}, struct {
        fn less(_: void, a: Cell, b: Cell) bool {
            return a.id < b.id;
        }
    }.less);
    var flat = Array.initCapacity(allocator, cells.len * 2) catch return error.OutOfMemory;
    for (sorted) |c| {
        flat.append(.{ .integer = c.id }) catch return error.OutOfMemory;
        flat.append(c.value) catch return error.OutOfMemory;
    }
    return flat;
}

/// `columnToJson` serializes a single `Column` into the JSON object the
/// daemon's `/kit/create_table` extractor recognizes. Always emits `id`,
/// `name`, `ty`, `primary_key`, and `nullable`. Adds `enum_variants` when
/// the field is set and non-empty, and `default_value` when set. Exposed at
/// module scope so wire-shape conformance tests can verify the produced
/// body without a live daemon.
pub fn columnToJson(allocator: Allocator, c: Column) Error!Value {
    var col = ObjectMap.init(allocator);
    col.put("id", .{ .integer = c.id }) catch return error.OutOfMemory;
    col.put("name", .{ .string = c.name }) catch return error.OutOfMemory;
    col.put("ty", .{ .string = c.ty }) catch return error.OutOfMemory;
    col.put("primary_key", .{ .bool = c.primary_key }) catch return error.OutOfMemory;
    col.put("nullable", .{ .bool = c.nullable }) catch return error.OutOfMemory;
    if (c.enum_variants) |variants| {
        if (variants.len > 0) {
            var arr = Array.initCapacity(allocator, variants.len) catch return error.OutOfMemory;
            for (variants) |v| {
                arr.append(.{ .string = v }) catch return error.OutOfMemory;
            }
            col.put("enum_variants", .{ .array = arr }) catch return error.OutOfMemory;
        }
    }
    if (c.default_expr) |expr| {
        col.put("default_expr", .{ .string = expr }) catch return error.OutOfMemory;
    } else if (c.default_scalar) |dv| {
        col.put("default_value", dv) catch return error.OutOfMemory;
    } else if (c.default_value) |dv| {
        col.put("default_value", .{ .string = dv }) catch return error.OutOfMemory;
    }
    return Value{ .object = col };
}

/// `createTablePayload` builds the JSON body accepted by `/kit/create_table`.
/// A null constraints value is omitted to preserve the old wire shape.
pub fn createTablePayload(
    allocator: Allocator,
    name: []const u8,
    columns: []const Column,
    constraints: ?Value,
) Error!Value {
    var col_arr = Array.initCapacity(allocator, columns.len) catch return error.OutOfMemory;
    for (columns) |column| {
        col_arr.append(try columnToJson(allocator, column)) catch return error.OutOfMemory;
    }
    var root = ObjectMap.init(allocator);
    root.put("name", .{ .string = name }) catch return error.OutOfMemory;
    root.put("columns", .{ .array = col_arr }) catch return error.OutOfMemory;
    if (constraints) |value| {
        root.put("constraints", value) catch return error.OutOfMemory;
    }
    return .{ .object = root };
}

/// `setHistoryRetentionPayload` builds the JSON body for the
/// `/history/retention` setter. Exposed at module scope so wire-shape tests
/// can assert the on-wire format without a daemon.
pub fn setHistoryRetentionPayload(allocator: Allocator, epochs: u64) Error!Value {
    var payload = ObjectMap.init(allocator);
    errdefer payload.deinit();
    if (epochs <= std.math.maxInt(i64)) {
        payload.put("history_retention_epochs", .{ .integer = @intCast(epochs) }) catch return error.OutOfMemory;
    } else {
        // u64 values above i64 max cannot use .integer; emit as number_string.
        const str = std.fmt.allocPrint(allocator, "{d}", .{epochs}) catch return error.OutOfMemory;
        payload.put("history_retention_epochs", .{ .number_string = str }) catch return error.OutOfMemory;
    }
    return .{ .object = payload };
}

/// `urlPathEscape` percent-escapes a path segment so table names containing
/// '/', '?', '#', or spaces cannot inject extra segments or break routing.
/// Only RFC 3986 unreserved characters pass through unescaped. The forward
/// slash is encoded.
pub fn urlPathEscape(seg: []const u8) []const u8 {
    // Fast path: nothing to escape.
    var need_escape = false;
    for (seg) |b| {
        switch (b) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => {},
            else => {
                need_escape = true;
                break;
            },
        }
    }
    if (!need_escape) return seg;

    // Worst case: every byte becomes %XX (3 bytes).
    var out: std.ArrayListUnmanaged(u8) = .{};
    const hex = "0123456789ABCDEF";
    for (seg) |b| {
        switch (b) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => out.append(std.heap.page_allocator, b) catch return seg,
            else => {
                out.append(std.heap.page_allocator, '%') catch return seg;
                out.append(std.heap.page_allocator, hex[b >> 4]) catch return seg;
                out.append(std.heap.page_allocator, hex[b & 0x0f]) catch return seg;
            },
        }
    }
    return out.toOwnedSlice(std.heap.page_allocator) catch seg;
}

// ── Value constructors ────────────────────────────────────────────────────

/// `intValue` builds a JSON integer cell value.
pub fn intValue(i: i64) Value {
    return .{ .integer = i };
}

/// `floatValue` builds a JSON float cell value.
pub fn floatValue(f: f64) Value {
    return .{ .float = f };
}

/// `stringValue` builds a JSON string cell value.
pub fn stringValue(s: []const u8) Value {
    return .{ .string = s };
}

/// `boolValue` builds a JSON boolean cell value.
pub fn boolValue(b: bool) Value {
    return .{ .bool = b };
}

/// `nullValue` builds a JSON null cell value.
pub fn nullValue() Value {
    return .{ .null = {} };
}

test {
    _ = @import("query.zig");
    _ = @import("transaction.zig");
}
