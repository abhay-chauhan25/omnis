import asyncio
import json
import unittest

from omnis_backend.service import EXIT_OK, EXIT_UNSUPPORTED_VERSION, Service

HELLO = b'{"type":"hello","protocol":2}\n'


def ask(request_id: str, text: str = "hello") -> bytes:
    return json.dumps({"type": "ask", "id": request_id, "text": text}).encode() + b"\n"


def cancel(request_id: str) -> bytes:
    return json.dumps({"type": "cancel", "id": request_id}).encode() + b"\n"


class Harness:
    """Runs a Service against an in-memory reader and collects what it writes."""

    def __init__(self, handler, idle_seconds=0.0):
        self.reader = asyncio.StreamReader()
        self.out: list[dict] = []
        self.service = Service(self.reader, self._write, handler, idle_seconds=idle_seconds)
        self.task = asyncio.create_task(self.service.run())

    def _write(self, data: bytes) -> None:
        for line in data.splitlines():
            self.out.append(json.loads(line))

    def feed(self, data: bytes) -> None:
        self.reader.feed_data(data)

    async def until(self, predicate, timeout=2.0):
        async def poll():
            while not predicate():
                await asyncio.sleep(0.005)

        await asyncio.wait_for(poll(), timeout)

    def of_type(self, kind: str) -> list[dict]:
        return [m for m in self.out if m["type"] == kind]

    async def close(self) -> int:
        self.reader.feed_eof()
        return await asyncio.wait_for(self.task, 2.0)


async def three_words(text, route="auto", web=True, history=None, cloud=None, attachments=None):
    for piece in ("one ", "two ", "three"):
        await asyncio.sleep(0)
        yield piece


async def slow(text, route="auto", web=True, history=None, cloud=None, attachments=None):
    for i in range(1000):
        await asyncio.sleep(0.01)
        yield f"{i} "


async def broken(text, route="auto", web=True, history=None, cloud=None, attachments=None):
    yield "partial "
    raise RuntimeError("secret detail that must not leak")


