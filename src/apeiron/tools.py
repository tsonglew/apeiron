"""内建工具与注册表（M0 只有 echo 占位；M1 接 bash/fs + 权限审批流）。"""
from __future__ import annotations

from .loop import Permission, Tool


async def _echo(args: dict[str, object]) -> str:
    return str(args.get("text", ""))


ECHO = Tool(
    name="echo",
    description="回显文本，用于验证工具回路。",
    input_schema={
        "type": "object",
        "properties": {"text": {"type": "string"}},
        "required": ["text"],
    },
    permission=Permission.READ_ONLY,
    handler=_echo,
)


def list_tools() -> list[Tool]:
    return [ECHO]
