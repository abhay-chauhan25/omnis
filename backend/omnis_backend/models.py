"""Shared types for anything that can answer a question."""

from __future__ import annotations

import asyncio
from dataclasses import asdict, dataclass


class AnswerError(Exception):
    """A failure that is safe to show to the user as-is."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass
class AnswerInfo:
    """What produced an answer and what it cost. Sent with `answer_done`."""

    model: str
    route: str  # "local", "cloud-mock" or "mock"
    reason: str = ""
    input_tokens: int = 0
    output_tokens: int = 0
    load_ms: int = 0
    total_ms: int = 0
    cost_usd: float = 0.0
    searches: int = 0

    def as_fields(self) -> dict:
        return asdict(self)


@dataclass
class ToolRequest:
    """Something the model wants the app to do on its behalf.

    The service passes it to the app and resolves `future` with the app's
    reply: {"ok": bool, "results": [...], "error": str}. The Python side
    never performs the action itself.
    """

    tool: str
    query: str
    future: "asyncio.Future[dict]"
