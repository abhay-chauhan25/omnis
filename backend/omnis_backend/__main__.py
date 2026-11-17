"""Entry point: `python3 -m omnis_backend [options]`."""

from __future__ import annotations

import argparse
import asyncio
import signal
import sys

from .engine import LocalEngine
from .handlers import mock_answer
from .ollama import DEFAULT_PORT, OllamaClient
from .service import Service

LINE_LIMIT = 1 << 20


async def _serve(args: argparse.Namespace) -> int:
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(limit=LINE_LIMIT)
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    out = sys.stdout.buffer

    def write(data: bytes) -> None:
        out.write(data)
        out.flush()

    engine: LocalEngine | None = None
    handler = mock_answer
    if args.engine == "local":
        client = OllamaClient(port=args.ollama_port, binary=args.ollama_bin)
        engine = LocalEngine(
            client,
            light_model=args.light_model,
            moderate_model=args.moderate_model,
            keep_alive_seconds=int(args.keep_alive_seconds),
        )
        handler = engine.answer

    service = Service(reader, write, handler, idle_seconds=args.idle_seconds)
    # The app stops this process with a terminate signal; finish cleanly so the
    # model server we started is stopped too.
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, service.request_stop)
    try:
        return await service.run()
    finally:
        if engine is not None:
            await engine.close()


def main() -> int:
    parser = argparse.ArgumentParser(prog="omnis_backend")
    parser.add_argument("--idle-seconds", type=float, default=300.0,
                        help="exit after this long with no requests (0 disables)")
    parser.add_argument("--engine", choices=("mock", "local"), default="mock",
                        help="mock: canned replies. local: models on this Mac through Ollama")
    parser.add_argument("--ollama-bin", default=None, help="path to the ollama program, to start it on demand")
    parser.add_argument("--ollama-port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--light-model", default="qwen3:4b")
    parser.add_argument("--moderate-model", default="qwen3:8b")
    parser.add_argument("--keep-alive-seconds", type=float, default=300.0,
                        help="how long an unused model stays in memory")
    args = parser.parse_args()
    try:
        return asyncio.run(_serve(args))
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
