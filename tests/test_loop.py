from __future__ import annotations

from apeiron.entries import EntryKind
from apeiron.log import SessionLog
from apeiron.loop import EventType, LLMResponse, ToolCall, messages_from_log, run_turn
from apeiron.tools import ECHO

from conftest import FakeProvider


async def test_turn_with_tool_then_final() -> None:
    log = SessionLog("s1")
    seen: list[EventType] = []

    async def on_event(event) -> None:
        seen.append(event.type)

    provider = FakeProvider(
        [
            LLMResponse(content=None, tool_calls=[ToolCall(id="t1", name="echo", args={"text": "hi"})]),
            LLMResponse(content="done"),
        ]
    )
    entries, messages = await run_turn(
        log, [], provider, [ECHO], "say hi", on_event=on_event
    )

    assert [e.kind for e in entries] == [
        EntryKind.USER,
        EntryKind.TOOL_CALL,
        EntryKind.TOOL_RESULT,
        EntryKind.ASSISTANT,
    ]
    assert entries[2].payload == {"tool_call_id": "t1", "output": "hi"}
    assert messages[-1] == {"role": "assistant", "content": "done"}
    assert seen == [
        EventType.TURN_START,
        EventType.TOOL_CALL,
        EventType.TOOL_RESULT,
        EventType.MESSAGE_END,
        EventType.TURN_END,
    ]


async def test_unknown_tool_becomes_error_result() -> None:
    log = SessionLog("s1")
    provider = FakeProvider(
        [LLMResponse(content=None, tool_calls=[ToolCall(id="t1", name="nope", args={})])]
    )
    entries, _ = await run_turn(log, [], provider, [ECHO], "x")
    assert "error" in entries[2].payload


async def test_messages_from_log_rebuilds_chat() -> None:
    log = SessionLog("s1")
    # run a real turn then rebuild messages from log entries
    provider = FakeProvider(
        [
            LLMResponse(content=None, tool_calls=[ToolCall(id="t1", name="echo", args={"text": "hi"})]),
            LLMResponse(content="ok"),
        ]
    )
    await run_turn(log, [], provider, [ECHO], "go")
    rebuilt = messages_from_log(log.entries(0))
    assert [m["role"] for m in rebuilt] == ["user", "assistant", "tool", "assistant"]
    assert rebuilt[1]["tool_calls"][0]["name"] == "echo"
    assert rebuilt[2]["content"] == '{"output": "hi"}'
    assert rebuilt[3]["content"] == "ok"
