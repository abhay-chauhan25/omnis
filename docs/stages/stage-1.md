# Stage 1 — Local models behind the popup

## Approval checkpoint (before work)

**Status: APPROVED by the user on 2026-11-16**

### Goal and user-visible result

The "Ask OMNIS" row gives a real answer from a model running on this Mac, streamed into the popup, with a label showing which model answered. A measured report says how fast each model is and what it costs in memory.

### Proposed approach

- **Runtime: Ollama.** The Python service talks to it over the local loopback address only.
- **Models:** `qwen3:4b` (about 2.5 GB download) for light requests and `qwen3:8b` (about 5.2 GB) for moderate ones. Both are text-only. Licence to be confirmed on the official model page before download.
- **Adapters:** one small interface with three implementations: Ollama, a mock, and a mock Claude that replays recorded fixtures. Swapping the runtime later means writing one new adapter.
- **Router, first version:** a manual choice (`local`, `auto`, `Claude`) plus simple rules for `auto`. A request routed to Claude gets the mock and says so. No silent fallback to a weaker model.
- **Lifecycle:** one model loaded at a time, unloaded after 5 idle minutes (configurable), one request at a time, cancel supported, and a time limit on stalled answers.
- **Cost log:** every request records route, model, latency and token counts. Mock Claude records a calculated cost of zero.

### Alternatives

| Option | For | Against |
|---|---|---|
| Ollama (recommended) | One install, simple model management, built-in unload timer, uses Apple's MLX engine on Apple Silicon in current releases | A small helper process stays running; one report says its MLX path needs 32 GB, which must be checked on this 24 GB Mac |
| MLX directly (`mlx-lm`) | No helper process, runs inside the Python service | A Python dependency, manual model management, we write the unload logic |
| llama.cpp | Most control | Most work, least convenience |

### Needs explicit approval

- Installing Ollama.
- Downloading the two models (about 7.7 GB together).
- Loopback-only network use between the Python service and Ollama.

### Privacy, permissions, RAM, battery, cost

- Nothing leaves the Mac. No API cost.
- Memory while a model is loaded, load time after idle, speed, and the difference on battery are measured and reported, not promised.

### Tests and acceptance criteria

- Adapter tests against a fake Ollama server; router tests for every route and override; unload timer; cancel; time limit; no silent fallback.
- A live test with the real models, run on request.
- A benchmark report: cold and warm time to first word, words per second, memory for each model, on power and on battery.
- Independent review by the Verification Agent.

### Decisions awaiting user approval

1. Ollama as the first runtime.
2. Install Ollama and download both models.
3. The 5 minute unload timer as the starting value.

## Implementation log

### Changes made

- `backend/omnis_backend/router.py`: rule-based choice between the light model, the moderate model and Claude.
- `backend/omnis_backend/ollama.py`: a standard-library client for an Ollama server on this machine only. Starts the server on demand and stops it only if it started it.
- `backend/omnis_backend/engine.py`: one request at a time, one model in memory at a time, time limits, and the Claude stand-in.
- `backend/omnis_backend/models.py`, `service.py`, `protocol.py`, `__main__.py`: answer details (model, route, reason, token counts, timings, cost) travel with each finished answer.
- `backend/scripts/benchmark.py` and `docs/benchmarks/stage-1-local-models.md`.
- `macos/Sources/OmnisCore/AnswerFormatter.swift`: formats model text and removes links. Also splits a typed `local:` or `claude:` prefix.
- `macos/Sources/OmnisCore/BackendProtocol.swift`, `BackendService.swift`; `macos/Sources/OmnisApp/PopupModel.swift`, `PopupView.swift`, `AppEnvironment.swift`; `macos/scripts/bundle.sh`.
- Installed: Ollama 0.40.16 (Homebrew), `qwen3:4b` and `qwen3:8b` (7.2 GB on disk, Apache 2.0).

### Tests executed and results

- Python: 60 tests, all passing. They use a fake model server, so they need no model.
- Swift: 56 tests, all passing, plus one live test that is skipped unless asked for.
- Live test (`OMNIS_LIVE_TESTS=1 swift test --filter live`): passed. A real question went from Swift through the Python service to `qwen3:4b` and back, a Claude request got the labelled stand-in at zero cost, and a typed `local` route kept a Claude-sounding request on this Mac.
- Benchmark: see `docs/benchmarks/stage-1-local-models.md`. Measured on battery only.
- After every run, no model server or backend process was left running.
- Independent review, twice. Both passes: pass with warnings. Findings and actions are below. The changes made after the second pass are covered by tests but were not reviewed a third time.

