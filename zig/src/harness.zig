//! 编排层：session 生命周期、phase 状态机、hook 与 save point。
//!
//! 语义对齐 Python 参照实现 src/apeiron/harness.py（设计规格，不再演进）。
//! 一次 turn 的安全边界：IDLE -> TURN ->（save point）-> IDLE。
//! M0 的 save point 是「turn 结束后批量落盘」；M1 起细化成 pi 式
//! pending writes 在多个边界 flush，崩溃后从 last_seq 重放即可。
const std = @import("std");
const entries = @import("entries.zig");
const log_mod = @import("log.zig");
const loop = @import("loop.zig");
const store_mod = @import("store.zig");

pub const Entry = entries.Entry;
pub const SessionId = entries.SessionId;

pub const Phase = enum {
    idle,
    turn,
    compact,
    aborted,
};

/// 会话非空闲时收到 prompt（对应 pi 的 LaneBusy）。
pub const HarnessError = error{
    HarnessBusy,
    OutOfMemory,
};

pub const HookFn = *const fn (ctx: ?*anyopaque, session_id: []const u8) anyerror!void;

pub const Hook = struct {
    ctx: ?*anyopaque = null,
    f: HookFn,

    pub fn invoke(self: Hook, session_id: []const u8) anyerror!void {
        return self.f(self.ctx, session_id);
    }
};

pub const Hooks = struct {
    before_turn: ?Hook = null,
    after_turn: ?Hook = null,
    on_save_point: ?Hook = null,
};

pub const Session = struct {
    alloc: std.mem.Allocator,
    session_id: SessionId, // 借用：指向 log.session（log 持有的副本）
    log: log_mod.SessionLog,
    messages: std.ArrayList(loop.Message),
    phase: Phase = .idle,

    pub fn init(alloc: std.mem.Allocator, session_id: SessionId) !Session {
        const log = try log_mod.SessionLog.init(alloc, session_id);
        return .{
            .alloc = alloc,
            .session_id = log.session,
            .log = log,
            .messages = .empty,
        };
    }

    pub fn deinit(self: *Session) void {
        for (self.messages.items) |*m| m.deinit(self.alloc);
        self.messages.deinit(self.alloc);
        self.log.deinit();
    }
};

pub const PromptResult = struct {
    new_entries: []const Entry, // 借用：属于 session.log
    new_count: usize,
};

pub const Harness = struct {
    alloc: std.mem.Allocator,
    store: store_mod.SessionStore,
    provider: loop.LLMProvider,
    tools: []const loop.Tool,
    hooks: Hooks,
    /// session_id -> 已落盘的最大 seq（key 为 allocator 副本）。
    persisted: std.StringArrayHashMapUnmanaged(u64),

    pub fn init(
        alloc: std.mem.Allocator,
        store: store_mod.SessionStore,
        provider: loop.LLMProvider,
        tools: []const loop.Tool,
        hooks: Hooks,
    ) Harness {
        return .{
            .alloc = alloc,
            .store = store,
            .provider = provider,
            .tools = tools,
            .hooks = hooks,
            .persisted = .empty,
        };
    }

    pub fn deinit(self: *Harness) void {
        var it = self.persisted.iterator();
        while (it.next()) |kv| self.alloc.free(kv.key_ptr.*);
        self.persisted.deinit(self.alloc);
    }

    /// 创建会话；传 session_id 用于「恢复到指定会话」；缺省生成 uuid4 hex。
    pub fn createSession(self: *Harness, alloc: std.mem.Allocator, session_id: ?SessionId) !Session {
        _ = self;
        if (session_id) |sid| return Session.init(alloc, sid);
        const sid_buf = entries.newEntryId();
        return Session.init(alloc, &sid_buf);
    }

    /// 执行一次 turn：busy 守卫 -> before_turn -> run_turn -> save_point -> after_turn。
    /// 任何失败（含取消）都把 phase 复位为 IDLE——恢复靠存储重放，内存状态随时可扔。
    pub fn prompt(
        self: *Harness,
        session: *Session,
        message: []const u8,
        on_event: ?loop.EventFn,
        on_event_ctx: ?*anyopaque,
    ) anyerror!PromptResult {
        if (session.phase != .idle) return error.HarnessBusy;
        session.phase = .turn;
        errdefer { if (session.phase == .turn) session.phase = .idle; }

        if (self.hooks.before_turn) |h| try h.invoke(session.session_id);

        // run_turn 与参照实现同构（Zig 侧同步接口；IO 型工具后续经线程池）
        var turn = try loop.runTurn(
            self.alloc,
            &session.log,
            session.messages.items,
            &self.provider,
            self.tools,
            message,
            on_event,
            on_event_ctx,
            loop.DEFAULT_MAX_TOOL_ROUNDS,
        );
        errdefer turn.deinit(self.alloc);

        const before_len = session.log.len() - turn.new_count;

        // 换装新消息（旧消息释放）
        for (session.messages.items) |*m| m.deinit(self.alloc);
        session.messages.deinit(self.alloc);
        session.messages = .empty;
        session.messages.appendSlice(self.alloc, turn.messages) catch return error.OutOfMemory;
        turn.messages = &.{}; // 所有权已移交 session.messages

        try self.savePoint(session);

        if (self.hooks.after_turn) |h| try h.invoke(session.session_id);

        session.phase = .idle;
        const new_entries = session.log.entriesSince(0)[before_len..];
        return .{ .new_entries = new_entries, .new_count = new_entries.len };
    }

    /// 把未落盘的 entries 批量写进存储（M0 粒度：turn 级）。
    pub fn savePoint(self: *Harness, session: *Session) anyerror!void {
        const since = self.persisted.get(session.session_id) orelse 0;
        const pending = session.log.entriesSince(since);
        for (pending) |*e| {
            try self.store.append(e);
        }
        const last_seq = if (session.log.head()) |h| h.seq else 0;

        const gop = self.persisted.getOrPut(self.alloc, session.session_id) catch return error.OutOfMemory;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.alloc.dupe(u8, session.session_id) catch return error.OutOfMemory;
            gop.value_ptr.* = last_seq;
        } else {
            gop.value_ptr.* = last_seq;
        }

        if (self.hooks.on_save_point) |h| try h.invoke(session.session_id);
    }

    /// 从存储把内存日志 head 之后的 entries 重放进来并重建 messages。
    /// 空日志即全量重放（恢复场景）；已有日志只补 tail（幂等）。
    /// 后续 M2 改为 snapshot + tail：先从快照恢复 last_seq，再取增量。
    pub fn resumeSession(self: *Harness, session: *Session) anyerror!void {
        const head = session.log.head();
        const since = if (head) |h| h.seq else 0;
        const stored = try self.store.entries(self.alloc, session.session_id, since);
        errdefer store_mod.releaseEntries(self.alloc, stored);
        try session.log.restore(stored); // 所有权移交 log（含 payload）

        // 重建消息
        for (session.messages.items) |*m| m.deinit(self.alloc);
        session.messages.deinit(self.alloc);
        session.messages = .empty;
        const rebuilt = try loop.messagesFromLog(self.alloc, session.log.entriesSince(0));
        session.messages.appendSlice(self.alloc, rebuilt) catch return error.OutOfMemory;

        const last_seq = if (session.log.head()) |h| h.seq else 0;
        const gop = self.persisted.getOrPut(self.alloc, session.session_id) catch return error.OutOfMemory;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.alloc.dupe(u8, session.session_id) catch return error.OutOfMemory;
        }
        gop.value_ptr.* = last_seq;
    }

    pub fn abort(self: *Harness, session: *Session) void {
        _ = self;
        session.phase = .aborted;
    }
};

