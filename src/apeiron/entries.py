"""事件溯源模型：会话由不可变 Entry 序列构成。"""
from __future__ import annotations

import time
import uuid
from dataclasses import dataclass, field
from enum import StrEnum
from typing import Any

SessionId = str
EntryId = str
SCHEMA_VERSION = 1


class EntryKind(StrEnum):
    USER = "user"
    ASSISTANT = "assistant"
    TOOL_CALL = "tool_call"
    TOOL_RESULT = "tool_result"
    SUMMARY = "summary"
    CHECKPOINT = "checkpoint"


class Author(StrEnum):
    USER = "user"
    MODEL = "model"
    TOOL = "tool"
    HOOK = "hook"
    SYSTEM = "system"


@dataclass(frozen=True, slots=True)
class Entry:
    """一条不可变会话记录。

    seq 在会话内单调递增（存储层乐观并发控制的唯一依据）；
    parent_id 指向树式历史：fork / 重试 / 并行 lane / 子代理都建立在树上。
    payload 的演进靠 schema_version 兼容，不破坏旧存档。
    """

    session: SessionId
    seq: int
    entry_id: EntryId
    parent_id: EntryId | None
    author: Author
    kind: EntryKind
    payload: dict[str, Any]
    created_at: float = field(default_factory=time.time)
    schema_version: int = SCHEMA_VERSION


def new_entry(
    session: SessionId,
    seq: int,
    parent_id: EntryId | None,
    author: Author,
    kind: EntryKind,
    payload: dict[str, Any],
) -> Entry:
    return Entry(
        session=session,
        seq=seq,
        entry_id=uuid.uuid4().hex,
        parent_id=parent_id,
        author=author,
        kind=kind,
        payload=payload,
    )


def plain(entry: Entry) -> dict[str, Any]:
    """序列化到 JSON / 传输协议。"""
    return {
        "session": entry.session,
        "seq": entry.seq,
        "entry_id": entry.entry_id,
        "parent_id": entry.parent_id,
        "author": entry.author.value,
        "kind": entry.kind.value,
        "payload": entry.payload,
        "created_at": entry.created_at,
        "schema_version": entry.schema_version,
    }


def from_plain(data: dict[str, Any]) -> Entry:
    return Entry(
        session=data["session"],
        seq=data["seq"],
        entry_id=data["entry_id"],
        parent_id=data["parent_id"],
        author=Author(data["author"]),
        kind=EntryKind(data["kind"]),
        payload=data["payload"],
        created_at=data["created_at"],
        schema_version=data.get("schema_version", SCHEMA_VERSION),
    )
