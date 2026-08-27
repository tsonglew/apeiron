---
title: 语言与生态：Rust → Python
description: 一个真实的决策过程——先是 Rust，当天换成 Python，以及代价清单
publishDate: "2026-08-26"
order: 4
---

# 04. 语言与生态：Rust → Python

2026-08-26。这是一个真实的决策过程，不是选定论先行的回忆。

## 第一轮：Rust（约 20 分钟）

在设计讨论时，我先问用户（技术栈 + 用途），回答是 **Rust + 通用开源框架**。
当时的论证：

1. **类型即状态机**：pi 的 phase 状态机靠运行时枚举检查（`prompt` 只在 `IDLE`
   时允许，违反抛 `LaneBusy`）；Rust 用 typestate 把非法状态编译期消灭；
2. **单写者纪律免费**：每会话一个 actor（tokio task + channel），所有权天然保证
   读写分离，与分布式 lease 语义 1:1；
3. **单二进制**：`apeiron serve` 即完整 app-server（codex 路线），
   沙箱/静态链接对工具安全有实在好处；
4. 认真面对了 Rust 的短板：插件生态没有等价物，设计了 WASM（wasmtime +
   wit）作为动态插件层。

## 第二轮：换成 Python（当天）

用户拍板：**换成 Python**。事后复盘，这个决定把方案改得更简单而不是更弱：

- **插件问题直接消失**：Python 的 entry points（`pip install` 即插件，
  `apeiron.models/apeiron.tools/...` 每个是一个 entry-point 组）天然等价于
  dsh 的 Cordis 插件机制——**动态插件是语言原生能力**，不需要 wasmtime；
- **团队迭代速度**：改动即跑，eval 生态（huggingface 等）现成；
  `pp-agent-core`（pi 的 PyPI 移植）已验证三层模型可搬到 Python——
  但它恰恰**没实现 AgentHarness 层**（`HarnessNotImplemented`），
  我们要补的正是这块空白本身；
- **代价清单（诚实记录）**：
  - typestate 没了 → phase 枚举 + 运行时守卫 + `HarnessBusy` 异常；
  - 性能上限低 → 可接受：harness 是 IO-bound（LLM 调用占大头），
    评测农场用 asyncio 并发，单进程可挂上千个会话 actor；
  - 阻塞调用纪律 → **核心循环里禁止同步阻塞**：
    `asyncio.to_thread`（sqlite/file）与 `create_subprocess_exec`（shell）是唯一出口。

## 落定的技术选择

| 决策点 | 选择 | 理由 |
| --- | --- | --- |
| 类型 | dataclasses + `typing.Protocol` | 核心零依赖；M1 协议边界再考虑 pydantic |
| 存储 | stdlib `sqlite3` + `asyncio.to_thread` | M0 零依赖跑起来；M2 换 asyncpg（接口不变） |
| 并发 | asyncio 单事件循环 + 每会话 actor（queue + task） | 单写者本地版 |
| 取消 | `CancelledError` 在 save point 边界复位 phase | 恢复=存储重放，内存状态随时可扔 |
| 运行时 | Python ≥ 3.12（StrEnum/dataclass slots） | 开发机 3.14 |

## 为什么这个切换不推翻设计

第二轮的方案里，架构（事件溯源、单写者、协议、插件槽、trace-first）
与语言无关；切换只影响**实现形态**：typestate → 守卫、
Rust 插件三层 → entry points 一层、channel → asyncio.Queue。
所以换语言发生在「搭 M0 之前」，代价 = 0；
如果发生在 M2 之后，代价就是全部重写——**架构决策宁可先慢一天，不可先错一步**。
