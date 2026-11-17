"""Chooses which model should answer.

This is a first, deliberately simple version: plain rules, no model call, the
same answer for the same input. It is meant to be measured against real
requests and replaced or tuned later (Stage 6).
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

# Topics that are usually better handled by Claude. A match here does NOT
# send the request to Claude: local-only is the default (ADR-0006), and word
# matching is too blunt to spend money on. It picks the larger local model
# and records that Claude was a candidate, so real requests can be reviewed
# when automatic cloud routing is designed and measured (Stage 6).
_CLAUDE_CANDIDATES = re.compile(
    r"\bresearch paper\b|\b(this|the|that|my|attached) (paper|pdf|article)\b|\bmethodology\b"
    r"|\bleetcode\b|\balgorithm\b|\bdynamic programming\b|\btime complexity\b|\bprove that\b|\bproof\b",
    re.IGNORECASE,
)

_MODERATE_HINTS = re.compile(
    r"\bstep[- ]by[- ]step\b|\bplan\b|\bcompare\b|\btrade-?offs?\b|\bsummar(y|ise|ize)\b"
    r"|\bexplain (why|how)\b|\bwrite (a|some|the)?\s*(code|function|script|program)\b|\bdebug\b|\brefactor\b",
    re.IGNORECASE,
)

LONG_REQUEST_WORDS = 40


def decide(text: str, override: str = "auto") -> Decision:
    """Claude is chosen only when the user asks for it, by override or by name."""
    if override == "claude":
        return Decision(Target.CLOUD, "you chose Claude")
    if override != "local" and _ASKED_FOR_CLAUDE.search(text):
        return Decision(Target.CLOUD, "you asked for Claude")

    prefix = "you chose local; " if override == "local" else ""
    if _CLAUDE_CANDIDATES.search(text):
        return Decision(Target.MODERATE, prefix + "it may suit Claude, which is used only when you ask for it")
    if _MODERATE_HINTS.search(text):
        return Decision(Target.MODERATE, prefix + "it asks for planning, comparison, code or a summary")
    if len(text.split()) > LONG_REQUEST_WORDS:
        return Decision(Target.MODERATE, prefix + "it is a long request")
    return Decision(Target.LIGHT, prefix + "it is a short, simple request")
