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
