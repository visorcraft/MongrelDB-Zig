//! Wire-shape conformance tests for the mongreldb Zig client.
//!
//! These tests are pure (no daemon required) - they serialize a `Column` via
//! `columnToJson`, stringify the result, and assert the exact keys + values
//! appear in the outgoing JSON body. They guard the T5.ZIG ergonomic
//! extension: adding `enum_variants`, `default_value`, and table
//! `constraints` keys to the `/kit/create_table` payload. A future regression
//! that drops any key would silently break user schemas, so the wire shape is
//! asserted here rather than only on the server side.

const std = @import("std");
const testing = std.testing;

const mongreldb = @import("mongreldb");
const Column = mongreldb.Column;
const Value = mongreldb.Value;

/// `stringifyValue` flattens a `std.json.Value` to a compact JSON string
/// using an internal scratch buffer that the caller frees. The buffer is
/// built via `std.json.stringify` into an `ArrayList(u8)` and toOwnedSlice'd.
fn stringifyValue(a: std.mem.Allocator, v: Value) ![]u8 {
    var buf = std.ArrayList(u8).init(a);
    try std.json.stringify(v, .{}, buf.writer());
    return buf.toOwnedSlice();
}

test "columnToJson emits enum_variants and default_value verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const col = Column{
        .id = 1,
        .name = "color",
        .ty = "string",
        .primary_key = false,
        .nullable = false,
        .enum_variants = &[_][]const u8{ "a", "b" },
        .default_value = "a",
    };

    const v = try mongreldb.columnToJson(a, col);
    const s = try stringifyValue(a, v);
    defer a.free(s);

    try testing.expect(std.mem.indexOf(u8, s, "\"enum_variants\":[\"a\",\"b\"]") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"default_value\":\"a\"") != null);
}

test "createTablePayload emits table checks" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var checks = mongreldb.ObjectMap.init(a);
    var check = mongreldb.ObjectMap.init(a);
    check.put("id", .{ .integer = 1 }) catch return error.OutOfMemory;
    check.put("name", .{ .string = "ck_color" }) catch return error.OutOfMemory;
    var expr = mongreldb.ObjectMap.init(a);
    expr.put("IsNotNull", .{ .integer = 1 }) catch return error.OutOfMemory;
    check.put("expr", .{ .object = expr }) catch return error.OutOfMemory;
    var check_list = mongreldb.Array.init(a);
    check_list.append(.{ .object = check }) catch return error.OutOfMemory;
    checks.put("checks", .{ .array = check_list }) catch return error.OutOfMemory;

    const payload = try mongreldb.createTablePayload(a, "colors", &[_]Column{}, .{ .object = checks });
    const s = try stringifyValue(a, payload);
    defer a.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "\"constraints\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"checks\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"IsNotNull\":1") != null);
}

test "columnToJson omits absent enum_variants and default_value" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No enum/default supplied - both keys must be absent so the wire shape
    // matches the pre-T5.1 baseline exactly.
    const col = Column{
        .id = 2,
        .name = "amount",
        .ty = "int64",
        .primary_key = true,
        .nullable = false,
    };

    const v = try mongreldb.columnToJson(a, col);
    const s = try stringifyValue(a, v);
    defer a.free(s);

    try testing.expect(std.mem.indexOf(u8, s, "enum_variants") == null);
    try testing.expect(std.mem.indexOf(u8, s, "default_value") == null);
    try testing.expect(std.mem.indexOf(u8, s, "\"primary_key\":true") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"nullable\":false") != null);
}

test "columnToJson omits empty enum_variants slice" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An explicit empty slice should not be emitted - null and empty are
    // treated the same on the wire to keep schemas identical to the no-key
    // case.
    const col = Column{
        .id = 3,
        .name = "label",
        .ty = "string",
        .enum_variants = &[_][]const u8{},
        .default_value = "x",
    };

    const v = try mongreldb.columnToJson(a, col);
    const s = try stringifyValue(a, v);
    defer a.free(s);

    try testing.expect(std.mem.indexOf(u8, s, "enum_variants") == null);
    try testing.expect(std.mem.indexOf(u8, s, "\"default_value\":\"x\"") != null);
}

