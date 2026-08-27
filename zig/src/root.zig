//! apeiron 核心库入口：Zig 实现（M0 起）。
//!
//! 语义对齐 Python 参照实现 src/apeiron/（设计规格，不再演进）。
//! 模块划分（与参照实现一一对应）：
//!   entries   事件溯源模型（不可变 Entry）
//!   log       进程内会话日志（追加/查询/快照）
//!   store     存储接口 vtable + 内建后端（Memory；SQLite/PG 后续）
//!   loop      无状态 agent 循环（LLM -> 工具 -> 回喂）+ 事件流 + 历史重建
//!   tools     内建工具（echo 占位）
//!   harness   编排层（phase 状态机、hooks、save point、resume、abort）
//!   control   控制通道（steer/abort/approve，与主写路径分离）
//!   rpc       JSON-RPC 2.0 over stdio（thread/start、thread/add、turn/run、thread/read）
//!   eval      TraceWriter（JSONL 落盘）+ runHeadless
//!   demo      WASM 演示入口（导出 C ABI：demo_init/prompt/resume/result）
//! M0 八模块齐（与参照实现一一对应）；M1 起接真实 LLM/插件槽/审批流。
pub const entries = @import("entries.zig");
pub const log = @import("log.zig");
pub const store = @import("store.zig");
pub const loop = @import("loop.zig");
pub const tools = @import("tools.zig");
pub const harness = @import("harness.zig");
pub const control = @import("control.zig");
pub const rpc = @import("rpc.zig");
pub const eval = @import("eval.zig");
pub const demo = @import("demo.zig");

test {
    _ = entries;
    _ = log;
    _ = store;
    _ = loop;
    _ = tools;
    _ = harness;
    _ = control;
    _ = rpc;
    _ = eval;
    _ = demo;
}
