//! 无状态 agent 循环：消息 -> LLM -> 工具执行 -> 回喂。
//!
//! 语义对齐 Python 参照实现 src/apeiron/loop.py（设计规格，不再演进）。
//! 本模块不持有状态（SessionLog 归调用方所有），因此可单测、可重放——
//! 这是「分布式」成立的前提：任何一个进程都能用同一份日志重演同一段交互。
//!
//! 所有权约定：
//! - ToolCall / Message / LLMResponse / 工具返回数据均为**自有**对象，deinit 释放；
//! - provider / 工具 handler 返回所有权，run_turn 消费后释放；
//! - Event 回调中的字段为**借用**视图，仅回调期间有效。
const std = @import("std");
const entries = @import("entries.zig");
const log_mod = @import("log.zig");

pub const Entry = entries.Entry;
pub const EntryId = entries.EntryId;
pub const EntryKind = entries.EntryKind;
pub const Author = entries.Author;

pub const DEFAULT_MAX_TOOL_ROUNDS: usize = 16;

// ---------------------------------------------------------------- 类型 ---

/// 工具权限分级（M1 接入审批流）。
pub const Permission = enum {
    read_only,
    needs_approval,
    dangerous,
};

pub const ToolError = error{
    ToolFailed,
    OutOfMemory,
};

/// 一个可调用工具。
/// - schema/name/description 为借用（生命周期 ≥ 工具本身）；
/// - handler 接收 args（借用）并返回**自有**数据（allocator 分配），
///   失败返回 error（run_turn 会把它落成 {"error": ...} 日志，不中断循环）。
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: std.json.Value,
    permission: Permission,
    handler_ctx: *anyopaque,
    handlerFn: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, args: std.json.Value) ToolError!std.json.Value,

    pub fn call(self: *const Tool, alloc: std.mem.Allocator, args: std.json.Value) ToolError!std.json.Value {
        return self.handlerFn(self.handler_ctx, alloc, args);
    }
};

/// 一次工具调用（自有所有权）。
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    args: std.json.Value,

    pub fn deinit(self: *ToolCall, alloc: std.mem.Allocator) void {
        entries.valueDeinit(alloc, &self.args);
        alloc.free(self.id);
        alloc.free(self.name);
    }
};

pub fn toolCallDup(alloc: std.mem.Allocator, src: ToolCall) !ToolCall {
    const id = try alloc.dupe(u8, src.id);
    errdefer alloc.free(id);
    const name = try alloc.dupe(u8, src.name);
    errdefer alloc.free(name);
    const args = try entries.payloadDup(alloc, src.args);
    return .{ .id = id, .name = name, .args = args };
}

/// 聊天消息（自有所有权；role/content/tool_call_id 均为 allocator 副本）。
pub const Message = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]ToolCall = null,
    tool_call_id: ?[]const u8 = null,

    pub fn deinit(self: *Message, alloc: std.mem.Allocator) void {
        if (self.content) |c| alloc.free(c);
        if (self.tool_call_id) |t| alloc.free(t);
        if (self.tool_calls) |tcs| {
            for (tcs) |*tc| tc.deinit(alloc);
            alloc.free(tcs);
        }
        alloc.free(self.role);
    }
};

pub fn messageDup(alloc: std.mem.Allocator, src: Message) !Message {
    const role = try alloc.dupe(u8, src.role);
    errdefer alloc.free(role);
    const content = if (src.content) |c| try alloc.dupe(u8, c) else null;
    errdefer if (content) |c| alloc.free(c);
    const tool_call_id = if (src.tool_call_id) |t| try alloc.dupe(u8, t) else null;
    errdefer if (tool_call_id) |t| alloc.free(t);
    const tool_calls = if (src.tool_calls) |tcs| blk: {
        const out = try alloc.alloc(ToolCall, tcs.len);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |*tc| tc.deinit(alloc);
            alloc.free(out);
        }
        for (tcs, 0..) |tc, i| {
            out[i] = try toolCallDup(alloc, tc);
            filled += 1;
        }
        break :blk out;
    } else null;
    return .{ .role = role, .content = content, .tool_calls = tool_calls, .tool_call_id = tool_call_id };
}

