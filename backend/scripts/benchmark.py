"""Measures the local models on this Mac and prints a Markdown report.

    cd backend && python3 scripts/benchmark.py --ollama-bin "$(command -v ollama)"

Starts the model server if needed and stops it afterwards if it started it.
Nothing leaves this machine.
"""

from __future__ import annotations

import argparse
import asyncio
import pathlib
import platform
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from omnis_backend.engine import SYSTEM_PROMPT  # noqa: E402
from omnis_backend.ollama import OllamaClient  # noqa: E402

PROMPTS = {
    "short": "What is the capital of France? Answer in one short sentence.",
    "medium": "Compare SQLite and Postgres for a small personal app in five short bullet points.",
}


def power_source() -> str:
    try:
        out = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    return "battery" if "Battery Power" in out else "mains power" if "AC Power" in out else "unknown"


async def one_run(client: OllamaClient, model: str, prompt: str) -> dict:
    messages = [{"role": "system", "content": SYSTEM_PROMPT}, {"role": "user", "content": prompt}]
    started = time.monotonic()
    first_any = first_visible = None
    final: dict = {}
    async for event in client.chat(model, messages, keep_alive_seconds=300):
        message = event.get("message") or {}
        now = time.monotonic() - started
        if first_any is None and (message.get("thinking") or message.get("content")):
            first_any = now
        if first_visible is None and message.get("content"):
            first_visible = now
        if event.get("done"):
            final = event
    total = time.monotonic() - started
    eval_count = int(final.get("eval_count") or 0)
    eval_seconds = (final.get("eval_duration") or 0) / 1e9
    return {
        "first_any": first_any or total,
        "first_visible": first_visible or total,
        "total": total,
        "load": (final.get("load_duration") or 0) / 1e9,
        "tokens": eval_count,
        "tokens_per_second": eval_count / eval_seconds if eval_seconds else 0.0,
    }


async def memory(client: OllamaClient, model: str) -> tuple[float, float]:
    for entry in await client.loaded():
        if entry.get("name") == model or entry.get("model") == model:
            return entry.get("size", 0) / 1e9, entry.get("size_vram", 0) / 1e9
    return 0.0, 0.0


async def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ollama-bin", default=None)
    parser.add_argument("--models", nargs="+", default=["qwen3:4b", "qwen3:8b"])
    parser.add_argument("--warm-runs", type=int, default=3)
    args = parser.parse_args()

    client = OllamaClient(binary=args.ollama_bin)
    await client.ensure_server()
    rows = []
    try:
        for entry in await client.loaded():
            await client.unload(entry.get("name", ""))
        for model in args.models:
            cold = await one_run(client, model, PROMPTS["short"])
            size, on_gpu = await memory(client, model)
            warm = [await one_run(client, model, PROMPTS["short"]) for _ in range(args.warm_runs)]
            medium = await one_run(client, model, PROMPTS["medium"])
            rows.append((model, cold, warm, medium, size, on_gpu))
            await client.unload(model)
    finally:
        version = await client.version()
        await client.stop_server()

    def mean(values):
        return sum(values) / len(values)

    print(f"Machine: {platform.machine()}, macOS {platform.mac_ver()[0]}. Ollama {version}. Power: {power_source()}.")
    print(f"Context limit 8192 tokens. Warm figures are the mean of {args.warm_runs} runs.\n")
    print("| Model | Memory while loaded | Load from cold | Cold: first visible word | Warm: first visible word | Warm: whole short answer | Medium answer | Speed |")
    print("|---|---|---|---|---|---|---|---|")
    for model, cold, warm, medium, size, on_gpu in rows:
        print(
            f"| `{model}` | {size:.1f} GB ({on_gpu:.1f} GB on GPU) | {cold['load']:.1f} s | {cold['first_visible']:.1f} s "
            f"| {mean([w['first_visible'] for w in warm]):.1f} s | {mean([w['total'] for w in warm]):.1f} s "
            f"| {medium['total']:.1f} s ({medium['tokens']} tokens) | {mean([w['tokens_per_second'] for w in warm]):.0f} tokens/s |"
        )
    print("\nReasoning before the answer (warm, short question):\n")
    print("| Model | First reasoning token | First visible word | Tokens generated in total |")
    print("|---|---|---|---|")
    for model, cold, warm, medium, size, on_gpu in rows:
        print(
            f"| `{model}` | {mean([w['first_any'] for w in warm]):.2f} s | {mean([w['first_visible'] for w in warm]):.1f} s "
            f"| {mean([w['tokens'] for w in warm]):.0f} |"
        )
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
