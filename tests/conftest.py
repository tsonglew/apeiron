from __future__ import annotations

from apeiron.loop import LLMResponse, Tool


class FakeProvider:
    """按队列依次吐 LLMResponse；吐完兜底返回内容 "done"。"""

    name = "fake"

    def __init__(self, responses: list[LLMResponse]) -> None:
        self._responses = list(responses)

    async def complete(
        self, messages: list[dict], tools: list[Tool]
    ) -> LLMResponse:
        if self._responses:
            return self._responses.pop(0)
        return LLMResponse(content="done")
