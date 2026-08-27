//! 评测：headless 运行 + trace 落盘（model-visible means logged）。
//!
//! 语义对齐 Python 参照实现 src/apeiron/eval.py（设计规格，不再演进）。
//! M0 只有 TraceWriter + runHeadless；M1 补四指标（turns/token/耗时/成本）
//! 与 trace 回放（换 provider 重演同一条 trace，对比行为）。
//! 所有权：runHeadless 返回深拷贝的 []Entry（payload 自有，session 借用），
//! 调用方用 store.releaseEntries 释放。
//! IO：Zig 0.16 使用 std.Io 句柄模型（调用方提供 Io/Dir；测试传 std.testing.io）。
const std = @import("std");
const entries = @import("entries.zig");
const harness = @import("harness.zig");
const loop = @import("loop.zig");
const store_mod = @import("store.zig");

pub const Entry = entries.Entry;

/// trace 目标：目录 + 文件名（相对 dir）。
pub const TraceTarget = struct {
    dir: std.Io.Dir,
    name: []const u8,
};

/// JSONL 追加写入器。每个可观察事件一行，是审计与回放的数据底座。
/// M0 直接写文件（写即落盘，无内部缓冲）；close 后不得再 write。
pub const TraceWriter = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8, // 自有副本
    file: std.Io.File,
    open: bool,

    pub fn create(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !TraceWriter {
        const file = try std.Io.Dir.createFile(dir, io, name, .{});
        errdefer std.Io.File.close(file, io);
        return .{
            .alloc = alloc,
            .io = io,
            .dir = dir,
            .name = try alloc.dupe(u8, name),
            .file = file,
            .open = true,
        };
    }

    pub fn close(self: *TraceWriter) void {
        if (self.open) {
            std.Io.File.close(self.file, self.io);
            self.open = false;
        }
    }

    pub fn deinit(self: *TraceWriter) void {
        self.close();
        self.alloc.free(self.name);
    }

    /// 写一行 JSONL（record 为借用视图：本调用内被 stringify，不取所有权）。
    pub fn write(self: *TraceWriter, record: std.json.Value) !void {
        if (!self.open) return error.TraceWriterClosed;
        const line = try loop.jsonString(self.alloc, record);
        defer self.alloc.free(line);
        try std.Io.File.writeStreamingAll(self.file, self.io, line);
        try std.Io.File.writeStreamingAll(self.file, self.io, "\n");
    }
};

/// 无 UI 跑一条任务：新建会话 -> prompt -> 返回 entries（深拷贝）；可同时落 trace。
/// session 在函数内创建并被丢弃，因此 entries 必须深拷贝返回。
pub fn runHeadless(
    alloc: std.mem.Allocator,
    io: std.Io,
    h: *harness.Harness,
    message: []const u8,
    trace: ?TraceTarget,
) anyerror![]Entry {
    var session = try h.createSession(alloc, null);
    defer session.deinit();

    const result = if (trace) |t| blk: {
        var writer = try TraceWriter.create(alloc, io, t.dir, t.name);
        defer writer.deinit();
        var trace_ctx = TraceCtx{ .writer = &writer, .session_id = session.session_id };
        break :blk try h.prompt(&session, message, traceEventFn, &trace_ctx);
    } else try h.prompt(&session, message, null, null);

    // 深拷贝后返回（session 即将销毁）
    const out = try alloc.alloc(Entry, result.new_entries.len);
    errdefer {
        for (out) |*e| entries.entryDeinit(alloc, e);
        alloc.free(out);
    }
    for (result.new_entries, 0..) |e, i| {
        var copy = e;
        copy.payload = try entries.payloadDup(alloc, e.payload);
        out[i] = copy;
    }
    return out;
}

const TraceCtx = struct {
    writer: *TraceWriter,
    session_id: []const u8,
};

fn traceEventFn(ctx: ?*anyopaque, event: *const loop.Event) anyerror!void {
    const t: *TraceCtx = @ptrCast(@alignCast(ctx.?));
    var record = try eventRecord(t.writer.alloc, t.session_id, event);
    defer entries.valueDeinit(t.writer.alloc, &record);
    try t.writer.write(record);
}

