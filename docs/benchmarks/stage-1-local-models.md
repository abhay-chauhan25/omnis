# Stage 1 benchmark — local models

Measured on 2026-11-16 with `backend/scripts/benchmark.py`.

- Machine: Apple M4 Pro, 24 GB RAM, macOS 26.5.1.
- Runtime: Ollama 0.40.16, models in the Q4_K_M format.
- Power: **battery**. Mains power was not measured.
- Context limit: 8192 tokens.
- One run from cold, three warm runs (mean shown), one medium-length request.

## Results

| Model | Memory while loaded | Load from cold | Cold: first visible word | Warm: first visible word | Warm: whole short answer | Medium answer | Speed |
|---|---|---|---|---|---|---|---|
| `qwen3:4b` | 3.8 GB | 1.8 s | 4.1 s | 1.9 s | 2.0 s | 16.2 s (1156 tokens) | 74 tokens/s |
| `qwen3:8b` | 6.2 GB | 3.1 s | 6.8 s | 2.1 s | 2.3 s | 9.8 s (403 tokens) | 42 tokens/s |

Both models ran fully on the GPU.

## Reasoning before the answer

This build of Qwen3 always reasons before it answers. Turning that off through the runtime did not work: the reasoning then appeared inside the answer. OMNIS asks for the reasoning separately and discards it, so only the answer is shown.

| Model | First reasoning token (warm) | First visible word (warm) | Tokens generated for a one-sentence answer |
|---|---|---|---|
| `qwen3:4b` | 0.02 s | 1.9 s | 147 |
| `qwen3:8b` | 0.08 s | 2.1 s | 95 |

Almost all of the wait for a short answer is reasoning, not start-up.

## What this shows

- A short question takes about 2 seconds warm and 4 to 7 seconds from cold on either model.
- The smaller model generates tokens almost twice as fast but reasoned at much greater length on the medium request, so it finished later. That is one run, so it is an observation and not a rule.
- The larger model costs 2.4 GB more memory while loaded.
- When idle, neither model is in memory and the model server is not running.

## What this does not show

- Answer quality. Nothing here says which model gives better answers.
- Mains power, and energy drawn from the battery.
- Behaviour under memory pressure from Docker, browsers and other work.
- Whether a build that can skip reasoning would be faster. If so, short answers could drop well under a second.

## Open question

Whether two local models earn their keep. On speed alone the smaller one is not clearly ahead for real requests. Quality has to be judged on real tasks before deciding.
