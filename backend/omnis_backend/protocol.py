"""Message protocol between the OMNIS app and the backend service.

One JSON object per line, UTF-8, newline terminated.

App to service:
    {"type": "hello",  "protocol": 1}
    {"type": "ask",    "id": "<request id>", "text": "<question>", "route": "auto"}
        ("route" is optional: "auto", "local" or "claude")
    {"type": "cancel", "id": "<request id>"}
    {"type": "configure", "claude_key": "<key or empty>"}
        (sent once after hello; the key is held in memory only)
    {"type": "tool_result", "id": "<request id>", "call_id": "...", "ok": true,
     "results": [{"title": "...", "url": "...", "snippet": "..."}], "error": "...",
     "content": "<text for tools that return text, such as the calendar>"}
        ("ask" may also carry "web": false to forbid web search for that question,
         "history": [{"role": "user"|"assistant", "content": "..."}] holding the
         earlier turns of the conversation, oldest first, and
         "cloud": {"allowed": true, "max_usd": 1.0, "reason": "..."}, the app's
         say on whether Claude may be used for this question, and
         "attachments": [{"kind": "image", "name": "...", "data": "<base64 JPEG or PNG>"},
                         {"kind": "text", "name": "...", "text": "..."}], files the user
         attached. A history entry from the user may carry "attachments" too.
         "personal": true marks the question as touching personal data, and
         "calendar": true says the app will read the calendar if asked.)

Service to app:
    {"type": "hello", "protocol": 1, "service": "omnis-backend", "version": "..."}
    {"type": "answer_chunk", "id": "...", "text": "..."}
    {"type": "answer_done",  "id": "...", "model": "...", "cancelled": false,
     "route": "...", "reason": "...", "input_tokens": 0, "output_tokens": 0,
     "load_ms": 0, "total_ms": 0, "cost_usd": 0.0}
        (everything after "cancelled" is optional)
    {"type": "tool_request", "id": "...", "call_id": "...", "tool": "web_search", "query": "..."}
    {"type": "tool_request", "id": "...", "call_id": "...", "tool": "calendar_events", "query": "",
     "arguments": {"start": "2026-11-18", "end": "2026-11-18"}}
    {"type": "usage", "id": "...", "model": "...", "input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0}
        (after every Claude turn, so cost is recorded even if the answer does not finish)
    {"type": "error", "code": "...", "message": "...", "id": "..."}   (id optional)
    {"type": "bye", "reason": "idle"}
"""

from __future__ import annotations

import json
import re
from typing import Any

from . import __version__

PROTOCOL_VERSION = 2
SERVICE_NAME = "omnis-backend"
MAX_TEXT_CHARS = 100_000
MAX_ID_CHARS = 128

CLIENT_TYPES = ("hello", "ask", "cancel", "tool_result", "configure")
MAX_KEY_CHARS = 500
MAX_ATTACHMENTS = 4
MAX_IMAGE_BASE64_CHARS = 6_000_000      # about 4.5 MB of image
MAX_ATTACHMENT_TEXT_CHARS = 60_000
MAX_NAME_CHARS = 200
MAX_HISTORY_MESSAGES = 24
MAX_HISTORY_CHARS = 12_000
MAX_TOOL_CONTENT_CHARS = 20_000
MAX_RESULTS = 8
MAX_RESULT_FIELD_CHARS = 2000
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

    if kind == "configure":
        key = obj.get("claude_key", "")
        if not isinstance(key, str) or len(key) > MAX_KEY_CHARS:
            raise ProtocolError("bad_request", "'claude_key' must be a short string")
        return {"type": "configure", "claude_key": key.strip()}

    request_id = _require_id(obj)
    if kind == "cancel":
        return {"type": "cancel", "id": request_id}
    if kind == "tool_result":
        return _decode_tool_result(obj, request_id)

    text = obj.get("text")
    if not isinstance(text, str) or not text.strip():
        raise ProtocolError("bad_request", "'text' must be a non-empty string", request_id)
    if len(text) > MAX_TEXT_CHARS:
        raise ProtocolError("bad_request", "'text' is too long", request_id)
    route = obj.get("route", "auto")
    if route not in ROUTES:
        raise ProtocolError("bad_request", "'route' must be auto, local or claude", request_id)
    web = obj.get("web", True)
    if not isinstance(web, bool):
        raise ProtocolError("bad_request", "'web' must be true or false", request_id)
    return {
        "type": "ask", "id": request_id, "text": text, "route": route, "web": web,
        "history": _decode_history(obj.get("history", []), request_id),
        "cloud": _decode_cloud(obj.get("cloud", {}), request_id),
        "attachments": _decode_attachments(obj.get("attachments", []), request_id),
        "options": {"personal": _flag(obj, "personal", request_id), "calendar": _flag(obj, "calendar", request_id)},
    }


def _flag(obj: dict[str, Any], name: str, request_id: str) -> bool:
    value = obj.get(name, False)
    if not isinstance(value, bool):
        raise ProtocolError("bad_request", f"'{name}' must be true or false", request_id)
    return value


_BASE64 = re.compile(r"[A-Za-z0-9+/]*={0,2}")


