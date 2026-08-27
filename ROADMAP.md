# ROADMAP

> 从基础到复杂功能。每个里程碑以「可验收」结束。
> 为什么这么排、每步的取舍见 [book/06-roadmap-logic.md](book/06-roadmap-logic.md)。

现状：**M0 已完成**（2026-08-26，Python 参照实现，15 tests green）
**2026-08-27：核心迁移至 Zig 并完成 M0-Zig**（八模块齐，21 tests green，见 [book/04](book/04-stack-decisions.md)）；
下文中「M0 已完成」指语义规格已定，Zig 里程碑以 `zig test` 为准。

---

## M0 · 单进程骨架 ✅

**目标**：在一个进程里讲清楚「会话 = 事件溯源日志」，并且把协议先立住。

- `entries / log / store / loop / harness / control / rpc / eval` 八个模块
- SessionStore 接口 + MemoryStore + SqliteStore（`(session_id, seq)` 主键即 CAS）
- JSON-RPC 2.0 over stdio（thread/start、thread/add、turn/run、thread/read）
- trace 落盘（JSONL）与 headless runner 雏形

**验收**：`uv run pytest -q` 15 个用例通过。

## M1 · 单机完整闭环

**目标**：能对真实任务跑出一个可用的单机闭环。

1. **真实 LLM provider**：OpenAI 兼容端点 + Anthropic；重试/降级/超时
2. **插件槽（entry points）**：`apeiron.models / apeiron.tools / apeiron.stores / apeiron.loops / apeiron.hooks`——`pip install` 即插即用
3. **工具集**：bash、文件读写、Web 抓取（READ_ONLY 起步）+ 权限审批流（`auto` / `suggest` 策略，经 control channel 审批）
4. **交互 CLI host**（基于 `rpc.serve`，本地对话/继续会话）
5. **headless 四指标**：turns、token（含 cache 命中率）、耗时、成本 + run-to-run 对比
6. **compaction v1**：turn 数/上下文超阈 → 生成 `SUMMARY` entry（后续重放截断到 checkpoint）
7. **子代理 v1**：tool spawn 子 session，树结构挂到父 session（parentId 免费获得）

**验收**：单机真实任务跑通且 trace 完整；远程会话可 `--resume` 继续。

## M2 · 分布式状态

**目标**：会话状态跨进程/跨机器存活，崩溃无丢失。正确性只压在一个约束上：**每会话单写者 + seq CAS**。

1. **Postgres Store**：`INSERT ON CONFLICT (session_id, seq)` 即 CAS；外部会话可见性
2. **会话 lease**：TTL + 心跳，owner 崩溃后过期接管（恢复语义 = snapshot + tail）
3. **控制通道分布式化**：PG LISTEN/NOTIFY（steer/abort/approve 不占主写路径）
4. **进程模型**：exec-server（后台无 UI，CI 用）与 app-server（嵌入产品）分离
5. **trace 回放**：真实 trace 换 provider 重演，对比行为（模型回归的测试手段）
6. **分片路由**：按 `session_id` 定位存储与单写者

**验收**：kill -9 会话进程后另一进程/机器可无缝接管；恢复后语义与崩溃前一致。

## M3 · 规模与评测

**目标**：多会话、大日志、持续评测。

1. Redis 热读（投影缓存） + S3 冷归档；compaction 自动化（阈值 + 计划任务）
2. WebUI / WebSocket host（订阅事件流推 UI）
3. **评测农场**：headless 批量跑 + dsh 式基准任务集 + run-to-run 对比 + cache 命中统计
4. **stepper**：单步执行/回滚（参考 `mupt-ai/steppable-pi` 的步进式 fork——是评测调试双用途）

## M4 · 生态

1. 插件发布规范 + 官方插件包（bash/fs/http/沙箱）
2. 协议互操作：codex / dsh 作为 subagent 接入（Tree 挂载）或反向被嵌入
3. dogfood：用 apeiron 自身写代码、跑通自举

---

## 排序原则（摘要，详见书 06 章）

- **协议先行**：M0 就定 JSON-RPC——host（CLI/UI/CI）、互操作、评测全依赖它，后改成本极高
- **loop 永远无状态**：M0 起。分布式的正确性是 store 层的责任，核心循环绝不染指
- **评测 M1 接线**：没有 trace 就没有"崩溃恢复后行为一致"的验证手段
- **单写者 + seq，不做 CRDT**：正确性压成一个约束，而不是一套同步协议
- **权限审批 M1 而非 M0**：pi 的教训是缺权限系统，但 M0 先验证核心，M1 立刻补上
