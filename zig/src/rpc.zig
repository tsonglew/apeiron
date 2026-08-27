//! JSON-RPC 2.0 over stdio：协议层是框架的命脉（codex app-server 的启示）。
//!
//! 语义对齐 Python 参照实现 src/apeiron/rpc.py（设计规格，不再演进）。
//! M0 四个方法（thread/start、thread/add、turn/run、thread/read）的骨架。
//! 所有 host（CLI / TUI / web / CI）和外部 agent（codex / dsh 互操作）
//! 都走这一个协议；payload 走 entries.plainValue 保持版本化。
const std = @import("std");
const entries = @import("entries.zig");
const harness = @import("harness.zig");
const loop = @import("loop.zig");
const store_mod = @import("store.zig");

pub const SessionId = entries.SessionId;
pub const Entry = entries.Entry;

pub const RpcError = struct {
    code: i64,
    message: []const u8, // 字面量或自有（由调用方管理）
};

const METHOD_NOT_FOUND: i64 = -32601;
const INTERNAL_ERROR: i64 = -32603;
const INVALID_PARAMS: i64 = -32602;
const THREAD_NOT_FOUND: i64 = -32000;
const PARSE_ERROR: i64 = -32700;

pub const RpcServer = struct {
    alloc: std.mem.Allocator,
    harness: *harness.Harness,
    /// thread_id -> *Session（服务器拥有；key 为 allocator 副本）
    threads: std.StringArrayHashMapUnmanaged(*harness.Session),

    pub fn init(alloc: std.mem.Allocator, h: *harness.Harness) RpcServer {
        return .{ .alloc = alloc, .harness = h, .threads = .empty };
    }

    pub fn deinit(self: *RpcServer) void {
        var it = self.threads.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.*.deinit();
            self.alloc.destroy(kv.value_ptr.*);
            self.alloc.free(kv.key_ptr.*);
        }
        self.threads.deinit(self.alloc);
    }

    fn get(self: *RpcServer, thread_id: []const u8) anyerror!*harness.Session {
        return self.threads.get(thread_id) orelse error.ThreadNotFound;
    }

    /// 处理一行请求 JSON，返回响应 JSON 文本（自有，调用方释放）。
    pub fn handle(self: *RpcServer, raw: []const u8) ![]u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, raw, .{ .allocate = .alloc_always }) catch {
            return try self.responseText(.null, null, .{ .code = PARSE_ERROR, .message = "parse error" });
        };
        var request = parsed.value;
        defer entries.valueDeinit(self.alloc, &request);

        const request_id = switch (request) {
            .object => |obj| obj.get("id") orelse .null,
            else => .null,
        };

        var params: std.json.Value = std.json.Value{ .object = std.json.ObjectMap{} };
        const method = switch (request) {
            .object => |obj| blk: {
                if (obj.get("params")) |p| params = p;
                const m = obj.get("method") orelse return try self.responseText(.null, null, .{ .code = PARSE_ERROR, .message = "invalid request" });
                break :blk m.string;
            },
            else => return try self.responseText(.null, null, .{ .code = PARSE_ERROR, .message = "invalid request" }),
        };

        if (eql(method, "thread/start")) {
            return self.response(request_id, self.mThreadStart());
        } else if (eql(method, "thread/add")) {
            return self.response(request_id, self.mThreadAdd(params));
        } else if (eql(method, "turn/run")) {
            return self.response(request_id, self.mTurnRun(params));
        } else if (eql(method, "thread/read")) {
            return self.response(request_id, self.mThreadRead(params));
        }
        return self.responseText(request_id, null, .{ .code = METHOD_NOT_FOUND, .message = "method not found" });
    }

    fn response(self: *RpcServer, request_id: std.json.Value, result: anyerror!std.json.Value) ![]u8 {
        const v = result catch |err| {
            return self.responseText(request_id, null, switch (err) {
                error.ThreadNotFound => RpcError{ .code = THREAD_NOT_FOUND, .message = "thread not found" },
                error.InvalidKind => RpcError{ .code = INVALID_PARAMS, .message = "invalid kind" },
                else => RpcError{ .code = INTERNAL_ERROR, .message = "internal error" },
            });
        };
        return self.responseText(request_id, v, .{ .code = 0, .message = "" });
    }

    fn responseText(self: *RpcServer, request_id: std.json.Value, result: ?std.json.Value, err: RpcError) ![]u8 {
        var obj = std.json.ObjectMap{};
        errdefer obj.deinit(self.alloc);
        try obj.put(self.alloc, try self.alloc.dupe(u8, "jsonrpc"), .{ .string = try self.alloc.dupe(u8, "2.0") });
        // id：请求里的 id 值（深拷贝，因为 request 即将释放）
        const id_value = switch (request_id) {
            .null => std.json.Value.null,
            else => try entries.payloadDup(self.alloc, request_id),
        };
        try obj.put(self.alloc, try self.alloc.dupe(u8, "id"), id_value);

        if (result) |r| {
            try obj.put(self.alloc, try self.alloc.dupe(u8, "result"), r);
        } else {
            var err_obj = std.json.ObjectMap{};
            try err_obj.put(self.alloc, try self.alloc.dupe(u8, "code"), .{ .integer = err.code });
            try err_obj.put(self.alloc, try self.alloc.dupe(u8, "message"), .{ .string = try self.alloc.dupe(u8, err.message) });
            try obj.put(self.alloc, try self.alloc.dupe(u8, "error"), .{ .object = err_obj });
        }
        var v = std.json.Value{ .object = obj };
        defer entries.valueDeinit(self.alloc, &v);
        return loop.jsonString(self.alloc, v);
    }

    fn eql(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    // ---- methods ----

    fn mThreadStart(self: *RpcServer) anyerror!std.json.Value {
        const session = try self.alloc.create(harness.Session);
        errdefer self.alloc.destroy(session);
        session.* = try self.harness.createSession(self.alloc, null);

        const key = try self.alloc.dupe(u8, session.session_id);
        errdefer self.alloc.free(key);
        try self.threads.put(self.alloc, key, session);

        var obj = std.json.ObjectMap{};
        errdefer obj.deinit(self.alloc);
        try obj.put(self.alloc, try self.alloc.dupe(u8, "thread_id"), .{ .string = try self.alloc.dupe(u8, session.session_id) });
        return .{ .object = obj };
    }

    fn mThreadAdd(self: *RpcServer, params: std.json.Value) anyerror!std.json.Value {
        const session = try self.get(params.object.get("thread_id").?.string);
        const kind_str = params.object.get("kind").?.string;
        const kind = std.meta.stringToEnum(entries.EntryKind, kind_str) orelse return error.InvalidKind;
        if (kind != .user and kind != .summary and kind != .checkpoint) return error.InvalidKind;
        const author: entries.Author = if (kind == .user) .user else .system;

        const payload: std.json.Value = if (params.object.get("payload")) |p| p else std.json.Value{ .object = std.json.ObjectMap{} };
        const parent_id: ?entries.EntryId = if (params.object.get("parent_id")) |pid| blk: {
            switch (pid) {
                .null => break :blk null,
                .string => |s| break :blk try parseId(s),
                else => return error.InvalidKind,
            }
        } else null;

        const entry = try session.log.add(author, kind, try entries.payloadDup(self.alloc, payload), parent_id);
        try self.harness.savePoint(session);
        return try entries.plainValue(entry, self.alloc);
    }

    fn mTurnRun(self: *RpcServer, params: std.json.Value) anyerror!std.json.Value {
        const session = try self.get(params.object.get("thread_id").?.string);
        const message = params.object.get("message").?.string;
        const r = try self.harness.prompt(session, message, null, null);

        var list = std.array_list.Managed(std.json.Value).init(self.alloc);
        for (r.new_entries) |e| {
            try list.append(try entries.plainValue(e, self.alloc));
        }
        var obj = std.json.ObjectMap{};
        errdefer obj.deinit(self.alloc);
        try obj.put(self.alloc, try self.alloc.dupe(u8, "entries"), .{ .array = list });
        return .{ .object = obj };
    }

    fn mThreadRead(self: *RpcServer, params: std.json.Value) anyerror!std.json.Value {
        const session = try self.get(params.object.get("thread_id").?.string);
        const since_seq: u64 = if (params.object.get("since_seq")) |v| @intCast(v.integer) else 0;
        const entries_slice = session.log.entriesSince(since_seq);

        var list = std.array_list.Managed(std.json.Value).init(self.alloc);
        for (entries_slice) |e| {
            try list.append(try entries.plainValue(e, self.alloc));
        }
        var obj = std.json.ObjectMap{};
        errdefer obj.deinit(self.alloc);
        try obj.put(self.alloc, try self.alloc.dupe(u8, "entries"), .{ .array = list });
        return .{ .object = obj };
    }
};

