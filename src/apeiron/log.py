"""进程内会话日志：追加 + 查询 + 快照。

存储层之外的唯一内存状态；持久化由 SessionStore 承担。
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .entries import Author, Entry, EntryId, EntryKind, SessionId, new_entry


@dataclass(frozen=True, slots=True)
class Snapshot:
    """压缩边界：last_seq 之后的 Entry 需要从存储重放。"""

    last_seq: int
    summary: dict[str, Any] | None = None


class SessionLog:
    def __init__(self, session: SessionId) -> None:
        self.session = session
        self._entries: list[Entry] = []
        self._by_id: dict[EntryId, Entry] = {}

    def add(
        self,
        author: Author,
        kind: EntryKind,
        payload: dict[str, Any],
        *,
        parent_id: EntryId | None = None,
    ) -> Entry:
        if parent_id is None:
            head = self.head()
            parent_id = head.entry_id if head is not None else None
        entry = new_entry(
            session=self.session,
            seq=len(self._entries) + 1,  # 1-based；恢复时由 restore 续接
            parent_id=parent_id,
            author=author,
            kind=kind,
            payload=payload,
        )
        self._entries.append(entry)
        self._by_id[entry.entry_id] = entry
        return entry

    def head(self) -> Entry | None:
        return self._entries[-1] if self._entries else None

    def entries(self, since_seq: int = 0) -> list[Entry]:
        return [e for e in self._entries if e.seq > since_seq]

    def find(self, entry_id: EntryId) -> Entry | None:
        return self._by_id.get(entry_id)

    def snapshot(self) -> Snapshot:
        head = self.head()
        return Snapshot(last_seq=head.seq if head else 0)

    def restore(self, entries: list[Entry]) -> None:
        """从存储回放：要求按 seq 升序且属于同一会话。"""
        for entry in entries:
            assert entry.session == self.session
            self._entries.append(entry)
            self._by_id[entry.entry_id] = entry