def _decode_attachments(raw: Any, request_id: str) -> list[dict[str, str]]:
    """Files attached to a message. Everything is size-limited, and an image
    must be plain base64 so it cannot smuggle anything else into the request."""
    if not isinstance(raw, list):
        raise ProtocolError("bad_request", "'attachments' must be a list", request_id)
    if len(raw) > MAX_ATTACHMENTS:
        raise ProtocolError("bad_request", "too many attachments", request_id)
    out: list[dict[str, str]] = []
    for item in raw:
        if not isinstance(item, dict):
            raise ProtocolError("bad_request", "each attachment must be an object", request_id)
        kind = item.get("kind")
        name = item.get("name", "")
        if not isinstance(name, str):
            raise ProtocolError("bad_request", "an attachment name must be text", request_id)
        name = " ".join(name.split())[:MAX_NAME_CHARS] or "attachment"
        if kind == "image":
            data = item.get("data")
            if not isinstance(data, str) or not data or len(data) > MAX_IMAGE_BASE64_CHARS:
                raise ProtocolError("bad_request", "an image attachment is missing or too large", request_id)
            if len(data) % 4 != 0 or not _BASE64.fullmatch(data):
                raise ProtocolError("bad_request", "an image attachment is not valid base64", request_id)
            out.append({"kind": "image", "name": name, "data": data})
        elif kind == "text":
            text = item.get("text")
            if not isinstance(text, str) or len(text) > MAX_ATTACHMENT_TEXT_CHARS:
                raise ProtocolError("bad_request", "a text attachment is missing or too large", request_id)
            out.append({"kind": "text", "name": name, "text": text})
        else:
            raise ProtocolError("bad_request", "unknown attachment kind", request_id)
    return out


def _decode_cloud(raw: Any, request_id: str) -> dict[str, Any]:
    """The app's permission for Claude. A malformed field is refused outright;
    a missing one means allowed at the default limit (the app always sends it)."""
    if not isinstance(raw, dict):
        raise ProtocolError("bad_request", "'cloud' must be an object", request_id)
    allowed = raw.get("allowed", True)
    limit = raw.get("max_usd", 1.0)
    reason = raw.get("reason", "")
    if not isinstance(allowed, bool) or isinstance(limit, bool) or not isinstance(limit, (int, float)):
        raise ProtocolError("bad_request", "'cloud' needs allowed (true/false) and max_usd (a number)", request_id)
    return {
        "allowed": allowed,
        "max_usd": max(0.0, min(float(limit), 100.0)),
        "reason": reason[:200] if isinstance(reason, str) else "",
    }


def _decode_history(raw: Any, request_id: str) -> list[dict[str, Any]]:
    """Earlier turns of the conversation. Only user and assistant turns are
    accepted, so nothing sent by the app can pose as a system instruction."""
    if not isinstance(raw, list):
        raise ProtocolError("bad_request", "'history' must be a list", request_id)
    turns: list[dict[str, Any]] = []
    for item in raw:
        if not isinstance(item, dict):
            raise ProtocolError("bad_request", "each history entry must be an object", request_id)
        role, content = item.get("role"), item.get("content")
        if role not in ("user", "assistant") or not isinstance(content, str):
            raise ProtocolError("bad_request", "history entries need a user or assistant role and text", request_id)
        attachments = _decode_attachments(item.get("attachments", []), request_id)
        if attachments and role != "user":
            raise ProtocolError("bad_request", "only a user turn may carry attachments", request_id)
        if content.strip() or attachments:
            turn: dict[str, Any] = {"role": role, "content": content}
            if attachments:
                turn["attachments"] = attachments
            turns.append(turn)
    # Keep the most recent turns that fit, dropping the oldest first.
    kept: list[dict[str, Any]] = []
    total = 0
    for turn in reversed(turns[-MAX_HISTORY_MESSAGES:]):
        total += len(turn["content"])
        if total > MAX_HISTORY_CHARS:
            break
        kept.append(turn)
    kept.reverse()
    # Never begin with an answer whose question was cut off.
    while kept and kept[0]["role"] != "user":
        kept.pop(0)
    return kept


def _decode_tool_result(obj: dict[str, Any], request_id: str) -> dict[str, Any]:
    call_id = obj.get("call_id")
    if not isinstance(call_id, str) or not call_id or len(call_id) > MAX_ID_CHARS:
        raise ProtocolError("bad_request", "'call_id' must be a non-empty string", request_id)
    ok = obj.get("ok")
    if not isinstance(ok, bool):
        raise ProtocolError("bad_request", "'ok' must be true or false", request_id)
    raw = obj.get("results", [])
    if not isinstance(raw, list):
        raise ProtocolError("bad_request", "'results' must be a list", request_id)
    results = []
    for item in raw[:MAX_RESULTS]:
        if not isinstance(item, dict):
            continue
        entry = {}
        for key in ("title", "url", "snippet"):
            value = item.get(key, "")
            entry[key] = value[:MAX_RESULT_FIELD_CHARS] if isinstance(value, str) else ""
        results.append(entry)
    error = obj.get("error", "")
    content = obj.get("content", "")
    return {
        "type": "tool_result",
        "id": request_id,
        "call_id": call_id,
        "ok": ok,
        "results": results,
        "error": error[:300] if isinstance(error, str) else "",
        "content": content[:MAX_TOOL_CONTENT_CHARS] if isinstance(content, str) else "",
    }


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


def usage(request_id: str, model: str, input_tokens: int, output_tokens: int, cost_usd: float) -> dict[str, Any]:
    return {"type": "usage", "id": request_id, "model": model, "input_tokens": input_tokens,
            "output_tokens": output_tokens, "cost_usd": cost_usd}


def tool_request(
    request_id: str, call_id: str, tool: str, query: str, arguments: dict[str, str] | None = None
) -> dict[str, Any]:
    out: dict[str, Any] = {"type": "tool_request", "id": request_id, "call_id": call_id, "tool": tool, "query": query}
    if arguments:
        out["arguments"] = arguments
    return out


def error(code: str, message: str, request_id: str | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {"type": "error", "code": code, "message": message}
    if request_id is not None:
        out["id"] = request_id
    return out


def bye(reason: str) -> dict[str, Any]:
    return {"type": "bye", "reason": reason}
