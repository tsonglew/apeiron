//! 进程内会话日志：追加 + 查询 + 快照。
//!
//! 语义对齐 Python 参照实现 src/apeiron/log.py（设计规格，不再演进）。
//! 存储层之外的唯一内存状态；持久化由 store.SessionStore 承担。
//! 所有权：add/restore 移交 Entry 所有权；deinit 递归释放全部。
const std = @import("std");
const entries = @import("entries.zig");

pub const Author = entries.Author;
pub const Entry = entries.Entry;
pub const EntryId = entries.EntryId;
pub const EntryKind = entries.EntryKind;
pub const SessionId = entries.SessionId;

/// 压缩边界：last_seq 之后的 Entry 需要从存储重放。
pub const Snapshot = struct {
    last_seq: u64,
    summary: ?std.json.Value = null,
};

pub const SessionLog = struct {
    alloc: std.mem.Allocator,
    session: SessionId, // 自有副本
    list: std.ArrayList(Entry), // 无管理器（unmanaged，方法带 allocator）
    by_id: std.AutoHashMapUnmanaged(EntryId, usize),

    pub fn init(alloc: std.mem.Allocator, session: SessionId) !SessionLog {
        return .{
            .alloc = alloc,
            .session = try alloc.dupe(u8, session),
            .list = .empty,
            .by_id = .{},
        };
    }

    pub fn deinit(self: *SessionLog) void {
        for (self.list.items) |*e| entries.entryDeinit(self.alloc, e);
        self.list.deinit(self.alloc);
        self.by_id.deinit(self.alloc);
        self.alloc.free(self.session);
    }

    /// 追加一条 entry；parent_id 缺省指向当前 head。seq = 现有长度 + 1（1-based）。
    pub fn add(self: *SessionLog, author: Author, kind: EntryKind, payload: std.json.Value, parent_id: ?EntryId) !Entry {
        var pid = parent_id;
        if (pid == null) {
            if (self.head()) |h| pid = h.entry_id;
        }
        const entry = entries.newEntry(self.session, self.list.items.len + 1, pid, author, kind, payload);
        var entry_copy = entry;
        const idx = self.list.items.len;
        errdefer entries.entryDeinit(self.alloc, &entry_copy);
        try self.list.append(self.alloc, entry_copy);
        try self.by_id.put(self.alloc, entry_copy.entry_id, idx);
        return entry_copy;
    }

    pub fn head(self: *const SessionLog) ?Entry {
        if (self.list.items.len == 0) return null;
        return self.list.items[self.list.items.len - 1];
    }

    pub fn len(self: *const SessionLog) usize {
        return self.list.items.len;
    }

    /// seq > since_seq 的尾部视图（seq 单调，故无需分配）。
    pub fn entriesSince(self: *const SessionLog, since_seq: u64) []const Entry {
        var i: usize = 0;
        while (i < self.list.items.len and self.list.items[i].seq <= since_seq) : (i += 1) {}
        return self.list.items[i..];
    }

    pub fn find(self: *const SessionLog, entry_id: EntryId) ?*const Entry {
        const idx = self.by_id.get(entry_id) orelse return null;
        return &self.list.items[idx];
    }

    pub fn snapshot(self: *const SessionLog) Snapshot {
        return .{ .last_seq = if (self.head()) |h| h.seq else 0 };
    }

    /// 从存储回放：要求按 seq 升序且属于同一会话。条目所有权移交本日志。
    /// session 引用统一重写为本日志的自有副本（存储返回的拷贝可安全转交）。
    pub fn restore(self: *SessionLog, restored: []const Entry) !void {
        for (restored) |e| {
            if (!std.mem.eql(u8, e.session, self.session)) return error.SessionMismatch;
            if (self.list.items.len > 0 and e.seq <= self.list.items[self.list.items.len - 1].seq)
                return error.SeqNotAscending;
            var owned = e;
            owned.session = self.session;
            const idx = self.list.items.len;
            try self.list.append(self.alloc, owned);
            try self.by_id.put(self.alloc, owned.entry_id, idx);
        }
    }
};

test "add: seq 递增、parent 指向 head" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var log = try SessionLog.init(a, "s1");
    const payload_a = try entries.payloadFromJson(a, "{\"content\":\"x\"}");
    const pa = try log.add(.user, .user, payload_a, null);
    const payload_b = try entries.payloadFromJson(a, "{\"content\":\"y\"}");
    const pb = try log.add(.model, .assistant, payload_b, null);

    try std.testing.expectEqual(@as(u64, 1), pa.seq);
    try std.testing.expectEqual(@as(u64, 2), pb.seq);
    try std.testing.expectEqual(pa.entry_id, pb.parent_id.?);
    try std.testing.expectEqual(@as(usize, 1), log.entriesSince(1).len);
    try std.testing.expect(log.find(pb.entry_id) != null);
    try std.testing.expectEqual(@as(u64, 2), log.snapshot().last_seq);
}

test "restore: 会话校验与 seq 升序" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var src = try SessionLog.init(a, "s1");
    const p1 = try entries.payloadFromJson(a, "{\"n\":1}");
    _ = try src.add(.user, .user, p1, null);
    const p2 = try entries.payloadFromJson(a, "{\"n\":2}");
    _ = try src.add(.user, .user, p2, null);

    // 还原：把 src 的条目浅拷贝到新日志（借用；此处只验证语义）
    var dst = try SessionLog.init(a, "s1");
    try dst.restore(src.list.items);
    try std.testing.expectEqual(@as(usize, 2), dst.list.items.len);
    try std.testing.expectEqual(@as(u64, 2), dst.snapshot().last_seq);

    // 会话不匹配 → SessionMismatch
    var other = try SessionLog.init(a, "s2");
    try std.testing.expectError(error.SessionMismatch, other.restore(src.list.items));
}
