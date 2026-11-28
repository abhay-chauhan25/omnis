"""Entry point: `python -m omnis_speech --models <folder>`.

One line of JSON in, one or more lines of JSON out.

    {"id": 1, "op": "say", "text": "...", "voice": "am_adam", "speed": 1.0}
        -> {"id": 1, "type": "audio", "rate": 24000, "pcm": "<base64, 16-bit>"}   once a sentence
        -> {"id": 1, "type": "done"}
    {"id": 2, "op": "hear", "rate": 16000, "pcm": "<base64, 16-bit>"}
        -> {"id": 2, "type": "heard", "text": "..."}
    {"op": "warm", "what": "voice"}      loads the voice ahead of the first words
    {"op": "warm", "what": "listener"}   loads the listener ahead of the first check
    {"op": "cancel"}     drops everything asked for so far

Sound is held in memory only while it is being worked on. Nothing is written
to disk and nothing is sent anywhere.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import queue
import sys
import threading
import time
from pathlib import Path

from .text import HEAR_RATE, MAX_HEAR_SECONDS, WAKE_HINT, sentences, speed_or_default, voice_or_default

# The libraries below must never look anything up online.
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

LINE_LIMIT = 4 << 20


class Models:
    """The voice and the listener, each loaded when first needed."""

    def __init__(self, folder: Path, voice_idle_seconds: float) -> None:
        self.folder = folder
        self.voice_idle_seconds = voice_idle_seconds
        self._voice = None
        self._listener = None
        self._voice_used = 0.0

    def voice(self):
        if self._voice is None:
            from kokoro_onnx import Kokoro

            self._voice = Kokoro(str(self.folder / "kokoro-v1.0.onnx"), str(self.folder / "voices-v1.0.bin"))
        self._voice_used = time.monotonic()
        return self._voice

    def listener(self):
        if self._listener is None:
            from faster_whisper import WhisperModel

            self._listener = WhisperModel(str(self.folder / "whisper-base.en"), device="cpu", compute_type="int8",
                                          local_files_only=True)
        return self._listener

    def rest(self) -> None:
        """Lets go of the voice once it has not been used for a while. It is the larger of the two."""
        if self._voice is not None and time.monotonic() - self._voice_used > self.voice_idle_seconds:
            self._voice = None
            import gc

            gc.collect()


def serve(models: Models, source, write) -> int:
    import numpy as np

    jobs: queue.Queue = queue.Queue()
    # Goes up when everything asked for so far is to be dropped.
    wave = [0]

    def read() -> None:
        for raw in source:
            if len(raw) > LINE_LIMIT:
                continue
            try:
                message = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(message, dict):
                continue
            if message.get("op") == "cancel":
                wave[0] += 1
                continue
            jobs.put((wave[0], message))
        jobs.put(None)

    threading.Thread(target=read, daemon=True).start()
    write({"type": "hello", "version": 1})

    while True:
        try:
            job = jobs.get(timeout=30)
        except queue.Empty:
            models.rest()
            continue
        if job is None:
            return 0
        mine, message = job
        # A cancel is about words waiting to be said. A listen is always answered, so nothing waits on it in vain.
        if mine != wave[0] and message.get("op") != "hear":
            continue
        identifier = message.get("id")
        try:
            op = message.get("op")
            if op == "warm":
                if message.get("what") == "listener":
                    models.listener()
                else:
                    models.voice()
            elif op == "say":
                voice = voice_or_default(message.get("voice"))
                speed = speed_or_default(message.get("speed"))
                for sentence in sentences(str(message.get("text", ""))):
                    if mine != wave[0]:
                        break
                    samples, rate = models.voice().create(sentence, voice=voice, speed=speed, lang="en-us")
                    if mine != wave[0]:
                        break
                    pcm = (np.clip(samples, -1.0, 1.0) * 32767.0).astype("<i2").tobytes()
                    write({"id": identifier, "type": "audio", "rate": int(rate), "pcm": base64.b64encode(pcm).decode("ascii")})
                write({"id": identifier, "type": "done"})
            elif op == "hear":
                if message.get("rate") != HEAR_RATE:
                    raise ValueError("sound must be at 16 kHz")
                pcm = base64.b64decode(str(message.get("pcm", "")), validate=True)
                samples = np.frombuffer(pcm[: len(pcm) // 2 * 2], dtype="<i2").astype("float32") / 32768.0
                samples = samples[: HEAR_RATE * MAX_HEAR_SECONDS]
                text = ""
                if len(samples) >= HEAR_RATE // 5:
                    # Told what to expect, the listener will write it for silence or a hum as well. So only
                    # stretches with a voice in them are listened to, and anything it was unsure held
                    # speech is left out.
                    segments, _ = models.listener().transcribe(samples, language="en", initial_prompt=WAKE_HINT, beam_size=5,
                                                               condition_on_previous_text=False, vad_filter=True)
                    text = " ".join(segment.text.strip() for segment in segments
                                    if segment.no_speech_prob < 0.6).strip()
                write({"id": identifier, "type": "heard", "text": text})
            else:
                raise ValueError("unknown request")
        except Exception as error:  # noqa: BLE001 - whatever went wrong is reported, and the helper carries on
            write({"id": identifier, "type": "error", "message": f"{type(error).__name__}: {error}"[:300]})


def main() -> int:
    parser = argparse.ArgumentParser(prog="omnis_speech")
    parser.add_argument("--models", required=True, help="folder holding the voice and the listener")
    parser.add_argument("--voice-idle-seconds", type=float, default=300.0,
                        help="how long the unused voice stays in memory")
    args = parser.parse_args()

    # Replies go out on the real standard output. Anything a library prints goes to standard error instead,
    # so it can never be mistaken for a reply.
    out = os.fdopen(os.dup(1), "wb")
    os.dup2(2, 1)
    lock = threading.Lock()

    def write(message: dict) -> None:
        data = json.dumps(message, separators=(",", ":")).encode() + b"\n"
        with lock:
            out.write(data)
            out.flush()

    try:
        return serve(Models(Path(args.models), args.voice_idle_seconds), sys.stdin.buffer, write)
    except (BrokenPipeError, KeyboardInterrupt):
        return 0


if __name__ == "__main__":
    sys.exit(main())
