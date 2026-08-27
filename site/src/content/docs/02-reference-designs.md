---
title: 三个参考：pi、DeepSeek Harness、Codex Harness
description: 三家解剖、各自的关键块、以及最重要的收敛观察；2026-08-27 源码级复核
publishDate: "2026-08-26"
order: 2
---

# 02. 三个参考：pi、DeepSeek Harness、Codex Harness

2026-08-26 初稿；**2026-08-27 以三个仓库的一手源码（浅克隆 + 实机安装包交叉验证）复核重写**。
本篇的事实以 8-27 复核版为准；与 8-26 印象相左的地方见文末「复核更新与勘误」。

三家是同一个问题的三种解法，解剖它们等于把这行的设计空间摸了一遍。

## 总览

| | pi (`earendil-works/pi`) | dsh (`deepseek-ai/deepseek-harness`) | Codex Harness (`openai/codex`) |
| --- | --- | --- | --- |
| 版本/发布 | npm monorepo，各包 `0.84.3`（HEAD `e868230`） | `@deepseek-ai/dsh-root@0.1.1-rc.2`（developer preview） | Rust workspace（源码 `0.0.0`，正式版走 GitHub Releases） |
| 栈 | TypeScript（tsgo + Biome + vitest + Bun） | TypeScript + **Cordis**（DI 容器 + 类型化事件 + 可逆效应） | Rust 核心 `codex-rs`（约 119 crate，Bazel+Cargo 双轨）+ TS/Python SDK |
| 核心抽象 | 低层运行时（agent-loop / reducer）+ **AgentHarness**（lanes/checkpoint/持久化）+ preset 插件 | **一切皆插件**：profile（命名组合）→ bundle（分发格式）→ patch（分层覆盖） | `codex exec` / SDK / **app-server** 协议三层 |
| 状态 | 会话树（`parentId` 分支）+ **写一次 entries + registers** + usage ledger | append-only `SessionEventMap` 日志，`deriveMessages()` 投影；**model-visible == logged 不变量** | canonical = JSONL rollout 文件；查询投影 = SQLite（`thread_turns`/`thread_items`） |
| 持久化 | Memory / JSONL v4 / SQLite（`node:sqlite`，`BEGIN IMMEDIATE` + `writer_lease` 强制单写） | JSONL artifact（每会话一文件，zstd 可选，`SESSION_FORMAT_VERSION=0`，崩溃截断 offset 修复） | rollout 文件即 checkpoint（resume/compaction 均重放）；fork 血缘 `parent_thread_id`/`forked_from_id` |
| 权限 | **无内建权限系统**（README 明示，靠 Gondolin/Docker/OpenShell 外部容器化） | 三档沙箱 `read-only|workspace-write|danger-full-access` + fail-closed 审批 + `permissionPresets` 命名组合 | 三档沙箱（seatbelt/landlock/bwrap）+ `permissions.toml`（allow/ask/deny + network/filesystem）+ `execpolicy`；approval 走协议 server→client |
| 评测 | `evals` 包 | `headless` bundle：stdout 最后非空文本 + 退出码；**四指标需从 session log 推导**（见勘误） | `TestCodexBuilder` + SSE mock 上游 `/responses`；TUI `insta` 快照；`otel`/`analytics`/`rollout-trace` |
| 文档 | [pi.dev](https://pi.dev/docs/latest)（含 `session-format`/`sessions`/`extensions` 页；**仓库内 `packages/agent/docs/harness.md` 是 harness 模型权威**） | 仓库内 `docs/*.zh.md` 双语文档（VitePress 源）；**公网文档站未开放**（`docs.deepseek.com/harness` NXDOMAIN） | [developers.openai.com/codex](https://developers.openai.com/codex) + 仓库 `docs/`（contributing/install/sandbox/execpolicy/skills） |

## 各自贡献的关键块

### pi：写一次 + registers，以及"可持续的程序计数器"

8-26 我们把它记为「agentLoop / Agent / AgentHarness 三层 API」——复核后更准确的表述是：
**三层不是三个包**，低层运行时与 AgentHarness 同在 `packages/agent`（pi-agent-core），preset 是 coding-agent 的扩展插件。
真正有贡献的是配套的持续化模型（`packages/agent/docs/harness.md`），与我们先验的设计几乎逐点对应：

- **写一次 + registers**：会话树 entries（write-once、append-only）+ 可变 registers（`lane.leaf`/`op.meta`/`op.state`/`pending.entry`）+ usage ledger。恢复 = 读 register，**无 reducer、无日记回放**；
- **持久化程序计数器**：一次操作（run/compaction/navigation）的完整状态整体覆写在 `op.state`，崩溃点可枚举（只在 transaction 之间）——这比"重放日志推断状态"在多进程场景便宜得多；
- **effect sandwich**（intent→effect→settlement 两次 commit）+ `replay: "never"|"safe"`：外部副作用"要么只发生一次、要么可安全重放"，这是把工具执行做成可恢复的唯一严谨做法；
- **lane 三态队列**：`steer`（跑动中注入）/ `followUp`（收尾时注入）/ `nextRun`（留给下一次 run）区分清楚；abort 先写 `control=cancel_requested` 再触发信号，杜绝"aborted 但 control=running"的非法态；
- **save point**（自包含 checkpoint 的 compaction entry）与 **fork**（`createForkMutations`，`scope: "tree"|"branch"`）；
- 会话树 + `parentId` 分支（M0 已吸收为 `entries.parent_id`）；UUIDv7 自排序 id。

约束与教训（都得到官方确认）：

- **单进程单写者**：SQLite `writer_lease` 强制，"One process per session / A session lives in one place"——这是我们对齐的方向，不是它的；
- **Harness 耐久层未建成**：上游 TS 与 Python 移植（PyPI `pp-agent-core` 0.2.1，源码在 `github.com/HSPK/pp_agent_core`，import 名 `pi_agent`）都有 `HarnessNotImplemented`（`agent_harness.py:66`）——facade 移植、run/compaction/navigation 引擎是 stub。**它恰恰把我们要补的空白又确认了一遍**；
- **无内建权限系统**（官方 README 明示），靠外部容器化——权限/审批必须内建（M1 落实）。

### dsh：插件化 + model-visible == logged 不变量

`Everything is a Plugin` 的机制比我们想象的更工程化，且**全部有源码级文档**（`docs/architecture.zh.md` + 各 `subsystems/*.zh.md`）：

- **Cordis**：DI 容器 + 类型化事件（`emit`/`waterfall`/`parallel`/`serial` + `@mode`）+ **可逆效应**（每个注册都有 disposer，卸载即撤销）；插件声明 `ctx.<serviceKey>`，加载顺序由服务可用性驱动；
- **profile → bundle → patch 分层**：`package.json` 的 `dsh` 字段声明贡献；每层向空 entry 列表按序 insert/patch（按 row id 整行替换或插新行）；`dsh --profile web --dump-config` 可查看实际树——**声明式可叠加配置**是它的产品级能力；
- **核心抽象 = seam 三件套**（Service Definition / Provider / Consumer）：每个可替换能力（fs、bash、llm、subagent、compaction…）拆成接口 + 实现 + 模型工具；换 provider 即换整个产品的行为，无需 fork。这与我们"插件槽"的对应关系：**扩展点 = service key + 事件名**，而非插件自封入口；
- **session log 与不变量**：append-only `SessionEventMap`（`turn/*`、`step/*`、`user/message`、`assistant/chunk`、`assistant/message`、`tool/call`、`tool/result`、`todo/write`、`request/*`、`session/end-seed`…），`deriveMessages()` 从日志投影模型历史；**"模型可见即已记录"由运行时不变量断言**——新增一项模型可见输入就必须新增一个会话事件。我们 M0 的 `eval.py: TraceWriter` 是它的第一步；
- **turn/step 两级生命周期**：step = 一次模型请求 + 其工具调用；turn 跨多个 step；`agent/pre-step` 是瀑布式事件（可改写/拒绝输入），`agent/turn-stopping` 是串行事件（无 `next()`）——**策略钩子不改 loop 本身**；
- **compaction 是可选 seam**（不是 loop 主干）：三个 log-only 事件（`compaction/start` 锁 / `summary` / `end`），经 `user/message` + `surfaceOp: replace` 替换 surface（唯一 surface 变异），保留 tool-call/result 配对——压缩是"事件"，所以可回放、可审计；
- **tools 四层**：tool-fs（schema/渲染）→ fs-observation-policy（策略=纯事件监听；WeakMap 记录"已观察"；`fs/write-intent`、`fs/edit-intent`（CAS 版本）、`fs/observed`；单槽先到先得）→ provider 契约 → 本地实现。**read-before-edit + 版本守卫就这么实现**；
- **审批与权限预设**：`ctx.approval` fail-closed（`allowed-once|rejected|cancelled|unavailable`），每请求配一对 `approval/asked`+`approval/decided` 事件；`permissionPresets` 把 sandbox-mode × approval-policy 打成命名组合（默认 `workspace-write`、`danger-full-access`），会话创建时固定；
- **skill / subagent / workflow 三种协作**：skill = 可选指示（注册表 + 按列表注入）；subagent = 按名注册的多 provider seam（capability 标志位 + `UNSUPPORTED_CAPABILITY` 防呆，可续子会话）；workflow = 模型写的纯数据 JS 脚本（`{script, meta, args, parent}`，先校验 meta 再执行，单引擎 worker_thread）——三者都作为**loop 之上的可选能力**，不嵌入主干；
- **headless 与 Python SDK**：`dsh --profile headless "<task>"`（无 server、无 HMR），Python SDK 经子进程 stdio 的 newline-delimited JSON-RPC 驱动——**headless 只输出最后非空文本 + 退出码**，"四指标"在当前版本并不存在（见勘误），但全部可从 session log 推导（turn 数 = `turn/start` 计数、token = `assistant/message.usage`、耗时 = 时间戳差、成本 = 规则计价）。

### Codex Harness：协议是命脉（源码级细节）

- **app-server 协议**：类 MCP 的 JSON-RPC 2.0（wire 省略 `jsonrpc` 字段），默认 stdio（newline-delimited JSON）；三原语 **Thread → Turn → Item**（Item 是带 tag 的 union：`userMessage`/`agentMessage`/`reasoning`/`commandExecution`/`fileChange`/`mcpToolCall`/`subAgentActivity`/`webSearch`/`contextCompaction`…）。生命周期 `initialize` → `thread/start|resume|fork`（返回 thread + `thread/started` 通知）→ `turn/start`（立即返回 turn，实际开跑发 `turn/started`）→ `item/*` 流（`item/started` → 各类型 delta → `item/completed` **权威终态**）→ `turn/completed`（status + token usage）；
- **双向控制面**：approval / elicitation / currentTime 是 **server→client 请求**（`item/commandExecution/requestApproval` → 客户端答 `{decision: accept|acceptForSession|decline|cancel}`）——这是它"全行业最好"的核心：控制权在协议层，host 与 UI 无需发明专属 channel；
- **canonical 历史与查询投影分离**：历史只写 append-only rollout（JSONL），SQLite 仅存可查询元数据（`thread_turns`/`thread_items` 投影表，主键 `(thread_id, turn_id, item_id)`，`item_json` 整条存）——**写路径极简、读路径可索引**，resume/fork/compaction 全都基于重放 rollout；
- **fork/resume 语义内建**：`parent_thread_id`/`forked_from_id` + `rollout_lineage`；分页历史 `thread/turns/list` + cursor（`nextCursor`/`backwardsCursor`）；过载回 `-32001` 可重试；
- **系统提示注入纪律**：`ContextualUserFragment`——增量构建、**无历史改写**、单 fragment ≤10K token、总量上限，直接服务于缓存命中与成本控制（我们 M0 说"trace-first 要缓存友好"，这是可执行机制）；
- **执行安全**：三档沙箱（read-only 默认 / workspace-write / danger-full-access，seatbelt/landlock/bwrap）+ `permissions.toml`（allow/ask/deny + network/filesystem）+ `execpolicy`；
- **评测与监控**：`TestCodexBuilder` + SSE mock 上游 `/responses` 断言请求体，TUI `insta` 快照，`divan` bench，`otel`/`analytics`/`rollout-trace`——**mock 上游的集成测试**是 harness 回归的可复制范式；
- 官方表述：产品方拥有 product context / business rules / tools，app-server 提供 agent loop。结论不变：**协议先行**（我们 M0 的 `rpc.py` 是它的第一步）。

## 三方对照：融合路线图

| 维度 | dsh | pi | codex | apeiron 取法 |
| --- | --- | --- | --- | --- |
| 循环 | turn/step + 瀑布 pre-step | lane/op + RunPhase | `turn.rs::run_turn` | turn/step 两级 + 事件钩子（注册表+回调，不学 Cordis） |
| 状态 | 事件日志 + `deriveMessages` | entries(write-once)+registers+ledger | rollout + SQLite 投影 | 事件源单一源真；**查询投影与历史分离**学 codex |
| 持久化 | JSONL artifact（zstd） | JSONL v4 / SQLite writer_lease | JSONL + SQLite | 单写者已定；M2 换 Postgres CAS（接口不变） |
| 压缩 | compaction seam（surface 替换、配对保留） | compaction entry 自包含 checkpoint | contextCompaction 压缩态落盘 | compaction v1 = 可选 seam + 事件化（学 dsh） |
| 控制面 | fail-closed 审批 + 权限预设 | steer/followUp/nextRun 三态队列 | 双向 JSON-RPC（approval 是 server→client 请求） | 控制通道与主写路径分离已定；**审批走协议**（学 codex 双向） |
| 沙箱 | 三档 + enforcement full/partial | 无（外部容器） | 三档 + execpolicy 细粒度 | 三档起步 + POSIX 简化（不做宏内核） |
| 插件 | Cordis（DI+事件+可逆效应） | preset 插件（非核心） | plugins/hooks/mcp_servers | **entry points**（已定）；扩展点 = service key + 事件名 |
| 评测 | headless（四指标需从 log 推导） | evals 包 | mock 上游的集成测试 | headless 四指标 = 自研评测层（从 session log 推导） |

## 收敛观察（8-27 加强版）

三家语言、风格完全不同，但状态模型收敛到了**同一个形状**，且比 8-26 记录的更具体：

> 会话 = 不可变追加日志（树结构）+ 一个可重建的投影；**canonical 历史与查询投影分离**，写路径极简、读路径可索引。

pi 的 entries+registers、dsh 的 `SessionEventMap`+`deriveMessages`、codex 的 rollout+SQLite 投影表，
本质是同一件事。另有一条只有 dsh 明说、但三家默示的纪律，我们采纳为**不变量**：
**"模型可见即已记录"**——一切进模型的东西都必须能从日志重建。
我们不需要发明新模型——照抄这个共识，然后把「存储换成分布式」和「语义可复现」这两件他们都没做透的事做好。

## 复核更新与勘误（2026-08-27）

源码级复核（3 个仓库浅克隆 + dsh 实机安装包 `node_modules/@deepseek-ai/*` 交叉验证）修正了 8-26 稿的以下事实：

1. **pi 的"三层"表述不准确**：不是三个包；AgentHarness 与底层运行时同在 `packages/agent`，preset 是 coding-agent 的扩展插件；且 **AgentHarness 耐久层未建成**（上游 TS 与 Python 移植均有 `HarnessNotImplemented`）；权威模型文档是 `packages/agent/docs/harness.md`；
2. **dsh headless "四指标"不存在**：当前版本 headless 只输出最后非空文本 + 退出码；turns/token/耗时/成本需从 session log 推导。M0 `eval.py` 的四指标作为自研评测层保留，但引用需修正；
3. **dsh 公网文档站未开放**（`docs.deepseek.com/harness` NXDOMAIN）；仓库 `docs/*.zh.md` 双语文档才是权威；
4. **"Agent = Model + Harness" 无单一 canonical 出处**（全网检索不到官方单篇；以 DeepSeek Harness 仓库/设计文档为准）；
5. **pi 无权限系统**得到官方 README 确认（"does not include a built-in permission system"，需外部容器化）——8-26 稿的"教训"成立；
6. **pp-agent-core（PyPI）真身在 `github.com/HSPK/pp_agent_core`**（非 earendil-works 系），0.2.1（2026-08-16），import 名 `pi_agent`；
7. **codex 开源版细节**：Bazel+Cargo 双轨、约 119 crate、`sdk/`（Python `openai-codex`/TypeScript）走 app-server 协议；官方文档 `developers.openai.com/codex`；
8. **版本号**：dsh `0.1.1-rc.2`、pi `0.84.3`（8-26 稿未记录）。
