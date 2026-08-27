---
title: 核心设计判断：五条原则
description: 事件溯源、分层边界、单写者、协议先行、trace-first
publishDate: "2026-08-26"
order: 3
---

# 03. 核心设计判断：五条原则

2026-08-26。全部原则在 M0 已落地，后续里程碑只深化不推翻。

## 1. 会话是事件日志，AgentState 只是投影

**不可变追加日志是单一源真**（source of truth）：`Entry{ session_id, seq, entry_id,
parent_id, author, kind, payload, schema_version }`，只增不改。
「当前会话状态」（消息列表、进行中的 turn）是从日志推导出来的投影。

为什么这么选——因为三个参考项目都收敛到这里（见 02 章），
且它是唯一让**分布式存储变得可解**的模型：
不用存一个可变对象，而是「存日志 + 缓存一份投影」。
可变对象（pi 的 `AgentState` Setter 复制）在单进程能凑合，
跨进程就是强一致性的泥潭。

推论（M0 直接体现）：

- 崩溃恢复 = 从最后 checkpoint/快照之后重放日志（`harness.resume`）；
- fork/回滚 = 在树上挑一个 parentId 延展（`entries.parent_id`）；
- 任何进程都能重演任何一段对话（`messages_from_log`）。

## 2. 分层的边界 = 状态的所有权

- `loop`：无状态。LLM → 工具 → 回喂的循环，**可单测、可重放**；
- `Agent/Session`：会话状态在内存中的投影（日志 + 消息）；
- `harness`：持久化与编排（phase 状态机、save point、hooks、子代理）；
- `protocol`：JSON-RPC 契约；
- `store`：日志的物理存储，唯一允许「跨进程」存在的地方。

边界为什么重要：**loop 永远无状态，是分布式正确性的前提**——
任何进程拿到日志 + provider，行为就一致。M0 之后无论做多复杂，
这个「分发责任」不能让。

## 3. 单写者：把正确性压缩成一个约束

分布式系统的核心难点是并发。我们的策略不是做一套同步协议（如 CRDT），
而是**从模型上消灭并发**：

> 每个会话同时只有一个写者；写 = 追加一条带单调 `seq` 的 entry；
> 存储层用 `(session_id, seq)` 主键/唯一索引天然做成 CAS。

单写者如何保证？本地是 asyncio actor（每会话一个 task，状态归 task 所有）；
分布式后是 **lease**（TTL + 心跳），会话进程崩溃后 lease 过期，另一个进程接管，
接管时从存储重放——语义就是「恢复」。

配套决策：**控制通道（steer/abort/approve）与主写路径分离**。
pi 的 steer/followUp 是进程内队列，分布式后必须变成独立通道
（PG LISTEN/NOTIFY、Redis Stream），否则控制消息和写路径互相等锁，死锁风险。
M0 已留缝（`control.py` 的 Protocol）。

## 4. 协议是框架的命脉

Codex 的启示（02 章）：真正让生态接入的是 `app-server` 协议，不是 CLI。
所以：

- 所有 host（CLI/TUI/web/CI）与外部 agent（codex/dsh 互操作）**只走协议**；
- 协议原语 = Thread / Turn / Item（对应我们的 session / turn / entry），
  JSON-RPC 2.0 over stdio / Unix socket；
- payload 带 `schema_version`（`entries.plain()`），**协议冻结先于 API 冻结**。

## 5. trace-first：model-visible means logged

模型看到的一切（system prompt、消息、工具参数与结果、控制注入）都必须落日志。
这张 JSONL 是审计、评测、回放的同一份数据底座：
没有它，「崩溃恢复后行为一致」「换模型回归对比」都无从验证。

这也是**评测从最早阶段就必须接线**的原因（ROADMAP M1 即做）：
trace 不是上线前的可视化工具，而是验证分布式语义的测试设施。
