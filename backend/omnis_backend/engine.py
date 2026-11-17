"""Answers questions with local models, or a Claude stand-in.

One request runs at a time and one local model is kept in memory at a time.
"""

from __future__ import annotations

import asyncio
import json
import pathlib
import re
import time
from collections.abc import AsyncIterator

from .models import AnswerError, AnswerInfo
from .ollama import OllamaClient
from .router import Decision, Target, decide

SYSTEM_PROMPT = (
    "You are OMNIS, an assistant that runs on the user's Mac. Answer directly and briefly, "
    "in plain language. You cannot open apps, read files or take any action yet; if asked to, "
    "say so in one sentence. If you are not sure of a fact, say that you are not sure."
)

FIXTURE = pathlib.Path(__file__).with_name("fixtures") / "claude_mock.json"


class LocalEngine:
    def __init__(
        self,
        client: OllamaClient,
        light_model: str = "qwen3:4b",
        moderate_model: str = "qwen3:8b",
        keep_alive_seconds: int = 300,
        first_piece_timeout: float = 180.0,
        next_piece_timeout: float = 60.0,
        whole_answer_timeout: float = 600.0,
    ):
        self._client = client
        self._models = {Target.LIGHT: light_model, Target.MODERATE: moderate_model}
        self._keep_alive = keep_alive_seconds
        self._first_timeout = first_piece_timeout
        self._next_timeout = next_piece_timeout
        self._whole_timeout = whole_answer_timeout
        self._lock = asyncio.Lock()
        self._in_memory: str | None = None
        self._used: set[str] = set()

    async def answer(self, text: str, route: str = "auto") -> AsyncIterator[str | AnswerInfo]:
        decision = decide(text, route)
        async with self._lock:
            if decision.target is Target.CLOUD:
                async for item in self._claude_stand_in(decision):
                    yield item
            else:
                async for item in self._local(text, decision):
                    yield item

    async def close(self) -> None:
        # Unload everything this engine loaded, in case an earlier unload failed.
        if self._client.started_server:
            for model in sorted(self._used):
                await self._client.unload(model)
        await self._client.stop_server()

    # -- local -----------------------------------------------------------

    async def _local(self, text: str, decision: Decision) -> AsyncIterator[str | AnswerInfo]:
        model = self._models[decision.target]
        started = time.monotonic()
        await self._client.ensure_server()
        if self._in_memory and self._in_memory != model:
            await self._client.unload(self._in_memory)
        self._in_memory = model
        self._used.add(model)

        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": text},
        ]
        info = AnswerInfo(model=model, route="local", reason=decision.reason)
        stream = self._client.chat(model, messages, self._keep_alive)
        finished = False
        shown = False
        try:
            timeout = self._first_timeout
            while True:
                # Reasoning counts as activity, so a model that reasons without
                # end is caught by the overall limit instead.
                remaining = self._whole_timeout - (time.monotonic() - started)
                try:
                    event = await asyncio.wait_for(anext(stream), max(0.0, min(timeout, remaining)))
                except StopAsyncIteration:
                    break
                except asyncio.TimeoutError:
                    raise AnswerError("timeout", f"{model} stopped responding, so the answer was abandoned.") from None
                timeout = self._next_timeout
                message = event.get("message")
                piece = message.get("content") if isinstance(message, dict) else None
                if isinstance(piece, str) and piece:
                    shown = True
                    yield piece
                if event.get("done") is True:
                    info.input_tokens = _count(event.get("prompt_eval_count"))
                    info.output_tokens = _count(event.get("eval_count"))
                    info.load_ms = _count(event.get("load_duration")) // 1_000_000
                    finished = True
                    break
        finally:
            await stream.aclose()
        if not finished:
            # The stream ended without the model saying it was done: the
            # answer on screen is cut short and must not look complete.
            raise AnswerError("model_unavailable", f"{model} stopped before finishing, so the answer is incomplete.")
        if not shown:
            raise AnswerError("empty_answer", f"{model} finished without giving an answer. Try asking again.")
        info.total_ms = int((time.monotonic() - started) * 1000)
        yield info

    # -- cloud stand-in ----------------------------------------------------

    async def _claude_stand_in(self, decision: Decision) -> AsyncIterator[str | AnswerInfo]:
        started = time.monotonic()
        fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
        reply = fixture["reply"].replace("{reason}", decision.reason)
        for piece in re.findall(r"\S+\s*", reply):
            await asyncio.sleep(0)
            yield piece
        yield AnswerInfo(
            model=fixture["model"],
            route="cloud-mock",
            reason=decision.reason,
            input_tokens=int(fixture.get("input_tokens", 0)),
            output_tokens=int(fixture.get("output_tokens", 0)),
            total_ms=int((time.monotonic() - started) * 1000),
            cost_usd=0.0,
        )


def _count(value: object) -> int:
    """A whole number from the model server, or 0 if it sent something else."""
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0
