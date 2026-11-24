"""Runs the real service as a child process, the way the app does."""

import json
import os
import pathlib
import subprocess
import sys
import unittest

BACKEND_DIR = pathlib.Path(__file__).resolve().parents[1]


def start(*args: str) -> subprocess.Popen:
    env = dict(os.environ, OMNIS_MOCK_DELAY_MS="1")
    return subprocess.Popen(
        [sys.executable, "-m", "omnis_backend", *args],
        cwd=BACKEND_DIR,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )


class ProcessTests(unittest.TestCase):
    def test_full_round_trip_over_pipes(self):
        proc = start("--idle-seconds", "0")
        try:
            proc.stdin.write(b'{"type":"hello","protocol":3}\n')
            proc.stdin.write(b'{"type":"ask","id":"q1","text":"what is OMNIS?"}\n')
            proc.stdin.flush()
            messages = []
            while True:
                line = proc.stdout.readline()
                self.assertTrue(line, "service closed its output early")
                messages.append(json.loads(line))
                if messages[-1]["type"] == "answer_done":
                    break
            self.assertEqual(messages[0]["type"], "hello")
            text = "".join(m["text"] for m in messages if m["type"] == "answer_chunk")
            self.assertIn("mock answer", text)
            self.assertIn("what is OMNIS?", text)
            proc.stdin.close()
            self.assertEqual(proc.wait(timeout=5), 0)
            self.assertEqual(proc.stderr.read(), b"")
        finally:
            proc.kill()
            proc.wait()
            for stream in (proc.stdout, proc.stderr):
                stream.close()

    def test_exits_by_itself_when_idle(self):
        proc = start("--idle-seconds", "0.3")
        try:
            proc.stdin.write(b'{"type":"hello","protocol":3}\n')
            proc.stdin.flush()
            self.assertEqual(proc.wait(timeout=5), 0)
            lines = [json.loads(line) for line in proc.stdout.read().splitlines()]
            self.assertEqual(lines[-1], {"type": "bye", "reason": "idle"})
        finally:
            proc.kill()
            proc.wait()
            for stream in (proc.stdin, proc.stdout, proc.stderr):
                stream.close()


if __name__ == "__main__":
    unittest.main()
