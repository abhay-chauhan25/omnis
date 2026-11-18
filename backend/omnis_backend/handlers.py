"""Answer handlers. Only a mock exists in the thin slice."""

from __future__ import annotations

import asyncio
import os
import re
from collections.abc import AsyncIterator

from .models import ToolRequest

MOCK_MODEL = "mock"


def _mock_delay_seconds() -> float:
    raw = os.environ.get("OMNIS_MOCK_DELAY_MS", "25")
    try:
        return max(0.0, float(raw) / 1000.0)
    except ValueError:
        return 0.025


async def mock_answer(
    text: str, route: str = "auto", web: bool = True, history: list | None = None, cloud: dict | None = None,
    attachments: list | None = None, options: dict | None = None,
) -> AsyncIterator["str | ToolRequest"]:
    """Yield a canned reply a word at a time, the way a real model would stream.

    A question starting with "search:" asks the app for a web search and
    reports what came back, so the search path can be exercised with no model.
    """
    stripped = text.strip()
    if stripped.lower().startswith("search:"):
        request = ToolRequest("web_search", stripped[7:].strip() or "test", asyncio.get_running_loop().create_future())
        yield request
        outcome = await request.future
        results = outcome.get("results") or []
        first = results[0]["title"] if results else "none"
        reply = f"Search ok={outcome.get('ok')} results={len(results)} first={first} error={outcome.get('error')}"
    elif stripped.lower().startswith("calendar:"):
        # Test aid: ask the app to read the calendar for "calendar: START END".
        dates = stripped[9:].split()
        arguments = {"start": dates[0] if dates else "2026-01-01", "end": dates[-1] if dates else "2026-01-01"}
        request = ToolRequest("calendar_events", "", asyncio.get_running_loop().create_future(), arguments)
        yield request
        outcome = await request.future
        reply = f"Calendar ok={outcome.get('ok')} error={outcome.get('error')} content={outcome.get('content')}"
    elif stripped.lower().startswith("event:"):
        # Test aid: propose "event: TITLE | START | END".
        parts = [part.strip() for part in stripped[6:].split("|")] + ["", ""]
        arguments = {"title": parts[0], "start": parts[1], "end": parts[2],
                     "all_day": "true" if len(parts[1]) == 10 else "false", "location": ""}
        request = ToolRequest("calendar_create_event", "", asyncio.get_running_loop().create_future(), arguments)
        yield request
        outcome = await request.future
        reply = f"Event ok={outcome.get('ok')} error={outcome.get('error')}"
    elif stripped.lower().startswith("tool:"):
        # Test aid: "tool: NAME key=value; key=value" asks the app to run any tool.
        name, _, rest = stripped[5:].strip().partition(" ")
        arguments = dict(part.strip().split("=", 1) for part in rest.split(";") if "=" in part)
        request = ToolRequest(name, "", asyncio.get_running_loop().create_future(), arguments)
        yield request
        outcome = await request.future
        reply = f"Tool ok={outcome.get('ok')} error={outcome.get('error')} content={outcome.get('content')}"
    elif stripped.lower() == "attachments?":
        # Test aid: report what files the app sent along, without echoing their content.
        now = attachments or []
        before = sum(len(t.get("attachments", [])) for t in (history or []))
        kinds = ", ".join(f"{a['kind']} {a['name']}" for a in now) or "none"
        reply = f"Got {len(now)} attachments ({kinds}). Earlier turns carried {before}."
    elif stripped.lower() == "history?":
        # Test aid: report what conversation the app sent along.
        turns = history or []
        last = next((t["content"] for t in reversed(turns) if t["role"] == "user"), "none")
        reply = f"History has {len(turns)} messages. The last thing you said before this was: {last}"
    else:
        reply = (
            "This is a mock answer from the OMNIS backend. No AI model is connected yet, "
            f"so nothing was analysed. You asked: \u201c{stripped}\u201d"
        )
    delay = _mock_delay_seconds()
    for piece in re.findall(r"\S+\s*", reply):
        if delay:
            await asyncio.sleep(delay)
        yield piece