/// 模型提供方的一次响应（自有所有权；loop 消费后释放）。
pub const LLMResponse = struct {
    content: ?[]const u8 = null,
    tool_calls: ?[]ToolCall = null,
    usage: ?std.json.Value = null,

    pub fn deinit(self: *LLMResponse, alloc: std.mem.Allocator) void {
        if (self.content) |c| alloc.free(c);
        if (self.tool_calls) |tcs| {
            for (tcs) |*tc| tc.deinit(alloc);
            alloc.free(tcs);
        }
        if (self.usage) |*u| entries.valueDeinit(alloc, u);
    }
};

/// 模型提供方（M1 起做成插件槽：OpenAI 兼容端点 / Anthropic / 本地模型）。
pub const LLMProvider = struct {
    ctx: *anyopaque,
    name: []const u8,
    completeFn: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, messages: []const Message, tools: []const Tool) anyerror!LLMResponse,

    pub fn complete(self: *const LLMProvider, alloc: std.mem.Allocator, messages: []const Message, tools: []const Tool) anyerror!LLMResponse {
        return self.completeFn(self.ctx, alloc, messages, tools);
    }
};

// ---------------------------------------------------------------- 事件 ---

pub const EventType = enum {
    turn_start,
    tool_call,
    tool_result,
    message_end,
    turn_end,
};

pub const Event = struct {
    type: EventType,
    seq: u64,
    count: ?usize = null,
    name: ?[]const u8 = null,
    args: ?std.json.Value = null,
    data: ?std.json.Value = null,
};

/// 事件观察者（借用视图：仅回调期间有效）。
pub const EventFn = *const fn (ctx: ?*anyopaque, event: *const Event) anyerror!void;

// ---------------------------------------------------------------- 循环 ---

pub const TurnResult = struct {
    messages: []Message, // 自有；调用方逐个 deinit 后 free
    new_count: usize,

    pub fn deinit(self: *TurnResult, alloc: std.mem.Allocator) void {
        for (self.messages) |*m| m.deinit(alloc);
        alloc.free(self.messages);
    }
};

/// 追加消息到列表；失败时归还所有权，保证不泄漏。
fn pushMessage(alloc: std.mem.Allocator, out: *std.ArrayList(Message), m: Message) !void {
    out.append(alloc, m) catch |err| {
        var owned = m;
        owned.deinit(alloc);
        return err;
    };
}

