from __future__ import annotations

import pytest

from apeiron.entries import EntryKind
from apeiron.harness import Harness, HarnessBusy, Hooks, Phase
from apeiron.loop import LLMResponse
from apeiron.tools import ECHO
from apeiron.store import MemoryStore

from conftest import FakeProvider


async def test_prompt_flushes_to_store_and_resume() -> None:
    store = MemoryStore()
    harness = Harness(store, FakeProvider([LLMResponse(content="hello")]), [ECHO])
    session = await harness.create_session()

    entries = await harness.prompt(session, "hi")
    assert [e.kind for e in entries] == [EntryKind.USER, EntryKind.ASSISTANT]
    assert session.phase is Phase.IDLE

    stored = await store.entries(session.session_id)
    assert [e.seq for e in stored] == [1, 2]

    # 新会话（同 ID）resume：从存储重放，重建完全一样的聊天消息
    fresh_session = await harness.create_session(session_id=session.session_id)
    await harness.resume(fresh_session)
    assert [m["role"] for m in fresh_session.messages] == ["user", "assistant"]
    assert fresh_session.messages[1]["content"] == "hello"


async def test_prompt_busy_guard() -> None:
    harness = Harness(MemoryStore(), FakeProvider([]), [ECHO])
    session = await harness.create_session()
    session.phase = Phase.TURN
    with pytest.raises(HarnessBusy):
        await harness.prompt(session, "x")


async def test_save_point_hook_fires() -> None:
    calls: list[int] = []

    async def on_save_point(session_id: str) -> None:
        calls.append(1)

    harness = Harness(
        MemoryStore(),
        FakeProvider([LLMResponse(content="ok")]),
        hooks=Hooks(on_save_point=on_save_point),
    )
    session = await harness.create_session()
    await harness.prompt(session, "hi")
    assert calls == [1]
