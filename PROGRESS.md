# OMNIS — Progress

Last updated: 2026-11-16

## Current stage

**Stage 0 — Discovery and architecture.** Approved 2026-11-16. No product code, no installs, no API use.

- [x] 0a Housekeeping: agent roster, README, `.gitignore`, this file, Git rules in `CLAUDE.md`
- [x] 0b Round 1: product scope and MVP (ADR-0001)
- [x] 0b Round 2: popup co-design (ADR-0002)
- [x] 0b Round 3: app structure and connection (ADR-0003). Local runtime is deferred to Stage 1 benchmarks.
- [ ] 0b Round 4: security, memory, cost
- [ ] Decision records written and accepted
- [ ] Thin-slice plan approved

## Build order (ADR-0001)

1. Stage 0: discovery and architecture.
2. Thin slice: popup → rule-based router → app and project registry → launch. No AI model.
3. Stages 1–7 from `CLAUDE.md` §9, each done properly with its own approval.

## Approved decisions

| Date | Decision | Record |
|---|---|---|
| 2026-11-16 | Begin Stage 0 as a planning-only stage. | — |
| 2026-11-16 | Commits use the existing Git identity (Abhay Chauhan, GitHub noreply email). | `CLAUDE.md` §10 |
| 2026-11-16 | Verified work is committed and pushed to `origin/main` without asking each time. Messages are 3–6 words, with no co-author or tool attribution. | `CLAUDE.md` §10 |
| 2026-11-16 | Agent roster: architecture-planner, macos-ux, local-inference, memory-graph, integrations-security, verification-agent. The main session builds and coordinates. | `CLAUDE.md` |
| 2026-11-16 | Popup is the first surface. Main app, notch overlay and the other surfaces stay in scope. | ADR-0001 |
| 2026-11-16 | Thin slice first, then the documented stages. | ADR-0001 |
| 2026-11-16 | Claude stays mocked. Credits are expected around 2026-11-23; verify in the Anthropic Console and get explicit approval before any live call. | — |
| 2026-11-16 | Personal use only. No public distribution planned. | — |
| 2026-11-16 | Full Xcode will be installed by the user when the build needs it. Done: Xcode 26.6 is installed. | — |
| 2026-11-16 | Popup: centre bar, Control+Space, launcher style, closes after a launch, native glass, subtle motion. | ADR-0002 |
| 2026-11-16 | "Voyager" means the `VoyagerAI` project. | — |
| 2026-11-16 | Ghidra is launched by running `~/Research/EmbeddedCybersecVIP/ghidra_12.1.3_PUBLIC/ghidraRun`. | — |
| 2026-11-16 | Structure: Swift core plus an on-demand Python service that proposes but never executes. | ADR-0003 |
| 2026-11-16 | Connection: Python runs as a child process, JSON messages over pipes, no network port. | ADR-0003 |
| 2026-11-16 | The finished popup must answer questions and show the answers in the popup. | ADR-0003 |
| 2026-11-16 | The macOS Control+Space input-source shortcut was turned off by the user, freeing the hotkey. | ADR-0002 |

The stack, models, UI, memory design and integrations are not decided yet. `CLAUDE.md` §3–§8 is still a proposal.

## Completed

- 2026-11-16: Read all project docs and agent definitions; checked the local environment.
- 2026-11-16: Stage 0a housekeeping.
- 2026-11-16: Round 1 decisions recorded in ADR-0001.
- 2026-11-16: Round 2 popup decisions recorded in ADR-0002.
- 2026-11-16: Round 3 structure and connection recorded in ADR-0003.

## First commands to support

Given by the user as everyday commands:

- "open Ghidra"
- "open ChatGPT Classic app"
- "open Voyager project in VS Code"

What they showed when checked against this Mac:

- `ChatGPT Classic.app` is a normal app in `/Applications`. The spoken name has an extra word ("app"), so matching cannot be exact.
- Ghidra is not installed as an app bundle and is not on the shell path. Launching it needs a registered custom launcher, so the registry must hold more than app names.
- `~/projects` has both `VoyagerAI` and `Voyagers`. "Voyager" is ambiguous, so the router needs a rule for near matches: ask once, then remember an alias.

## Open decisions

2. Stack: Swift app plus Python service, all-Swift, or a web-tech shell (Round 3).
3. App-to-backend connection and process lifecycle (Round 3).
4. Local runtime: Ollama, MLX, or llama.cpp; one local model or two (Round 3, benchmarked in Stage 1).
5. Permission model: what needs per-action confirmation and what gets scoped standing approval (Round 4).
6. Memory: what is saved automatically versus after review; Graphify evaluation (Round 4).
7. Claude: budgets, which data may be uploaded, exact model IDs (Round 4).

## Questions waiting on the user

- Approval of the thin-slice plan.
- The exact Graphify repo or link (needed by Round 4).

## Requirements not yet covered by the docs

- What "multimodal" means in v1. The base Qwen3 4B/8B models are believed to be text-only; to be verified.
- What handing off to Claude Code or a chat app concretely does.
- Whether conversation history is kept.
- Launch at login.
- Editors other than VS Code.
- A set of real tasks to evaluate routing against.

## Environment notes (checked 2026-11-16)

- Apple M4 Pro, 24 GB RAM, about 507 GB free, macOS 26.5.1.
- Present: Git, Python 3.13, uv, VS Code `code` command, Docker, Homebrew, Node.
- Xcode 26.6 installed and selected.
- Missing: Ollama, GitHub `gh` CLI. Each needs approval before install.
- Verification Agent is pinned to Sonnet; the other agents inherit the session model. Revisit for the security-heavy stages.

## Next step

Thin-slice plan for approval. Round 4 (security, memory, cost) follows the slice.