fn parseId(s: []const u8) !entries.EntryId {
    if (s.len != 32) return error.InvalidKind;
    var id: entries.EntryId = undefined;
    for (0..16) |i| {
        id[2 * i] = std.ascii.toLower(s[2 * i]);
        id[2 * i + 1] = std.ascii.toLower(s[2 * i + 1]);
    }
    return id;
}

/// 行分隔 JSON-RPC over stdio（fd 0/1，POSIX；M0 骨架）。
pub fn serve(server: *RpcServer, alloc: std.mem.Allocator) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(0, &chunk) catch |err| switch (err) {
            error.InputOutput => return,
            else => return err,
        };
        if (n == 0) return; // EOF
        for (chunk[0..n]) |c| {
            if (c == '\n') {
                if (buf.items.len > 0) {
                    const response = try server.handle(buf.items);
                    defer alloc.free(response);
                    try writeAll(1, response);
                    try writeAll(1, "\n");
                }
                buf.clearRetainingCapacity();
            } else {
                try buf.append(alloc, c);
            }
        }
    }
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        i += try std.posix.write(fd, bytes[i..]);
    }
}

// --------------------------------------------------------- 测试 ---

const testing = std.testing;

const FakeState = struct { content: []const u8 };

fn testHarness(alloc: std.mem.Allocator, state: *FakeState) !harness.Harness {
    var mem = try alloc.create(store_mod.MemoryStore);
    mem.* = store_mod.MemoryStore.init(alloc);
    return harness.Harness.init(alloc, mem.store(), .{
        .ctx = state,
        .name = "fake",
        .completeFn = fakeHello,
    }, &.{}, .{});
}

