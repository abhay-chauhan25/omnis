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
| Chat window with conversation memory | Built and reviewed 2026-11-17; tried by the user 2026-11-24 | ADR-0010 |
| Claude lane through an API key | Retired 2026-11-23, never run live. Replaced by Claude Code on the user's plan (ADR-0013). Its code was removed 2026-11-24 | ADR-0009 |
| Image and file attachments | Built and reviewed 2026-11-17; review findings fixed; tried by the user 2026-11-24 | `docs/stages/attachments.md` |
| Calendar, reading | Built and reviewed 2026-11-17; review findings fixed, fixes not re-reviewed; tried by the user 2026-11-24 | ADR-0011, `docs/stages/calendar-read.md` |
| Calendar, creating events | Built and reviewed 2026-11-17; review findings fixed, fixes not re-reviewed; tried by the user 2026-11-24 | `docs/stages/calendar-events.md` |
| Calendar, full control (change, delete, calendars) | Built and reviewed 2026-11-17; review findings fixed, fixes not re-reviewed; tried by the user 2026-11-24 | ADR-0012, `docs/stages/calendar-full-control.md` |
| Claude as the default (regular mode) | Built, tested live and reviewed 2026-11-23; review findings fixed, fixes not re-reviewed; tried by the user 2026-11-24 | ADR-0013, `docs/stages/claude-regular-mode.md` |
| Project mode (setup, terminals, advisor, following along) | All stages built 2026-11-24; core tested, advisor tested live; reviewed, findings fixed; tried by the user 2026-11-24 | ADR-0014, `docs/stages/project-mode.md` |
| Services: Reminders, GitHub (read), Spotify | Built 2026-11-24; tested with stand-ins and live through Claude; reviewed, findings fixed; tried by the user 2026-11-24 | `docs/stages/services.md` |
| Guard rails: the ask-once search question, fuller audit record, Activity view | Built and reviewed 2026-11-24; findings fixed; not yet seen on screen | `docs/stages/guard-rails.md` |
| Photos, reading only | Built 2026-11-24; tested with a stand-in and once live with a made-up picture; not yet run against the real library | `docs/stages/photos.md` |
| Messages | In progress 2026-11-24. Sending built and tested with stand-ins (Contacts lookup, preview to confirm); no real message sent yet. The separate reader is built, tested with a made-up database and tried on this Mac without access. Reading tools, Contacts names and sending not built. Security-reviewed and hardened. **Full Disk Access must not be given yet:** the signing key has to be protected first, which is waiting on the user | ADR-0015, `docs/stages/messages.md` |
| Voice ("Hey OMNIS") | Built 2026-11-24; the user has talked to it. Reworked 2026-11-26 for conversation: answers spoken as they are written, Haiku for talk, no "Anything else?", talking over OMNIS, opening apps. Rules tested and rehearsed against real Claude; **sentence-by-sentence speech, talking over and echo cancelling have not been run with a microphone** | ADR-0016, `docs/stages/voice.md` |
| Notch panel | Built 2026-11-24 from the approved design (voice view, everyday view, glow). Placement and content rules tested; never seen on screen | `docs/stages/notch.md` |
| Services: mail (school Outlook), browser | Not started. Probed 2026-11-24: Outlook answers scripts but shows them no accounts and no messages, so reading through the Outlook app is not possible as it is set up. Open routes: the account in Apple Mail, Outlook's older design if the school allows it, or Microsoft's online service with the school's consent | — |
| Dashboard (main window) | Built 2026-11-23 from the approved mock and reviewed; findings fixed. Since added: usage statistics from Claude Code's summary, memory, swap and energy in System, the Project switch. The user has seen it and asked for changes, all made. Voice and mail not built | `docs/stages/dashboard.md` |
| Icon and signing | Halo mark for the Dock and menu bar; the app is signed with a local identity so rebuilds keep their permissions (to be confirmed by the user over a few rebuilds) | `macos/scripts/make-icon.swift`, `macos/scripts/make-signing-identity.sh` |

