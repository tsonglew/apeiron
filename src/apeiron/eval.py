"""评测：headless 运行 + trace 落盘（model-visible means logged）。

M0 只有 TraceWriter + run_headless；M1 补四指标（turns/token/耗时/成本）
与 trace 回放（换 provider 重演同一条 trace，对比行为）。
"""
from __future__ import annotations

import json
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

from .entries import Entry
from .harness import Harness

TraceSink = Callable[[dict[str, Any]], None]


@dataclass(slots=True)
class TraceWriter:
    """JSONL 追加写入器。每个可观察事件一行，是审计与回放的数据底座。"""

    path: str
    _file: Any = field(default=None, repr=False)

    def __post_init__(self) -> None:
        self._file = open(self.path, "w", encoding="utf-8")

    def __enter__(self) -> "TraceWriter":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def close(self) -> None:
        if self._file is not None:
            self._file.close()
            self._file = None

    def write(self, record: dict[str, Any]) -> None:
        assert self._file is not None, "trace writer closed"
        self._file.write(json.dumps(record) + "\n")
        self._file.flush()


async def run_headless(
    harness: Harness,
    message: str,
    trace_path: str | None = None,
) -> list[Entry]:
    """无 UI 跑一条任务：新建会话 -> prompt -> 返回 entries；可同时落 trace。"""
    session = await harness.create_session()
    if trace_path is None:
        return await harness.prompt(session, message)
    with TraceWriter(trace_path) as writer:

        async def on_event(event) -> None:
            writer.write(
                {
                    "type": "event",
                    "session": session.session_id,
                    "event": event.type.value,
                    **event.payload,
                }
            )

        entries = await harness.prompt(session, message, on_event=on_event)
        return entries