### Review findings

| Finding | Action |
|---|---|
| Links written by a model were clickable in the popup, including `file:` links | Fixed. Every link is reduced to plain text. Tested with 26 link forms by the reviewer. |
| An answer cut off mid-stream looked like a normal finish | Fixed. It is reported as incomplete. |
| A model server that accepts a connection and never replies caused a wait with no limit | Fixed. Quick calls have a 10 second limit, and a whole answer has a 10 minute limit. |
| Everyday questions containing "paper", "pdf", "algorithm" or "proof" were sent to the Claude stand-in | Changed. See the first deviation below. |
| "Ask Claude How ..." was no longer recognised after a first fix | Fixed. Asking for Claude by name works in any capitalisation, except before a short list of surnames. |
| Wrongly typed numbers from the model server gave an opaque error | Fixed. They are read as zero. |
| The app had no way to choose `local` or `claude` | Added a typed prefix. See deviations. |
| A model that reasons and then gives no answer showed a blank | Fixed. It is reported as an error. |
| A failed unload could leave a model in memory until its timer ran out | Fixed. Every model used is unloaded again at exit. |

### Deviations and why

- **Claude is chosen only when asked for.** The plan had "simple rules for `auto`" that could pick Claude by topic. Word matching sent too many ordinary questions there, and ADR-0006 makes local-only the default. Now a hard-looking topic goes to the larger local model and the log notes that Claude was a candidate. Automatic cloud routing is left to Stage 6, where it can be measured against real requests.
- **Typed prefixes `local:` and `claude:`** were added so the manual override is usable from the popup. There is no visible control for it yet; that is a UI decision for later.
- **Reasoning cannot be switched off** for this build of Qwen3, so it is requested separately and discarded. It accounts for most of the wait on short answers.
- **The unload timer is Ollama's own.** OMNIS passes the 5 minute value with each request. The Python service also exits after 5 idle minutes and stops the model server it started, which frees the memory either way. The timer itself was not waited out in a test.
- **Answer text shows light Markdown** (bold, italics, inline code). Lists and headings appear as typed.

### Known limits

- If the Python service is killed outright (not quit normally), the model server it started keeps running until its 5 minute timer unloads the model. A normal quit, idle exit, or crash of the app does not leave it behind.
- If you already run your own Ollama server, OMNIS uses it, never stops it, and applies its own 5 minute keep-alive to the two Qwen3 models.
- A cancelled answer is not logged with its model name.
- Conversations are single questions. There is no follow-up context yet.
- Mains-power figures and energy use were not measured.

## Teaching handoff

1. **What was built.** The "Ask OMNIS" row now gets a real answer from a model on this Mac, streamed into the popup with a line saying which model answered and how long it took.
2. **Why this approach.** Ollama gives model download, loading and unloading for one install. Hiding it behind a small client and an engine means the runtime can be swapped without touching the popup. Starting it on demand keeps the idle cost at zero.
3. **How it works.**
   - Popup → `BackendService.ask(text, route)` → one JSON line to the Python service.
   - `router.decide` picks light, moderate or Claude and gives a reason in words.
   - `LocalEngine` makes sure the model server is up, unloads the other model if one is loaded, and streams the reply from `OllamaClient.chat`.
   - Reasoning pieces are dropped; answer pieces go back as `answer_chunk` lines.
   - `answer_done` carries model, route, reason, token counts, timings and cost. Swift shows the source line and writes those numbers to `audit.log`. The question and the answer are never written anywhere.
4. **How to run and test it.** Rebuild with `macos/scripts/bundle.sh`, open the app, press Control+Space and ask something. Try `claude: hello` and `local: use claude to say hi`. Run the benchmark with `cd backend && python3 scripts/benchmark.py --ollama-bin "$(command -v ollama)"`.
5. **What was verified.** See "Tests executed". Not verified by me: how answers look in the popup.
6. **Security, memory, battery, cost.** Loopback only, no API cost. 3.8 GB or 6.2 GB while a model is loaded, nothing when idle. Model output cannot produce a clickable link or trigger any action.
7. **Try next.** Ask the same question with and without `local:` on a hard topic and compare. Watch Activity Monitor for `ollama` appearing on the first question and going away after 5 idle minutes.
8. **Decisions needed.** Whether to keep two local models or one. Then the main-window design conversation before any Stage 2 work.