test "columnToJson emits boolean default scalar" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try mongreldb.columnToJson(a, .{
        .id = 4,
        .name = "enabled",
        .ty = "bool",
        .default_scalar = .{ .bool = true },
    });
    const s = try stringifyValue(a, value);
    defer a.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "\"default_value\":true") != null);
}

test "columnToJson emits integer and null default scalars" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const integer = try mongreldb.columnToJson(a, .{ .id = 5, .name = "retries", .ty = "int64", .default_scalar = .{ .integer = 3 } });
    const null_value = try mongreldb.columnToJson(a, .{ .id = 6, .name = "optional", .ty = "varchar", .default_scalar = .null });
    const integer_json = try stringifyValue(a, integer);
    const null_json = try stringifyValue(a, null_value);
    defer a.free(integer_json);
    defer a.free(null_json);
    try testing.expect(std.mem.indexOf(u8, integer_json, "\"default_value\":3") != null);
    try testing.expect(std.mem.indexOf(u8, null_json, "\"default_value\":null") != null);
}

test "columnToJson emits dynamic default expression" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try mongreldb.columnToJson(a, .{
        .id = 5,
        .name = "created_at",
        .ty = "timestamp",
        .default_value = "legacy",
        .default_scalar = .{ .bool = false },
        .default_expr = "now",
    });
    const s = try stringifyValue(a, value);
    defer a.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "\"default_expr\":\"now\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "default_value") == null);
}

test "columnToJson emits literal now and uuid defaults" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const now_col = try mongreldb.columnToJson(a, .{
        .id = 7,
        .name = "now_literal",
        .ty = "varchar",
        .default_value = "now",
    });
    const uuid_col = try mongreldb.columnToJson(a, .{
        .id = 8,
        .name = "uuid_literal",
        .ty = "varchar",
        .default_value = "uuid",
    });
    const now_json = try stringifyValue(a, now_col);
    const uuid_json = try stringifyValue(a, uuid_col);
    defer a.free(now_json);
    defer a.free(uuid_json);

    try testing.expect(std.mem.indexOf(u8, now_json, "\"default_value\":\"now\"") != null);
    try testing.expect(std.mem.indexOf(u8, uuid_json, "\"default_value\":\"uuid\"") != null);
}

test "setHistoryRetentionPayload shape" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const payload = try mongreldb.setHistoryRetentionPayload(a, 2048);
    const s = try stringifyValue(a, payload);
    defer a.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "\"history_retention_epochs\":2048") != null);
}

// ── Transport-level retention tests ────────────────────────────────────────
//
// The payload and parser tests above exercise the JSON helpers in isolation.
// These tests drive the client's real `historyRetention` and
// `setHistoryRetentionEpochs` methods through the HTTP transport layer
// (`Client.rawRequest` -> `std.http.Client.fetch`) against an in-process TCP
// mock, so we can assert the actual on-wire method, path, PUT body key, GET
// response keys, and the propagation of a non-2xx response to a typed Error.
//
// The mock is a tiny `std.net.Server` listener on a kernel-assigned port:
// each accepted connection's request line and body are parsed by hand and
// recorded; a canned `status + body` response is written back. This uses
// only the standard library (no new dependency).

const net = std.net;
const Thread = std.Thread;

