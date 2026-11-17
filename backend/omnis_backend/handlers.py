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


async def mock_answer(text: str, route: str = "auto", web: bool = True) -> AsyncIterator["str | ToolRequest"]:
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
