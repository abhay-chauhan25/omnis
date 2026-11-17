"""Entry point: `python3 -m omnis_backend [--idle-seconds N]`."""

from __future__ import annotations

import argparse
import asyncio
import sys

from .handlers import mock_answer
from .service import Service

LINE_LIMIT = 1 << 20


async def _serve(idle_seconds: float) -> int:
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(limit=LINE_LIMIT)
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    out = sys.stdout.buffer

    def write(data: bytes) -> None:
        out.write(data)
        out.flush()

    return await Service(reader, write, mock_answer, idle_seconds=idle_seconds).run()


def main() -> int:
    parser = argparse.ArgumentParser(prog="omnis_backend")
    parser.add_argument(
        "--idle-seconds",
        type=float,
        default=300.0,
        help="exit after this long with no requests (0 disables)",
    )
    args = parser.parse_args()
    try:
        return asyncio.run(_serve(args.idle_seconds))
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