/// `TransportMock` is a single-connection HTTP/1.1 mock used by the
/// retention transport tests. It listens on 127.0.0.1:0, records the last
/// request's method/path/body into shared fields guarded by a mutex, and
/// responds with whatever `setResponse` configured.
const TransportMock = struct {
    listener: std.net.Server,
    port: u16,
    thread: Thread,
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    mutex: Thread.Mutex = .{},
    last_method: []const u8 = "",
    last_path: []const u8 = "",
    last_body: []const u8 = "",
    resp_status: u16 = 200,
    resp_body: []const u8 = "{}",
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const Self = @This();

    /// `init` starts the listener and the background accept loop. The caller
    /// owns the returned mock and must `deinit` it.
    fn init(parent: std.mem.Allocator) !*Self {
        const self = try parent.create(Self);
        errdefer parent.destroy(self);
        self.arena = std.heap.ArenaAllocator.init(parent);
        self.allocator = self.arena.allocator();
        const address = try net.Address.parseIp("127.0.0.1", 0);
        self.listener = try address.listen(.{ .reuse_address = true });
        self.port = self.listener.listen_address.in.getPort();
        // `create` does not run struct-field default initializers, so the
        // remaining fields are set explicitly here.
        self.mutex = .{};
        self.last_method = "";
        self.last_path = "";
        self.last_body = "";
        self.resp_status = 200;
        self.resp_body = "{}";
        self.stop = std.atomic.Value(bool).init(false);
        self.thread = try Thread.spawn(.{}, mockLoop, .{self});
        return self;
    }

    /// `deinit` stops the accept loop, joins the thread, and frees all
    /// arena-backed allocations (recorded strings included).
    fn deinit(self: *Self, parent: std.mem.Allocator) void {
        self.stop.store(true, .release);
        // Closing the listener from another thread unblocks accept().
        self.listener.deinit();
        self.thread.join();
        self.arena.deinit();
        parent.destroy(self);
    }

    /// `setResponse` configures the canned status+body the mock will emit
    /// for subsequent requests. The strings are copied into the arena so the
    /// caller's buffers may be reused.
    fn setResponse(self: *Self, status: u16, body: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.resp_status = status;
        self.resp_body = self.allocator.dupe(u8, body) catch return;
    }

    /// `url` returns the base URL the mongreldb client should target to
    /// reach this mock.
    fn url(self: *Self, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.port}) catch unreachable;
    }

    /// `lastRequest` snapshots the most recently received request's method,
    /// path, and body into caller-owned allocations under `dst_alloc`.
    fn lastRequest(self: *Self, dst_alloc: std.mem.Allocator) !RecordedRequest {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .method = try dst_alloc.dupe(u8, self.last_method),
            .path = try dst_alloc.dupe(u8, self.last_path),
            .body = try dst_alloc.dupe(u8, self.last_body),
        };
    }
};

const RecordedRequest = struct {
    method: []u8,
    path: []u8,
    body: []u8,

    fn deinit(self: RecordedRequest, alloc: std.mem.Allocator) void {
        alloc.free(self.method);
        alloc.free(self.path);
        alloc.free(self.body);
    }
};

