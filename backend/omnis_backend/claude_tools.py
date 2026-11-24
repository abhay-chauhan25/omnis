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

PROJECT_TOOL = {
    "name": "project_create",
    "description": (
        "Prepare a new coding project: a folder in the user's projects folder, git, a GitHub repository, "
        "and opening it in their editor. The user sees a preview and must confirm before anything is created."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "name": {"type": "string", "description": "Folder and repository name: letters, digits, dashes, dots, underscores."},
            "visibility": {"type": "string", "enum": ["private", "public"],
                           "description": "Whether the GitHub repository is private or public. Ask the user; never guess."},
            "description": {"type": "string", "description": "One line about the project, if the user gave one."},
        },
        "required": ["name", "visibility"],
        "additionalProperties": True,
    },
}
UNAVAILABLE = "This tool is not available right now. Tell the user that OMNIS could not carry it out."


def _tool(name: str, description: str, properties: dict[str, str], required: list[str] | None = None) -> dict[str, Any]:
    return {"name": name, "description": description, "inputSchema": {
        "type": "object",
        "properties": {key: {"type": "string", "description": text} for key, text in properties.items()},
        "required": required if required is not None else list(properties),
        "additionalProperties": True,
    }}


SERVICE_TOOLS = [
    _tool("reminders_list", "List the user's open reminders. Each has an id like r3.",
          {"list": "Only this reminders list. Leave out for all."}, []),
    _tool("reminders_add", "Prepare a new reminder. The user must confirm.",
          {"title": "What to be reminded of.", "due": "When, as YYYY-MM-DD or YYYY-MM-DDTHH:MM local time. Leave out for none.",
           "list": "Which reminders list. Leave out for the default.", "notes": "Extra notes."}, ["title"]),
    _tool("reminders_complete", "Prepare marking a reminder as done. The user must confirm.",
          {"reminder": "The reminder's id from reminders_list, like r3."}),
    _tool("reminders_delete", "Prepare deleting a reminder. The user must confirm.",
          {"reminder": "The reminder's id from reminders_list, like r3."}),
    _tool("github_overview", "Show the user's open pull requests, pull requests waiting for their review, and issues assigned to them.", {}),
    _tool("spotify_now_playing", "Say what Spotify is playing.", {}),
    _tool("spotify_control", "Control Spotify playback at once.", {"action": "One of: play, pause, toggle, next, previous."}),
    _tool("spotify_search", "Open Spotify showing search results for something.", {"query": "What to search for."}),
]


def tools() -> list[dict[str, Any]]:
    """The calendar tools in the form MCP expects. The schemas are the ones the local model uses."""
    listed = []
    for tool in CALENDAR_READ_TOOLS + CALENDAR_WRITE_TOOLS:
        function = tool["function"]
        schema = dict(function["parameters"])
        # The app replaces the arguments with its reply, so anything must be accepted here.
        schema["additionalProperties"] = True
        listed.append({"name": function["name"], "description": function["description"], "inputSchema": schema})
    return listed + [PROJECT_TOOL] + SERVICE_TOOLS


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
