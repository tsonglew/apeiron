//! WASM 交互演示入口：浏览器里真实运行 harness 核心（演示即真相）。
//!
//! 导出 C ABI 函数供 JS 调用：
//!   demo_init()            初始化（静态 1MiB 内存上的 FixedBufferAllocator）
//!   demo_input_ptr()       返回静态输入缓冲区指针（JS 写入 UTF-8 消息）
//!   demo_set_input(len)    把输入缓冲区拷入会话消息
//!   demo_prompt()          跑一个 turn（脚本化 provider：echo 工具 + 收尾消息）
//!   demo_resume()          新会话同 id 从存储恢复（崩溃恢复语义演示）
//!   demo_result_ptr/len()  最近一次操作的 JSON 结果（静态缓冲，跨调用有效）
//!
//! 结果 JSON：
//!   prompt: {"entries":[...], "events":[{"event":..,"seq":..},...],
//!            "messages":[{"role":..,"content":..},...]}
//!   resume: {"entries":[...], "messages":[...]}
const std = @import("std");
const entries = @import("entries.zig");
const store = @import("store.zig");
const loop = @import("loop.zig");
const tools = @import("tools.zig");
const harness = @import("harness.zig");

var mem_bytes: [1024 * 1024]u8 align(16) = undefined;
var mem_fba: std.heap.FixedBufferAllocator = undefined;
var input_buf: [64 * 1024]u8 = undefined;
var input_len: usize = 0;

var result_buf: [256 * 1024]u8 = undefined;
var result_len: usize = 0;

// ---- 演示状态 ----
var dem_store: store.MemoryStore = undefined;
var dem_harness: harness.Harness = undefined;
var dem_session: harness.Session = undefined;
var dem_session_ready = false;
var script_step: usize = 0;

const ProviderState = struct { content: []const u8 };
var provider_state = ProviderState{ .content = "" };

fn aa() std.mem.Allocator {
    return mem_fba.allocator();
}

fn providerComplete(ctx: *anyopaque, alloc: std.mem.Allocator, messages: []const loop.Message, tool_defs: []const loop.Tool) anyerror!loop.LLMResponse {
    _ = ctx;
    _ = tool_defs;
    var last_user: []const u8 = "";
    for (messages) |m| {
        if (std.mem.eql(u8, m.role, "user")) last_user = m.content orelse "";
    }

    if (script_step == 0) {
        script_step += 1;
        var obj = std.json.ObjectMap{};
        try obj.put(alloc, try alloc.dupe(u8, "text"), .{ .string = try alloc.dupe(u8, last_user) });
        const calls = try alloc.alloc(loop.ToolCall, 1);
        calls[0] = .{
            .id = try alloc.dupe(u8, "t1"),
            .name = try alloc.dupe(u8, "echo"),
            .args = .{ .object = obj },
        };
        return .{ .tool_calls = calls };
    }
    return .{ .content = try std.fmt.allocPrint(alloc, "done: {s}", .{last_user}) };
}

const EvRec = struct {
    name: []const u8,
    seq: u64,
    count: ?usize = null,
};

fn collectEvent(ctx: ?*anyopaque, event: *const loop.Event) anyerror!void {
    const list: *std.ArrayList(EvRec) = @ptrCast(@alignCast(ctx.?));
    try list.append(aa(), .{ .name = @tagName(event.type), .seq = event.seq, .count = event.count });
}

// ---- JSON 辅助 ----

fn setResult(json: []const u8) void {
    const n = @min(json.len, result_buf.len);
    @memcpy(result_buf[0..n], json[0..n]);
    result_len = n;
}

fn putOwned(obj: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    try obj.put(aa(), try aa().dupe(u8, key), value);
}

fn buildEntries(alloc: std.mem.Allocator, items: []const entries.Entry) !std.json.Value {
    var list = std.array_list.Managed(std.json.Value).init(alloc);
    for (items) |e| try list.append(try entries.plainValue(e, alloc));
    return .{ .array = list };
}

fn buildEvents(alloc: std.mem.Allocator, items: []const EvRec) !std.json.Value {
    var list = std.array_list.Managed(std.json.Value).init(alloc);
    for (items) |item| {
        var obj = std.json.ObjectMap{};
        try putOwned(&obj, "event", .{ .string = item.name });
        try putOwned(&obj, "seq", .{ .integer = @intCast(item.seq) });
        if (item.count) |c| try putOwned(&obj, "count", .{ .integer = @intCast(c) });
        try list.append(.{ .object = obj });
    }
    return .{ .array = list };
}

