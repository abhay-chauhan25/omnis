"""A small client for a local Ollama server, using only the standard library.

It only ever talks to this machine. The server is started on demand and, if
this process started it, stopped again when this process exits.
"""

from __future__ import annotations

import asyncio
import json
import os
from collections.abc import AsyncIterator

from .models import AnswerError

LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "::1")
DEFAULT_PORT = 11434
MAX_LINE = 4 * 1024 * 1024
CONTROL_TIMEOUT = 10.0  # for quick calls: version, unload, list


class OllamaError(AnswerError):
    def __init__(self, message: str, code: str = "model_unavailable"):
        super().__init__(code, message)


class OllamaClient:
    def __init__(
        self,
        host: str = "127.0.0.1",
        port: int = DEFAULT_PORT,
        binary: str | None = None,
        start_timeout: float = 20.0,
    ):
        if host not in LOOPBACK_HOSTS:
            raise ValueError("Ollama must be reached on this machine only")
        self.host = host
        self.port = port
        self.binary = binary
        self.start_timeout = start_timeout
        self._server: asyncio.subprocess.Process | None = None

    # -- HTTP -----------------------------------------------------------

    async def _open(self, method: str, path: str, body: dict | None):
        try:
            reader, writer = await asyncio.open_connection(self.host, self.port, limit=MAX_LINE)
        except OSError:
            raise OllamaError("The local model server is not running.") from None
        payload = b"" if body is None else json.dumps(body).encode("utf-8")
        head = (
            f"{method} {path} HTTP/1.1\r\n"
            f"Host: {self.host}:{self.port}\r\n"
            "Accept: application/x-ndjson, application/json\r\n"
            "Connection: close\r\n"
            f"Content-Length: {len(payload)}\r\n"
            + ("Content-Type: application/json\r\n" if body is not None else "")
            + "\r\n"
        ).encode("ascii")
        try:
            writer.write(head + payload)
            await writer.drain()
            status_line = await reader.readline()
            parts = status_line.split()
            if len(parts) < 2 or not parts[1].isdigit():
                raise ValueError("unreadable status line")
            status = int(parts[1])
            headers: dict[str, str] = {}
            while True:
                line = await reader.readline()
                if line in (b"\r\n", b"\n", b""):
                    break
                name, _, value = line.decode("latin-1").partition(":")
                headers[name.strip().lower()] = value.strip()
        except (OSError, asyncio.IncompleteReadError, ValueError):
            writer.close()
            raise OllamaError("The local model server sent an unreadable reply or closed the connection.") from None
        except BaseException:
            writer.close()  # cancelled or timed out while waiting for the reply
            raise
        return status, headers, reader, writer

    @staticmethod
    async def _body(reader: asyncio.StreamReader, headers: dict[str, str]) -> AsyncIterator[bytes]:
        """Yield the response body in pieces, undoing chunked transfer encoding."""
        if "chunked" in headers.get("transfer-encoding", "").lower():
            while True:
                size_line = await reader.readline()
                if not size_line:
                    # The stream stopped without its closing marker.
                    raise asyncio.IncompleteReadError(b"", None)
                size = int(size_line.split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    return
                if size < 0 or size > MAX_LINE:
                    raise ValueError("chunk size out of range")
                yield await reader.readexactly(size)
                await reader.readexactly(2)  # CRLF after each chunk
        elif "content-length" in headers:
            remaining = int(headers["content-length"])
            while remaining > 0:
                data = await reader.read(min(remaining, 65536))
                if not data:
                    return
                remaining -= len(data)
                yield data
        else:
            while True:
                data = await reader.read(65536)
                if not data:
                    return
                yield data

    async def _lines(self, reader, headers) -> AsyncIterator[dict]:
        buffer = b""
        async for piece in self._body(reader, headers):
            buffer += piece
            if len(buffer) > MAX_LINE:
                raise OllamaError("The local model server sent an oversized reply.")
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                if line.strip():
                    yield self._parse(line)
        if buffer.strip():
            yield self._parse(buffer)

    @staticmethod
    def _parse(line: bytes) -> dict:
        try:
            value = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            raise OllamaError("The local model server sent an unreadable reply.") from None
        if not isinstance(value, dict):
            raise OllamaError("The local model server sent an unreadable reply.")
        return value

    async def _json(self, method: str, path: str, body: dict | None = None) -> dict:
        try:
            return await asyncio.wait_for(self._json_untimed(method, path, body), CONTROL_TIMEOUT)
        except asyncio.TimeoutError:
            raise OllamaError("The local model server is not responding.") from None

    async def _json_untimed(self, method: str, path: str, body: dict | None = None) -> dict:
        status, headers, reader, writer = await self._open(method, path, body)
        try:
            result: dict = {}
            async for value in self._lines(reader, headers):
                result = value
            if status != 200:
                raise OllamaError(_server_message(result, status))
            return result
        except (OSError, asyncio.IncompleteReadError, ValueError):
            raise OllamaError("The local model server closed the connection.") from None
        finally:
            writer.close()

    # -- server lifecycle ------------------------------------------------

    async def version(self) -> str | None:
        try:
            return str((await self._json("GET", "/api/version")).get("version", ""))
        except OllamaError:
            return None

    @property
    def started_server(self) -> bool:
        return self._server is not None and self._server.returncode is None

    async def ensure_server(self) -> None:
        """Make sure a server is answering, starting one if we know how."""
        if await self.version() is not None:
            return
        if not self.binary:
            raise OllamaError("The local model server is not running and OMNIS was not told how to start it.")
        if not self.started_server:
            env = dict(os.environ, OLLAMA_HOST=f"{self.host}:{self.port}")
            try:
                self._server = await asyncio.create_subprocess_exec(
                    self.binary,
                    "serve",
                    env=env,
                    stdin=asyncio.subprocess.DEVNULL,
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.DEVNULL,
                )
            except OSError:
                raise OllamaError("The local model server could not be started.") from None
        loop = asyncio.get_running_loop()
        deadline = loop.time() + self.start_timeout
        while loop.time() < deadline:
            if await self.version() is not None:
                return
            if self._server is not None and self._server.returncode is not None:
                break
            await asyncio.sleep(0.1)
        raise OllamaError("The local model server did not start in time.")

    async def stop_server(self) -> None:
        """Stop the server, but only if this process started it."""
        server, self._server = self._server, None
        if server is None or server.returncode is not None:
            return
        server.terminate()
        try:
            await asyncio.wait_for(server.wait(), 5)
        except asyncio.TimeoutError:
            server.kill()
            await server.wait()

    # -- models ----------------------------------------------------------

    async def chat(
        self,
        model: str,
        messages: list[dict],
        keep_alive_seconds: int,
        context_tokens: int = 8192,
    ) -> AsyncIterator[dict]:
        """Stream a chat reply. Yields the server's JSON objects one by one.

        Closing this generator closes the connection, which makes the server
        stop generating.
        """
        body = {
            "model": model,
            "messages": messages,
            "stream": True,
            # This Qwen3 build always reasons first. Asking for the reasoning
            # separately keeps it out of the answer text ("message.thinking"
            # instead of "message.content"); turning it off does not work.
            "think": True,
            "keep_alive": f"{int(keep_alive_seconds)}s",
            # The model allows a far larger context than a popup question
            # needs; a bounded one keeps memory use predictable.
            "options": {"num_ctx": context_tokens},
        }
        status, headers, reader, writer = await self._open("POST", "/api/chat", body)
        try:
            if status != 200:
                last: dict = {}
                async for value in self._lines(reader, headers):
                    last = value
                raise OllamaError(_server_message(last, status))
            async for value in self._lines(reader, headers):
                if "error" in value:
                    raise OllamaError(_server_message(value, status))
                yield value
        except (OSError, asyncio.IncompleteReadError, ValueError):
            raise OllamaError("The local model server closed the connection.") from None
        finally:
            writer.close()

    async def unload(self, model: str) -> None:
        """Ask the server to drop a model from memory now."""
        try:
            await self._json("POST", "/api/generate", {"model": model, "keep_alive": 0})
        except OllamaError:
            pass

    async def loaded(self) -> list[dict]:
        """Models currently in memory, with their sizes."""
        return list((await self._json("GET", "/api/ps")).get("models", []))


def _server_message(value: dict, status: int) -> str:
    detail = value.get("error") if isinstance(value, dict) else None
    if isinstance(detail, str) and detail:
        return f"The local model server reported: {detail[:300]}"
    return f"The local model server replied with status {status}."
