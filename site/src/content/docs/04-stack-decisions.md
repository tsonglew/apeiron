---
title: 语言与生态：Rust → Python → Zig
description: 一个真实的决策过程——先是 Rust，当天换成 Python，M0 之后又换 Zig；每次的代价清单
publishDate: "2026-08-26"
order: 4
---

# 04. 语言与生态：Rust → Python → Zig

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

## 落定的技术选择（8-26 第二轮，历史记录）

| 决策点 | 选择 | 理由 |
| --- | --- | --- |
| 类型 | dataclasses + `typing.Protocol` | 核心零依赖；M1 协议边界再考虑 pydantic |
| 存储 | stdlib `sqlite3` + `asyncio.to_thread` | M0 零依赖跑起来；M2 换 asyncpg（接口不变） |
| 并发 | asyncio 单事件循环 + 每会话 actor（queue + task） | 单写者本地版 |
| 取消 | `CancelledError` 在 save point 边界复位 phase | 恢复=存储重放，内存状态随时可扔 |
| 运行时 | Python ≥ 3.12（StrEnum/dataclass slots） | 开发机 3.14 |

## 第三轮：M0 之后换成 Zig（2026-08-27）

用户拍板：**整个框架用 Zig 实现，M0 起重写**；Python 版 M0 保留为
「设计规格 + 测试语义参照」，不再演进；**教程网页的交互演示 = Zig 编译
WASM 跑真实核心**。这是书里 8-26 明示过的"最贵情形"——换语言发生在
M0 完成之后。为什么仍然成立：

1. **WASM 单轨（决定性理由）**：教程要求交互式演示。Zig 是本研究界
   编译 WASM 摩擦最小的语言：`-target wasm32-freestanding` 一条命令、
   无 GC、无运行时依赖；浏览器里跑的就是 harness 真身（事件日志、循环、
   回放、工具调用）——**演示即真相**，与 trace-first 精神同源；
2. **第一轮 Rust 的理由在 Zig 同样成立且更轻**：typestate 用 Zig 的
   结构类型 + comptime 更手到擒来；单写者纪律靠所有权（无借用检查器的
   激进，但有指针纪律）；单二进制 + 静态链接对沙箱/工具安全实在；
   无 GC 停顿对 IO-bound 的核心循环无妨；
3. **插件生态重新权衡**：Python entry points 的"进程内动态插件"优势
   依然真实，但协议先行原则给了更对等的替代——**插件即独立二进制/独立
   进程，按协议接入**（codex app-server 路线；dsh 的 subagent seam
   也证明"跨产品的协议化委派"才是生态方向）。M1 插件槽的实现形式从
   entry points 改为协议插件 + 注册表，语义不变；
4. **工具链成本的一面**：Zig 无包管理器（标准库里 JSON/HTTP 需自建或用
   第三方 vendored），但核心对依赖的要求本来就低（M0 零依赖的哲学延续）。

**代价清单（诚实记录）**：

- M0 八个模块按语义重写（`entries/log/store/loop/harness/control/rpc/eval`
  的数据结构与接口保持不变——它们是设计，语言只是实现）；
- 内存与错误处理：error union 显式处理、Slice/arena 生命周期管理；
- 构建：`pyproject.toml + uv` → `build.zig`；测试：pytest → `zig test`
  （迁移 15 个用例）；
- JSON/序列化：手写或 vendored 库（协议层 M1 再定）；
- 异步：asyncio → 自实现 event loop 或线程池（工具调用多为进程 spawn，
  需求简单）。

**为什么这次切换仍然不推翻设计**：架构（事件溯源、单写者、协议、插件槽、
trace-first）依旧是语言无关的；变的只是实现形态——
asyncio actor → 自管 event loop、dataclasses → 普通 struct、
异常守卫 → error union + 显式状态检查。**但这次例外成立的前提是**
Python M0 的语义参照完整（15 用例 + book 决策日志），
重写不是从零开始，而是"换语言照抄语义"。
