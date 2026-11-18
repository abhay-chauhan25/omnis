# OMNIS — Progress

Last updated: 2026-11-17

## Where things stand

OMNIS is a working chat window on the Mac. It launches apps and projects, answers questions with a model on this Mac, searches the web when a question needs it, and has a lane for Claude that stays off until a key and credit exist.

| Piece | State | Record |
|---|---|---|
| Stage 0: discovery and architecture | Closed 2026-11-16 | ADR-0001 to ADR-0006 |
| Thin slice: launcher and backend connection | Accepted by the user 2026-11-16 | `docs/stages/thin-slice.md` |
| Stage 1: local models | Built 2026-11-16; models since replaced | `docs/stages/stage-1.md` |
| Web search | Built and reviewed 2026-11-17 | ADR-0008 |
| Local model `gemma4:12b` | Chosen by measurement 2026-11-17 | ADR-0007, `docs/benchmarks/model-bake-off.md` |
| Chat window with conversation memory | Built and reviewed 2026-11-17; user testing in progress | ADR-0010 |
| Claude lane | Built against a stand-in 2026-11-17; never run live | ADR-0009 |
| Stage 2: main window | Not started. Waits for a design conversation | — |

The walkthrough for everything built on 2026-11-17 is `docs/stages/stage-1b-search-chat-claude.md`.

## Tests

- Python: 100. Swift: 115. Three more live tests use the real model and real search when asked for.
- Independent review after each piece; findings and what was done about them are listed in the stage documents.

## Open items

- [ ] User's hands-on check of the chat window (look, feel, dragging, sources, launch strip).
- [ ] Verify API credit in the Anthropic Console (expected around 2026-11-23).
- [ ] Approval to install the `anthropic` package, then a first live Claude call.
- [ ] Check Claude prices against the live price list before going live (the built-in ones are dated 2026-11-03).
- [ ] Test the local model on personal-data tasks (email summaries, replies, calendar events) before trusting it with them.
- [ ] Read the licence for `gemma4:12b`.
- [ ] Icon design for the Dock and menu bar (placeholders are in use).
- [ ] The exact Graphify repo or link (needed for the memory stage).

## Decisions waiting on the user

1. What to build next: image and PDF input in the chat window, the main window (Stage 2), or the first personal-data integration.
2. Whether OMNIS should ask "keep this local?" when typed text looks personal, or leave that to the Local control.
3. Whether opening a source should be recorded in the audit log by site name, as it is now.

## Approved decisions

| Date | Decision | Record |
|---|---|---|
| 2026-11-16 | Commits use the existing Git identity; verified work is committed and pushed without asking; 3 to 6 word messages; no co-author or tool attribution. | `CLAUDE.md` §10 |
| 2026-11-16 | Popup first, all surfaces in scope; thin slice first, then the documented stages. | ADR-0001 |
| 2026-11-16 | Control+Space hotkey, native glass, subtle motion. | ADR-0002 |
| 2026-11-16 | Swift core plus an on-demand Python service that proposes and never executes; child process over pipes. | ADR-0003 |
| 2026-11-16 | Permission tiers: read and launch freely; preview and confirm local changes; confirm every outside effect; destructive actions blocked. | ADR-0004 |
| 2026-11-16 | Facts are remembered only after review; conversations kept locally for 30 days once storage exists. | ADR-0005 |
| 2026-11-16 | Claude limits: 1 USD per request, 20 USD per month, warnings at 50% and 80%. Local models may run on battery. | ADR-0006 |
| 2026-11-16 | Personal use only. Dock icon and menu-bar icon. Runtime files in `~/Library/Application Support/OMNIS/`. No sandbox. | `docs/stages/thin-slice.md` |
| 2026-11-17 | One local model, `gemma4:12b`, reasoning off. The six other models were deleted. | ADR-0007 |
| 2026-11-17 | Web search through SearXNG in Docker, started on demand; the model decides when; sources clickable; also used for the Claude lane. | ADR-0008 |
| 2026-11-17 | Route by data: personal stays local, public questions go to Claude; OMNIS picks the Claude model; with no key or no credit, answer locally and say so. | ADR-0009 |
| 2026-11-17 | The popup becomes a movable, persistent chat window with session memory. | ADR-0010 |
| 2026-11-17 | Nothing about the architecture is settled; better approaches are to be raised and discussed. | `CLAUDE.md` §0 rule 8 |
| 2026-11-17 | Commit and push as work is completed, without waiting to be told. | — |

## Things worth knowing

- **Accuracy:** on current-events questions the local model was right 20 to 23 times in 26 across four runs. Its mistakes are mostly about dates.
- **Search engines throttle bursts.** Heavy testing got this network refused by three engines for some hours. More engines are now switched on and tests pause between searches.
- **Memory:** 7.7 GB while the model is loaded; nothing when idle.
- **The real Claude connection is untested.** It is written from the library's documentation and has never run.
- **Ghidra** is launched by a script, registered in `registry.json`; "voyager" is an alias for the `VoyagerAI` project.

## Environment (checked 2026-11-17)

- Apple M4 Pro, 24 GB RAM, about 467 GB free, macOS 26.5.1.
- Xcode 26.6, Python 3.13, Docker Desktop, Homebrew, VS Code `code` command.
- Ollama 0.40.16 (Homebrew), started on demand. Model on disk: `gemma4:12b` (7.7 GB).
- Docker image `searxng/searxng:latest`, started on demand.
- Not installed: the `anthropic` Python package, the GitHub `gh` CLI. Each needs approval.
- The Verification Agent is pinned to Sonnet; the other agents inherit the session model.

## Next step

The user tests the chat window. Then the choice of what to build next.