/// 执行一次完整 turn：追加 user entry、循环 LLM+工具、返回新消息。
/// parent 链路：user -> tool_call -> tool_result -> ... -> assistant。
pub fn runTurn(
    alloc: std.mem.Allocator,
    log: *log_mod.SessionLog,
    prev_messages: []const Message,
    provider: *const LLMProvider,
    tools: []const Tool,
    text: []const u8,
    on_event: ?EventFn,
    on_event_ctx: ?*anyopaque,
    max_rounds: usize,
) anyerror!TurnResult {
    var messages_out: std.ArrayList(Message) = .empty;
    errdefer {
        for (messages_out.items) |*m| m.deinit(alloc);
        messages_out.deinit(alloc);
    }

    const start_len = log.len(); // 在追加 user entry 之前记录（new_count 含 user）

    // user entry + user message（历史消息深拷贝，结果与调用方解耦）
    const user_entry = try log.add(.user, .user, try objectContent(alloc, text), null);
    try pushMessage(alloc, &messages_out, try messageDup(alloc, .{ .role = "user", .content = text }));
    for (prev_messages) |m| try pushMessage(alloc, &messages_out, try messageDup(alloc, m));

    try emit(on_event, on_event_ctx, .{ .type = .turn_start, .seq = user_entry.seq });

    var done = false;
    var round: usize = 0;
    while (round < max_rounds and !done) : (round += 1) {
        var response = try provider.complete(alloc, messages_out.items, tools);
        defer response.deinit(alloc);

        if (response.tool_calls) |calls| {
            for (calls) |call| {
                const head = log.head();
                const call_entry = try log.add(.model, .tool_call, try toolCallPayload(alloc, call), if (head) |h| h.entry_id else null);
                try emit(on_event, on_event_ctx, .{ .type = .tool_call, .seq = call_entry.seq, .name = call.name, .args = call.args });

                // 工具失败也要落日志，不能带崩循环
                var data: std.json.Value = undefined;
                if (findTool(tools, call.name)) |tool| {
                    data = tool.call(alloc, call.args) catch |err| blk: {
                        const msg = try std.fmt.allocPrint(alloc, "ToolFailed: {s}", .{@errorName(err)});
                        defer alloc.free(msg);
                        break :blk try errValue(alloc, msg);
                    };
                } else {
                    const msg = try std.fmt.allocPrint(alloc, "unknown tool: {s}", .{call.name});
                    defer alloc.free(msg);
                    data = try errValue(alloc, msg);
                }
                defer entries.valueDeinit(alloc, &data);

                const result_entry = try log.add(.tool, .tool_result, try toolResultPayload(alloc, call.id, data), call_entry.entry_id);
                try emit(on_event, on_event_ctx, .{ .type = .tool_result, .seq = result_entry.seq, .data = data });

                // 回喂：assistant(tool_calls) + tool(result)
                var tc_view = [_]ToolCall{.{ .id = call.id, .name = call.name, .args = call.args }};
                try pushMessage(alloc, &messages_out, try messageDup(alloc, .{
                    .role = "assistant",
                    .tool_calls = tc_view[0..],
                }));
                const result_json = try jsonString(alloc, data);
                defer alloc.free(result_json);
                try pushMessage(alloc, &messages_out, try messageDup(alloc, .{
                    .role = "tool",
                    .tool_call_id = call.id,
                    .content = result_json,
                }));
            }
            continue;
        }

        const content = response.content orelse "";
        const head = log.head();
        const msg_entry = try log.add(.model, .assistant, try objectContent(alloc, content), if (head) |h| h.entry_id else null);
        try emit(on_event, on_event_ctx, .{ .type = .message_end, .seq = msg_entry.seq });
        try pushMessage(alloc, &messages_out, try messageDup(alloc, .{ .role = "assistant", .content = content }));
        done = true;
    }

    const new_count = log.len() - start_len;
    try emit(on_event, on_event_ctx, .{ .type = .turn_end, .seq = user_entry.seq, .count = new_count });
    return .{ .messages = try messages_out.toOwnedSlice(alloc), .new_count = new_count };
}

fn emit(on_event: ?EventFn, ctx: ?*anyopaque, event: Event) !void {
    if (on_event) |f| try f(ctx, &event);
}

fn findTool(tools: []const Tool, name: []const u8) ?*const Tool {
    for (tools) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// 把数据并入 tool_result payload：对象逐字段合并，否则挂到 "output"。
fn mergeData(alloc: std.mem.Allocator, obj: *std.json.ObjectMap, data: std.json.Value) !void {
    switch (data) {
        .object => |*src| {
            var it = src.iterator();
            while (it.next()) |kv| {
                const key = try alloc.dupe(u8, kv.key_ptr.*);
                errdefer alloc.free(key);
                const value = try entries.payloadDup(alloc, kv.value_ptr.*);
                try obj.put(alloc, key, value);
            }
        },
        else => {
            const key = try alloc.dupe(u8, "output");
            errdefer alloc.free(key);
            const value = try entries.payloadDup(alloc, data);
            try obj.put(alloc, key, value);
        },
    }
}

fn objectContent(alloc: std.mem.Allocator, content: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap{};
    errdefer obj.deinit(alloc);
    const key = try alloc.dupe(u8, "content");
    errdefer alloc.free(key);
    const value_owned = try alloc.dupe(u8, content);
    try obj.put(alloc, key, .{ .string = value_owned });
    return .{ .object = obj };
}

fn toolCallPayload(alloc: std.mem.Allocator, call: ToolCall) !std.json.Value {
    var obj = std.json.ObjectMap{};
    errdefer obj.deinit(alloc);
    const k1 = try alloc.dupe(u8, "tool_call_id");
    errdefer alloc.free(k1);
    try obj.put(alloc, k1, .{ .string = try alloc.dupe(u8, call.id) });
    const k2 = try alloc.dupe(u8, "name");
    errdefer alloc.free(k2);
    try obj.put(alloc, k2, .{ .string = try alloc.dupe(u8, call.name) });
    const k3 = try alloc.dupe(u8, "args");
    errdefer alloc.free(k3);
    try obj.put(alloc, k3, try entries.payloadDup(alloc, call.args));
    return .{ .object = obj };
}

fn toolResultPayload(alloc: std.mem.Allocator, call_id: []const u8, data: std.json.Value) !std.json.Value {
    var obj = std.json.ObjectMap{};
    errdefer obj.deinit(alloc);
    const k = try alloc.dupe(u8, "tool_call_id");
    errdefer alloc.free(k);
    try obj.put(alloc, k, .{ .string = try alloc.dupe(u8, call_id) });
    try mergeData(alloc, &obj, data);
    return .{ .object = obj };
}

fn errValue(alloc: std.mem.Allocator, msg: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap{};
    errdefer obj.deinit(alloc);
    const k = try alloc.dupe(u8, "error");
    errdefer alloc.free(k);
    try obj.put(alloc, k, .{ .string = try alloc.dupe(u8, msg) });
    return .{ .object = obj };
}

pub fn jsonString(alloc: std.mem.Allocator, v: std.json.Value) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, v, .{});
}

