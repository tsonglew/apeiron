//! 控制通道：steer / abort / approve 与主写路径分离。
//!
//! 语义对齐 Python 参照实现 src/apeiron/control.py（设计规格，不再演进）。
//! 本地实现是每会话一个 FIFO 队列；分布式后换成 Postgres LISTEN/NOTIFY 或
//! Redis Stream，Protocol（vtable）不变。主循环只在下一次安全边界
//! （turn 之间 / tool 之间）消费它。
//!
//! 所有权：send 移交 message 的所有权（队列持有）；receive 返回自有 Value，
//! 调用方用 entries.valueDeinit 释放。M0 的 receive 为非阻塞（空队列返回
//! null，对应 Python 超时返回 None；阻塞版由协议/分布式层提供）。
const std = @import("std");
const entries = @import("entries.zig");

pub const SessionId = entries.SessionId;

/// 控制通道接口：与主写路径分离，避免互锁。
pub const ControlChannel = struct {
    ctx: *anyopaque,
    sendFn: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, session: SessionId, message: std.json.Value) anyerror!void,
    receiveFn: *const fn (ctx: *anyopaque, session: SessionId) anyerror!?std.json.Value,

    pub fn send(self: *const ControlChannel, alloc: std.mem.Allocator, session: SessionId, message: std.json.Value) anyerror!void {
        return self.sendFn(self.ctx, alloc, session, message);
    }

    pub fn receive(self: *const ControlChannel, session: SessionId) anyerror!?std.json.Value {
        return self.receiveFn(self.ctx, session);
    }
};

pub const LocalChannel = struct {
    const Queue = struct {
        items: std.ArrayList(std.json.Value) = .empty,
        head: usize = 0,
    };

    alloc: std.mem.Allocator,
    /// session -> FIFO；key 为 allocator 副本。
    queues: std.StringArrayHashMapUnmanaged(Queue),

    pub fn init(alloc: std.mem.Allocator) LocalChannel {
        return .{ .alloc = alloc, .queues = .empty };
    }

    pub fn deinit(self: *LocalChannel) void {
        var it = self.queues.iterator();
        while (it.next()) |kv| {
            for (kv.value_ptr.items.items[kv.value_ptr.head..]) |*m| entries.valueDeinit(self.alloc, m);
            kv.value_ptr.items.deinit(self.alloc);
            self.alloc.free(kv.key_ptr.*);
        }
        self.queues.deinit(self.alloc);
    }

    pub fn send(self: *LocalChannel, alloc: std.mem.Allocator, session: SessionId, message: std.json.Value) anyerror!void {
        if (self.queues.getPtr(session)) |q| {
            try q.items.append(alloc, message);
            return;
        }
        const key = try alloc.dupe(u8, session);
        errdefer alloc.free(key);
        var q: Queue = .{};
        errdefer q.items.deinit(alloc);
        try q.items.append(alloc, message);
        try self.queues.put(alloc, key, q);
    }

    /// 非阻塞：空队列返回 null。返回的 Value 自有，调用方释放。
    pub fn receive(self: *LocalChannel, session: SessionId) anyerror!?std.json.Value {
        const q = self.queues.getPtr(session) orelse return null;
        if (q.head >= q.items.items.len) return null;
        const message = q.items.items[q.head];
        q.head += 1;
        // 队列排空后清零（保留容量，避免反复增长）
        if (q.head == q.items.items.len) {
            q.head = 0;
            q.items.clearRetainingCapacity();
        }
        return message;
    }

    pub fn channel(self: *LocalChannel) ControlChannel {
        return .{
            .ctx = self,
            .sendFn = sendFn,
            .receiveFn = receiveFn,
        };
    }

    fn sendFn(ctx: *anyopaque, alloc: std.mem.Allocator, session: SessionId, message: std.json.Value) anyerror!void {
        const self: *LocalChannel = @ptrCast(@alignCast(ctx));
        return self.send(alloc, session, message);
    }

    fn receiveFn(ctx: *anyopaque, session: SessionId) anyerror!?std.json.Value {
        const self: *LocalChannel = @ptrCast(@alignCast(ctx));
        return self.receive(session);
    }
};

const testing = std.testing;

fn jsonMsg(alloc: std.mem.Allocator, src: []const u8) !std.json.Value {
    return entries.payloadFromJson(alloc, src);
}

test "control: 发送/接收 FIFO 与跨会话隔离" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var chan = LocalChannel.init(a);
    defer chan.deinit();
    const ch = chan.channel();

    const m1 = try jsonMsg(a, "{\"op\":\"steer\",\"value\":\"a\"}");
    try ch.send(a, "s1", m1);
    const m2 = try jsonMsg(a, "{\"op\":\"steer\",\"value\":\"b\"}");
    try ch.send(a, "s1", m2);
    const m3 = try jsonMsg(a, "{\"op\":\"abort\"}");
    try ch.send(a, "s2", m3);

    var got = (try ch.receive("s1")).?;
    try testing.expectEqualStrings("steer", got.object.get("op").?.string);
    try testing.expectEqualStrings("a", got.object.get("value").?.string);
    entries.valueDeinit(a, &got);

    got = (try ch.receive("s1")).?;
    try testing.expectEqualStrings("b", got.object.get("value").?.string);
    entries.valueDeinit(a, &got);

    // s1 已清空 → null；s2 隔离
    try testing.expect((try ch.receive("s1")) == null);
    got = (try ch.receive("s2")).?;
    try testing.expectEqualStrings("abort", got.object.get("op").?.string);
    entries.valueDeinit(a, &got);
    try testing.expect((try ch.receive("s2")) == null);
    try testing.expect((try ch.receive("missing")) == null);
}
