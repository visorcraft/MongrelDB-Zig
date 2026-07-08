//! mongreldb.transaction — batched, atomic transactions.
//!
//! A `Transaction` buffers a sequence of put and delete operations and flushes
//! them atomically in a single `/kit/txn` request. The builder methods return
//! the transaction so calls can be chained.

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

const mongreldb = @import("mongreldb.zig");
const Client = mongreldb.Client;
const Cell = mongreldb.Cell;
const Value = mongreldb.Value;
const Array = mongreldb.Array;
const ObjectMap = mongreldb.ObjectMap;
const Error = mongreldb.Error;

pub const Transaction = struct {
    client: *Client,
    allocator: Allocator,
    ops: Array,
    committed: bool = false,

    pub fn init(client: *Client, allocator: Allocator) Transaction {
        return .{
            .client = client,
            .allocator = allocator,
            .ops = Array.init(allocator),
        };
    }

    pub fn put(self: *Transaction, table: []const u8, cells: []const Cell, returning: bool) Error!*Transaction {
        if (self.committed) return error.AlreadyCommitted;

        var inner = ObjectMap.init(self.allocator);
        inner.put("table", .{ .string = table }) catch return error.OutOfMemory;
        inner.put("cells", .{ .array = try mongreldb.flattenCells(self.allocator, cells) }) catch return error.OutOfMemory;
        inner.put("returning", .{ .bool = returning }) catch return error.OutOfMemory;

        var op = ObjectMap.init(self.allocator);
        op.put("put", .{ .object = inner }) catch return error.OutOfMemory;

        self.ops.append(.{ .object = op }) catch return error.OutOfMemory;
        return self;
    }

    pub fn delete(self: *Transaction, table: []const u8, row_id: i64) Error!*Transaction {
        if (self.committed) return error.AlreadyCommitted;

        var inner = ObjectMap.init(self.allocator);
        inner.put("table", .{ .string = table }) catch return error.OutOfMemory;
        inner.put("row_id", .{ .integer = row_id }) catch return error.OutOfMemory;

        var op = ObjectMap.init(self.allocator);
        op.put("delete", .{ .object = inner }) catch return error.OutOfMemory;

        self.ops.append(.{ .object = op }) catch return error.OutOfMemory;
        return self;
    }

    pub fn deleteByPk(self: *Transaction, table: []const u8, pk: Value) Error!*Transaction {
        if (self.committed) return error.AlreadyCommitted;

        var inner = ObjectMap.init(self.allocator);
        inner.put("table", .{ .string = table }) catch return error.OutOfMemory;
        inner.put("pk", pk) catch return error.OutOfMemory;

        var op = ObjectMap.init(self.allocator);
        op.put("delete_by_pk", .{ .object = inner }) catch return error.OutOfMemory;

        self.ops.append(.{ .object = op }) catch return error.OutOfMemory;
        return self;
    }

    pub fn count(self: *Transaction) usize {
        return self.ops.items.len;
    }

    pub fn commit(self: *Transaction, idempotency_key: []const u8) Error!Array {
        if (self.committed) return error.AlreadyCommitted;
        self.committed = true;
        if (self.ops.items.len == 0) return Array.init(self.allocator);
        return self.client.commitTxn(self.allocator, self.ops, idempotency_key);
    }

    pub fn rollback(self: *Transaction) Error!void {
        if (self.committed) return error.AlreadyCommitted;
        self.committed = true;
        self.ops.clearAndFree();
    }
};
