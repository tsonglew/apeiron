"""JSON-RPC 2.0 over stdio：协议层是框架的命脉（codex app-server 的启示）。

M0 四个方法的骨架。所有 host（CLI / TUI / web / CI）和外部 agent
（codex / dsh 互操作）都走这一个协议；payload 走 entries.plain 保持版本化。
"""
from __future__ import annotations

import asyncio
import json
import sys
from typing import Any, TextIO

from .entries import Author, Entry, EntryKind, SessionId, plain
from .harness import Harness, Session


class RpcError(Exception):
    def __init__(self, code: int, message: str) -> None:
        self.code = code
        self.message = message

    def to_json(self, request_id: Any) -> dict[str, Any]:
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": self.code, "message": self.message},
        }


class RpcServer:
    """方法名 -> m_<method with / replaced by _>；M1 起用 JSON Schema 生成规范。"""

    def __init__(self, harness: Harness) -> None:
        self.harness = harness
        self._threads: dict[str, Session] = {}

    def _get(self, thread_id: str) -> Session:
        session = self._threads.get(thread_id)
        if session is None:
            raise RpcError(-32000, f"thread not found: {thread_id}")
        return session

    async def handle(self, request: dict[str, Any]) -> dict[str, Any]:
        request_id = request.get("id")
        method = request.get("method")
        params = request.get("params") or {}
        try:
            handler = getattr(self, "m_" + method.replace("/", "_"))
        except (AttributeError, TypeError):
            return RpcError(-32601, f"method not found: {method}").to_json(request_id)
        try:
            result = await handler(params)
            return {"jsonrpc": "2.0", "id": request_id, "result": result}
        except RpcError as exc:
            return exc.to_json(request_id)
        except Exception as exc:
            return RpcError(-32603, f"internal error: {exc}").to_json(request_id)

    # ---- methods ----

    async def m_thread_start(self, params: dict[str, Any]) -> dict[str, Any]:
        session = await self.harness.create_session()
        self._threads[session.session_id] = session
        return {"thread_id": session.session_id}

    async def m_thread_add(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self._get(params["thread_id"])
        kind = EntryKind(params.get("kind", "user"))
        if kind not in (EntryKind.USER, EntryKind.SUMMARY, EntryKind.CHECKPOINT):
            raise RpcError(-32602, f"thread/add 不支持 kind: {kind.value}")
        author = Author.USER if kind is EntryKind.USER else Author.SYSTEM
        entry = session.log.add(
            author,
            kind,
            params.get("payload") or {},
            parent_id=params.get("parent_id"),
        )
        await self.harness.save_point(session)
        return plain(entry)

    async def m_turn_run(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self._get(params["thread_id"])
        entries = await self.harness.prompt(session, params["message"])
        return {"entries": [plain(e) for e in entries]}

    async def m_thread_read(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self._get(params["thread_id"])
        since = params.get("since_seq", 0)
        return {"entries": [plain(e) for e in session.log.entries(since)]}


async def serve(
    rpc: RpcServer,
    stdin: TextIO | None = None,
    stdout: TextIO | None = None,
) -> None:
    """逐行读取 JSON 请求并回写响应（行分隔 JSON-RPC）。"""
    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout
    while True:
        line = await asyncio.to_thread(stdin.readline)
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            response: dict[str, Any] = await rpc.handle(request)
        except json.JSONDecodeError:
            response = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32700, "message": "parse error"},
            }
        await asyncio.to_thread(stdout.write, json.dumps(response) + "\n")
        await asyncio.to_thread(stdout.flush)
