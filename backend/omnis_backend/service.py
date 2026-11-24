"""The service loop: read messages, answer them, stop when idle."""

from __future__ import annotations

import asyncio
import time
import uuid
from collections.abc import AsyncIterator, Callable

from . import protocol
from .handlers import MOCK_MODEL
from .models import AnswerError, AnswerInfo, ToolRequest

# A handler takes the question, the requested route, whether web search is
# allowed, the earlier turns of the conversation, any files attached to the
# question, and what the app allows for it. It yields pieces of
# text, may yield ToolRequests for the app to carry out, and may finish with
# one AnswerInfo describing what answered.
Handler = Callable[[str, str, bool, list, list, dict], AsyncIterator["str | AnswerInfo | ToolRequest"]]
Writer = Callable[[bytes], None]

EXIT_OK = 0
EXIT_UNSUPPORTED_VERSION = 2


class Service:
    """Serves one app over a pair of pipes.

    `reader` yields lines from the app, `write` sends bytes back. Both are
    injected so the loop can be tested without real pipes.
    """

    def __init__(
        self,
        reader: asyncio.StreamReader,
        write: Writer,
        handler: Handler,
        idle_seconds: float = 300.0,
        model_name: str = MOCK_MODEL,
    ):
        self._reader = reader
        self._write = write
        self._handler = handler
        self._idle_seconds = idle_seconds
        self._model_name = model_name
        self._tasks: dict[str, asyncio.Task[None]] = {}
        # (request id, call id) -> the future the handler is waiting on.
        self._tool_waiters: dict[tuple[str, str], asyncio.Future] = {}
        self._greeted = False
        self._stop = asyncio.Event()
        self._exit_code = EXIT_OK
        self._last_activity = time.monotonic()

    def request_stop(self) -> None:
        """Ask the loop to finish (used when the app tells the process to quit)."""
        self._stop.set()

    # -- output ---------------------------------------------------------

    def _send(self, message: dict) -> None:
        try:
            self._write(protocol.encode(message))
        except (BrokenPipeError, ValueError, OSError):
            # The app went away. Nothing left to talk to.
            self._stop.set()

    def _touch(self) -> None:
        self._last_activity = time.monotonic()

    # -- main loop ------------------------------------------------------

    async def run(self) -> int:
        self._touch()
        idle_task = asyncio.create_task(self._watch_idle())
        try:
            while not self._stop.is_set():
                read = asyncio.ensure_future(self._reader.readline())
                stopped = asyncio.ensure_future(self._stop.wait())
                await asyncio.wait({read, stopped}, return_when=asyncio.FIRST_COMPLETED)
                stopped.cancel()
                if not read.done():
                    read.cancel()
                    break
                try:
                    line = read.result()
                except ValueError:
                    self._send(protocol.error("bad_request", "message line is too long"))
                    continue
                if not line:
                    break  # the app closed its end of the pipe
                self._touch()
                if line.strip():
                    self._handle_line(line)
        finally:
            idle_task.cancel()
            pending = list(self._tasks.values())
            for task in pending:
                task.cancel()
            await asyncio.gather(idle_task, *pending, return_exceptions=True)
        return self._exit_code

    async def _watch_idle(self) -> None:
        if self._idle_seconds <= 0:
            return
        while True:
            remaining = self._last_activity + self._idle_seconds - time.monotonic()
            if remaining > 0:
                await asyncio.sleep(remaining)
                continue
            if self._tasks:
                self._touch()  # still answering; not idle
                continue
            self._send(protocol.bye("idle"))
            self._stop.set()
            return

    # -- message handling -----------------------------------------------

    def _handle_line(self, line: bytes) -> None:
        try:
            message = protocol.decode_client(line)
        except protocol.ProtocolError as exc:
            self._send(protocol.error(exc.code, exc.message, exc.request_id))
            return

        kind = message["type"]
        if kind == "hello":
            if message["protocol"] != protocol.PROTOCOL_VERSION:
                self._send(
                    protocol.error(
                        "unsupported_version",
                        f"service speaks protocol {protocol.PROTOCOL_VERSION}",
                    )
                )
                self._exit_code = EXIT_UNSUPPORTED_VERSION
                self._stop.set()
                return
            self._greeted = True
            self._send(protocol.hello())
            return

        if not self._greeted:
            self._send(protocol.error("bad_request", "expected hello first", message.get("id")))
            return

        request_id = message["id"]
        if kind == "tool_result":
            waiter = self._tool_waiters.pop((request_id, message["call_id"]), None)
            if waiter is not None and not waiter.done():
                waiter.set_result(
                    {"ok": message["ok"], "results": message["results"], "error": message["error"],
                     "content": message["content"]}
                )
            return  # a result nobody is waiting for is ignored
        if kind == "cancel":
            task = self._tasks.get(request_id)
            if task is not None:
                task.cancel()
            return

        if request_id in self._tasks:
            self._send(protocol.error("bad_request", "request id is already in use", request_id))
            return
        self._tasks[request_id] = asyncio.create_task(
            self._answer(
                request_id, message["text"], message.get("route", "auto"),
                message.get("web", True), message.get("history", []),
                message.get("attachments", []), message.get("options", {}),
            )
        )

    async def _answer(
        self, request_id: str, text: str, route: str, web: bool, history: list, attachments: list,
        options: dict,
    ) -> None:
        info: AnswerInfo | None = None
        try:
            async for piece in self._handler(text, route, web, history, attachments, options):
                if isinstance(piece, AnswerInfo):
                    info = piece
                elif isinstance(piece, ToolRequest):
                    call_id = uuid.uuid4().hex
                    self._tool_waiters[(request_id, call_id)] = piece.future
                    self._send(protocol.tool_request(request_id, call_id, piece.tool, piece.query, piece.arguments))
                else:
                    self._send(protocol.answer_chunk(request_id, piece))
            if info is None:
                self._send(protocol.answer_done(request_id, self._model_name))
            else:
                self._send(protocol.answer_done(request_id, info.model, details=info.as_fields()))
        except asyncio.CancelledError:
            self._send(protocol.answer_done(request_id, self._model_name, cancelled=True))
        except AnswerError as exc:
            self._send(protocol.error(exc.code, exc.message, request_id))
        except Exception as exc:  # a handler bug must not take the service down
            self._send(protocol.error("internal", type(exc).__name__, request_id))
        finally:
            self._tasks.pop(request_id, None)
            for key in [key for key in self._tool_waiters if key[0] == request_id]:
                del self._tool_waiters[key]
            self._touch()
