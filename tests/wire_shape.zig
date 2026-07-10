//! Wire-shape conformance tests for the mongreldb Zig client.
//!
//! These tests are pure (no daemon required) - they serialize a `Column` via
//! `columnToJson`, stringify the result, and assert the exact keys + values
//! appear in the outgoing JSON body. They guard the T5.ZIG ergonomic
//! extension: adding `enum_variants` and `default_value` keys to the
//! per-column payload that `/kit/create_table` accepts. A future regression
//! that drops either key would silently break user schemas, so the wire
//! shape is asserted here rather than only on the server side.

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