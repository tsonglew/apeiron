from __future__ import annotations

from apeiron.entries import Author, EntryKind, from_plain, new_entry, plain
from apeiron.log import SessionLog


def test_new_entry_fields() -> None:
    e = new_entry("s1", 1, None, Author.USER, EntryKind.USER, {"content": "hi"})
    assert e.seq == 1
    assert e.entry_id
    assert e.parent_id is None
    assert e.schema_version == 1


def test_plain_roundtrip() -> None:
    e = new_entry("s1", 3, "p1", Author.MODEL, EntryKind.ASSISTANT, {"content": "x"})
    assert from_plain(plain(e)) == e


def test_log_add_seq_and_parent() -> None:
    log = SessionLog("s1")
    a = log.add(Author.USER, EntryKind.USER, {"content": "x"})
    b = log.add(Author.MODEL, EntryKind.ASSISTANT, {"content": "y"})
    assert (a.seq, b.seq) == (1, 2)
    assert b.parent_id == a.entry_id
    assert [e.seq for e in log.entries(1)] == [2]
    assert log.find(b.entry_id) is b
    assert log.snapshot().last_seq == 2
