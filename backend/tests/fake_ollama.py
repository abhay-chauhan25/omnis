"""A stand-in Ollama server for tests. Speaks just enough HTTP."""

from __future__ import annotations

import asyncio
import json


class FakeOllama:
    def __init__(self):
        self.requests: list[tuple[str, str, dict | None]] = []
        self.pieces = ["Paris ", "is ", "the ", "capital."]
        self.thinking = ["Let me think. "]
        self.delay = 0.0
        self.stall_after: int | None = None  # stop sending after this many pieces
        self.cut_after: int | None = None  # drop the connection after this many pieces
        self.think_delay = 0.0
        self.final_extra: dict = {}
        # Each chat request that offers tools pops one entry and replies with
        # that tool call instead of an answer. A dict is sent as the raw call.
        self.tool_calls: list = []
        self.error: str | None = None
        self.status = 200
        self.disconnected = asyncio.Event()
        self.server: asyncio.AbstractServer | None = None
        self._handlers: set[asyncio.Task] = set()
        self.port = 0

    async def start(self) -> "FakeOllama":
        self.server = await asyncio.start_server(self._serve, "127.0.0.1", 0)
        self.port = self.server.sockets[0].getsockname()[1]
        return self

    async def stop(self) -> None:
        if self.server is not None:
            self.server.close()
            # A handler may be parked mid-reply (the stall test); end it so
            # closing the server cannot wait on it.
            for task in list(self._handlers):
                task.cancel()
            await asyncio.gather(*self._handlers, return_exceptions=True)
            await self.server.wait_closed()
            self.server = None

    def paths(self) -> list[str]:
        return [path for _, path, _ in self.requests]

    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        task = asyncio.current_task()
        self._handlers.add(task)
        try:
            request_line = (await reader.readline()).decode()
            method, path, _ = request_line.split()
            length = 0
            while True:
                line = await reader.readline()
                if line in (b"\r\n", b""):
                    break
                name, _, value = line.decode().partition(":")
                if name.lower() == "content-length":
                    length = int(value)
            body = json.loads(await reader.readexactly(length)) if length else None
            self.requests.append((method, path, body))

            if path == "/api/version":
                await self._plain(writer, 200, {"version": "fake"})
            elif path == "/api/ps":
                await self._plain(writer, 200, {"models": [{"name": "qwen3:4b", "size": 123}]})
            elif path == "/api/generate":
                await self._plain(writer, 200, {"done": True})
            elif path == "/api/chat":
                await self._chat(writer)
            else:
                await self._plain(writer, 404, {"error": "not found"})
        except (ConnectionError, asyncio.IncompleteReadError):
            self.disconnected.set()
        finally:
            self._handlers.discard(task)
            writer.close()

    async def _plain(self, writer, status: int, value: dict) -> None:
        payload = json.dumps(value).encode()
        writer.write(
            f"HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\n\r\n".encode()
            + payload
        )
        await writer.drain()

    async def _chunk(self, writer, value: dict) -> None:
        data = json.dumps(value).encode() + b"\n"
        writer.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
        await writer.drain()

    async def _chat(self, writer) -> None:
        if self.status != 200:
            await self._plain(writer, self.status, {"error": self.error or "boom"})
            return
        writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n")
        body = self.requests[-1][2] or {}
        if body.get("tools") and self.tool_calls:
            call = self.tool_calls.pop(0)
            if not isinstance(call, dict):
                call = {"id": "call_1", "function": {"index": 0, "name": "web_search", "arguments": {"query": call}}}
            await self._chunk(writer, {"message": {"role": "assistant", "content": "", "tool_calls": [call]}, "done": False})
            await self._chunk(writer, {"message": {"role": "assistant", "content": ""}, "done": True,
                                       "prompt_eval_count": 5, "eval_count": 7})
            writer.write(b"0\r\n\r\n")
            await writer.drain()
            return
        try:
            for piece in self.thinking:
                if self.think_delay:
                    await asyncio.sleep(self.think_delay)
                await self._chunk(writer, {"message": {"role": "assistant", "content": "", "thinking": piece}, "done": False})
            for index, piece in enumerate(self.pieces):
                if self.stall_after is not None and index >= self.stall_after:
                    await asyncio.sleep(3600)
                if self.cut_after is not None and index >= self.cut_after:
                    return  # connection closes with no end marker
                if self.delay:
                    await asyncio.sleep(self.delay)
                if self.error and index == 1:
                    await self._chunk(writer, {"error": self.error})
                    break
                await self._chunk(writer, {"message": {"role": "assistant", "content": piece}, "done": False})
            else:
                await self._chunk(
                    writer,
                    {
                        "message": {"role": "assistant", "content": ""},
                        "done": True,
                        "prompt_eval_count": 12,
                        "eval_count": 34,
                        "load_duration": 2_000_000_000,
                        **self.final_extra,
                    },
                )
            writer.write(b"0\r\n\r\n")
            await writer.drain()
        except (ConnectionError, OSError):
            self.disconnected.set()
