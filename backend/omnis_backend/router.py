"""Chooses where a request is answered.

The rule is about data, not difficulty (ADR-0009): anything personal stays on
this Mac; a public question goes to Claude when Claude can be used. Plain
rules, no model call, the same answer for the same input.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum


class Target(Enum):
    LIGHT = "light"
    MODERATE = "moderate"
    CLOUD = "cloud"


@dataclass(frozen=True)
class Decision:
    target: Target
    reason: str


OVERRIDES = ("auto", "local", "claude")

# People called Claude. "ask Claude Shannon ..." is about a person, not a
# request for the model. A short list is crude but predictable.
_SURNAMES = (
    "shannon", "monet", "debussy", "bernard", "rains", "lorrain", "chabrol",
    "lelouch", "cahun", "makelele", "giroux", "levi", "van",
)
_ASKED_FOR_CLAUDE = re.compile(
    r"\b(use|ask|with|via|using)\s+claude\b(?!\s+(" + "|".join(_SURNAMES) + r")\b)", re.IGNORECASE
)

_MODERATE_HINTS = re.compile(
    r"\bstep[- ]by[- ]step\b|\bplan\b|\bcompare\b|\btrade-?offs?\b|\bsummar(y|ise|ize)\b"
    r"|\bexplain (why|how)\b|\bwrite (a|some|the)?\s*(code|function|script|program)\b|\bdebug\b|\brefactor\b"
    r"|\bleetcode\b|\balgorithm\b|\btime complexity\b|\bprove\b|\bproof\b",
    re.IGNORECASE,
)

LONG_REQUEST_WORDS = 40


def wants_claude(text: str, override: str = "auto") -> bool:
    """True if the user asked for Claude outright, by control or by name."""
    return override == "claude" or (override != "local" and bool(_ASKED_FOR_CLAUDE.search(text)))


def decide(text: str, override: str = "auto", cloud_ready: bool = False, personal: bool = False) -> Decision:
    """`cloud_ready` says whether Claude can be used right now. `personal`
    says the request touches personal data, which never leaves this Mac."""
    if personal:
        return _local(text, "it uses personal data, which stays on this Mac; ")
    if override == "local":
        return _local(text, "you chose local; ")
    if cloud_ready:
        if override == "claude":
            return Decision(Target.CLOUD, "you chose Claude")
        if _ASKED_FOR_CLAUDE.search(text):
            return Decision(Target.CLOUD, "you asked for Claude")
        return Decision(Target.CLOUD, "it is a public question")
    return _local(text, "")


def _local(text: str, prefix: str) -> Decision:
    if _MODERATE_HINTS.search(text):
        return Decision(Target.MODERATE, prefix + "it asks for planning, comparison, code or a summary")
    if len(text.split()) > LONG_REQUEST_WORDS:
        return Decision(Target.MODERATE, prefix + "it is a long request")
    return Decision(Target.LIGHT, prefix + "it is a short, simple request")
