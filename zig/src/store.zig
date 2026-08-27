//! SessionStore 接口与内建后端：内存（M0）。
//!
//! 语义对齐 Python 参照实现 src/apeiron/store.py（设计规格，不再演进）。
//! 分布式路线：PostgreSQL 等实现同一接口——(session_id, seq) 主键即 CAS，
//! append 冲突即单写者被破坏。M0 内建 MemoryStore；SQLite/Postgres 后续加入
//! （接口不变，只有实现换个 vtable）。
const std = @import("std");
const ent = @import("entries.zig");

pub const Entry = ent.Entry;
pub const SessionId = ent.SessionId;

pub const StoreError = error{
    OutOfMemory,
    SessionNotFound,
    SeqConflict,
};

/// 存储接口（vtable）：append 幂等性由 (session_id, seq) 约束保证；
/// entries 返回调用方持有的切片（用 allocator 释放切片本身；
/// 条目 payload 所有权归 store，调用方只读、不释放）。
pub const SessionStore = struct {
    ctx: *anyopaque,
    appendFn: *const fn (ctx: *anyopaque, entry: *const Entry) StoreError!void,
    entriesFn: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, session: SessionId, since_seq: u64) StoreError![]Entry,
    closeFn: *const fn (ctx: *anyopaque) void,

    pub fn append(self: *const SessionStore, entry: *const Entry) StoreError!void {
        return self.appendFn(self.ctx, entry);
    }

    pub fn entries(self: *const SessionStore, alloc: std.mem.Allocator, session: SessionId, since_seq: u64) StoreError![]Entry {
        return self.entriesFn(self.ctx, alloc, session, since_seq);
    }

    pub fn close(self: *const SessionStore) void {
        self.closeFn(self.ctx);
    }
};

pub const MemoryStore = struct {
    alloc: std.mem.Allocator,
    /// session -> 条目序列；key 为 session 的自有副本。
    logs: std.StringArrayHashMapUnmanaged(std.ArrayList(Entry)),

    pub fn init(alloc: std.mem.Allocator) MemoryStore {
        return .{ .alloc = alloc, .logs = .empty };
    }

    pub fn deinit(self: *MemoryStore) void {
        var it = self.logs.iterator();
        while (it.next()) |kv| {
            for (kv.value_ptr.items) |*e| ent.entryDeinit(self.alloc, e);
            kv.value_ptr.deinit(self.alloc);
            self.alloc.free(kv.key_ptr.*);
        }
        self.logs.deinit(self.alloc);
    }

    pub fn append(self: *MemoryStore, entry: *const Entry) StoreError!void {
        // 深拷贝 payload：store 拥有自己的副本（与日志/调用方解耦，互不 double-free）
        var copy = try self.dupEntry(entry);
        errdefer ent.entryDeinit(self.alloc, &copy);
        if (self.logs.getPtr(entry.session)) |log| {
            for (log.items) |existing| {
                if (existing.seq == entry.seq) return error.SeqConflict;
            }
            log.append(self.alloc, copy) catch return error.OutOfMemory;
            return;
        }
        const key = self.alloc.dupe(u8, entry.session) catch return error.OutOfMemory;
        errdefer self.alloc.free(key);
        var log: std.ArrayList(Entry) = .empty;
        errdefer log.deinit(self.alloc);
        log.append(self.alloc, copy) catch return error.OutOfMemory;
        self.logs.put(self.alloc, key, log) catch return error.OutOfMemory;
    }

    fn dupEntry(self: *MemoryStore, entry: *const Entry) !Entry {
        var copy = entry.*;
        copy.payload = try ent.payloadDup(self.alloc, entry.payload);
        return copy;
    }

    /// 返回条目深拷贝切片（payload 自有；调用方用 store.freeEntries 释放）。
    pub fn entries(self: *MemoryStore, alloc: std.mem.Allocator, session: SessionId, since_seq: u64) StoreError![]Entry {
        const log = self.logs.get(session) orelse return &[_]Entry{};
        var out: std.ArrayList(Entry) = .empty;
        errdefer out.deinit(alloc);
        for (log.items) |e| {
            if (e.seq > since_seq) {
                var copy = try self.dupEntry(&e);
                copy.session = session; // 借用：调用期间有效
                errdefer ent.entryDeinit(alloc, &copy);
                out.append(alloc, copy) catch return error.OutOfMemory;
            }
        }
        return out.toOwnedSlice(alloc) catch return error.OutOfMemory;
    }

    /// 释放 entries() 返回的切片（含 payload；session 为借用，不释放）。
    pub fn freeEntries(self: *MemoryStore, alloc: std.mem.Allocator, entries_slice: []Entry) void {
        _ = self;
        releaseEntries(alloc, entries_slice);
    }

    pub fn close(self: *MemoryStore) void {
        // 进程内后端：close 即释放；无外部资源
        self.deinit();
    }

    /// 适配为 SessionStore vtable。
    pub fn store(self: *MemoryStore) SessionStore {
        return .{
            .ctx = self,
            .appendFn = appendFn,
            .entriesFn = entriesFn,
            .closeFn = closeFn,
        };
    }

    fn appendFn(ctx: *anyopaque, entry: *const Entry) StoreError!void {
        const self: *MemoryStore = @ptrCast(@alignCast(ctx));
        return self.append(entry);
    }

    fn entriesFn(ctx: *anyopaque, alloc: std.mem.Allocator, session: SessionId, since_seq: u64) StoreError![]Entry {
        const self: *MemoryStore = @ptrCast(@alignCast(ctx));
        return self.entries(alloc, session, since_seq);
    }

    fn closeFn(ctx: *anyopaque) void {
        const self: *MemoryStore = @ptrCast(@alignCast(ctx));
        self.close();
    }
};

/// 模块级：释放任意后端 entries() 返回的切片（与后端无关的通用规则）。
/// 释放 payload（session 为借用，不释放）。
pub fn releaseEntries(alloc: std.mem.Allocator, entries_slice: []Entry) void {
    for (entries_slice) |*e| ent.entryDeinit(alloc, e);
    alloc.free(entries_slice);
}

fn makeEntry(alloc: std.mem.Allocator, session: SessionId, seq: u64) !Entry {
    const payload = try ent.payloadFromJson(alloc, "{}");
    return ent.newEntry(session, seq, null, .user, .user, payload);
}

test "memory: 追加、查询、since_seq、空会话" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemoryStore.init(a);
    defer mem.deinit();
    const s = mem.store();

    const e1 = try makeEntry(a, "s1", 1);
    try s.append(&e1);
    const e2 = try makeEntry(a, "s1", 2);
    try s.append(&e2);

    const all = try s.entries(a, "s1", 0);
    defer a.free(all);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqual(@as(u64, 1), all[0].seq);
    try std.testing.expectEqual(@as(u64, 2), all[1].seq);

    const tail = try s.entries(a, "s1", 1);
    defer a.free(tail);
    try std.testing.expectEqual(@as(usize, 1), tail.len);
    try std.testing.expectEqual(@as(u64, 2), tail[0].seq);

    const none = try s.entries(a, "s2", 0);
    defer a.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "memory: 相同 (session, seq) 冲突即单写者被破坏" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemoryStore.init(a);
    defer mem.deinit();
    const s = mem.store();

    const e1 = try makeEntry(a, "s1", 1);
    try s.append(&e1);
    const dup = try makeEntry(a, "s1", 1);
    try std.testing.expectError(error.SeqConflict, s.append(&dup));
}