// ------------------------------------------------------- 历史重建 ---

/// 把历史 entries 重建为聊天消息（resume 用；M0 支持线性历史）。
pub fn messagesFromLog(alloc: std.mem.Allocator, entries_slice: []const Entry) ![]Message {
    var out: std.ArrayList(Message) = .empty;
    errdefer {
        for (out.items) |*m| m.deinit(alloc);
        out.deinit(alloc);
    }
    var pending: ?ToolCall = null;
    errdefer if (pending) |*p| p.deinit(alloc);

    for (entries_slice) |e| {
        switch (e.kind) {
            .user => try pushMessage(alloc, &out, try messageDup(alloc, .{
                .role = "user",
                .content = e.payload.object.get("content").?.string,
            })),
            .assistant => try pushMessage(alloc, &out, try messageDup(alloc, .{
                .role = "assistant",
                .content = e.payload.object.get("content").?.string,
            })),
            .tool_call => {
                if (pending) |*p| p.deinit(alloc);
                pending = try toolCallDup(alloc, .{
                    .id = e.payload.object.get("tool_call_id").?.string,
                    .name = e.payload.object.get("name").?.string,
                    .args = e.payload.object.get("args").?,
                });
            },
            .tool_result => {
                if (pending) |p| {
                    var tc_view = [_]ToolCall{p};
                    try pushMessage(alloc, &out, try messageDup(alloc, .{
                        .role = "assistant",
                        .tool_calls = tc_view[0..],
                    }));
                    pending = null;
                }
                const call_id = e.payload.object.get("tool_call_id").?.string;
                var data = try stripToolCallId(alloc, e.payload);
                defer entries.valueDeinit(alloc, &data);
                const content = try jsonString(alloc, data);
                defer alloc.free(content);
                try pushMessage(alloc, &out, try messageDup(alloc, .{
                    .role = "tool",
                    .tool_call_id = call_id,
                    .content = content,
                }));
            },
            else => {}, // summary / checkpoint：不进消息流
        }
    }
    return out.toOwnedSlice(alloc);
}

fn stripToolCallId(alloc: std.mem.Allocator, payload: std.json.Value) !std.json.Value {
    var obj = std.json.ObjectMap{};
    errdefer obj.deinit(alloc);
    const src = payload.object;
    var it = src.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key_ptr.*, "tool_call_id")) continue;
        const key = try alloc.dupe(u8, kv.key_ptr.*);
        errdefer alloc.free(key);
        const value = try entries.payloadDup(alloc, kv.value_ptr.*);
        try obj.put(alloc, key, value);
    }
    return .{ .object = obj };
}

// ---------------------------------------------------------- 测试 ---