/// `mockLoop` is the background accept loop. It parses the HTTP/1.1 request
/// line + headers + body by hand (bodies here are always small JSON
/// objects, so a single read is sufficient), records the request, and writes
/// back a canned response with an explicit Content-Length + Connection:
/// close so the client's parser sees a well-formed message.
fn mockLoop(self: *TransportMock) void {
    var read_buf: [16 * 1024]u8 = undefined;
    while (!self.stop.load(.acquire)) {
        const conn = self.listener.accept() catch return;
        defer conn.stream.close();
        const n = conn.stream.read(&read_buf) catch continue;
        if (n == 0) continue;
        const req = read_buf[0..n];

        // Parse: METHOD SP TARGET SP HTTP/1.1\r\n ...
        const line_end = std.mem.indexOf(u8, req, "\r\n") orelse req.len;
        const request_line = req[0..line_end];
        var it = std.mem.tokenizeScalar(u8, request_line, ' ');
        const method = it.next() orelse continue;
        const target = it.next() orelse continue;

        // Body begins after the first blank line.
        const body_start = if (std.mem.indexOf(u8, req, "\r\n\r\n")) |idx| idx + 4 else req.len;
        const body = if (body_start <= req.len) req[body_start..] else "";

        // Snapshot method/path/body into the mock's arena so they outlive
        // the connection-local read buffer.
        const method_copy = self.allocator.dupe(u8, method) catch "";
        const path_copy = self.allocator.dupe(u8, target) catch "";
        const body_copy = self.allocator.dupe(u8, body) catch "";

        var status: u16 = 200;
        var resp_body: []const u8 = "{}";
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.last_method = method_copy;
            self.last_path = path_copy;
            self.last_body = body_copy;
            status = self.resp_status;
            resp_body = self.resp_body;
        }

        // Build and write the response. Content-Length and Connection:
        // close guarantee the client's HTTP parser sees a complete message
        // and does not try to reuse the connection.
        var resp_buf: [8192]u8 = undefined;
        const reason: []const u8 = if (status == 200) "OK" else if (status == 404) "Not Found" else "Error";
        const resp = std.fmt.bufPrint(&resp_buf,
            "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ status, reason, resp_body.len, resp_body },
        ) catch continue;
        conn.stream.writeAll(resp) catch {};
    }
}

test "historyRetention transport: GET method, /history/retention path, response keys" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = try TransportMock.init(std.heap.page_allocator);
    defer mock.deinit(std.heap.page_allocator);
    mock.setResponse(200, "{\"history_retention_epochs\":250,\"earliest_retained_epoch\":5}");

    var url_buf: [64]u8 = undefined;
    var db = mongreldb.Client.init(a, mock.url(&url_buf), .{});
    defer db.deinit();

    const hr = try db.historyRetention(a);
    try testing.expectEqual(@as(u64, 250), hr.history_retention_epochs);
    try testing.expectEqual(@as(u64, 5), hr.earliest_retained_epoch);

    const req = try mock.lastRequest(a);
    try testing.expectEqualStrings("GET", req.method);
    try testing.expect(std.mem.indexOf(u8, req.path, "/history/retention") != null);
}

test "setHistoryRetentionEpochs transport: PUT method, path, and body key" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = try TransportMock.init(std.heap.page_allocator);
    defer mock.deinit(std.heap.page_allocator);
    mock.setResponse(200, "{\"history_retention_epochs\":2048,\"earliest_retained_epoch\":7}");

    var url_buf: [64]u8 = undefined;
    var db = mongreldb.Client.init(a, mock.url(&url_buf), .{});
    defer db.deinit();

    const hr = try db.setHistoryRetentionEpochs(a, 2048);
    try testing.expectEqual(@as(u64, 2048), hr.history_retention_epochs);
    try testing.expectEqual(@as(u64, 7), hr.earliest_retained_epoch);

    const req = try mock.lastRequest(a);
    try testing.expectEqualStrings("PUT", req.method);
    try testing.expect(std.mem.indexOf(u8, req.path, "/history/retention") != null);
    // The PUT body must carry the single key the server reads.
    try testing.expect(std.mem.indexOf(u8, req.body, "\"history_retention_epochs\":2048") != null);
}

test "historyRetention transport: non-2xx response propagates as a typed error" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = try TransportMock.init(std.heap.page_allocator);
    defer mock.deinit(std.heap.page_allocator);
    // 500 maps to error.Http in mongreldb.mapStatus.
    mock.setResponse(500, "{\"error\":{\"message\":\"boom\"}}");

    var url_buf: [64]u8 = undefined;
    var db = mongreldb.Client.init(a, mock.url(&url_buf), .{});
    defer db.deinit();

    const result = db.historyRetention(a);
    try testing.expectError(error.Http, result);

    // 404 maps to error.NotFound (proves the status code is actually read,
    // not just any failure path).
    mock.setResponse(404, "not found: /history/retention");
    const result2 = db.setHistoryRetentionEpochs(a, 1);
    try testing.expectError(error.NotFound, result2);
}
