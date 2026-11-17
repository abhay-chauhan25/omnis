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

## Implementation log (only after approval)

- Changes made:
- Tests executed and results:
- Deviations and why:

## Teaching handoff (required before next stage)

1. **What** was built:
2. **Why** this approach:
3. **How** it works (files and request/data flow):
4. **How to run and test** it:
5. **What was verified** and what remains unverified:
6. **Security, memory, battery and API cost** observations:
7. **What you should understand / try next:**
8. **Questions and approval needed for the next stage:**
