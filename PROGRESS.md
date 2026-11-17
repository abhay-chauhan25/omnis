# OMNIS — Progress

Last updated: 2026-11-16

## Current stage

**Stage 1 — Local models behind the popup.** Approved 2026-11-16 (`docs/stages/stage-1.md`).

Stage 0 (discovery and architecture) closed on 2026-11-16 with ADR-0001 to ADR-0006. Stage 2 must not start until it has been discussed with the user.

Stage 0 checklist:

- [x] 0a Housekeeping: agent roster, README, `.gitignore`, this file, Git rules in `CLAUDE.md`
- [x] 0b Round 1: product scope and MVP (ADR-0001)
- [x] 0b Round 2: popup co-design (ADR-0002)
- [x] 0b Round 3: app structure and connection (ADR-0003). Local runtime is deferred to Stage 1 benchmarks.
- [x] 0b Round 4: permissions, memory, Claude and battery (ADR-0004, ADR-0005, ADR-0006)
- [x] Decision records written and accepted
- [x] Thin-slice plan approved (`docs/stages/thin-slice.md`)

## Thin slice

Built, tested and accepted by the user on 2026-11-16. Visual refinements are deferred to a later UI pass.

- [x] Popup, hotkey, Dock and menu-bar presence
- [x] Rule-based router, registry, launcher, audit log
- [x] Python service started on demand over pipes, mock answers
- [x] 52 Swift tests and 26 Python tests passing
- [x] Independent review (two passes), findings fixed
- [x] User check: accepted
- [ ] Decision: may Enter on a partial match run a launcher script? Unchanged until the user chooses.

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
| 2026-11-16 | Thin slice approved, with a Dock icon as well as a menu-bar icon. Launcher sees `/Applications`, `/System/Applications`, `~/projects` and listed launchers. Runtime files live in `~/Library/Application Support/OMNIS/`. No sandbox. | `docs/stages/thin-slice.md` |
| 2026-11-16 | Permission tiers: read and launch freely; preview and confirm local changes; confirm every outside effect; destructive actions blocked. | ADR-0004 |
| 2026-11-16 | Facts are remembered only after review; conversations kept locally for 30 days. | ADR-0005 |
| 2026-11-16 | Claude: local-only default, per-file upload confirmation, 1 USD per request and 20 USD per month, no silent fallback. Local models allowed on battery. | ADR-0006 |
| 2026-11-16 | Stage 1 approved: Ollama, `qwen3:4b` and `qwen3:8b`, loopback only, 5 minute unload. | `docs/stages/stage-1.md` |
| 2026-11-16 | Stage 2 waits for a conversation with the user. | — |
| 2026-11-16 | The macOS Control+Space input-source shortcut was turned off by the user, freeing the hotkey. | ADR-0002 |

The stack, models, UI, memory design and integrations are not decided yet. `CLAUDE.md` §3–§8 is still a proposal.

## Completed

- 2026-11-16: Read all project docs and agent definitions; checked the local environment.
- 2026-11-16: Stage 0a housekeeping.
- 2026-11-16: Round 1 decisions recorded in ADR-0001.
- 2026-11-16: Round 2 popup decisions recorded in ADR-0002.
- 2026-11-16: Round 3 structure and connection recorded in ADR-0003.
- 2026-11-16: Thin slice implemented, reviewed and fixed.

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

1. Whether two local models earn their keep over one (Stage 1 benchmarks).
2. Graphify evaluation (needs the link; Stage 4).
3. Exact Claude model IDs (when live use is approved).
4. Main-window design (before Stage 2).

## Questions waiting on the user

- Main-window design choices for Stage 2.
- Whether Enter on a partial match may run a launcher script.
- Icon design for the Dock and menu bar (placeholders are in use).
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
- Ollama 0.40.16 installed with Homebrew on 2026-11-16. It is started on demand, not at login.
- Missing: GitHub `gh` CLI. Needs approval before install.
- Verification Agent is pinned to Sonnet; the other agents inherit the session model. Revisit for the security-heavy stages.

## Next step

Build Stage 1. Then discuss the main-window design with the user before any Stage 2 work.
