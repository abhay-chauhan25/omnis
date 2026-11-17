import json
import unittest

from omnis_backend import protocol


class DecodeClientTests(unittest.TestCase):
    def test_hello(self):
        self.assertEqual(
            protocol.decode_client(b'{"type":"hello","protocol":1}'),
            {"type": "hello", "protocol": 1},
        )

    def test_ask(self):
        got = protocol.decode_client(b'{"type":"ask","id":"a1","text":"hi there"}')
        self.assertEqual(got, {"type": "ask", "id": "a1", "text": "hi there", "route": "auto"})

    def test_cancel(self):
        self.assertEqual(
            protocol.decode_client(b'{"type":"cancel","id":"a1"}'),
            {"type": "cancel", "id": "a1"},
        )

    def test_extra_fields_are_dropped(self):
        got = protocol.decode_client(b'{"type":"cancel","id":"a1","run":"rm -rf /"}')
        self.assertEqual(got, {"type": "cancel", "id": "a1"})

    def assert_bad(self, line: bytes):
        with self.assertRaises(protocol.ProtocolError) as ctx:
            protocol.decode_client(line)
        self.assertEqual(ctx.exception.code, "bad_request")
        return ctx.exception

    def test_rejects_malformed(self):
        for line in (
            b"not json",
            b"\xff\xfe",
            b"[1,2,3]",
            b'{"type":"shell","cmd":"ls"}',
            b'{"type":"hello","protocol":"1"}',
            b'{"type":"hello","protocol":true}',
            b'{"type":"ask","text":"no id"}',
            b'{"type":"ask","id":"","text":"x"}',
            b'{"type":"ask","id":7,"text":"x"}',
            b'{"type":"ask","id":"a","text":"   "}',
            b'{"type":"ask","id":"a","text":5}',
            b'{"type":"cancel"}',
        ):
            with self.subTest(line=line):
                self.assert_bad(line)

    def test_rejects_oversized_text_and_keeps_id(self):
        big = "x" * (protocol.MAX_TEXT_CHARS + 1)
        exc = self.assert_bad(json.dumps({"type": "ask", "id": "a9", "text": big}).encode())
        self.assertEqual(exc.request_id, "a9")

    def test_rejects_oversized_id(self):
        self.assert_bad(json.dumps({"type": "cancel", "id": "i" * 500}).encode())


class EncodeTests(unittest.TestCase):
    def test_one_line_per_message(self):
        data = protocol.encode(protocol.answer_chunk("a", "line one\nline two"))
        self.assertTrue(data.endswith(b"\n"))
        self.assertEqual(data.count(b"\n"), 1)
        self.assertEqual(json.loads(data)["text"], "line one\nline two")

    def test_unicode_round_trip(self):
        data = protocol.encode(protocol.answer_chunk("a", "café “quoted”"))
        self.assertEqual(json.loads(data.decode("utf-8"))["text"], "café “quoted”")

    def test_error_id_is_optional(self):
        self.assertNotIn("id", protocol.error("bad_request", "m"))
        self.assertEqual(protocol.error("bad_request", "m", "a")["id"], "a")

    def test_hello_carries_version(self):
        self.assertEqual(protocol.hello()["protocol"], protocol.PROTOCOL_VERSION)


if __name__ == "__main__":
    unittest.main()
