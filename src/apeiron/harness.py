"""编排层：session 生命周期、phase 状态机、hook 与 save point。

一次 turn 的安全边界：IDLE -> TURN ->（save point）-> IDLE。
M0 的 save point 是「turn 结束后批量落盘」；M1 起细化成 pi 式
pending writes 在多个边界 flush，崩溃后从 last_seq 重放即可。
"""
from __future__ import annotations

import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from enum import StrEnum
from typing import Any

from .entries import Entry, SessionId
from .log import SessionLog
from .loop import (
    Event,
    LLMProvider,
    Tool,
    messages_from_log,
    run_turn,
)
from .store import SessionStore

Hook = Callable[[SessionId], Awaitable[None]]


class Phase(StrEnum):
    IDLE = "idle"
    TURN = "turn"
    COMPACT = "compact"
    ABORTED = "aborted"


class HarnessBusy(Exception):
    """会话非空闲时收到 prompt（对应 pi 的 LaneBusy）。"""


@dataclass(slots=True)
class Hooks:
    before_turn: Hook | None = None
    after_turn: Hook | None = None
    on_save_point: Hook | None = None


@dataclass
class Session:
    session_id: SessionId
    log: SessionLog
    messages: list[dict[str, Any]]
    phase: Phase = Phase.IDLE


class Harness:
    def __init__(
        self,
        store: SessionStore,
        provider: LLMProvider,
        tools: list[Tool] | None = None,
        hooks: Hooks | None = None,
    ) -> None:
        self.store = store
        self.provider = provider
        self.tools = tools or []
        self.hooks = hooks or Hooks()
        self._persisted: dict[SessionId, int] = {}

    async def create_session(self, session_id: SessionId | None = None) -> Session:
        """创建会话；传 session_id 用于「恢复到指定会话」。"""
        session_id = session_id or uuid.uuid4().hex
        return Session(session_id=session_id, log=SessionLog(session_id), messages=[])

    async def prompt(
        self,
        session: Session,
        message: str,
        *,
        on_event: Callable[[Event], Awaitable[None]] | None = None,
    ) -> list[Entry]:
        if session.phase is not Phase.IDLE:
            raise HarnessBusy(f"session {session.session_id} is {session.phase.value}")
        session.phase = Phase.TURN
        try:
            if self.hooks.before_turn is not None:
                await self.hooks.before_turn(session.session_id)
            entries, messages = await run_turn(
                session.log,
                session.messages,
                self.provider,
                self.tools,
                message,
                on_event=on_event,
            )
            session.messages = messages
            await self.save_point(session)
            if self.hooks.after_turn is not None:
                await self.hooks.after_turn(session.session_id)
            session.phase = Phase.IDLE
            return entries
        except BaseException:  # 含 CancelledError：phase 必须复位，恢复靠存储重放
            if session.phase is Phase.TURN:
                session.phase = Phase.IDLE
            raise

    async def save_point(self, session: Session) -> None:
        """把未落盘的 entries 批量写进存储（M0 粒度：turn 级）。"""
        since = self._persisted.get(session.session_id, 0)
        pending = session.log.entries(since)
        for entry in pending:
            await self.store.append(entry)
        head = session.log.head()
        self._persisted[session.session_id] = head.seq if head else 0
        if self.hooks.on_save_point is not None:
            await self.hooks.on_save_point(session.session_id)

    async def resume(self, session: Session) -> None:
        """从存储把内存日志 head 之后的 entries 重放进来并重建 messages。

        空日志即全量重放（恢复场景）；已有日志只补 tail（幂等）。
        后续 M2 改为 snapshot + tail：先从快照恢复 last_seq，再取增量。
        """
        head = session.log.head()
        since = head.seq if head else 0
        stored = await self.store.entries(session.session_id, since)
        session.log.restore(stored)
        session.messages = messages_from_log(session.log.entries(0))
        head = session.log.head()
        self._persisted[session.session_id] = head.seq if head else 0

    async def abort(self, session: Session) -> None:
        session.phase = Phase.ABORTED
