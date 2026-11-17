"""Message protocol between the OMNIS app and the backend service.

One JSON object per line, UTF-8, newline terminated.

App to service:
    {"type": "hello",  "protocol": 1}
    {"type": "ask",    "id": "<request id>", "text": "<question>", "route": "auto"}
        ("route" is optional: "auto", "local" or "claude")
    {"type": "cancel", "id": "<request id>"}

Service to app:
    {"type": "hello", "protocol": 1, "service": "omnis-backend", "version": "..."}
    {"type": "answer_chunk", "id": "...", "text": "..."}
    {"type": "answer_done",  "id": "...", "model": "...", "cancelled": false,
     "route": "...", "reason": "...", "input_tokens": 0, "output_tokens": 0,
     "load_ms": 0, "total_ms": 0, "cost_usd": 0.0}
        (everything after "cancelled" is optional)
    {"type": "error", "code": "...", "message": "...", "id": "..."}   (id optional)
    {"type": "bye", "reason": "idle"}
"""

from __future__ import annotations

import json
from typing import Any

from . import __version__

PROTOCOL_VERSION = 1
SERVICE_NAME = "omnis-backend"
MAX_TEXT_CHARS = 100_000
MAX_ID_CHARS = 128

CLIENT_TYPES = ("hello", "ask", "cancel")
ROUTES = ("auto", "local", "claude")


class ProtocolError(Exception):
    """A message from the app was malformed or not allowed."""

    def __init__(self, code: str, message: str, request_id: str | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.request_id = request_id


def _require_id(obj: dict[str, Any]) -> str:
    value = obj.get("id")
    if not isinstance(value, str) or not value or len(value) > MAX_ID_CHARS:
        raise ProtocolError("bad_request", "'id' must be a non-empty string")
    return value


def decode_client(line: bytes) -> dict[str, Any]:
    """Parse and validate one line sent by the app. Raises ProtocolError."""
    try:
        obj = json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ProtocolError("bad_request", "message is not valid UTF-8 JSON") from None
    if not isinstance(obj, dict):
        raise ProtocolError("bad_request", "message must be a JSON object")

    kind = obj.get("type")
    if kind not in CLIENT_TYPES:
        raise ProtocolError("bad_request", "unknown message type")

    if kind == "hello":
        version = obj.get("protocol")
        if not isinstance(version, int) or isinstance(version, bool):
            raise ProtocolError("bad_request", "'protocol' must be an integer")
        return {"type": "hello", "protocol": version}

    request_id = _require_id(obj)
    if kind == "cancel":
        return {"type": "cancel", "id": request_id}

    text = obj.get("text")
    if not isinstance(text, str) or not text.strip():
        raise ProtocolError("bad_request", "'text' must be a non-empty string", request_id)
    if len(text) > MAX_TEXT_CHARS:
        raise ProtocolError("bad_request", "'text' is too long", request_id)
    route = obj.get("route", "auto")
    if route not in ROUTES:
        raise ProtocolError("bad_request", "'route' must be auto, local or claude", request_id)
    return {"type": "ask", "id": request_id, "text": text, "route": route}


def encode(message: dict[str, Any]) -> bytes:
    """Serialise one message as a single line."""
    return json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"


def hello() -> dict[str, Any]:
    return {
        "type": "hello",
        "protocol": PROTOCOL_VERSION,
        "service": SERVICE_NAME,
        "version": __version__,
    }


def answer_chunk(request_id: str, text: str) -> dict[str, Any]:
    return {"type": "answer_chunk", "id": request_id, "text": text}


def answer_done(
    request_id: str, model: str, cancelled: bool = False, details: dict[str, Any] | None = None
) -> dict[str, Any]:
    out: dict[str, Any] = {"type": "answer_done", "id": request_id, "model": model, "cancelled": cancelled}
    for key, value in (details or {}).items():
        out.setdefault(key, value)
    return out


def error(code: str, message: str, request_id: str | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {"type": "error", "code": code, "message": message}
    if request_id is not None:
        out["id"] = request_id
    return out


def bye(reason: str) -> dict[str, Any]:
    return {"type": "bye", "reason": reason}
