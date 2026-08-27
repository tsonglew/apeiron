---
title: M0 实现记录：结构、bug 与复盘
description: 每个文件为什么存在、parent 链设计、三只 bug 与最有价值的一次语义修正
date: "2026-08-26"
order: 5
---

# 05. M0 实现记录：结构、bug 与复盘

2026-08-26。M0 目标：在一个进程里讲清楚「会话 = 事件溯源日志」，协议先立住。
验收：`uv run pytest -q` 15 个用例通过。

## 结构（为什么每个文件存在）

```
src/apeiron/
  entries.py    Entry/EntryKind/Author：不可变记录模型，payload 版本化
  log.py        SessionLog：进程内追加 + 快照 + restore 重放（内存状态唯一居所）
  store.py      SessionStore Protocol + MemoryStore + SqliteStore（CAS 的证据在存储层）
  loop.py       无状态 run_turn：LLM → 工具 → 回喂；事件流；parent 链
  tools.py      echo 占位 + Permission 分级（READ_ONLY/NEEDS_APPROVAL/DANGEROUS）
  harness.py    phase 状态机 + hooks + turn 级 save point + resume + 守卫
  control.py    控制通道 Protocol + LocalChannel（为分布式留缝，不是为鸡肋而写）
  rpc.py        JSON-RPC 2.0 over stdio：thread/start、thread/add、turn/run、thread/read
  eval.py       TraceWriter + run_headless（trace-first 从 M0 落地）
```

刻意不做的（M0 边界）：真实 provider、权限审批执行、compaction、
子代理、多进程——全部排进 M1/M2，**M0 只验证「状态模型成立」**。

## Loop 的 parent 链设计

一次 turn 的树形结构：`user → tool_call → tool_result → … → assistant`。
`SessionLog.add` 默认把 parent 指向当前 head——这带来一个免费的好处：
**每个 entry 的合法前缀都是可恢复的会话**。这就是 pi 的「追加树」、
codex 的 `thread/fork`、评测需要的「回滚」，三件事共用一根链条。

## 实现过程中修的三个 bug（值得记录）

### Bug 1：SQLite 序列化不对称

`SqliteStore.append` 把 payload `json.dumps` 存进去，`entries` 读出来却是
字符串直接喂给 `from_plain`——**roundtrip 测试跑一遍就炸**：
`entries[0].payload == '{"content": "m1"}'`。
修：读侧 `json.loads` 后再还原。

> 复盘：协议边界（存储/传输）永远要写 roundtrip 测试，一个都不能少。
> 这类 bug 单侧单测看不出来，只有「存→读」成对出现才暴露。

### Bug 2：phase 复位只写了失败路径

`Harness.prompt` 的 guard 结构：`try … except BaseException: 复位 phase; raise`。
看代码，成功路径**忘了复位 phase**——但测试直接抓到 `session.phase is TURN`
而非 `IDLE`。修：成功路径 `session.phase = Phase.IDLE; return entries`。

> 复盘：状态机代码的盲区总是「成功」分支（人会假设『成功嘛，自然是终态』）。
> 以后再写 phase 迁移，先写**终态断言测试**再写逻辑。

### Bug 3：resume 的水位语义（最值钱的一次）

第一版：`Harness._persisted` 记录「每个 session 已落盘的水位」，resume 用它
做 `since`。结果：同一 harness 里第一个会话把该 session_id 推到 2，
新会话 resume 从 2 开始读——**什么都读不到**。
修：水位不应该是全局簿记，而应该是**每个内存日志自己的状态**：

```python
head = session.log.head()
since = head.seq if head else 0
stored = await self.store.entries(session.session_id, since)
```

空日志 = 全量重放（恢复场景），有日志 = 补 tail（幂等、可对同一会话重复调用）。

> 复盘：这是设计语义错误，不是 typo。它暴露的深层问题是——
> **「已持久化」是日志自己的属性，不是 harness 的全局计数器**。
> 这个含义会在 M2 分布式接管时原样放大：
> 接管者不需要知道世界状态，只需要「内存 head + 存储 tail」两条信息。
> 第一版的水位写法到了 M2 会成为「为什么宕机后另一台机器不知道从哪开始」的著名 bug，
> 幸好 M0 就暴露了。

## 坦诚的简化之处

- save point 是 **turn 级**批处理（M1 细化成 pi 式 pending-writes 多边界 flush）；
- 工具失败已捕获（`{"error": …}` 进日志，循环不崩），但**失败工具的审批流未接**；
- `control.py` 留了缝但主循环尚未消费（steer 行为 M1 接）；
- `rpc.serve` 的行分隔 JSON 是 M0 的朴素的实现，M1 加批量/流式响应。

M0 验收之外最重要的产出，其实是**拿这三只虫子证明了方案的合理性**：
状态模型（事件溯源 + 单写者 + 树）在最小的代码里就自洽了，
没有引入任何需要「等 M2 重构」的东西。
