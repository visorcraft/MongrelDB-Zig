//! mongreldb.query — fluent query builder.
//!
//! `QueryBuilder` pushes selection conditions down to the engine's native
//! indexes rather than pulling rows client-side. Chain conditions, projection,
//! and a limit, then call `execute`:
//!
//! ```zig
//! var q = db.query(arena.allocator(), "users");
//! _ = q.where("pk", .{ .value = mongreldb.intValue(1) });
//! _ = q.projection(&.{ 1, 2 });
//! _ = q.limit(10);
//! const result = try q.execute();
//! ```

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

const mongreldb = @import("mongreldb.zig");
const Client = mongreldb.Client;
const Value = mongreldb.Value;
const Array = mongreldb.Array;
const ObjectMap = mongreldb.ObjectMap;
const Error = mongreldb.Error;

/// `QueryBuilder` accumulates a single table query. Methods return the builder
/// for chaining.
pub const QueryBuilder = struct {
    client: *Client,
    allocator: Allocator,
    table: []const u8,
    conditions: Array,
    projection: Array,
    has_projection: bool = false,
    limit: ?i64 = null,
    truncated: bool = false,

    /// `init` creates a new builder for `table`.
    pub fn init(client: *Client, allocator: Allocator, table: []const u8) QueryBuilder {
        return .{
            .client = client,
            .allocator = allocator,
            .table = table,
            .conditions = Array.init(allocator),
            .projection = Array.init(allocator),
        };
    }

    /// `where` appends a condition. `cond_type` names the condition (e.g.
    /// "pk", "column_eq", "range", "fm_contains"); `params` is the condition
    /// payload, normalized as in the PHP/Go clients.
    pub fn where(self: *QueryBuilder, cond_type: []const u8, params: ObjectMap) Error!*QueryBuilder {
        const normalized = normalizeCondition(self.allocator, cond_type, params) catch return error.OutOfMemory;

        var cond = ObjectMap.init(self.allocator);
        cond.put(cond_type, .{ .object = normalized }) catch return error.OutOfMemory;

        self.conditions.append(.{ .object = cond }) catch return error.OutOfMemory;
        return self;
    }

    /// `projection` requests only the given column ids in each row.
    pub fn projection(self: *QueryBuilder, column_ids: []const i64) Error!*QueryBuilder {
        self.projection.clearRetainingCapacity();
        self.projection.ensureTotalCapacity(column_ids.len) catch return error.OutOfMemory;
        for (column_ids) |id| {
            self.projection.append(.{ .integer = id }) catch return error.OutOfMemory;
        }
        self.has_projection = true;
        return self;
    }

    /// `limit` caps the number of rows returned.
    pub fn limit(self: *QueryBuilder, row_limit: i64) Error!*QueryBuilder {
        self.limit = row_limit;
        return self;
    }

    /// `execute` builds the request, POSTs it to `/kit/query`, decodes the
    /// result set, records whether it was truncated, and returns the rows.
    pub fn execute(self: *QueryBuilder) Error!Array {
        var root = ObjectMap.init(self.allocator);
        root.put("table", .{ .string = self.table }) catch return error.OutOfMemory;
        if (self.conditions.items.len > 0) {
            root.put("conditions", .{ .array = self.conditions }) catch return error.OutOfMemory;
        }
        if (self.has_projection) {
            root.put("projection", .{ .array = self.projection }) catch return error.OutOfMemory;
        }
        if (self.limit) |lim| {
            root.put("limit", .{ .integer = lim }) catch return error.OutOfMemory;
        }

        const resp = try self.client.doPost(self.allocator, "/kit/query", .{ .object = root });
        const obj = switch (resp) {
            .object => |o| o,
            else => return error.Json,
        };
        self.truncated = if (obj.get("truncated")) |t| switch (t) {
            .bool => |b| b,
            else => false,
        } else false;
        const rows_val = obj.get("rows") orelse return Array.init(self.allocator);
        return switch (rows_val) {
            .array => |a| a,
            else => error.Json,
        };
    }

    /// `truncatedResult` reports whether the most recent `execute` was
    /// truncated by the server-side limit.
    pub fn truncatedResult(self: *QueryBuilder) bool {
        return self.truncated;
    }
};

/// `normalizeCondition` rewrites user-facing param names to the engine's
/// canonical condition fields. The column alias maps to `column_id`; range
/// bounds use `lo`/`hi` with inclusive flags; and `value` is renamed to
/// `pattern` for the `fm_contains` and `fm_contains_all` conditions only.
pub fn normalizeCondition(allocator: Allocator, cond_type: []const u8, params: ObjectMap) !ObjectMap {
    var out = ObjectMap.init(allocator);
    const fm_contains = std.mem.eql(u8, cond_type, "fm_contains") or
        std.mem.eql(u8, cond_type, "fm_contains_all");

    var it = params.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;

        var name: []const u8 = undefined;
        if (std.mem.eql(u8, key, "column")) {
            name = "column_id";
        } else if (std.mem.eql(u8, key, "min")) {
            name = "lo";
        } else if (std.mem.eql(u8, key, "max")) {
            name = "hi";
        } else if (std.mem.eql(u8, key, "min_inclusive")) {
            name = "lo_inclusive";
        } else if (std.mem.eql(u8, key, "max_inclusive")) {
            name = "hi_inclusive";
        } else if (fm_contains and std.mem.eql(u8, key, "value")) {
            name = "pattern";
        } else {
            name = key;
        }
        try out.put(name, val);
    }
    return out;
}