fn fakeHello(ctx: *anyopaque, alloc: std.mem.Allocator, messages: []const loop.Message, tools: []const loop.Tool) anyerror!loop.LLMResponse {
    _ = messages;
    _ = tools;
    const s: *FakeState = @ptrCast(@alignCast(ctx));
    return .{ .content = try alloc.dupe(u8, s.content) };
}

fn req(alloc: std.mem.Allocator, id: i64, method: []const u8, params_json: []const u8) ![]u8 {
    // 返回自有切片（调用方负责释放），切勿 defer free
    return try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params_json });
}

fn respField(alloc: std.mem.Allocator, response: []const u8, key: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, response, .{ .allocate = .alloc_always });
    defer entries.valueDeinit(alloc, &parsed.value);
    return entries.payloadDup(alloc, parsed.value.object.get(key).?);
}

test "rpc: thread 生命周期 + 错误码" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state_ok = FakeState{ .content = "ok" };

    var h = try testHarness(a, &state_ok);
    var server = RpcServer.init(a, &h);
    defer server.deinit();

    // thread/start
    const r1_raw = try req(a, 1, "thread/start", "{}");
    const r1 = try server.handle(r1_raw);

    var result_obj = try std.json.parseFromSlice(std.json.Value, a, r1, .{});
    const thread_id = result_obj.value.object.get("result").?.object.get("thread_id").?.string;
    defer entries.valueDeinit(a, &result_obj.value);

    // turn/run
    const r2_raw = try req(a, 2, "turn/run", try std.fmt.allocPrint(a, "{{\"thread_id\":\"{s}\",\"message\":\"hi\"}}", .{thread_id}));
    const r2 = try server.handle(r2_raw);
    var parsed2 = try std.json.parseFromSlice(std.json.Value, a, r2, .{});
    defer entries.valueDeinit(a, &parsed2.value);
    const entries_list = parsed2.value.object.get("result").?.object.get("entries").?.array;
    try testing.expectEqual(@as(usize, 2), entries_list.items.len);
    try testing.expectEqualStrings("user", entries_list.items[0].object.get("kind").?.string);
    try testing.expectEqualStrings("assistant", entries_list.items[1].object.get("kind").?.string);

    // thread/read since_seq=1
    const r3_raw = try req(a, 3, "thread/read", try std.fmt.allocPrint(a, "{{\"thread_id\":\"{s}\",\"since_seq\":1}}", .{thread_id}));
    const r3 = try server.handle(r3_raw);
    var parsed3 = try std.json.parseFromSlice(std.json.Value, a, r3, .{});
    defer entries.valueDeinit(a, &parsed3.value);
    const tail = parsed3.value.object.get("result").?.object.get("entries").?.array;
    try testing.expectEqual(@as(usize, 1), tail.items.len);
    try testing.expectEqual(@as(i64, 2), tail.items[0].object.get("seq").?.integer);

    // 未知方法 -> -32601
    const r4_raw = try req(a, 4, "nope", "{}");
    const r4 = try server.handle(r4_raw);
    var parsed4 = try std.json.parseFromSlice(std.json.Value, a, r4, .{});
    defer entries.valueDeinit(a, &parsed4.value);
    try testing.expectEqual(METHOD_NOT_FOUND, parsed4.value.object.get("error").?.object.get("code").?.integer);

    // 缺失 thread -> -32000
    const r5_raw = try req(a, 5, "turn/run", "{\"thread_id\":\"missing\",\"message\":\"hi\"}");
    const r5 = try server.handle(r5_raw);
    var parsed5 = try std.json.parseFromSlice(std.json.Value, a, r5, .{});
    defer entries.valueDeinit(a, &parsed5.value);
    try testing.expectEqual(THREAD_NOT_FOUND, parsed5.value.object.get("error").?.object.get("code").?.integer);
}