// ------------------------------------------------------------- 测试 ---

const testing = std.testing;

const FakeState = struct {
    content: []const u8 = "hello",
};

fn fakeHello(ctx: *anyopaque, alloc: std.mem.Allocator, messages: []const loop.Message, tools: []const loop.Tool) anyerror!loop.LLMResponse {
    _ = messages;
    _ = tools;
    const s: *FakeState = @ptrCast(@alignCast(ctx));
    return .{ .content = try alloc.dupe(u8, s.content) };
}

const tools_mod = @import("tools.zig");

test "prompt: 落盘 + 恢复重建消息" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = store_mod.MemoryStore.init(a);
    defer mem.deinit();
    var state = FakeState{};
    const provider: loop.LLMProvider = .{ .ctx = &state, .name = "fake", .completeFn = fakeHello };
    var harness = Harness.init(a, mem.store(), provider, &.{tools_mod.ECHO}, .{});
    defer harness.deinit();

    var session = try harness.createSession(a, "s1");

    const result = try harness.prompt(&session, "hi", null, null);
    try testing.expectEqual(@as(usize, 2), result.new_count);
    try testing.expectEqual(entries.EntryKind.user, result.new_entries[0].kind);
    try testing.expectEqual(entries.EntryKind.assistant, result.new_entries[1].kind);
    try testing.expectEqual(Phase.idle, session.phase);

    // 存储里应有 seq 1,2
    const stored = try mem.entries(a, "s1", 0);
    defer store_mod.releaseEntries(a, stored);
    try testing.expectEqual(@as(usize, 2), stored.len);
    try testing.expectEqual(@as(u64, 1), stored[0].seq);
    try testing.expectEqual(@as(u64, 2), stored[1].seq);

    // 新会话（同 ID）resume：从存储重放，重建完全一样的聊天消息
    var fresh = try harness.createSession(a, "s1");
    try harness.resumeSession(&fresh);
    try testing.expectEqual(@as(usize, 2), fresh.messages.items.len);
    try testing.expectEqualStrings("user", fresh.messages.items[0].role);
    try testing.expectEqualStrings("assistant", fresh.messages.items[1].role);
    try testing.expectEqualStrings("hello", fresh.messages.items[1].content.?);
}

test "prompt: busy 守卫" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = store_mod.MemoryStore.init(a);
    var dummy: u8 = 0;
    const provider: loop.LLMProvider = .{ .ctx = &dummy, .name = "fake", .completeFn = fakeHello };
    var harness = Harness.init(a, mem.store(), provider, &.{}, .{});

    var session = try harness.createSession(a, "s1");
    session.phase = .turn;
    try testing.expectError(error.HarnessBusy, harness.prompt(&session, "x", null, null));
}

test "save point hook 触发一次" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var calls: usize = 0;
    const HookState = struct { calls: *usize };
    var hook_state = HookState{ .calls = &calls };
    const on_save_point = Hook{ .ctx = &hook_state, .f = struct {
        fn f(ctx: ?*anyopaque, session_id: []const u8) anyerror!void {
            _ = session_id;
            const s: *HookState = @ptrCast(@alignCast(ctx.?));
            s.calls.* += 1;
        }
    }.f };

    var mem = store_mod.MemoryStore.init(a);
    var provider_state = FakeState{};
    const provider: loop.LLMProvider = .{ .ctx = &provider_state, .name = "fake", .completeFn = fakeHello };
    var harness = Harness.init(a, mem.store(), provider, &.{}, .{ .on_save_point = on_save_point });

    var session = try harness.createSession(a, "s1");
    _ = try harness.prompt(&session, "hi", null, null);
    try testing.expectEqual(@as(usize, 1), calls);
}
