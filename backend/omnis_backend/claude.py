"""The Claude lane: public questions answered by a Claude model.

Nothing here runs unless an API key was supplied by the app. The real client
needs Anthropic's `anthropic` package; without it, or without a key, OMNIS
answers locally and says so.
"""

from __future__ import annotations

import os
import re
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from typing import Any, Protocol

HAIKU = "claude-haiku-5-5"
SONNET = "claude-sonnet-5-5"
OPUS = "claude-opus-5-5"

# US dollars per million tokens (input, output). From Anthropic's price list
# as of 2026-11-03; check the current list before relying on these.
PRICES: dict[str, tuple[float, float]] = {
    HAIKU: (0.10, 0.50),
    SONNET: (2.00, 10.00),
    OPUS: (4.00, 20.00),
}

DISPLAY_NAMES = {HAIKU: "Claude Haiku 5.5", SONNET: "Claude Sonnet 5.5", OPUS: "Claude Opus 5.5"}

# The most output one answer may use. It bounds the cost of a request.
MAX_OUTPUT_TOKENS = 4096


def cost_usd(model: str, input_tokens: int, output_tokens: int) -> float:
    price_in, price_out = PRICES.get(model, PRICES[OPUS])  # unknown model: assume the dearest
    return (input_tokens * price_in + output_tokens * price_out) / 1_000_000


def worst_case_cost(model: str, input_characters: int, turns: int = 3) -> float:
    """An upper estimate for one request: every turn re-reads the input and
    writes the maximum output. About three characters per token is assumed,
    which overestimates for ordinary English."""
    input_tokens = input_characters // 3 + 500
    return cost_usd(model, input_tokens * turns, MAX_OUTPUT_TOKENS * turns)


_ASKED_FOR_OPUS = re.compile(r"\bclaude\s+opus\b|\b(use|ask|with|via|using)\s+opus\b", re.IGNORECASE)
# "Opus" is also an audio format; a question about that is not a request for the model.
_OPUS_THE_CODEC = re.compile(r"\b(codec|audio|aac|mp3|ogg|bitrate|flac)\b", re.IGNORECASE)
# Kept to wording that reliably means code or formal reasoning. Broad words
# such as "architecture" or "proof" pulled in everyday questions.
_HARD = re.compile(
    r"\bleetcode\b|\balgorithm\b|\bdynamic programming\b|\btime complexity\b|\bprove that\b"
    r"|\bproof of correctness\b|\bdebug\b|\brefactor\b|\bstep[- ]by[- ]step\b|```"
    r"|\bwrite (a|an|some|the)?\s*(code|function|script|program|class|query)\b",
    re.IGNORECASE,
)
LONG_REQUEST_WORDS = 300


def choose_model(text: str) -> tuple[str, str]:
    """Pick the cheapest Claude model likely to do the job. Returns (model, why)."""
    if _ASKED_FOR_OPUS.search(text) and not _OPUS_THE_CODEC.search(text):
        return OPUS, "you asked for Opus"
    if _HARD.search(text):
        return SONNET, "it looks like coding or careful reasoning"
    if len(text.split()) > LONG_REQUEST_WORDS:
        return SONNET, "it is a long request"
    return HAIKU, "it is an everyday question"


class ClaudeUnavailable(Exception):
    """Claude could not be used for this request. `kind` says why."""

    #: Kinds that will not fix themselves in a moment, so Claude is rested for a while.
    LASTING = ("no_credit", "auth", "not_installed")

    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind
        self.message = message


@dataclass
class ClaudeTurn:
    """One reply from Claude."""

    text: str = ""
    #: Tool requests as {"id", "name", "input"}.
    tool_uses: list[dict] = field(default_factory=list)
    #: The reply's content exactly as received, to send back on the next turn.
    content: Any = None
    input_tokens: int = 0
    output_tokens: int = 0
    stop_reason: str = ""


class ClaudeClient(Protocol):
    def turn(
        self, model: str, system: str, messages: list[dict], tools: list[dict], effort: str,
        allow_tools: bool = True,
    ) -> AsyncIterator["str | ClaudeTurn"]:
        """Yields pieces of text as they arrive, then one ClaudeTurn.

        `tools` must be given on every turn of a conversation that has used a
        tool, or the API rejects the request. `allow_tools=False` keeps the
        definitions but tells Claude it may not call them, which is how a
        final answer is forced after the last permitted search."""
        ...


