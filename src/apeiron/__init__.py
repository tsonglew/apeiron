"""apeiron —— 面向有状态智能体的 agent harness。

核心思想：会话是事件溯源的不可变 Entry 序列（单一源真），
AgentState 只是它的投影；存储层可插拔，单进程 SQLite 与分布式后端走同一接口。
"""

__version__ = "0.1.0"
