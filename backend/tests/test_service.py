import asyncio
import json
import unittest

from omnis_backend.service import EXIT_OK, EXIT_UNSUPPORTED_VERSION, Service

HELLO = b'{"type":"hello","protocol":1}\n'


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


async def three_words(text, route="auto"):
    for piece in ("one ", "two ", "three"):
        await asyncio.sleep(0)
        yield piece


async def slow(text, route="auto"):
    for i in range(1000):
        await asyncio.sleep(0.01)
        yield f"{i} "


async def broken(text, route="auto"):
    yield "partial "
    raise RuntimeError("secret detail that must not leak")


class ServiceTests(unittest.IsolatedAsyncioTestCase):
    async def test_hello_then_ask_streams_chunks_then_done(self):
        h = Harness(three_words)
        h.feed(HELLO + ask("r1"))
        await h.until(lambda: h.of_type("answer_done"))
        self.assertEqual(h.out[0]["type"], "hello")
        self.assertEqual(h.out[0]["protocol"], 1)
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