const testing = std.testing;
const tools_mod = @import("tools.zig");

const FakeScript = struct {
    content: ?[]const u8 = null,
    call_name: ?[]const u8 = null,
    call_id: []const u8 = "t1",
    call_args: ?[]const u8 = null,
};

const FakeState = struct {
    script: []const FakeScript,
    idx: usize = 0,
};

fn fakeComplete(ctx: *anyopaque, alloc: std.mem.Allocator, messages: []const Message, tools: []const Tool) anyerror!LLMResponse {
    _ = messages;
    _ = tools;
    const s: *FakeState = @ptrCast(@alignCast(ctx));
    if (s.idx >= s.script.len) {
        return .{ .content = try alloc.dupe(u8, "done") };
    }
    const item = s.script[s.idx];
    s.idx += 1;
    if (item.call_name) |name| {
        const args = try entries.payloadFromJson(alloc, item.call_args orelse "{}");
        const calls = try alloc.alloc(ToolCall, 1);
        calls[0] = .{
            .id = try alloc.dupe(u8, item.call_id),
            .name = try alloc.dupe(u8, name),
            .args = args,
        };
        return .{ .tool_calls = calls };
    }
    return .{ .content = try alloc.dupe(u8, item.content orelse "done") };
}

const Collector = struct {
    alloc: std.mem.Allocator,
    list: *std.ArrayList(EventType),
};

fn collectEvents(ctx: ?*anyopaque, event: *const Event) !void {
    const c: *Collector = @ptrCast(@alignCast(ctx.?));
    try c.list.append(c.alloc, event.type);
}

test "runTurn: 工具回路后输出最终消息（含事件顺序）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var log = try log_mod.SessionLog.init(a, "s1");
    var seen: std.ArrayList(EventType) = .empty;
    var collector = Collector{ .alloc = a, .list = &seen };
    var state = FakeState{ .script = &.{
        .{ .call_name = "echo", .call_args = "{\"text\":\"hi\"}" },
        .{ .content = "done" },
    } };
    const provider: LLMProvider = .{ .ctx = &state, .name = "fake", .completeFn = fakeComplete };

    var result = try runTurn(a, &log, &.{}, &provider, &.{tools_mod.ECHO}, "say hi", collectEvents, &collector, DEFAULT_MAX_TOOL_ROUNDS);
    defer result.deinit(a);

    const all = log.entriesSince(0);
    try testing.expectEqual(@as(usize, 4), all.len);
    try testing.expectEqual(EntryKind.user, all[0].kind);
    try testing.expectEqual(EntryKind.tool_call, all[1].kind);
    try testing.expectEqual(EntryKind.tool_result, all[2].kind);
    try testing.expectEqual(EntryKind.assistant, all[3].kind);
    // tool_result payload: {tool_call_id, output}
    try testing.expectEqualStrings("t1", all[2].payload.object.get("tool_call_id").?.string);
    try testing.expectEqualStrings("hi", all[2].payload.object.get("output").?.string);
    // 消息流：最后一条是 assistant "done"
    try testing.expectEqualStrings("assistant", result.messages[result.messages.len - 1].role);
    try testing.expectEqualStrings("done", result.messages[result.messages.len - 1].content.?);
    // 事件顺序：turn_start, tool_call, tool_result, message_end, turn_end
    try testing.expectEqual(@as(usize, 5), seen.items.len);
    try testing.expectEqual(EventType.turn_start, seen.items[0]);
    try testing.expectEqual(EventType.tool_call, seen.items[1]);
    try testing.expectEqual(EventType.tool_result, seen.items[2]);
    try testing.expectEqual(EventType.message_end, seen.items[3]);
    try testing.expectEqual(EventType.turn_end, seen.items[4]);
}

