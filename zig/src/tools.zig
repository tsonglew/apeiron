//! 内建工具（M0 只有 echo 占位；M1 接 bash/fs + 权限审批流）。
//!
//! 语义对齐 Python 参照实现 src/apeiron/tools.py（设计规格，不再演进）。
const std = @import("std");
const loop = @import("loop.zig");

var echo_marker: u8 = 0;

fn echoHandler(ctx_: *anyopaque, alloc: std.mem.Allocator, args: std.json.Value) loop.ToolError!std.json.Value {
    _ = ctx_;
    const text = args.object.get("text").?.string;
    return .{ .string = try alloc.dupe(u8, text) };
}

pub const ECHO = loop.Tool{
    .name = "echo",
    .description = "回显文本，用于验证工具回路。",
    .input_schema = .{ .object = .empty },
    .permission = .read_only,
    .handler_ctx = &echo_marker,
    .handlerFn = &echoHandler,
};

pub fn listTools() []const loop.Tool {
    return &.{ECHO};
}
