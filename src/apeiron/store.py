"""SessionStore 接口与内建后端：内存 / SQLite。

分布式路线：PostgreSQL 等后端实现同一接口——(session_id, seq) 主键即 CAS，
append 冲突即单写者被破坏。M0 用 stdlib sqlite3（asyncio.to_thread 隔离阻塞 IO），
后续可换 aiosqlite/asyncpg，接口不变。
"""
from __future__ import annotations

import asyncio
import json
import sqlite3
from typing import Protocol

from .entries import Entry, SessionId, from_plain, plain


class SessionNotFound(Exception):
    """会话不存在或没有记录。"""


class SeqConflict(Exception):
    """(session_id, seq) 冲突：单写者被破坏或重复提交。"""


class SessionStore(Protocol):
    async def append(self, entry: Entry) -> None: ...
    async def entries(self, session: SessionId, since_seq: int = 0) -> list[Entry]: ...
    async def close(self) -> None: ...


class MemoryStore:
    """进程内存储：单测与本地开发用。"""

    def __init__(self) -> None:
        self._logs: dict[SessionId, list[Entry]] = {}

    async def append(self, entry: Entry) -> None:
        log = self._logs.setdefault(entry.session, [])
        if any(e.seq == entry.seq for e in log):
            raise SeqConflict(f"{entry.session}@{entry.seq}")
        log.append(entry)

    async def entries(self, session: SessionId, since_seq: int = 0) -> list[Entry]:
        return [e for e in self._logs.get(session, []) if e.seq > since_seq]

    async def close(self) -> None:
        return None


class SqliteStore:
    """SQLite 后端：每个操作独立连接（WAL），append 原子性由主键保证。

    注意：按会话串行 append 即可；多写者并发写同一会话时，后者收到 SeqConflict——
    这是特性，不是 bug（单写者 <=> 每秒序只有一个作者）。
    """

    def __init__(self, path: str) -> None:
        self._path = path

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self._path)
        conn.execute(
            "CREATE TABLE IF NOT EXISTS entries ("
            "session_id TEXT NOT NULL,"
            " seq INTEGER NOT NULL,"
            " entry_id TEXT NOT NULL,"
            " parent_id TEXT,"
            " author TEXT NOT NULL,"
            " kind TEXT NOT NULL,"
            " payload TEXT NOT NULL,"
            " created_at REAL NOT NULL,"
            " schema_version INTEGER NOT NULL,"
            " PRIMARY KEY (session_id, seq))"
        )
        return conn

    async def _run(self, fn, *args):
        return await asyncio.to_thread(fn, *args)

    async def append(self, entry: Entry) -> None:
        def op() -> None:
            conn = self._connect()
            try:
                conn.execute(
                    "INSERT INTO entries (session_id, seq, entry_id, parent_id,"
                    " author, kind, payload, created_at, schema_version)"
                    " VALUES (?,?,?,?,?,?,?,?,?)",
                    (
                        entry.session,
                        entry.seq,
                        entry.entry_id,
                        entry.parent_id,
                        entry.author.value,
                        entry.kind.value,
                        json.dumps(entry.payload),
                        entry.created_at,
                        entry.schema_version,
                    ),
                )
                conn.commit()
            except sqlite3.IntegrityError as exc:
                raise SeqConflict(f"{entry.session}@{entry.seq}") from exc
            finally:
                conn.close()

        await self._run(op)

    async def entries(self, session: SessionId, since_seq: int = 0) -> list[Entry]:
        def op() -> list[Entry]:
            conn = self._connect()
            try:
                rows = conn.execute(
                    "SELECT session_id, seq, entry_id, parent_id, author, kind,"
                    " payload, created_at, schema_version FROM entries"
                    " WHERE session_id = ? AND seq > ? ORDER BY seq",
                    (session, since_seq),
                ).fetchall()
                cols = [
                    "session",
                    "seq",
                    "entry_id",
                    "parent_id",
                    "author",
                    "kind",
                    "payload",
                    "created_at",
                    "schema_version",
                ]
                result = []
                for row in rows:
                    data = dict(zip(cols, row))
                    data["payload"] = json.loads(data["payload"])
                    result.append(from_plain(data))
                return result
            finally:
                conn.close()

        return await self._run(op)

    async def close(self) -> None:
        return None