class ServiceTests(unittest.IsolatedAsyncioTestCase):
    async def test_hello_then_ask_streams_chunks_then_done(self):
        h = Harness(three_words)
        h.feed(HELLO + ask("r1"))
        await h.until(lambda: h.of_type("answer_done"))
        self.assertEqual(h.out[0]["type"], "hello")
        self.assertEqual(h.out[0]["protocol"], 2)
        self.assertEqual([m["text"] for m in h.of_type("answer_chunk")], ["one ", "two ", "three"])
        done = h.of_type("answer_done")[0]
        self.assertEqual((done["id"], done["cancelled"], done["model"]), ("r1", False, "mock"))
        self.assertEqual(await h.close(), EXIT_OK)

    async def test_ask_before_hello_is_refused(self):
        h = Harness(three_words)
        h.feed(ask("r1"))
        await h.until(lambda: h.of_type("error"))
        self.assertEqual(h.out[0]["code"], "bad_request")
        self.assertEqual(h.of_type("answer_chunk"), [])
        await h.close()

    async def test_version_mismatch_reports_and_exits(self):
        h = Harness(three_words)
        h.feed(b'{"type":"hello","protocol":99}\n')
        code = await asyncio.wait_for(h.task, 2.0)
        self.assertEqual(code, EXIT_UNSUPPORTED_VERSION)
        self.assertEqual(h.out[0]["code"], "unsupported_version")

    async def test_malformed_line_gets_error_and_service_survives(self):
        h = Harness(three_words)
        h.feed(HELLO + b"garbage\n" + ask("r1"))
        await h.until(lambda: h.of_type("answer_done"))
        self.assertEqual(h.of_type("error")[0]["code"], "bad_request")
        await h.close()

    async def test_cancel_stops_the_answer(self):
        h = Harness(slow)
        h.feed(HELLO + ask("r1"))
        await h.until(lambda: len(h.of_type("answer_chunk")) >= 2)
        h.feed(cancel("r1"))
        await h.until(lambda: h.of_type("answer_done"))
        self.assertTrue(h.of_type("answer_done")[0]["cancelled"])
        seen = len(h.of_type("answer_chunk"))
        await asyncio.sleep(0.05)
        self.assertEqual(len(h.of_type("answer_chunk")), seen)
        await h.close()

    async def test_cancel_of_unknown_id_is_ignored(self):
        h = Harness(three_words)
        h.feed(HELLO + cancel("nope") + ask("r1"))
        await h.until(lambda: h.of_type("answer_done"))
        self.assertEqual(h.of_type("error"), [])
        await h.close()

    async def test_duplicate_id_is_refused(self):
        h = Harness(slow)
        h.feed(HELLO + ask("r1") + ask("r1"))
        await h.until(lambda: h.of_type("error"))
        self.assertEqual(h.of_type("error")[0]["id"], "r1")
        await h.close()

    async def test_two_requests_run_side_by_side(self):
        h = Harness(three_words)
        h.feed(HELLO + ask("a") + ask("b"))
        await h.until(lambda: len(h.of_type("answer_done")) == 2)
        self.assertEqual({m["id"] for m in h.of_type("answer_done")}, {"a", "b"})
        await h.close()

    async def test_handler_failure_is_reported_without_details(self):
        h = Harness(broken)
        h.feed(HELLO + ask("r1") + ask("r2"))
        await h.until(lambda: len(h.of_type("error")) == 2)
        err = h.of_type("error")[0]
        self.assertEqual(err["code"], "internal")
        self.assertNotIn("secret", json.dumps(h.out))
        self.assertFalse(h.task.done())
        await h.close()

    async def test_a_tool_request_goes_out_and_its_result_comes_back(self):
        from omnis_backend.models import ToolRequest

        async def searcher(text, route="auto", web=True, history=None, cloud=None, attachments=None):
            request = ToolRequest("web_search", "the query", asyncio.get_running_loop().create_future())
            yield request
            outcome = await request.future
            yield f"got {len(outcome['results'])} results, web={web}"

        h = Harness(searcher)
        h.feed(HELLO + json.dumps({"type": "ask", "id": "r1", "text": "x", "web": True}).encode() + b"\n")
        await h.until(lambda: h.of_type("tool_request"))
        request = h.of_type("tool_request")[0]
        self.assertEqual((request["id"], request["tool"], request["query"]), ("r1", "web_search", "the query"))

        def result(request_id, call_id):
            return json.dumps({"type": "tool_result", "id": request_id, "call_id": call_id, "ok": True,
                               "results": [{"title": "t", "url": "https://a.example", "snippet": "s"}]}).encode() + b"\n"

        # Results for the wrong request or call are ignored, not delivered.
        h.feed(result("other", request["call_id"]) + result("r1", "wrong-call"))
        await asyncio.sleep(0.05)
        self.assertEqual(h.of_type("answer_chunk"), [])
        h.feed(result("r1", request["call_id"]))
        await h.until(lambda: h.of_type("answer_done"))
        self.assertEqual(h.of_type("answer_chunk")[0]["text"], "got 1 results, web=True")
        # A second copy of the same result has nowhere to go.
        h.feed(result("r1", request["call_id"]))
        await asyncio.sleep(0.05)
        self.assertEqual(h.of_type("error"), [])
        await h.close()

    async def test_cancel_while_waiting_for_a_search_cleans_up(self):
        from omnis_backend.models import ToolRequest

        async def searcher(text, route="auto", web=True, history=None, cloud=None, attachments=None):
            request = ToolRequest("web_search", "q", asyncio.get_running_loop().create_future())
            yield request
            await request.future
            yield "never"

        h = Harness(searcher)
        h.feed(HELLO + ask("r1"))
        await h.until(lambda: h.of_type("tool_request"))
        h.feed(cancel("r1"))
        await h.until(lambda: h.of_type("answer_done"))
        self.assertTrue(h.of_type("answer_done")[0]["cancelled"])
        self.assertEqual(h.service._tool_waiters, {})
        await h.close()

    async def test_conversation_history_reaches_the_handler(self):
        seen = []

        async def recorder(text, route="auto", web=True, history=None, cloud=None, attachments=None):
            seen.append(history)
            yield "ok"

        h = Harness(recorder)
        line = json.dumps({"type": "ask", "id": "r1", "text": "next",
                           "history": [{"role": "user", "content": "first"},
                                       {"role": "assistant", "content": "reply"}]}).encode() + b"\n"
        h.feed(HELLO + line + ask("r2"))
        await h.until(lambda: len(h.of_type("answer_done")) == 2)
        self.assertEqual(seen[0], [{"role": "user", "content": "first"}, {"role": "assistant", "content": "reply"}])
        self.assertEqual(seen[1], [])
        await h.close()

    async def test_usage_is_sent_as_it_happens_and_the_key_is_never_echoed(self):
        from omnis_backend.models import UsageEvent
        configured = []

        async def billed(text, route="auto", web=True, history=None, cloud=None, attachments=None):
            yield UsageEvent("claude-haiku-5-5", 100, 20, 0.00002)
            raise RuntimeError("fails after being billed")

        reader = asyncio.StreamReader()
        out = []
        service = Service(reader, lambda data: out.extend(json.loads(l) for l in data.splitlines()),
                          billed, idle_seconds=0, on_configure=configured.append)
        task = asyncio.create_task(service.run())
        reader.feed_data(HELLO + b'{"type":"configure","claude_key":"sk-secret-value"}\n' + ask("r1"))
        while not any(m["type"] == "error" for m in out):
            await asyncio.sleep(0.005)
        self.assertEqual(configured, [{"claude_key": "sk-secret-value"}])
        usage = [m for m in out if m["type"] == "usage"]
        self.assertEqual(usage, [{"type": "usage", "id": "r1", "model": "claude-haiku-5-5",
                                  "input_tokens": 100, "output_tokens": 20, "cost_usd": 0.00002}])
        self.assertNotIn("sk-secret-value", json.dumps(out))
        reader.feed_eof()
        await asyncio.wait_for(task, 2)

    async def test_stops_itself_when_idle(self):
        h = Harness(three_words, idle_seconds=0.15)
        h.feed(HELLO + ask("r1"))
        code = await asyncio.wait_for(h.task, 2.0)
        self.assertEqual(code, EXIT_OK)
        self.assertEqual(h.out[-1], {"type": "bye", "reason": "idle"})
        self.assertEqual(len(h.of_type("answer_done")), 1)

    async def test_does_not_go_idle_while_answering(self):
        h = Harness(slow, idle_seconds=0.1)
        h.feed(HELLO + ask("r1"))
        await asyncio.sleep(0.35)
        self.assertFalse(h.task.done())
        self.assertEqual(h.of_type("bye"), [])
        h.feed(cancel("r1"))
        await asyncio.wait_for(h.task, 2.0)

    async def test_exits_when_the_app_closes_the_pipe(self):
        h = Harness(slow)
        h.feed(HELLO + ask("r1"))
        await h.until(lambda: h.of_type("answer_chunk"))
        self.assertEqual(await h.close(), EXIT_OK)

    async def test_stops_when_the_app_is_gone(self):
        reader = asyncio.StreamReader()

        def write(_):
            raise BrokenPipeError

        task = asyncio.create_task(Service(reader, write, three_words, idle_seconds=0).run())
        reader.feed_data(HELLO)
        self.assertEqual(await asyncio.wait_for(task, 2.0), EXIT_OK)


if __name__ == "__main__":
    unittest.main()
