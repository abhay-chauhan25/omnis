"""Answer handlers. Only a mock exists in the thin slice."""

from __future__ import annotations

import asyncio
import os
import re
from collections.abc import AsyncIterator

MOCK_MODEL = "mock"


def _mock_delay_seconds() -> float:
    raw = os.environ.get("OMNIS_MOCK_DELAY_MS", "25")
    try:
        return max(0.0, float(raw) / 1000.0)
    except ValueError:
        return 0.025


async def mock_answer(text: str, route: str = "auto") -> AsyncIterator[str]:
    """Yield a canned reply a word at a time, the way a real model would stream."""
    reply = (
        "This is a mock answer from the OMNIS backend. No AI model is connected yet, "
        f"so nothing was analysed. You asked: “{text.strip()}”"
    )
    delay = _mock_delay_seconds()
    for piece in re.findall(r"\S+\s*", reply):
        if delay:
            await asyncio.sleep(delay)
        yield piece
