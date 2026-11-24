# OMNIS — Progress

Last updated: 2026-11-24

## Where things stand

OMNIS is a working chat window on the Mac. It launches apps and projects, answers questions with Claude by default (through Claude Code on the user's own plan) or with a model on this Mac when switched off the grid, searches the web, and reads and changes the calendar with a confirmation for every change.

| Piece | State | Record |
|---|---|---|
| Stage 0: discovery and architecture | Closed 2026-11-16 | ADR-0001 to ADR-0006 |
| Thin slice: launcher and backend connection | Accepted by the user 2026-11-16 | `docs/stages/thin-slice.md` |
| Stage 1: local models | Built 2026-11-16; models since replaced | `docs/stages/stage-1.md` |
| Web search | Built and reviewed 2026-11-17 | ADR-0008 |
| Local model `gemma4:12b` | Chosen by measurement 2026-11-17 | ADR-0007, `docs/benchmarks/model-bake-off.md` |
| Chat window with conversation memory | Built and reviewed 2026-11-17; user testing in progress | ADR-0010 |
| Claude lane | Built against a stand-in and reviewed 2026-11-17; review findings fixed, fixes not yet re-reviewed; never run live | ADR-0009 |
| Image and file attachments | Built and reviewed 2026-11-17; review findings fixed; user testing in progress | `docs/stages/attachments.md` |
| Calendar, reading | Built and reviewed 2026-11-17; review findings fixed, fixes not re-reviewed; waiting for the user's test with the real calendar | ADR-0011, `docs/stages/calendar-read.md` |
| Calendar, creating events | Built and reviewed 2026-11-17; review findings fixed, fixes not re-reviewed; waiting for the user's test and first real save | `docs/stages/calendar-events.md` |
| Calendar, full control (change, delete, calendars) | Built and reviewed 2026-11-17; review findings fixed, fixes not re-reviewed; no real change made yet; waiting for the user's test | ADR-0012, `docs/stages/calendar-full-control.md` |
| Claude as the default (regular mode) | Built, tested live and reviewed 2026-11-23; review findings fixed, fixes not re-reviewed; controls not yet seen on screen | ADR-0013, `docs/stages/claude-regular-mode.md` |
| Project mode (setup, terminals, advisor, following along) | All stages built 2026-11-24; core tested, advisor tested live; reviewed, findings fixed; the view not yet seen on screen and no real project set up | ADR-0014, `docs/stages/project-mode.md` |
| Services: Reminders, GitHub (read), Spotify | Built 2026-11-24; tested with stand-ins and live through Claude; reviewed, findings fixed; not yet run against the real Reminders or Spotify | `docs/stages/services.md` |
| Services: Gmail, Messages, browser | Not started. Each needs a decision from the user | — |
| Dashboard (main window) | First version built 2026-11-23 from the approved mock; waiting for the user's look; review pending. Voice and mail not built | `docs/stages/dashboard.md` |

The walkthrough for everything built on 2026-11-17 is `docs/stages/stage-1b-search-chat-claude.md`.

## Tests

- Python: 154. Swift: 251. Eight more live tests use the real model, real search, a real picture and a made-up calendar when asked for.
- Independent review after each piece; findings and what was done about them are listed in the stage documents.

## Open items

- [ ] User's hands-on check of the chat window (look, feel, dragging, sources, launch strip).
- [ ] User's test of calendar questions against the real calendar (needs the macOS permission prompt).
- [ ] User's test of adding events, including the first real save and an all-day event.
- [ ] User's feedback on the look of the event preview card.
- [ ] User's test of changing and deleting in a throwaway calendar (steps in `docs/stages/calendar-full-control.md`).
- [ ] User's look at the Model and Effort sliders, usage reading and typed commands.
- [ ] Remove the retired API-key lane from the code.
- [ ] User's look at the dashboard on screen.
- [ ] User's first run of project mode: open a terminal session, try the advisor, set up one real project.
- [ ] Voice ("Hey OMNIS"): the user will decide separately. Not built.
- [ ] Test the local model on personal-data tasks (email summaries, replies, calendar events) before trusting it with them.
- [ ] Read the licence for `gemma4:12b`.
- [ ] The exact Graphify repo or link (needed for the memory stage).

## Decisions waiting on the user

1. In a chat that holds a file or the calendar, whether to allow web searches built only from the words the user typed.
2. Whether OMNIS should ask "keep this local?" when typed text looks personal, or leave that to the Local control.
3. Whether opening a source should be recorded in the audit log by site name, as it is now.
4. Whether an answer given locally because Claude was unavailable should keep that chat local afterwards.

5. Whether a new event preview should withdraw an unrelated one still waiting, as it does now.

6. Whether calendar changes should ever happen without the confirmation click. Built with confirmation.

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
| 2026-11-17 | Calendar through Apple's EventKit, read-only first, then creating events. | ADR-0011 |
| 2026-11-17 | Events: create only; preview and a click every time; default calendar, shown on the preview. | `docs/stages/calendar-events.md` |
| 2026-11-17 | Full calendar control: every command, including deleting. Each change still confirmed. | ADR-0012 |
| 2026-11-23 | Claude by default through Claude Code on the user's plan; local model as an off-the-grid switch; ordinary chats stop at 70% weekly and 80% five-hour usage. Replaces ADR-0009. | ADR-0013 |
| 2026-11-23 | New tools are connected to OMNIS, not straight to Claude, so confirmations and rules apply. | `docs/stages/claude-regular-mode.md` |
| 2026-11-24 | Logo: the Halo mark (three gold arcs closing on a bright centre), used for the Dock icon and the menu-bar glyph. | `macos/scripts/make-icon.swift` |
| 2026-11-24 | The app is signed with a local identity kept in the login keychain, so rebuilds keep their macOS permissions. | `macos/scripts/make-signing-identity.sh` |
| 2026-11-24 | Project mode: real Claude Code terminals in the dashboard with OMNIS as a read-only advisor; SwiftTerm added as the first third-party dependency; edits and safe commands free in the project folder, the rest asked. | ADR-0014 |

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

The user tries project mode and the dashboard. Then: voice, mail, or removing the unused API-key code.
