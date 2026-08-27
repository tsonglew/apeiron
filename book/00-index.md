---
title: 目录
description: 这本书是什么、如何阅读、如何维护
date: "2026-08-26"
order: 0
---

# 《apeiron 构建手记》

> 记录 apeiron——一个面向有状态智能体（含分布式状态存储）的 agent harness——
> 从零到一的完整思考过程：为什么做、参考了什么、决定留下什么、删掉什么、实现时踩了什么坑。

## 这本书是什么

- **不是 API 文档**。接口和 docstring 在代码里（`src/apeiron/`）。
- **不是博客**。它是与代码并行的**决策日志（decision log）**：每个章节记录一个阶段的
  思考、取舍、实现重点与事后复盘。
- 与 [ROADMAP.md](../ROADMAP.md) 配合：roadmap 说「做哪些、按什么顺序」，
  本书说「为什么、怎么想的」。

## 约定

- 日期用 YYYY-MM-DD；里程碑编号（M0/M1/…）与 ROADMAP 对齐
- 章节按时间线组织；追溯时从后往前读
- 存疑或尚未验证的观点标 ⚠️ 和日期

## 目录

| 章节 | 内容 |
| --- | --- |
| [01](01-problem.md) | 问题：为什么需要 harness，状态为什么是核心 |
| [02](02-reference-designs.md) | 三个参考：pi、DeepSeek Harness、Codex Harness 的解剖与借鉴 |
| [03](03-core-principles.md) | 核心设计判断：五条原则 |
| [04](04-stack-decisions.md) | 语言与生态：Rust → Python 的决策过程 |
| [05](05-m0-implementation.md) | M0 实现记录：结构、bug 与复盘 |
| [06](06-roadmap-logic.md) | 路线图为什么这样排 |

## 如何维护

写完一章的当下就更新正文（先记录、后润色）；每次里程碑验收时补一节「复盘」。
