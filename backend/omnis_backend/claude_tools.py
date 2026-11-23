"""The tool list OMNIS gives to Claude Code, as a tiny MCP server.

    python3 -m omnis_backend.claude_tools

Claude Code starts this and learns from it which calendar tools exist. This
program can do nothing itself: it has no access to the calendar or anything
else. Before every tool call Claude Code asks the OMNIS app for permission.
The app does the work (a read) or shows the user a preview (a change), and
passes back the text to give the model in a "_result" value. All this program
does is hand that text over. Called without it, a tool says it is unavailable.
"""

from __future__ import annotations

import json
import sys
from typing import Any, TextIO

from .engine import CALENDAR_READ_TOOLS, CALENDAR_WRITE_TOOLS

SERVER_NAME = "omnis"
UNAVAILABLE = "This tool is not available right now. Tell the user that OMNIS could not carry it out."


def tools() -> list[dict[str, Any]]:
    """The calendar tools in the form MCP expects. The schemas are the ones the local model uses."""
    listed = []
    for tool in CALENDAR_READ_TOOLS + CALENDAR_WRITE_TOOLS:
        function = tool["function"]
        schema = dict(function["parameters"])
        # The app replaces the arguments with its reply, so anything must be accepted here.
        schema["additionalProperties"] = True
        listed.append({"name": function["name"], "description": function["description"], "inputSchema": schema})
    return listed


def handle(message: dict[str, Any]) -> dict[str, Any] | None:
    """The reply to one request, or None for a notification."""
    if "id" not in message:
        return None
    method = message.get("method")
    params = message.get("params") if isinstance(message.get("params"), dict) else {}
    if method == "initialize":
        result: dict[str, Any] = {
            "protocolVersion": params.get("protocolVersion", "2025-06-18"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME, "version": "1"},
        }
    elif method == "tools/list":
        result = {"tools": tools()}
    elif method == "tools/call":
        arguments = params.get("arguments") if isinstance(params.get("arguments"), dict) else {}
        text = arguments.get("_result")
        known = params.get("name") in {tool["name"] for tool in tools()}
        ok = known and isinstance(text, str) and bool(text)
        result = {"content": [{"type": "text", "text": text if ok else UNAVAILABLE}], "isError": not ok}
    elif method == "ping":
        result = {}
    else:
        return {"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "method not found"}}
    return {"jsonrpc": "2.0", "id": message["id"], "result": result}


def serve(reader: TextIO, writer: TextIO) -> None:
    for line in reader:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if not isinstance(message, dict):
            continue
        reply = handle(message)
        if reply is not None:
            writer.write(json.dumps(reply) + "\n")
            writer.flush()


if __name__ == "__main__":
    serve(sys.stdin, sys.stdout)