test "rpc: thread/add 支持 summary/checkpoint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state_ok = FakeState{ .content = "ok" };

    var h = try testHarness(a, &state_ok);
    var server = RpcServer.init(a, &h);
    defer server.deinit();

    const r1_raw = try req(a, 1, "thread/start", "{}");
    const r1 = try server.handle(r1_raw);
    var parsed1 = try std.json.parseFromSlice(std.json.Value, a, r1, .{});
    defer entries.valueDeinit(a, &parsed1.value);
    const thread_id = parsed1.value.object.get("result").?.object.get("thread_id").?.string;

    const r2_raw = try req(a, 2, "thread/add", try std.fmt.allocPrint(a, "{{\"thread_id\":\"{s}\",\"kind\":\"summary\",\"payload\":{{\"note\":\"saved\"}}}}", .{thread_id}));
    const r2 = try server.handle(r2_raw);
    var parsed2 = try std.json.parseFromSlice(std.json.Value, a, r2, .{});
    defer entries.valueDeinit(a, &parsed2.value);
    try testing.expectEqualStrings("summary", parsed2.value.object.get("result").?.object.get("kind").?.string);

    // 非法 kind -> -32602
    const r3_raw = try req(a, 3, "thread/add", try std.fmt.allocPrint(a, "{{\"thread_id\":\"{s}\",\"kind\":\"tool_call\"}}", .{thread_id}));
    const r3 = try server.handle(r3_raw);
    var parsed3 = try std.json.parseFromSlice(std.json.Value, a, r3, .{});
    defer entries.valueDeinit(a, &parsed3.value);
    try testing.expectEqual(INVALID_PARAMS, parsed3.value.object.get("error").?.object.get("code").?.integer);
}