fn eventRecord(alloc: std.mem.Allocator, session_id: []const u8, event: *const loop.Event) !std.json.Value {
    var obj = std.json.ObjectMap{};
    errdefer obj.deinit(alloc);
    try obj.put(alloc, try alloc.dupe(u8, "type"), .{ .string = try alloc.dupe(u8, "event") });
    try obj.put(alloc, try alloc.dupe(u8, "session"), .{ .string = try alloc.dupe(u8, session_id) });
    try obj.put(alloc, try alloc.dupe(u8, "event"), .{ .string = try alloc.dupe(u8, @tagName(event.type)) });
    try obj.put(alloc, try alloc.dupe(u8, "seq"), .{ .integer = @intCast(event.seq) });
    if (event.count) |c| try obj.put(alloc, try alloc.dupe(u8, "count"), .{ .integer = @intCast(c) });
    if (event.name) |n| try obj.put(alloc, try alloc.dupe(u8, "name"), .{ .string = try alloc.dupe(u8, n) });
    if (event.args) |args| try obj.put(alloc, try alloc.dupe(u8, "args"), try entries.payloadDup(alloc, args));
    if (event.data) |data| try obj.put(alloc, try alloc.dupe(u8, "data"), try entries.payloadDup(alloc, data));
    return .{ .object = obj };
}

// ---------------------------------------------------------- 测试 ---

const testing = std.testing;

const FakeState = struct { content: []const u8 };

fn fakeHello(ctx: *anyopaque, alloc: std.mem.Allocator, messages: []const loop.Message, tools: []const loop.Tool) anyerror!loop.LLMResponse {
    _ = messages;
    _ = tools;
    const s: *FakeState = @ptrCast(@alignCast(ctx));
    return .{ .content = try alloc.dupe(u8, s.content) };
}

test "TraceWriter: JSONL 往返" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var writer = try TraceWriter.create(a, testing.io, tmp.dir, "trace.jsonl");
        const rec1 = try entries.payloadFromJson(a, "{\"type\":\"event\",\"event\":\"turn_start\",\"seq\":1}");
        try writer.write(rec1);
        const rec2 = try entries.payloadFromJson(a, "{\"type\":\"event\",\"event\":\"turn_end\",\"count\":2}");
        try writer.write(rec2);
        writer.deinit();
    }

    const text = try tmp.dir.readFileAlloc(testing.io, "trace.jsonl", a, .unlimited);
    var lines = std.mem.splitScalar(u8, text, '\n');
    try testing.expectEqualStrings("{\"type\":\"event\",\"event\":\"turn_start\",\"seq\":1}", lines.next().?);
    try testing.expectEqualStrings("{\"type\":\"event\",\"event\":\"turn_end\",\"count\":2}", lines.next().?);
}

test "runHeadless: trace 落盘 + 事件行数 + entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var mem = store_mod.MemoryStore.init(a);
    var state = FakeState{ .content = "hello" };
    const provider: loop.LLMProvider = .{ .ctx = &state, .name = "fake", .completeFn = fakeHello };
    var h = harness.Harness.init(a, mem.store(), provider, &.{}, .{});
    defer h.deinit();

    const out = try runHeadless(a, testing.io, &h, "hi", .{ .dir = tmp.dir, .name = "headless.jsonl" });
    defer store_mod.releaseEntries(a, out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(entries.EntryKind.user, out[0].kind);
    try testing.expectEqual(entries.EntryKind.assistant, out[1].kind);

    // trace 里有 5 种事件（turn_start/tool 场景未发生：turn_start, message_end, turn_end 计 3？
    // 参照实现语义：无工具时事件为 turn_start, message_end, turn_end —— 验证行数
    const text = try tmp.dir.readFileAlloc(testing.io, "headless.jsonl", a, .unlimited);
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "runHeadless: 无 trace 路径" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = store_mod.MemoryStore.init(a);
    var state = FakeState{ .content = "ok" };
    const provider: loop.LLMProvider = .{ .ctx = &state, .name = "fake", .completeFn = fakeHello };
    var h = harness.Harness.init(a, mem.store(), provider, &.{}, .{});
    defer h.deinit();

    const out = try runHeadless(a, testing.io, &h, "hi", null);
    defer store_mod.releaseEntries(a, out);
    try testing.expectEqual(@as(usize, 2), out.len);
}