The walkthrough for everything built on 2026-11-17 is `docs/stages/stage-1b-search-chat-claude.md`.

## Picking this up in a new session

Read `CLAUDE.md` first: it is the contract. Then this file, then the stage document for whatever is being worked on.

**What is waiting on the user right now**

1. Gmail, one account. Through Apple's Mail app (no setup; recommended to start) or Gmail's own service (fuller, needs a Google Cloud project made by the user). Which account, and which way. Reading freely; every send a preview to confirm.
2. Messages. Reading needs Full Disk Access for OMNIS, which is a lot. Read and send, or send only.
3. Browser. Chrome or Safari; and light (address and title, reads public pages) or full (reads what is on screen, needs a developer setting switched on in the browser).
4. Voice ("Hey OMNIS"). The user will decide. Proposed: Apple's own on-device speech, only while the dashboard is open, switched on by the user.
5. Whether macOS still asks for permissions after a rebuild, now that the app has a stable signature.

**How the work is done here**

- Build the app with `macos/scripts/bundle.sh`; the user quits and reopens OMNIS to get a new build. Once the user has run `macos/scripts/protect-signing-key.sh`, the signing key is in its own locked keychain and **only the user can build**: the script asks for the keychain's password, so the assistant asks the user to run it. Until then the Messages reader is not built. The assistant cannot see the app's windows: the look is judged from the user's screenshots. It can still check behaviour for itself when OMNIS is not already running: start the built app, move the pointer with a small program, read window sizes from the system's window list, and `sample` the process to see whether the main thread is stuck. Do this before handing over anything that opens, closes or animates. Two more aids: `OMNIS --render-notch <folder>` draws the notch panel to PNG files, so its look can be read as an image; `OMNIS --rehearse-voice "hey omnis ...|that's all"` runs a spoken conversation silently against real Claude and prints both sides. Both run alongside the user's own OMNIS. `OMNIS --voice-trace <file>` writes what voice hears and does to a file for finding faults; the file holds spoken words, so delete it afterwards. The assistant does not switch the microphone on itself: a live voice test is the user's to run or to approve.
- Tests: `cd macos && swift test` and `cd backend && python3 -m unittest discover -s tests -t .`. Live tests (`OMNIS_LIVE_TESTS=1 swift test --filter live…`) use the real local model, real web search or the user's Claude plan, so they are run sparingly and one at a time.
- Tests never touch the user's real calendar, reminders, Spotify or GitHub account beyond reading GitHub. Anything that needs a macOS permission prompt is left for the user to try.
- After each meaningful piece: an independent review by the verification agent (read-only, told not to run real services), then fix what it finds, then record the findings and actions in the stage document.
- Every change to the user's data goes through a preview the user confirms. New services follow `OmnisCore/AssistantTools.swift`.
- Design mocks are on two private canvases the user owns: the dashboard (https://claude.ai/artifact/UhokCmEDyfwy1vFDrJLMAL) and the logo (https://claude.ai/artifact/PjxtwYqD2NC3mTf4ExFwhz).
- `image/` and `personal-notes.md` in the repo root are the user's own and are not committed.

**Known loose ends**

- The new services have no dashboard panels yet. The Mail panel is a placeholder.
- Spotify plays a named song or playlist once the user has connected Spotify's catalogue (`/spotify`; needs their own Spotify developer app and Premium). Built 2026-11-26, never run against Spotify itself.
- The new services and project setup are offered to Claude only, not to the model on this Mac.
- On 2026-11-24 the user reported having tried everything built so far and found it working. The "not verified" lists in the stage documents predate that.
- If a Claude API key was ever saved, it is still in the Keychain (service `local.omnis.app`, account `anthropic-api-key`), and `claude-usage.csv` may still be in the support folder. Nothing reads either now.

## Tests

- Python: 120. Swift: 315. Eight more live tests use the real model, real search, a real picture and a made-up calendar when asked for.
- Independent review after each piece; findings and what was done about them are listed in the stage documents.

## Open items

- [x] User's hands-on check of the chat window (look, feel, dragging, sources, launch strip).
- [x] User's test of calendar questions against the real calendar (needs the macOS permission prompt).
- [x] User's test of adding events, including the first real save and an all-day event.
- [ ] User's feedback on the look of the event preview card.
- [x] User's test of changing and deleting in a throwaway calendar (steps in `docs/stages/calendar-full-control.md`).
- [x] User's look at the Model and Effort sliders, usage reading and typed commands.
- [x] Remove the retired API-key lane from the code.
- [ ] Gmail, Messages and browser: waiting on the user's choices (see the top of this file).
- [x] User's first use of Reminders and Spotify (each asks for a macOS permission once).
- [x] User's look at the dashboard on screen.
- [x] User's first run of project mode: open a terminal session, try the advisor, set up one real project.
- [ ] Voice: the user's first real conversation, a better voice downloaded, power use measured.
- [ ] Notch panel: the user's first look (appearance, hover, full-screen apps, menu-bar items beside the notch).
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
| 2026-11-24 | In a Claude chat that holds personal information, web searches are asked about once per chat, and only then. | `docs/stages/guard-rails.md` |
| 2026-11-24 | The audit log is shown as an Activity mode in the dashboard. | `docs/stages/guard-rails.md` |
| 2026-11-24 | No Full Disk Access for OMNIS. No file access yet; a folder is asked for when needed. Messages reading goes through a separate helper. Contacts may be used to match names. School Outlook is the mail account. | — |
| 2026-11-24 | On Auto, Claude answers with Sonnet at medium effort, and with Opus at high effort when the message says "deep dive", "think about", "think through" or "decide". Checked live: the model changes within one chat. | `ClaudeRouter` in `ClaudeLane.swift` |
| 2026-11-24 | The signing key moves to its own password-protected keychain, with a new key; Claude may see photo album names. | `macos/scripts/protect-signing-key.sh` |
| 2026-11-24 | Project mode: real Claude Code terminals in the dashboard with OMNIS as a read-only advisor; SwiftTerm added as the first third-party dependency; edits and safe commands free in the project folder, the rest asked. | ADR-0014 |

## Things worth knowing

- **Accuracy:** on current-events questions the local model was right 20 to 23 times in 26 across four runs. Its mistakes are mostly about dates.
- **Search engines throttle bursts.** Heavy testing got this network refused by three engines for some hours. More engines are now switched on and tests pause between searches.
- **Memory:** 7.7 GB while the model is loaded; nothing when idle.
- **Ghidra** is launched by a script, registered in `registry.json`; "voyager" is an alias for the `VoyagerAI` project.

## Environment (checked 2026-11-17)

- Apple M4 Pro, 24 GB RAM, about 467 GB free, macOS 26.5.1.
- Xcode 26.6, Python 3.13, Docker Desktop, Homebrew, VS Code `code` command.
- Ollama 0.40.16 (Homebrew), started on demand. Model on disk: `gemma4:12b` (7.7 GB).
- Docker image `searxng/searxng:latest`, started on demand.
- The GitHub `gh` CLI is installed (`/opt/homebrew/bin/gh`).
- The Verification Agent is pinned to Sonnet; the other agents inherit the session model.

## Next step

Voice is built and waiting for the user's first real conversation. The notch panel is built and waiting for the user's first look: nobody has seen it on screen.

Also waiting on the user: running `macos/scripts/protect-signing-key.sh`; trying a real send; whether the school account connects in Apple Mail; hardening OMNIS itself.

Earlier note:

The user chooses what comes next: Gmail, Messages, the browser, voice, or memory (a small reviewed fact store was recommended; see ADR-0005).
