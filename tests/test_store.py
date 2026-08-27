from __future__ import annotations

import pytest

from apeiron.entries import Author, Entry, EntryKind, new_entry
from apeiron.store import MemoryStore, SeqConflict, SqliteStore


def entry(session: str, seq: int) -> Entry:
    return new_entry(
        session, seq, None, Author.USER, EntryKind.USER, {"content": f"m{seq}"}
    )


async def test_memory_roundtrip() -> None:
    store = MemoryStore()
    await store.append(entry("s1", 1))
    await store.append(entry("s1", 2))
    assert [e.seq for e in await store.entries("s1")] == [1, 2]
    assert [e.seq for e in await store.entries("s1", 1)] == [2]
    assert await store.entries("s2") == []


async def test_memory_seq_conflict() -> None:
    store = MemoryStore()
    await store.append(entry("s1", 1))
    with pytest.raises(SeqConflict):
        await store.append(entry("s1", 1))


async def test_sqlite_roundtrip(tmp_path) -> None:
    store = SqliteStore(str(tmp_path / "s.db"))
    await store.append(entry("s1", 1))
    await store.append(entry("s1", 2))
    entries = await store.entries("s1")
    assert [e.seq for e in entries] == [1, 2]
    assert entries[0].payload == {"content": "m1"}
    assert await store.entries("s1", 1) == [entries[1]]


async def test_sqlite_seq_conflict(tmp_path) -> None:
    store = SqliteStore(str(tmp_path / "s.db"))
    await store.append(entry("s1", 5))
    with pytest.raises(SeqConflict):
        await store.append(entry("s1", 5))
