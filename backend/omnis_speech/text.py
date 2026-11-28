"""Plain text work that needs no model, so it can be tested without one."""

from __future__ import annotations

import re

# The names Whisper is told to expect. It writes an unfamiliar name far more
# reliably once it has seen it spelled.
WAKE_HINT = "Hey Omnis. Yo Omnis. Hey Omi. Yo Omi."

VOICES = ("am_adam", "af_heart")
DEFAULT_VOICE = "am_adam"

MAX_SAY_CHARACTERS = 4000
# Sound for the wake check: at most this many seconds, at 16 kHz.
HEAR_RATE = 16000
MAX_HEAR_SECONDS = 15

_END = re.compile(r"(?<=[.!?])[\"')\]]*\s+")


def sentences(text: str) -> list[str]:
    """The text a sentence at a time, so the first can be heard while the rest is made."""
    whole = " ".join(text.split())[:MAX_SAY_CHARACTERS]
    parts = [part.strip() for part in _END.split(whole)]
    return [part for part in parts if any(character.isalnum() for character in part)]


def voice_or_default(name: object) -> str:
    return name if isinstance(name, str) and name in VOICES else DEFAULT_VOICE


def speed_or_default(value: object) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 1.0
    return min(1.5, max(0.7, float(value)))
