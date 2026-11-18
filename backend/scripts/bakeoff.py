"""Compares local models on the things OMNIS needs. Prints progress and
writes a JSON file of everything measured.

    cd backend && python3 scripts/bakeoff.py --ollama-bin "$(command -v ollama)" \\
        --images DIR --out results.json MODEL [MODEL ...]

Needs the SearXNG container running on 127.0.0.1:18888 for the search tests.
Nothing but search terms leaves this machine.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import pathlib
import sys
import time
import urllib.parse
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from omnis_backend.engine import (  # noqa: E402
    DATE_PROMPT,
    MAX_SEARCHES,
    SYSTEM_PROMPT,
    WEB_PROMPT,
    WEB_SEARCH_TOOL,
    _results_for_model,
    _search_query,
)
from omnis_backend.ollama import OllamaClient, OllamaError  # noqa: E402

# (question, should it search?)
EVERYDAY = [
    ("What is the capital of France? Answer in one short sentence.", False),
    ("hi", False),
    ("define entropy in one sentence", False),
    ("what is 12 times 12", False),
    ("who wrote Pride and Prejudice", False),
    ("how many days are in a leap year", False),
    ("what is the weather in Atlanta today", True),
    ("what is the latest version of macOS", True),
    ("what are the benefits of the claude max plan", True),
    ("who won the most recent formula 1 race", True),
]

# Seconds to wait after each web search. A burst of searches gets the whole
# network refused by the search engines for a while; this keeps tests polite.
SEARCH_PAUSE = 6.0

IMAGES = [
    ("chart.html.png", "Which quarter had the highest revenue, what was that value, and what is the total for the whole year?",
     ["q4", "77", "206"]),
    ("table.html.png", "Which step failed, how long did it take, and what was the error message?",
     ["integration", "131", "5432"]),
]


def web_search(query: str) -> dict:
    url = "http://127.0.0.1:18888/search?" + urllib.parse.urlencode({"q": query, "format": "json"})
    try:
        data = json.load(urllib.request.urlopen(url, timeout=25))
    except Exception as exc:  # the model is told the search failed, as in the app
        return {"ok": False, "results": [], "error": type(exc).__name__}
    results = [
        {"title": r.get("title", ""), "url": r.get("url", ""), "snippet": r.get("content") or ""}
        for r in data.get("results", [])[:6]
    ]
    return {"ok": bool(results), "results": results, "error": ""}


async def one_turn(client, model, messages, tools, think):
    started = time.monotonic()
    text, thinking, calls, first_visible, final = "", 0, [], None, {}
    async for event in client.chat(model, messages, keep_alive_seconds=600, tools=tools, think=think):
        message = event.get("message") or {}
        if message.get("thinking"):
            thinking += len(message["thinking"])
        if message.get("content"):
            first_visible = first_visible or time.monotonic() - started
            text += message["content"]
        if message.get("tool_calls"):
            calls += message["tool_calls"]
        if event.get("done"):
            final = event
    return {
        "text": text, "thinking_chars": thinking, "calls": calls,
        "first_visible": first_visible, "seconds": time.monotonic() - started,
        "out_tokens": int(final.get("eval_count") or 0),
        "tokens_per_second": (final.get("eval_count") or 0) / ((final.get("eval_duration") or 0) / 1e9 or 1e9),
    }


async def answer(client, model, question, web, think, today):
    """The same loop the app runs: offer the tool, search if asked, answer."""
    system = SYSTEM_PROMPT + DATE_PROMPT.format(today=today) + (WEB_PROMPT if web else "")
    messages = [{"role": "system", "content": system}, {"role": "user", "content": question}]
    started = time.monotonic()
    searches, queries, out_tokens, thinking, text, first_visible = 0, [], 0, 0, "", None
    paused = 0.0  # time spent waiting politely, not counted in the answer time
    while True:
        tools = [WEB_SEARCH_TOOL] if web and searches < MAX_SEARCHES else None
        turn = await one_turn(client, model, messages, tools, think)
        out_tokens += turn["out_tokens"]
        thinking += turn["thinking_chars"]
        text += turn["text"]
        if turn["first_visible"] is not None and first_visible is None:
            first_visible = time.monotonic() - started - turn["seconds"] + turn["first_visible"]
        found = _search_query(turn["calls"]) if tools else None
        if found is None:
            break
        query = found[0]
        searches += 1
        queries.append(query)
        outcome = await asyncio.to_thread(web_search, query)
        await asyncio.sleep(SEARCH_PAUSE)
        paused += SEARCH_PAUSE
        messages.append({"role": "assistant", "content": turn["text"], "tool_calls": turn["calls"][:1]})
        messages.append({"role": "tool", "tool_name": "web_search", "content": _results_for_model(query, outcome, today)})
    return {
        "seconds": round(time.monotonic() - started - paused, 1), "first_visible": first_visible and round(first_visible, 1),
        "searches": searches, "queries": queries, "out_tokens": out_tokens,
        "thinking_chars": thinking, "text": text.strip(),
    }


async def find_thinking_mode(client, model):
    """Can this model answer without reasoning first? Returns (mode, note)."""
    messages = [{"role": "user", "content": "What is the capital of France? Answer in one short sentence."}]
    for mode in (False, None, True):
        try:
            turn = await one_turn(client, model, messages, None, mode)
        except OllamaError as exc:
            note = exc.message
            continue
        clean = "paris" in turn["text"].lower() and len(turn["text"]) < 200 and "</think>" not in turn["text"]
        if mode is True:
            return True, f"reasons before answering ({turn['thinking_chars']} characters of reasoning)"
        if clean and turn["thinking_chars"] == 0:
            return mode, "answers without reasoning" + ("" if mode is False else " (does not take the setting at all)")
        note = "reasoning could not be switched off cleanly"
    return True, note


async def bake(client, model, image_dir, today):
    record = {"model": model}
    print(f"\n===== {model}", flush=True)
    for entry in await client.loaded():
        await client.unload(entry.get("name", ""))

    started = time.monotonic()
    think, note = await find_thinking_mode(client, model)
    record["load_and_probe_seconds"] = round(time.monotonic() - started, 1)
    record["thinking"] = note
    record["think_setting"] = think
    loaded = [e for e in await client.loaded() if e.get("name") == model or e.get("model") == model]
    record["memory_gb"] = round(loaded[0].get("size", 0) / 1e9, 1) if loaded else None
    print(f"  thinking: {note}; memory {record['memory_gb']} GB", flush=True)

    rows = []
    for question, should_search in EVERYDAY:
        try:
            with_tool = await answer(client, model, question, True, think, today)
            without = await answer(client, model, question, False, think, today)
        except OllamaError as exc:
            rows.append({"question": question, "error": exc.message})
            print(f"  ERROR {question[:40]}: {exc.message}", flush=True)
            continue
        rows.append({"question": question, "should_search": should_search, "with_tool": with_tool, "without": without})
        print(f"  {question[:44]:44} tool {with_tool['seconds']:5.1f}s ({with_tool['searches']} search) | "
              f"no tool {without['seconds']:5.1f}s", flush=True)
    record["everyday"] = rows

    images = []
    for name, question, expected in IMAGES:
        data = base64.b64encode((image_dir / name).read_bytes()).decode()
        messages = [{"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": question, "images": [data]}]
        try:
            turn = await one_turn(client, model, messages, None, think)
            found = [item for item in expected if item in turn["text"].lower().replace(",", "")]
            images.append({"image": name, "seconds": round(turn["seconds"], 1), "text": turn["text"].strip(),
                           "expected": expected, "found": found})
            print(f"  image {name}: {len(found)}/{len(expected)} facts in {turn['seconds']:.1f}s", flush=True)
        except OllamaError as exc:
            images.append({"image": name, "error": exc.message})
            print(f"  image {name}: ERROR {exc.message}", flush=True)
    record["images"] = images
    await client.unload(model)
    return record


async def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("models", nargs="+")
    parser.add_argument("--ollama-bin", default=None)
    parser.add_argument("--images", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--pause", type=float, default=6.0,
                        help="seconds to wait after each web search, so search engines are not flooded")
    args = parser.parse_args()
    import datetime
    today = datetime.date.today().strftime("%d %B %Y")
    global SEARCH_PAUSE
    SEARCH_PAUSE = args.pause

    client = OllamaClient(binary=args.ollama_bin)
    await client.ensure_server()
    results = []
    try:
        for model in args.models:
            try:
                results.append(await bake(client, model, pathlib.Path(args.images), today))
            except Exception as exc:  # one broken model must not lose the others' results
                results.append({"model": model, "fatal": f"{type(exc).__name__}: {exc}"})
                print(f"  FATAL {model}: {type(exc).__name__}: {exc}", flush=True)
            pathlib.Path(args.out).write_text(json.dumps(results, indent=1))
    finally:
        await client.stop_server()
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
