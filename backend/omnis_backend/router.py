"""Chooses which local model answers a request, and says why.

Everything this service answers is answered on this Mac. Plain rules, no
model call, the same answer for the same input.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum


class Target(Enum):
    LIGHT = "light"
    MODERATE = "moderate"


@dataclass(frozen=True)
class Decision:
    target: Target
    reason: str


OVERRIDES = ("auto", "local")

_MODERATE_HINTS = re.compile(
    r"\bstep[- ]by[- ]step\b|\bplan\b|\bcompare\b|\btrade-?offs?\b|\bsummar(y|ise|ize)\b"
    r"|\bexplain (why|how)\b|\bwrite (a|some|the)?\s*(code|function|script|program)\b|\bdebug\b|\brefactor\b"
    r"|\bleetcode\b|\balgorithm\b|\btime complexity\b|\bprove\b|\bproof\b",
    re.IGNORECASE,
)

LONG_REQUEST_WORDS = 40


def decide(text: str, override: str = "auto", personal: bool = False) -> Decision:
    """`personal` says the request touches personal data."""
    if personal:
        return _local(text, "it uses personal data, which stays on this Mac; ")
    if override == "local":
        return _local(text, "you chose local; ")
    return _local(text, "")


def _local(text: str, prefix: str) -> Decision:
    if _MODERATE_HINTS.search(text):
        return Decision(Target.MODERATE, prefix + "it asks for planning, comparison, code or a summary")
    if len(text.split()) > LONG_REQUEST_WORDS:
        return Decision(Target.MODERATE, prefix + "it is a long request")
    return Decision(Target.LIGHT, prefix + "it is a short, simple request")
