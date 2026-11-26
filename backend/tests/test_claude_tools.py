import io
import json
import subprocess
import sys
import unittest

from omnis_backend import claude_tools


class ClaudeToolsTests(unittest.TestCase):
    def call(self, method, params=None, id=1):
        return claude_tools.handle({"jsonrpc": "2.0", "id": id, "method": method, "params": params or {}})

    def test_it_lists_the_calendar_tools_and_the_project_tool_with_open_schemas(self):
        tools = self.call("tools/list")["result"]["tools"]
        self.assertEqual([tool["name"] for tool in tools], [
            "calendar_events", "calendar_event_details", "calendar_list",
            "calendar_create_event", "calendar_update_event", "calendar_delete_event",
            "calendar_create_calendar", "calendar_rename_calendar", "calendar_delete_calendar", "project_create",
            "reminders_list", "reminders_add", "reminders_complete", "reminders_delete", "github_overview",
            "spotify_now_playing", "spotify_control", "spotify_search", "spotify_play", "apps_open", "messages_send",
            "photos_search", "photos_albums", "photos_show"])
        for tool in tools:
            self.assertEqual(tool["inputSchema"]["type"], "object")
            self.assertTrue(tool["inputSchema"]["additionalProperties"])
            self.assertTrue(tool["description"])

    def test_a_call_only_hands_back_the_text_the_app_supplied(self):
        reply = self.call("tools/call", {"name": "calendar_events", "arguments": {"_result": "[e1] 10:00 Dentist"}})
        self.assertEqual(reply["result"], {"content": [{"type": "text", "text": "[e1] 10:00 Dentist"}], "isError": False})

    def test_pictures_the_app_supplied_are_handed_over_and_anything_else_is_left_out(self):
        good = "aGVsbG8="
        reply = self.call("tools/call", {"name": "photos_show", "arguments": {
            "_result": "Two photos.", "_images": [good, "not base64!", 7, "abc", "", good]}})["result"]
        self.assertFalse(reply["isError"])
        self.assertEqual(reply["content"][:2], [{"type": "text", "text": "Two photos."},
                                                {"type": "image", "data": good, "mimeType": "image/jpeg"}])
        # The model is told when pictures were left out, so it does not describe what it never saw.
        self.assertEqual(len(reply["content"]), 3)
        self.assertIn("5 of the pictures could not be passed on", reply["content"][2]["text"])
        # Only the first four are passed on, and a picture is never sent without the app's text.
        many = self.call("tools/call", {"name": "photos_show", "arguments": {"_result": "x", "_images": [good] * 9}})["result"]
        self.assertEqual([part["type"] for part in many["content"]], ["text"] + ["image"] * 4 + ["text"])
        # No other tool can carry a picture.
        other = self.call("tools/call", {"name": "calendar_events", "arguments": {"_result": "x", "_images": [good]}})["result"]
        self.assertEqual(other["content"], [{"type": "text", "text": "x"}])
        alone = self.call("tools/call", {"name": "photos_show", "arguments": {"_images": [good]}})["result"]
        self.assertEqual(alone["content"], [{"type": "text", "text": claude_tools.UNAVAILABLE}])
        for odd in ("text", {"a": 1}, None):
            self.assertEqual(len(self.call("tools/call", {"name": "photos_show", "arguments": {"_result": "x", "_images": odd}})["result"]["content"]), 1)
        big = "A" * (claude_tools.MAX_IMAGE_CHARS + 4)
        self.assertEqual(len(self.call("tools/call", {"name": "photos_show", "arguments": {"_result": "x", "_images": [big]}})["result"]["content"]), 2)

    def test_without_the_apps_text_or_for_an_unknown_tool_nothing_happens(self):
        for params in ({"name": "calendar_delete_calendar", "arguments": {"name": "Work"}},
                       {"name": "calendar_events", "arguments": {"_result": ""}},
                       {"name": "calendar_events", "arguments": {"_result": 7}},
                       {"name": "calendar_events"},
                       {"name": "run_shell", "arguments": {"_result": "done"}}):
            reply = self.call("tools/call", params)["result"]
            self.assertTrue(reply["isError"], params)
            self.assertEqual(reply["content"][0]["text"], claude_tools.UNAVAILABLE)

    def test_the_handshake_notifications_and_unknown_methods(self):
        start = self.call("initialize", {"protocolVersion": "2025-11-25"})["result"]
        self.assertEqual((start["protocolVersion"], start["serverInfo"]["name"]), ("2025-11-25", "omnis"))
        self.assertIsNone(claude_tools.handle({"jsonrpc": "2.0", "method": "notifications/initialized"}))
        self.assertEqual(self.call("resources/list")["error"]["code"], -32601)

    def test_it_runs_as_a_program_over_pipes_and_ignores_rubbish(self):
        lines = "not json\n[1]\n" + json.dumps({"jsonrpc": "2.0", "id": 5, "method": "tools/list"}) + "\n"
        out = subprocess.run([sys.executable, "-m", "omnis_backend.claude_tools"], input=lines, capture_output=True,
                             text=True, timeout=20)
        replies = [json.loads(line) for line in out.stdout.splitlines()]
        self.assertEqual(len(replies), 1)
        self.assertEqual((replies[0]["id"], len(replies[0]["result"]["tools"])), (5, 24))
        self.assertEqual(out.stderr, "")

    def test_serve_reads_until_the_input_ends(self):
        writer = io.StringIO()
        claude_tools.serve(io.StringIO(json.dumps({"id": 1, "method": "ping"}) + "\n"), writer)
        self.assertEqual(json.loads(writer.getvalue()), {"jsonrpc": "2.0", "id": 1, "result": {}})
