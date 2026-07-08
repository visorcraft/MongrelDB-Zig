//! mongreldb.transaction — batched, atomic transactions.
//!
//! A `Transaction` buffers a sequence of put and delete operations and flushes
//! them atomically in a single `/kit/txn` request. The builder methods return
//! the transaction so calls can be chained:
//!
//! ```zig
//! var txn = db.begin(arena.allocator());
//! _ = try txn.put("users", &.{.{ .id = 1, .value = mongreldb.intValue(42) }}, false);
//! _ = try txn.deleteByPk("users", mongreldb.intValue(1));
//! try txn.commit("");
//! ```

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

/// `Transaction` stages operations in memory. Call `commit` to flush them to
/// the daemon, or `rollback` to discard them. Once committed the transaction
/// is frozen — any further use returns `error.AlreadyCommitted`.
pub const Transaction = struct {
    client: *Client,
    allocator: Allocator,
    ops: Array,
    committed: bool = false,

    /// `init` creates a fresh, empty transaction bound to `client`.
    pub fn init(client: *Client, allocator: Allocator) Transaction {
        return .{
            .client = client,
            .allocator = allocator,
            .ops = Array.init(allocator),
        };
    }

    /// `put` stages a row insert/update for `table` with the given `cells`.
    /// When `returning` is true, the committed result for this op includes the
    /// stored row. Returns the transaction for chaining.
    pub fn put(self: *Transaction, table: []const u8, cells: []const Cell, returning: bool) Error!*Transaction {
        if (self.committed) return error.AlreadyCommitted;

        var op = ObjectMap.init(self.allocator);
        op.put("table", .{ .string = table }) catch return error.OutOfMemory;
        op.put("cells", .{ .array = try mongreldb.flattenCells(self.allocator, cells) }) catch return error.OutOfMemory;
        op.put("returning", .{ .bool = returning }) catch return error.OutOfMemory;

        self.ops.append(.{ .object = op }) catch return error.OutOfMemory;
        return self;
    }

    /// `delete` stages a delete-by-row-id op.
    pub fn delete(self: *Transaction, table: []const u8, row_id: i64) Error!*Transaction {
        if (self.committed) return error.AlreadyCommitted;

        var op = ObjectMap.init(self.allocator);
        op.put("table", .{ .string = table }) catch return error.OutOfMemory;
        op.put("row_id", .{ .integer = row_id }) catch return error.OutOfMemory;

        self.ops.append(.{ .object = op }) catch return error.OutOfMemory;
        return self;
    }

    /// `deleteByPk` stages a delete-by-primary-key op.
    pub fn deleteByPk(self: *Transaction, table: []const u8, pk: Value) Error!*Transaction {
        if (self.committed) return error.AlreadyCommitted;

        var op = ObjectMap.init(self.allocator);
        op.put("table", .{ .string = table }) catch return error.OutOfMemory;
        op.put("pk", pk) catch return error.OutOfMemory;

        self.ops.append(.{ .object = op }) catch return error.OutOfMemory;
        return self;
    }

    /// `count` returns the number of staged operations.
    pub fn count(self: *Transaction) usize {
        return self.ops.items.len;
    }

    /// `commit` flushes the staged operations atomically. `idempotency_key`,
    /// if non-empty, makes the commit safe to retry — the daemon returns the
    /// original result on a duplicate commit. After a successful commit the
    /// transaction is frozen; further mutations return
    /// `error.AlreadyCommitted`. Returns the per-operation results (may be
    /// empty if the daemon omits them).
    pub fn commit(self: *Transaction, idempotency_key: []const u8) Error!Array {
        if (self.committed) return error.AlreadyCommitted;
        self.committed = true;
        if (self.ops.items.len == 0) return Array.init(self.allocator);
        return self.client.commitTxn(self.allocator, self.ops, idempotency_key);
    }

    /// `rollback` discards the staged operations and freezes the transaction.
    pub fn rollback(self: *Transaction) Error!void {
        if (self.committed) return error.AlreadyCommitted;
        self.committed = true;
        self.ops.clearAndFree();
    }
};
