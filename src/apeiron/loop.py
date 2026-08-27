"""无状态 agent 循环：消息 -> LLM -> 工具执行 -> 回喂。

本模块不持有状态（SessionLog 归调用方所有），因此可单测、可重放——
这是「分布式」成立的前提：任何一个进程都能用同一份日志重演同一段交互。
"""
from __future__ import annotations

import json
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from enum import StrEnum
from typing import Any, Protocol

from .entries import Author, Entry, EntryKind
from .log import SessionLog

DEFAULT_MAX_TOOL_ROUNDS = 16


class Permission(StrEnum):
    """工具权限分级（M1 接入审批流）。"""

    READ_ONLY = "read_only"
    NEEDS_APPROVAL = "needs_approval"
    DANGEROUS = "dangerous"


@dataclass(slots=True)
class Tool:
    name: str
    description: str
    input_schema: dict[str, Any]
    permission: Permission
    handler: Callable[[dict[str, Any]], Awaitable[str]]

    def spec(self) -> dict[str, Any]:
        return {
            "type": "function",
            "function": {
                "name": self.name,
                "description": self.description,
                "parameters": self.input_schema,
            },
        }


@dataclass(slots=True)
class ToolCall:
    id: str
    name: str
    args: dict[str, Any]


@dataclass(slots=True)
class LLMResponse:
    content: str | None
    tool_calls: list[ToolCall] | None = None
    usage: dict[str, Any] | None = None


class LLMProvider(Protocol):
    """模型提供方：M1 起做成插件槽（OpenAI 兼容端点 / Anthropic / 本地模型）。"""

    name: str

    async def complete(
        self, messages: list[dict[str, Any]], tools: list[Tool]
    ) -> LLMResponse: ...


class EventType(StrEnum):
    TURN_START = "turn_start"
    TOOL_CALL = "tool_call"
    TOOL_RESULT = "tool_result"
    MESSAGE_END = "message_end"
    TURN_END = "turn_end"


@dataclass(frozen=True, slots=True)
class Event:
    type: EventType
    payload: dict[str, Any]


async def run_turn(
    log: SessionLog,
    messages: list[dict[str, Any]],
    provider: LLMProvider,
    tools: list[Tool],
    message: str,
    *,
    on_event: Callable[[Event], Awaitable[None]] | None = None,
    max_rounds: int = DEFAULT_MAX_TOOL_ROUNDS,
) -> tuple[list[Entry], list[dict[str, Any]]]:
    """执行一次完整 turn：追加 user entry、循环 LLM+工具、返回新 entries 与消息。

    parent 链路：user -> tool_call -> tool_result -> ... -> assistant。
    """

    async def emit(type: EventType, **payload: Any) -> None:
        if on_event is not None:
            await on_event(Event(type, payload))

    user_entry = log.add(Author.USER, EntryKind.USER, {"content": message})
    messages = [*messages, {"role": "user", "content": message}]
    new_entries: list[Entry] = [user_entry]
    tool_index = {tool.name: tool for tool in tools}
    await emit(EventType.TURN_START, seq=user_entry.seq)

    for _ in range(max_rounds):
        response = await provider.complete(messages, tools)
        if response.tool_calls:
            for call in response.tool_calls:
                head = log.head()
                call_entry = log.add(
                    Author.MODEL,
                    EntryKind.TOOL_CALL,
                    {"tool_call_id": call.id, "name": call.name, "args": call.args},
                    parent_id=head.entry_id if head else None,
                )
                await emit(
                    EventType.TOOL_CALL,
                    seq=call_entry.seq,
                    name=call.name,
                    args=call.args,
                )
                tool = tool_index.get(call.name)
                if tool is None:
                    data = {"error": f"unknown tool: {call.name}"}
                else:
                    try:
                        data = {"output": await tool.handler(call.args)}
                    except Exception as exc:  # 工具失败也要落日志，不能带崩循环
                        data = {"error": f"{type(exc).__name__}: {exc}"}
                result_entry = log.add(
                    Author.TOOL,
                    EntryKind.TOOL_RESULT,
                    {"tool_call_id": call.id, **data},
                    parent_id=call_entry.entry_id,
                )
                await emit(EventType.TOOL_RESULT, seq=result_entry.seq, **data)
                messages.append(
                    {
                        "role": "assistant",
                        "content": None,
                        "tool_calls": [
                            {
                                "id": call.id,
                                "name": call.name,
                                "arguments": json.dumps(call.args),
                            }
                        ],
                    }
                )
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": call.id,
                        "content": json.dumps(data),
                    }
                )
                new_entries += [call_entry, result_entry]
            continue

        content = response.content or ""
        head = log.head()
        msg_entry = log.add(
            Author.MODEL,
            EntryKind.ASSISTANT,
            {"content": content},
            parent_id=head.entry_id if head else None,
        )
        await emit(EventType.MESSAGE_END, seq=msg_entry.seq)
        messages.append({"role": "assistant", "content": content})
        new_entries.append(msg_entry)
        break

    await emit(EventType.TURN_END, count=len(new_entries))
    return new_entries, messages


def messages_from_log(entries: list[Entry]) -> list[dict[str, Any]]:
    """把历史 entries 重建为聊天消息（resume 用；M0 支持线性历史）。"""
    messages: list[dict[str, Any]] = []
    pending_call: dict[str, Any] | None = None
    for entry in entries:
        if entry.kind is EntryKind.USER:
            messages.append({"role": "user", "content": entry.payload.get("content")})
        elif entry.kind is EntryKind.ASSISTANT:
            messages.append({"role": "assistant", "content": entry.payload.get("content")})
        elif entry.kind is EntryKind.TOOL_CALL:
            pending_call = {
                "id": entry.payload["tool_call_id"],
                "name": entry.payload["name"],
                "arguments": json.dumps(entry.payload.get("args") or {}),
            }
        elif entry.kind is EntryKind.TOOL_RESULT:
            if pending_call is not None:
                messages.append({"role": "assistant", "content": None, "tool_calls": [pending_call]})
                pending_call = None
            data = {
                k: v for k, v in entry.payload.items() if k != "tool_call_id"
            }
            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": entry.payload["tool_call_id"],
                    "content": json.dumps(data),
                }
            )
    return messages
