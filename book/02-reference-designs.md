---
title: 三个参考：pi、DeepSeek Harness、Codex Harness
description: 三家解剖、各自的关键块、以及最重要的收敛观察
date: "2026-08-26"
order: 2
---

# 02. 三个参考：pi、DeepSeek Harness、Codex Harness

2026-08-26。三家是同一个问题的三种解法，解剖它们等于把这行的设计空间摸了一遍。

## 总览

| | pi (`earendil-works/pi`) | dsh (`deepseek-ai/deepseek-harness`) | Codex Harness (`openai/codex`) |
| --- | --- | --- | --- |
| 发布 | 2025-2026 持续演进 | 2026-08-13（与 V4-Pro 同期） | 2026-08-19 全量开源 |
| 栈 | TypeScript monorepo | TypeScript + Cordis 插件框架 | Rust 核心（`codex-rs`）+ TS SDK |
| 核心抽象 | `agentLoop` / `Agent` / `AgentHarness` 三层 | 一切皆插件（model/tool/sandbox/storage/loop） | `codex exec` / SDK / `app-server` 三层 |
| 状态 | 会话 = 含 parentId 的**追加树**；save point 批量落盘；SQLite 默认 | append-only session log；**trace-first** | `thread-store` 持久化；`thread/resume`、`thread/fork`、`turn/interrupt` |
| 权限 | **无内建权限系统**（公开承认，靠 Docker 隔离） | sandbox 插件 | sandboxing + approval policy + permission profile |
| 评测 | — | headless 模式 + Minimal preset（只留 bash+编辑器，专为模型基准） | `codex exec` 非交互、CI 可用 |

## 各自贡献的关键块

### pi：分层与「状态一切从树上来」

三层 API 是 pi 最大的贡献，直接回答「状态应该放在哪一层」：

- `agentLoop`：纯流式生成器，LLM 调用 → 工具执行 → 回喂，**无状态**；
- `Agent`：状态化封装（`AgentState`、事件订阅、steer/follow-up 队列、中断控制）；
- `AgentHarness`：持久化编排（phase 状态机、save point、hooks、durable sessions）。

另一个关键设计：**会话是追加树**（每条 entry 带 `parentId`，合法前缀都可恢复）。
fork、重试、并行 lane、子代理、崩溃恢复全部免费获得——全是树操作，没有新机制。
这个模型我们在 M0 原样吸收（`entries.py` 的 `parent_id`）。

教训也明确：**没有内建权限系统**，被社区直接点名批评。
权限/审批必须内建，不能「让用户自己隔离」（M1 落实）。

### dsh：插件化 + trace-first

`Everything is a Plugin` 不是口号：模型、工具、沙箱、会话存储、**连主循环都可换**。
好处是生态爆发（一周 5k+ 社区插件）；代价是核心未稳就开放（rc.5→rc.8 一周连跳、
零 issue 策略），V4-Pro 的 headline 分数混着 harness 本身的贡献。

最有价值的理念是 **trace-first**：「一切 model-visible 的都要写进日志」
（system prompt、推理、工具调用、子代理派发、上下文注入）。
这条原则让 replay、审计、评测有了数据底座。我们在 M0 就落：
`eval.py` 的 TraceWriter，任何事件一行 JSONL。

### Codex Harness：协议是命脉

Codex 的三层接口 `codex exec` / SDK / `app-server` 里，真正的杀手锏是
**app-server 协议**（JSON-RPC 2.0，三原语 **Thread / Turn / Item**，
`resume`/`fork`/`interrupt`），VS Code 插件和桌面 App 都靠它连接。
官方表述：产品方拥有「product context, business rules, and tools」，
app-server 提供 agent loop。

结论：**协议先行**。host（CLI/TUI/web/CI）与外部 agent 互操作
（dsh 已经这么干：把 codex 挂成子代理）都只依赖协议，不依赖实现语言。
我们在 M0 立了 `rpc.py`（JSON-RPC 2.0 over stdio），后续所有宿主都走它。

## 收敛观察（最重要的一条）

三家语言、风格完全不同，**但状态模型收敛到了同一个形状**：

> 会话 = 不可变追加日志（树结构）+ 一个可重建的投影。

pi 的 entry 树、dsh 的 append-only session log、codex 的 Thread/Item，
本质是同一个东西。我们不需要发明新模型——**照抄这个共识**，然后把
「存储换成分布式」和「语义可复现」这两件他们都没做透的事做好。
