"""控制通道：steer / abort / approve 与主写路径分离。

本地实现是每会话一个 asyncio.Queue；分布式后换成
Postgres LISTEN/NOTIFY 或 Redis Stream，Protocol 不变。
主循环只在下一次安全边界（turn 之间 / tool 之间）消费它。
"""
from __future__ import annotations

import asyncio
from typing import Any, Protocol

from .entries import SessionId


class ControlChannel(Protocol):
    async def send(self, session: SessionId, message: dict[str, Any]) -> None: ...
    async def receive(
        self, session: SessionId, timeout: float | None = None
    ) -> dict[str, Any] | None: ...


class LocalChannel:
    """单进程实现（M0）。"""

    def __init__(self) -> None:
        self._queues: dict[SessionId, asyncio.Queue[dict[str, Any]]] = {}

    def _queue(self, session: SessionId) -> asyncio.Queue[dict[str, Any]]:
        if session not in self._queues:
            self._queues[session] = asyncio.Queue()
        return self._queues[session]

    async def send(self, session: SessionId, message: dict[str, Any]) -> None:
        await self._queue(session).put(message)

    async def receive(
        self, session: SessionId, timeout: float | None = None
    ) -> dict[str, Any] | None:
        if timeout is None:
            return await self._queue(session).get()
        try:
            return await asyncio.wait_for(self._queue(session).get(), timeout)
        except TimeoutError:
            return None
