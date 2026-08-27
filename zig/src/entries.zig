//! 事件溯源模型：会话由不可变 Entry 序列构成。
//!
//! 语义对齐 Python 参照实现 src/apeiron/entries.py（设计规格，不再演进）。
//! 所有权约定：payload 及其字符串由构造方以 allocator 分配，所有权移交 Entry；
//! 释放请用 entryDeinit（递归释放 payload 的字符串与容器）。
const std = @import("std");
const builtin = @import("builtin");

pub const SessionId = []const u8;
/// uuid4 的 32 位小写 hex（跟 Python `uuid.uuid4().hex` 对齐）。
pub const EntryId = [32]u8;
pub const SCHEMA_VERSION: u32 = 1;

pub const EntryKind = enum {
    user,
    assistant,
    tool_call,
    tool_result,
    summary,
    checkpoint,
};

pub const Author = enum {
    user,
    model,
    tool,
    hook,
    system,
};

pub const Entry = struct {
    session: SessionId,
    /// 会话内单调递增；存储层乐观并发控制（CAS）的唯一依据。
    seq: u64,
    entry_id: EntryId,
    /// 树式历史：fork / 重试 / 并行 lane / 子代理都建立在树上。
    parent_id: ?EntryId,
    author: Author,
    kind: EntryKind,
    payload: std.json.Value,
    created_at: f64,
    schema_version: u32,
};

/// UUIDv4（版本位/variant 位置好），32 位小写 hex。
pub fn newEntryId() EntryId {
    var raw: [16]u8 = undefined;
    randomBytes(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40; // version 4
    raw[8] = (raw[8] & 0x3f) | 0x80; // RFC 4122 variant
    const hex = "0123456789abcdef";
    var id: EntryId = undefined;
    for (raw, 0..) |byte, i| {
        id[2 * i] = hex[byte >> 4];
        id[2 * i + 1] = hex[byte & 0x0f];
    }
    return id;
}

// --- 弱熵随机（M0 够用；WASM 演示下可后续注入确定性种子） ---

var rng_state: std.Random.Xoshiro256 = undefined;
var rng_ready = false;

fn randomBytes(buf: []u8) void {
    if (!rng_ready) {
        const t = nowMicros();
        rng_state = std.Random.Xoshiro256.init(t ^ @as(u64, @intCast(@intFromPtr(&rng_state))));
        rng_ready = true;
    }
    rng_state.random().bytes(buf);
}

fn nowMicros() u64 {
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .linux) {
        var ts: std.posix.timespec = undefined;
        switch (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts))) {
            .SUCCESS => return @as(u64, @intCast(ts.sec)) * std.time.us_per_s +
                @as(u64, @intCast(ts.nsec)) / std.time.ns_per_us,
            else => {},
        }
    }
    return 0;
}

/// UNIX 秒（f64，对齐 Python `time.time()`；WASM 无时钟时返回 0.0）。
pub fn nowSeconds() f64 {
    return @as(f64, @floatFromInt(nowMicros())) / std.time.us_per_s;
}

pub fn newEntry(
    session: SessionId,
    seq: u64,
    parent_id: ?EntryId,
    author: Author,
    kind: EntryKind,
    payload: std.json.Value,
) Entry {
    return .{
        .session = session,
        .seq = seq,
        .entry_id = newEntryId(),
        .parent_id = parent_id,
        .author = author,
        .kind = kind,
        .payload = payload,
        .created_at = nowSeconds(),
        .schema_version = SCHEMA_VERSION,
    };
}

/// 深拷贝 payload（字符串与容器全部由 allocator 占有）。
pub fn payloadDup(alloc: std.mem.Allocator, src: std.json.Value) !std.json.Value {
    return switch (src) {
        .array => |arr| blk: {
            var out = std.array_list.Managed(std.json.Value).init(alloc);
            errdefer {
                for (out.items) |*item| valueDeinit(alloc, item);
                out.deinit();
            }
            for (arr.items) |item| try out.append(try payloadDup(alloc, item));
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out = std.json.ObjectMap{};
            errdefer {
                var it = out.iterator();
                while (it.next()) |kv| {
                    valueDeinit(alloc, &kv.value_ptr.*);
                    alloc.free(kv.key_ptr.*);
                }
                out.deinit(alloc);
            }
            var it = obj.iterator();
            while (it.next()) |kv| {
                const key = try alloc.dupe(u8, kv.key_ptr.*);
                errdefer alloc.free(key);
                const value = try payloadDup(alloc, kv.value_ptr.*);
                try out.put(alloc, key, value);
            }
            break :blk .{ .object = out };
        },
        .string => |s| .{ .string = try alloc.dupe(u8, s) },
        else => src,
    };
}

/// 序列化为 JSON 值（内部用；调用方须 valueDeinit —— 全量自有，可安全释放）。
/// 注意：ObjectMap 不复制 key，必须 put 前 dup；StringArrayHashMap 亦然。
pub fn plainValue(e: Entry, alloc: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap{};
    errdefer {
        var it = obj.iterator();
        while (it.next()) |kv| {
            valueDeinit(alloc, &kv.value_ptr.*);
            alloc.free(kv.key_ptr.*);
        }
        obj.deinit(alloc);
    }
    try obj.put(alloc, try alloc.dupe(u8, "session"), .{ .string = try alloc.dupe(u8, e.session) });
    try obj.put(alloc, try alloc.dupe(u8, "seq"), .{ .integer = @intCast(e.seq) });
    try obj.put(alloc, try alloc.dupe(u8, "entry_id"), .{ .string = try alloc.dupe(u8, &e.entry_id) });
    if (e.parent_id) |pid| {
        try obj.put(alloc, try alloc.dupe(u8, "parent_id"), .{ .string = try alloc.dupe(u8, &pid) });
    } else {
        try obj.put(alloc, try alloc.dupe(u8, "parent_id"), .null);
    }
    try obj.put(alloc, try alloc.dupe(u8, "author"), .{ .string = try alloc.dupe(u8, @tagName(e.author)) });
    try obj.put(alloc, try alloc.dupe(u8, "kind"), .{ .string = try alloc.dupe(u8, @tagName(e.kind)) });
    try obj.put(alloc, try alloc.dupe(u8, "payload"), try payloadDup(alloc, e.payload));
    try obj.put(alloc, try alloc.dupe(u8, "created_at"), .{ .float = e.created_at });
    try obj.put(alloc, try alloc.dupe(u8, "schema_version"), .{ .integer = e.schema_version });
    return .{ .object = obj };
}

