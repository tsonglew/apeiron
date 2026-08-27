from __future__ import annotations

from apeiron.harness import Harness
from apeiron.loop import LLMResponse
from apeiron.rpc import RpcServer
from apeiron.store import MemoryStore

from conftest import FakeProvider


async def make_server() -> RpcServer:
    harness = Harness(
        MemoryStore(), FakeProvider([LLMResponse(content="ok")]), []
    )
    return RpcServer(harness)


async def test_thread_lifecycle() -> None:
    server = await make_server()

    r1 = await server.handle({"jsonrpc": "2.0", "id": 1, "method": "thread/start", "params": {}})
    thread_id = r1["result"]["thread_id"]

    r2 = await server.handle(
        {"jsonrpc": "2.0", "id": 2, "method": "turn/run", "params": {"thread_id": thread_id, "message": "hi"}}
    )
    assert [e["kind"] for e in r2["result"]["entries"]] == ["user", "assistant"]

    r3 = await server.handle(
        {"jsonrpc": "2.0", "id": 3, "method": "thread/read", "params": {"thread_id": thread_id, "since_seq": 1}}
    )
    assert [e["seq"] for e in r3["result"]["entries"]] == [2]

    r4 = await server.handle({"jsonrpc": "2.0", "id": 4, "method": "nope", "params": {}})
    assert r4["error"]["code"] == -32601

    r5 = await server.handle(
        {"jsonrpc": "2.0", "id": 5, "method": "turn/run", "params": {"thread_id": "missing", "message": "hi"}}
    )
    assert r5["error"]["code"] == -32000


async def test_thread_add() -> None:
    server = await make_server()
    r1 = await server.handle({"jsonrpc": "2.0", "id": 1, "method": "thread/start", "params": {}})
    thread_id = r1["result"]["thread_id"]
    r2 = await server.handle(
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "thread/add",
            "params": {"thread_id": thread_id, "kind": "summary", "payload": {"note": "saved"}},
        }
    )
    assert r2["result"]["kind"] == "summary"