fn buildMessages(alloc: std.mem.Allocator, items: []const loop.Message) !std.json.Value {
    var list = std.array_list.Managed(std.json.Value).init(alloc);
    for (items) |m| {
        var obj = std.json.ObjectMap{};
        try putOwned(&obj, "role", .{ .string = m.role });
        if (m.content) |c| try putOwned(&obj, "content", .{ .string = c });
        try list.append(.{ .object = obj });
    }
    return .{ .array = list };
}

fn emitResult(root: std.json.ObjectMap) void {
    const out = loop.jsonString(aa(), .{ .object = root }) catch {
        result_len = 0;
        return;
    };
    setResult(out);
}

// ---- 导出 API（callconv(.c)，JS 可直调） ----

export fn demo_init() void {
    mem_fba = std.heap.FixedBufferAllocator.init(&mem_bytes);
    provider_state = .{ .content = "" };
    dem_store = store.MemoryStore.init(aa());
    dem_harness = harness.Harness.init(
        aa(),
        dem_store.store(),
        .{ .ctx = &provider_state, .name = "demo", .completeFn = providerComplete },
        &.{tools.ECHO},
        .{},
    );
    dem_session_ready = false;
    result_len = 0;
}

export fn demo_input_ptr() [*]u8 {
    return &input_buf;
}

export fn demo_set_input(len: usize) void {
    input_len = @min(len, input_buf.len);
}

export fn demo_prompt() i32 {
    result_len = 0;
    script_step = 0;

    if (!dem_session_ready) {
        dem_session = dem_harness.createSession(aa(), "demo-session") catch return -1;
        dem_session_ready = true;
    }

    var ev_list: std.ArrayList(EvRec) = .empty;
    const result = dem_harness.prompt(&dem_session, input_buf[0..input_len], collectEvent, &ev_list) catch return -1;

    var root = std.json.ObjectMap{};
    putOwned(&root, "entries", buildEntries(aa(), result.new_entries) catch return -1) catch return -1;
    putOwned(&root, "events", buildEvents(aa(), ev_list.items) catch return -1) catch return -1;
    putOwned(&root, "messages", buildMessages(aa(), dem_session.messages.items) catch return -1) catch return -1;
    putOwned(&root, "seq", .{ .integer = @intCast(result.new_count) }) catch return -1;
    emitResult(root);
    return 0;
}

export fn demo_resume() i32 {
    result_len = 0;
    if (!dem_session_ready) return -1;

    var fresh = dem_harness.createSession(aa(), "demo-session") catch return -1;
    dem_harness.resumeSession(&fresh) catch return -1;

    var root = std.json.ObjectMap{};
    putOwned(&root, "entries", buildEntries(aa(), fresh.log.entriesSince(0)) catch return -1) catch return -1;
    putOwned(&root, "messages", buildMessages(aa(), fresh.messages.items) catch return -1) catch return -1;
    emitResult(root);
    return 0;
}

export fn demo_result_ptr() [*]const u8 {
    return &result_buf;
}

export fn demo_result_len() usize {
    return result_len;
}

// ---------------------------------------------------------- 测试 ---

const testing = std.testing;

test "demo: prompt->resume 核心语义（native 直测）" {
    demo_init();
    const msg = "hello wasm";
    @memcpy(input_buf[0..msg.len], msg);
    demo_set_input(msg.len);
    try testing.expectEqual(@as(i32, 0), demo_prompt());

    const text = demo_result_ptr()[0..demo_result_len()];
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(usize, 4), root.get("entries").?.array.items.len);
    const events = root.get("events").?.array;
    try testing.expectEqual(@as(usize, 5), events.items.len);
    try testing.expectEqualStrings("turn_start", events.items[0].object.get("event").?.string);
    try testing.expectEqualStrings("turn_end", events.items[4].object.get("event").?.string);

    // resume：新会话同 id 恢复，消息重建
    try testing.expectEqual(@as(i32, 0), demo_resume());
    const text2 = demo_result_ptr()[0..demo_result_len()];
    const parsed2 = try std.json.parseFromSlice(std.json.Value, testing.allocator, text2, .{});
    defer parsed2.deinit();
    const msgs = parsed2.value.object.get("messages").?.array;
    try testing.expectEqual(@as(usize, 4), msgs.items.len);
    try testing.expectEqualStrings("user", msgs.items[0].object.get("role").?.string);
    try testing.expectEqualStrings("done: hello wasm", msgs.items[3].object.get("content").?.string);
}