/// 序列化为 JSON 文本（协议/持久化用）。调用方释放返回的 []u8。
pub fn stringify(e: Entry, alloc: std.mem.Allocator) ![]u8 {
    var v = try plainValue(e, alloc);
    defer valueDeinit(alloc, &v);
    return try std.json.Stringify.valueAlloc(alloc, v, .{});
}

/// 从 JSON 文本解析 Entry（字符串全部由 allocator 占有；释放用 entryDeinit）。
pub fn parse(alloc: std.mem.Allocator, json: []const u8) !Entry {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{ .allocate = .alloc_always });
    return fromPlain(alloc, parsed.value);
}

/// 从 plain JSON 值构造 Entry。
/// 所有权：取得 v 及其字符串（要求以 alloc_always 解析或由 allocator 分配），
/// 返回的 Entry 一并拥有；释放用 entryDeinit。
pub fn fromPlain(alloc: std.mem.Allocator, v: std.json.Value) !Entry {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.InvalidPlainEntry,
    };
    return .{
        .session = try alloc.dupe(u8, obj.get("session").?.string),
        .seq = @intCast(obj.get("seq").?.integer),
        .entry_id = try parseEntryId(obj.get("entry_id").?.string),
        .parent_id = switch (obj.get("parent_id").?) {
            .null => null,
            .string => |s| try parseEntryId(s),
            else => return error.InvalidPlainEntry,
        },
        .author = std.meta.stringToEnum(Author, obj.get("author").?.string) orelse return error.InvalidPlainEntry,
        .kind = std.meta.stringToEnum(EntryKind, obj.get("kind").?.string) orelse return error.InvalidPlainEntry,
        .payload = obj.get("payload").?,
        .created_at = switch (obj.get("created_at").?) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => return error.InvalidPlainEntry,
        },
        .schema_version = if (obj.get("schema_version")) |sv| @intCast(sv.integer) else SCHEMA_VERSION,
    };
}

fn parseEntryId(s: []const u8) !EntryId {
    if (s.len != 32) return error.InvalidEntryId;
    var id: EntryId = undefined;
    for (0..16) |i| {
        id[2 * i] = std.ascii.toLower(s[2 * i]);
        id[2 * i + 1] = std.ascii.toLower(s[2 * i + 1]);
    }
    return id;
}

/// 递归释放 payload 的字符串/容器。
/// 注意：Entry.session 是**借用引用**（同一会话的所有 entry 共享，
/// 所有权属 SessionLog/store 或调用方），此处不释放。
pub fn entryDeinit(alloc: std.mem.Allocator, e: *Entry) void {
    valueDeinit(alloc, &e.payload);
}

pub fn valueDeinit(alloc: std.mem.Allocator, v: *std.json.Value) void {
    switch (v.*) {
        .array => |*arr| {
            for (arr.items) |*item| valueDeinit(alloc, item);
            arr.deinit(); // 0.16: Value.array 是 Managed 列表（自带 allocator）
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |kv| {
                valueDeinit(alloc, &kv.value_ptr.*);
                alloc.free(kv.key_ptr.*);
            }
            obj.deinit(alloc);
        },
        .string => |s| alloc.free(s),
        else => {},
    }
}

/// 便捷：从 JSON 片段构造 payload（字符串全部由 allocator 占有，可直接移交）。
pub fn payloadFromJson(alloc: std.mem.Allocator, src: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, src, .{ .allocate = .alloc_always });
    return parsed.value; // 所有权移交调用方（勿调用 parsed.deinit）
}

test "new_entry 字段与约定" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const payload = try payloadFromJson(a, "{\"content\":\"hi\"}");
    const e = newEntry("s1", 1, null, .user, .user, payload);
    try std.testing.expectEqual(@as(u64, 1), e.seq);
    try std.testing.expectEqual(SCHEMA_VERSION, e.schema_version);
    try std.testing.expect(e.parent_id == null);
    try std.testing.expectEqualStrings("hi", e.payload.object.get("content").?.string);
}

test "stringify / parse 往返" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parent: EntryId = undefined;
    @memset(&parent, 'p');

    const payload = try payloadFromJson(a, "{\"content\":\"x\"}");
    const e = newEntry("s1", 3, parent, .model, .assistant, payload);
    const json = try stringify(e, a);
    const e2 = try parse(a, json);
    try std.testing.expectEqualStrings("s1", e2.session);
    try std.testing.expectEqual(e.seq, e2.seq);
    try std.testing.expectEqual(e.entry_id, e2.entry_id);
    try std.testing.expectEqual(e.parent_id, e2.parent_id);
    try std.testing.expectEqual(e.author, e2.author);
    try std.testing.expectEqual(e.kind, e2.kind);
    try std.testing.expectEqualStrings("x", e2.payload.object.get("content").?.string);
}

test "entry_id 是 32 位小写 hex（0-9 a-f）" {
    const id = newEntryId();
    for (id) |c| try std.testing.expect(
        (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'),
    );
}