class AnthropicClaudeClient:
    """Talks to the real Claude API through Anthropic's official library."""

    def __init__(self, api_key: str) -> None:
        try:
            import anthropic
        except ImportError:
            raise ClaudeUnavailable(
                "not_installed", "the Anthropic library is not installed"
            ) from None
        self._anthropic = anthropic
        # The key is handed over by the app in memory. It is never read from
        # the environment, written to disk, or logged.
        self._client = anthropic.AsyncAnthropic(api_key=api_key, max_retries=1, timeout=120.0)

    async def turn(self, model, system, messages, tools, effort, allow_tools=True) -> AsyncIterator["str | ClaudeTurn"]:
        anthropic = self._anthropic
        request: dict[str, Any] = {
            "model": model,
            "max_tokens": MAX_OUTPUT_TOKENS,
            "system": system,
            "messages": messages,
            "output_config": {"effort": effort},
        }
        if tools:
            request["tools"] = tools
            if not allow_tools:
                request["tool_choice"] = {"type": "none"}
        try:
            async with self._client.messages.stream(**request) as stream:
                async for event in stream:
                    if event.type == "text":
                        yield event.text
                final = await stream.get_final_message()
        except anthropic.AuthenticationError:
            raise ClaudeUnavailable("auth", "the Claude API key was not accepted") from None
        except anthropic.PermissionDeniedError:
            raise ClaudeUnavailable("auth", "the Claude API key is not allowed to do this") from None
        except anthropic.RateLimitError:
            raise ClaudeUnavailable("rate_limit", "Claude is rate-limiting requests") from None
        except anthropic.APIStatusError as error:
            kind = getattr(error, "type", "") or ""
            text = str(getattr(error, "message", "")).lower()
            if error.status_code == 402 or kind == "billing_error" or "credit balance" in text:
                raise ClaudeUnavailable("no_credit", "there is no Claude API credit") from None
            if error.status_code >= 500:
                raise ClaudeUnavailable("server", "Claude is having problems") from None
            raise ClaudeUnavailable("rejected", "Claude rejected the request") from None
        except anthropic.APIConnectionError:
            raise ClaudeUnavailable("network", "Claude could not be reached") from None
        except TypeError:
            # The installed library does not accept a setting used here.
            raise ClaudeUnavailable("not_installed", "the Anthropic library is too old") from None

        turn = ClaudeTurn(
            content=final.content,
            input_tokens=final.usage.input_tokens or 0,
            output_tokens=final.usage.output_tokens or 0,
            stop_reason=final.stop_reason or "",
        )
        for block in final.content:
            if block.type == "text":
                turn.text += block.text
            elif block.type == "tool_use":
                turn.tool_uses.append({"id": block.id, "name": block.name, "input": block.input})
        yield turn


class MockClaudeClient:
    """Stands in for Claude in tests and before credits exist. Makes no network call.

    `script` is a list consumed one item per turn: a string is a text reply,
    {"search": "terms"} is a search request, and an exception is raised. With
    no script it gives a canned reply, or searches if the question starts
    with "search:".
    """

    def __init__(self, script: list | None = None):
        self.script = list(script) if script is not None else None
        self.calls: list[dict] = []

    async def turn(self, model, system, messages, tools, effort, allow_tools=True) -> AsyncIterator["str | ClaudeTurn"]:
        self.calls.append({"model": model, "system": system, "messages": messages, "tools": tools,
                           "effort": effort, "allow_tools": allow_tools})
        # The real API rejects a request whose history uses a tool that the
        # request does not define. Refuse it here too, so tests catch it.
        uses_tools = any(
            isinstance(m.get("content"), list)
            and any(isinstance(b, dict) and b.get("type") in ("tool_use", "tool_result") for b in m["content"])
            for m in messages
        )
        if uses_tools and not tools:
            raise ClaudeUnavailable("rejected", "the request used a tool it did not define")
        if self.script is not None:
            step = self.script.pop(0) if self.script else "No more scripted replies."
        else:
            step = self._default(messages, tools if allow_tools else [])
        if isinstance(step, dict) and not (tools and allow_tools):
            step = "I was not allowed to search, so this is a mock answer without one."
        if isinstance(step, Exception):
            raise step

        characters = sum(len(str(m.get("content", ""))) for m in messages) + len(system)
        turn = ClaudeTurn(input_tokens=characters // 4)
        if isinstance(step, dict):
            call = {"id": f"toolu_mock_{len(self.calls)}", "name": "web_search", "input": {"query": step["search"]}}
            turn.tool_uses = [call]
            turn.content = [{"type": "tool_use", **call}]
            turn.stop_reason = "tool_use"
            turn.output_tokens = 20
        else:
            for piece in re.findall(r"\S+\s*", step):
                yield piece
            turn.text = step
            turn.content = [{"type": "text", "text": step}]
            turn.stop_reason = "end_turn"
            turn.output_tokens = max(1, len(step) // 4)
        yield turn

    @staticmethod
    def _default(messages: list[dict], tools: list[dict]):
        last = messages[-1].get("content") if messages else ""
        if isinstance(last, list):  # a search result came back
            return "Mock Claude reply written from the search results. No API call was made."
        question = str(last).strip()
        # Like the real thing, it can only ask for a search it was offered.
        if question.lower().startswith("search:") and tools:
            return {"search": question[7:].strip() or "test"}
        return f"Mock Claude reply. No API call was made. You asked: {question}"


def make_client(api_key: str | None) -> tuple[ClaudeClient | None, str]:
    """The client to use, and when there is none, why not.

    The reason is empty when Claude was simply never set up, so that case
    stays quiet. It is set when a key was supplied but cannot be used, so the
    user is told why their answers are still local.
    """
    if os.environ.get("OMNIS_CLAUDE") == "mock":
        return MockClaudeClient(), ""
    if not api_key:
        return None, ""
    try:
        return AnthropicClaudeClient(api_key), ""
    except ClaudeUnavailable as error:
        return None, error.message
