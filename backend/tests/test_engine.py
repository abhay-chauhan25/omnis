import asyncio
import json
import unittest

from omnis_backend.engine import LocalEngine
from omnis_backend.models import AnswerError, AnswerInfo
from omnis_backend.ollama import OllamaClient, OllamaError
from omnis_backend.service import Service

from .fake_ollama import FakeOllama


async def collect(stream):
    text, info = "", None
    async for item in stream:
        if isinstance(item, AnswerInfo):
            info = item
        else:
            text += item
    return text, info


class EngineTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.fake = await FakeOllama().start()
        self.client = OllamaClient(port=self.fake.port)
        self.engine = LocalEngine(self.client, first_piece_timeout=1.0, next_piece_timeout=0.3)

    async def asyncTearDown(self):
        await self.fake.stop()

    def chats(self):
        return [body for _, path, body in self.fake.requests if path == "/api/chat"]

    async def test_light_request_uses_the_small_model_and_reports_usage(self):
        text, info = await collect(self.engine.answer("What is the capital of France?"))
        self.assertEqual(text, "Paris is the capital.")
        self.assertEqual(info.model, "qwen3:4b")
        self.assertEqual(info.route, "local")
        self.assertEqual((info.input_tokens, info.output_tokens, info.load_ms), (12, 34, 2000))
        self.assertEqual(info.cost_usd, 0.0)
        self.assertTrue(info.reason)
        body = self.chats()[0]
        self.assertEqual(body["model"], "qwen3:4b")
        self.assertEqual(body["keep_alive"], "300s")
        self.assertEqual(body["messages"][-1], {"role": "user", "content": "What is the capital of France?"})
        self.assertEqual(body["messages"][0]["role"], "system")

    async def test_reasoning_text_is_never_shown(self):
        self.fake.thinking = ["secret scratch work ", "more scratch"]
        text, _ = await collect(self.engine.answer("hi"))
        self.assertNotIn("scratch", text)

    async def test_moderate_request_uses_the_larger_model(self):
        _, info = await collect(self.engine.answer("Compare SQLite and Postgres"))
        self.assertEqual(info.model, "qwen3:8b")

    async def test_switching_models_unloads_the_previous_one_first(self):
        await collect(self.engine.answer("hi"))
        await collect(self.engine.answer("Compare SQLite and Postgres"))
        unloads = [body for _, path, body in self.fake.requests if path == "/api/generate"]
        self.assertEqual(unloads, [{"model": "qwen3:4b", "keep_alive": 0}])
        order = [p for p in self.fake.paths() if p in ("/api/chat", "/api/generate")]
        self.assertEqual(order, ["/api/chat", "/api/generate", "/api/chat"])

    async def test_same_model_twice_does_not_unload(self):
        await collect(self.engine.answer("hi"))
        await collect(self.engine.answer("hello"))
        self.assertNotIn("/api/generate", self.fake.paths())

    async def test_claude_route_is_a_labelled_stand_in_and_touches_no_model(self):
        text, info = await collect(self.engine.answer("use claude to explain quicksort"))
        self.assertIn("not connected", text)
        self.assertIn("you asked for Claude", text)
        self.assertEqual((info.model, info.route, info.cost_usd), ("claude-mock", "cloud-mock", 0.0))
        self.assertEqual(self.fake.requests, [])

    async def test_local_override_keeps_a_claude_topic_on_this_mac(self):
        _, info = await collect(self.engine.answer("use claude to explain this research paper", "local"))
        self.assertEqual(info.route, "local")

    async def test_no_silent_fallback_when_the_local_server_is_down(self):
        await self.fake.stop()
        with self.assertRaises(AnswerError) as ctx:
            await collect(self.engine.answer("hi"))
        self.assertEqual(ctx.exception.code, "model_unavailable")

    async def test_a_stalled_model_is_abandoned(self):
        self.fake.stall_after = 2
        with self.assertRaises(AnswerError) as ctx:
            await collect(self.engine.answer("hi"))
        self.assertEqual(ctx.exception.code, "timeout")
        # The engine is usable again straight away.
        self.fake.stall_after = None
        text, _ = await collect(self.engine.answer("hi"))
        self.assertEqual(text, "Paris is the capital.")

    async def test_server_error_mid_answer_is_reported(self):
        self.fake.error = "model ran out of memory"
        with self.assertRaises(OllamaError) as ctx:
            await collect(self.engine.answer("hi"))
        self.assertIn("ran out of memory", ctx.exception.message)

    async def test_an_answer_cut_short_is_an_error_not_a_normal_finish(self):
        self.fake.cut_after = 2
        pieces = []
        with self.assertRaises(AnswerError) as ctx:
            async for item in self.engine.answer("hi"):
                pieces.append(item)
        self.assertEqual(pieces, ["Paris ", "is "])
        self.assertIn(ctx.exception.code, ("model_unavailable",))

    async def test_odd_values_from_the_server_do_not_break_the_answer(self):
        self.fake.final_extra = {"eval_count": "many", "prompt_eval_count": None, "load_duration": True}
        self.fake.pieces = ["ok"]
        text, info = await collect(self.engine.answer("hi"))
        self.assertEqual(text, "ok")
        self.assertEqual((info.input_tokens, info.output_tokens, info.load_ms), (0, 0, 0))

    async def test_endless_reasoning_hits_the_overall_limit(self):
        engine = LocalEngine(self.client, first_piece_timeout=5, next_piece_timeout=5, whole_answer_timeout=0.4)
        self.fake.thinking = ["hmm "] * 10_000
        self.fake.think_delay = 0.01
        with self.assertRaises(AnswerError) as ctx:
            await collect(engine.answer("hi"))
        self.assertEqual(ctx.exception.code, "timeout")

    async def test_reasoning_with_no_answer_is_an_error_not_a_blank(self):
        self.fake.pieces = []
        with self.assertRaises(AnswerError) as ctx:
            await collect(self.engine.answer("hi"))
        self.assertEqual(ctx.exception.code, "empty_answer")

    async def test_a_hard_topic_is_answered_locally_not_by_the_stand_in(self):
        _, info = await collect(self.engine.answer("What is the time complexity of quicksort?"))
        self.assertEqual((info.model, info.route), ("qwen3:8b", "local"))

    async def test_missing_model_is_reported(self):
        self.fake.status, self.fake.error = 404, "model 'qwen3:4b' not found"
        with self.assertRaises(OllamaError) as ctx:
            await collect(self.engine.answer("hi"))
        self.assertIn("not found", ctx.exception.message)

    async def test_stopping_early_closes_the_connection_so_the_model_stops(self):
        self.fake.delay = 0.05
        self.fake.pieces = ["x "] * 200
        stream = self.engine.answer("hi")
        async for item in stream:
            break
        await stream.aclose()
        await asyncio.wait_for(self.fake.disconnected.wait(), 2)

    async def test_one_request_at_a_time(self):
        self.fake.delay = 0.05
        first = asyncio.create_task(collect(self.engine.answer("hi")))
        second = asyncio.create_task(collect(self.engine.answer("hello")))
        await asyncio.sleep(0.12)
        self.assertEqual(len(self.chats()), 1)
        await asyncio.gather(first, second)
        self.assertEqual(len(self.chats()), 2)