test "runTurn: 未知工具落 error 结果，不中断循环" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var log = try log_mod.SessionLog.init(a, "s1");
    var state = FakeState{ .script = &.{
        .{ .call_name = "nope" },
        .{ .content = "ok" },
    } };
    const provider: LLMProvider = .{ .ctx = &state, .name = "fake", .completeFn = fakeComplete };

    var result = try runTurn(a, &log, &.{}, &provider, &.{tools_mod.ECHO}, "x", null, null, DEFAULT_MAX_TOOL_ROUNDS);
    defer result.deinit(a);

    const all = log.entriesSince(0);
    try testing.expectEqual(@as(usize, 4), all.len);
    // user, tool_call(nope), tool_result(error), assistant(ok)
    try testing.expect(all[2].payload.object.get("error") != null);
    try testing.expectEqual(EntryKind.assistant, all[3].kind);
}

test "runTurn: 工具失败落 error 结果" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var log = try log_mod.SessionLog.init(a, "s1");

    // 坏工具：handler 永远失败
    var marker: u8 = 0;
    const bad_tool = Tool{
        .name = "boom",
        .description = "always fails",
        .input_schema = .{ .object = std.json.ObjectMap{} },
        .permission = .read_only,
        .handler_ctx = &marker,
        .handlerFn = struct {
            fn f(ctx_: *anyopaque, alloc_: std.mem.Allocator, args: std.json.Value) ToolError!std.json.Value {
                _ = ctx_;
                _ = alloc_;
                _ = args;
                return error.ToolFailed;
            }
        }.f,
    };

    var state = FakeState{ .script = &.{
        .{ .call_name = "boom" },
        .{ .content = "ok" },
    } };
    const provider: LLMProvider = .{ .ctx = &state, .name = "fake", .completeFn = fakeComplete };

    var result = try runTurn(a, &log, &.{}, &provider, &.{bad_tool}, "x", null, null, DEFAULT_MAX_TOOL_ROUNDS);
    defer result.deinit(a);

    const all = log.entriesSince(0);
    try testing.expectEqual(@as(usize, 4), all.len);
    try testing.expect(all[2].payload.object.get("error") != null);
}

test "messagesFromLog: 由日志重建聊天" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var log = try log_mod.SessionLog.init(a, "s1");

    // 手工构造 user -> tool_call -> tool_result（无 assistant：模拟未完成 turn）
    _ = try log.add(.user, .user, .{ .object = blk: {
        var obj = std.json.ObjectMap{};
        const k = try a.dupe(u8, "content");
        try obj.put(a, k, .{ .string = try a.dupe(u8, "go") });
        break :blk obj;
    } }, null);
    _ = try log.add(.model, .tool_call, .{ .object = blk: {
        var obj = std.json.ObjectMap{};
        const k1 = try a.dupe(u8, "tool_call_id");
        try obj.put(a, k1, .{ .string = try a.dupe(u8, "t1") });
        const k2 = try a.dupe(u8, "name");
        try obj.put(a, k2, .{ .string = try a.dupe(u8, "echo") });
        const args = try entries.payloadFromJson(a, "{\"text\":\"hi\"}");
        const k3 = try a.dupe(u8, "args");
        try obj.put(a, k3, args);
        break :blk obj;
    } }, null);
    _ = try log.add(.tool, .tool_result, .{ .object = blk: {
        var obj = std.json.ObjectMap{};
        const k1 = try a.dupe(u8, "tool_call_id");
        try obj.put(a, k1, .{ .string = try a.dupe(u8, "t1") });
        const k2 = try a.dupe(u8, "output");
        try obj.put(a, k2, .{ .string = try a.dupe(u8, "hi") });
        break :blk obj;
    } }, null);

    const rebuilt = try messagesFromLog(a, log.entriesSince(0));
    try testing.expectEqual(@as(usize, 3), rebuilt.len);
    try testing.expectEqualStrings("user", rebuilt[0].role);
    try testing.expectEqualStrings("go", rebuilt[0].content.?);
    try testing.expectEqualStrings("assistant", rebuilt[1].role);
    try testing.expectEqualStrings("echo", rebuilt[1].tool_calls.?[0].name);
    try testing.expectEqualStrings("tool", rebuilt[2].role);
    try testing.expectEqualStrings("t1", rebuilt[2].tool_call_id.?);
    try testing.expectEqualStrings("{\"output\":\"hi\"}", rebuilt[2].content.?);
}
