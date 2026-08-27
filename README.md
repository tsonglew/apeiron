# apeiron

面向有状态智能体（含分布式状态存储）的 agent harness。

设计基线（吸收 pi / DeepSeek Harness / Codex Harness 的做法）：

- **事件溯源**：会话是不可变 Entry 序列（单一源真），AgentState 只是它的投影；
  存储层可插拔，单进程 SQLite 与分布式后端走同一接口。
- **分层**：loop（无状态、可重放）→ harness（phase 状态机 / hooks / save point）→
  protocol（JSON-RPC 2.0，所有 host 与外部 agent 都走协议）。
- **单写者**：每会话一个写者；`(session_id, seq)` 即乐观并发控制；
  控制通道（steer/abort/approve）与主写路径分离，避免互锁。
- **插件化（M1）**：模型 / 工具 / 沙箱 / 存储 / loop 皆可替换，以 entry points 注册。
- **trace-first**：model-visible means logged；headless + 四指标（turns/token/耗时/成本）用于评测。

## 现状（2026-08-27 更新）

> **技术栈变更**：核心实现迁移至 **Zig**（M0 起重写，见 [book/04](book/04-stack-decisions.md)）。
> 下方 `src/apeiron/` Python 版 M0 保留为**设计规格与测试语义参照**，不再演进；
> 新核心在 [`zig/`](zig/)（`zig test` 验证，**21/21 全绿**，含 WASM 交叉编译验证）。
> 教程交互演示 = Zig 编译 WASM 跑真实核心。

```
zig/src/（当前实现，M0 八模块齐）
  entries   Entry / EntryKind / Author，不可变记录模型（uuid4 hex id）
  log       SessionLog：进程内追加、查询、快照、restore
  store     SessionStore 接口（vtable）+ MemoryStore（(session_id,seq) 即 CAS）
  loop      无状态 run_turn：LLM -> 工具 -> 回喂；事件流；messagesFromLog
  tools     内建工具（echo 占位）与权限分级
  harness   phase 状态机、hooks、turn 级 save point、resumeSession、abort
  control   控制通道 Protocol + 本地 FIFO 队列（steer/abort/approve 用）
  rpc       JSON-RPC 2.0 over stdio：thread/start, thread/add, turn/run, thread/read
  eval      TraceWriter（JSONL 落盘）+ runHeadless
```

Python 参照实现（`src/apeiron/`，设计规格，不再演进）：entries / log / store / loop / tools / harness / control / rpc / eval 一一对应。

## 文档

- [ROADMAP.md](ROADMAP.md) —— 里程碑计划（M0 已完成）
- [book/](book/00-index.md) ——《apeiron 构建手记》：决策日志与实现重点
  （[Astro + Pure 主题站点](site/)，发布到 tsonglew.github.io/apeiron，
  push 后由 GitHub Actions 自动构建部署）

## 使用

```
# Zig 核心（当前实现）
zig build test

# Python 参照实现（语义规格）
uv run pytest -q
```

## 路线

- M1：插件槽（entry points）+ 工具权限审批流 + headless 四指标
- M2：Postgres 后端（seq CAS + 会话 lease + LISTEN/NOTIFY 控制通道）+ trace 回放 + compaction
- M3：Redis 热读 + S3 冷归档 + WebUI host