class ClientTests(unittest.IsolatedAsyncioTestCase):
    async def test_only_this_machine_is_allowed(self):
        for host in ("example.com", "192.168.1.5", "0.0.0.0", ""):
            with self.subTest(host=host):
                with self.assertRaises(ValueError):
                    OllamaClient(host=host)

    async def test_without_a_program_path_a_missing_server_is_an_error(self):
        client = OllamaClient(port=1)
        self.assertIsNone(await client.version())
        with self.assertRaises(OllamaError):
            await client.ensure_server()

    async def test_a_server_that_never_comes_up_is_an_error_and_is_cleaned_up(self):
        client = OllamaClient(port=1, binary="/bin/sleep", start_timeout=0.4)
        # "/bin/sleep serve" exits at once: it is not a server.
        with self.assertRaises(OllamaError):
            await client.ensure_server()
        await client.stop_server()
        self.assertFalse(client.started_server)

    async def test_a_server_that_accepts_but_never_replies_is_an_error(self):
        async def silent(reader, writer):
            await asyncio.sleep(30)

        server = await asyncio.start_server(silent, "127.0.0.1", 0)
        try:
            import omnis_backend.ollama as module
            original, module.CONTROL_TIMEOUT = module.CONTROL_TIMEOUT, 0.3
            try:
                client = OllamaClient(port=server.sockets[0].getsockname()[1])
                self.assertIsNone(await asyncio.wait_for(client.version(), 3))
                with self.assertRaises(OllamaError):
                    await asyncio.wait_for(client.ensure_server(), 3)
            finally:
                module.CONTROL_TIMEOUT = original
        finally:
            server.close()

    async def test_an_existing_server_is_used_and_never_stopped(self):
        fake = await FakeOllama().start()
        try:
            client = OllamaClient(port=fake.port, binary="/definitely/not/here")
            await client.ensure_server()
            self.assertFalse(client.started_server)
            await client.stop_server()
            self.assertEqual(await client.version(), "fake")
            self.assertEqual((await client.loaded())[0]["name"], "qwen3:4b")
        finally:
            await fake.stop()


class ServiceWithEngineTests(unittest.IsolatedAsyncioTestCase):
    async def test_details_and_safe_errors_reach_the_app(self):
        fake = await FakeOllama().start()
        try:
            engine = LocalEngine(OllamaClient(port=fake.port))
            reader, out = asyncio.StreamReader(), []
            service = Service(reader, lambda data: out.extend(json.loads(l) for l in data.splitlines()),
                              engine.answer, idle_seconds=0)
            task = asyncio.create_task(service.run())
            reader.feed_data(b'{"type":"hello","protocol":1}\n{"type":"ask","id":"a","text":"hi"}\n')
            while not any(m["type"] == "answer_done" for m in out):
                await asyncio.sleep(0.01)
            done = next(m for m in out if m["type"] == "answer_done")
            self.assertEqual((done["model"], done["route"], done["output_tokens"]), ("qwen3:4b", "local", 34))

            await fake.stop()
            reader.feed_data(b'{"type":"ask","id":"b","text":"hi","route":"local"}\n')
            while not any(m["type"] == "error" for m in out):
                await asyncio.sleep(0.01)
            error = next(m for m in out if m["type"] == "error")
            self.assertEqual((error["id"], error["code"]), ("b", "model_unavailable"))

            reader.feed_data(b'{"type":"ask","id":"c","text":"hi","route":"elsewhere"}\n')
            while sum(m["type"] == "error" for m in out) < 2:
                await asyncio.sleep(0.01)
            self.assertEqual(out[-1]["code"], "bad_request")
            reader.feed_eof()
            await asyncio.wait_for(task, 2)
        finally:
            await fake.stop()


if __name__ == "__main__":
    unittest.main()
