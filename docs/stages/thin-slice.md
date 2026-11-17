# Thin slice — Popup launcher with a proven backend connection

## Approval checkpoint (before work)

**Status: NOT APPROVED**

### Goal and user-visible result

Press Control+Space anywhere. A centre bar appears over the current screen. Typing shows live matches; Enter runs the top one. These work without any AI model:

- "open Ghidra"
- "open ChatGPT Classic app"
- "open Voyager project in VS Code" (resolves to `VoyagerAI`)

Text that matches nothing shows an "Ask OMNIS: …" row. Choosing it starts the Python service, sends the text, and shows a canned mock reply in the popup. That proves the app-to-backend connection of ADR-0003.

### In scope

| Part | Where | What |
|---|---|---|
| Popup | Swift app | Floating centre panel, Control+Space, live results, arrow keys, Enter, Esc, closes after a launch, stays open for errors, native glass, subtle fade and scale |
| Router | Swift | Rule-based matching: ignores filler words ("open", "app", "project", "in VS Code"), ranks prefix and close matches, honours aliases |
| Registry | Swift | Three entry kinds: installed app, project folder with an editor, custom launcher with a fixed script path |
| Executor | Swift | Runs only registry entries. Apps through the system launch API, VS Code and scripts as a program plus an argument list, never through a shell |
| Audit log | Swift | One line per action: time, action kind, target name, outcome |
| Backend service | Python | Child process, JSON messages over pipes, a mock "ask" handler, starts on first use, stops after an idle timeout, supports cancel |
| Protocol | Both | Versioned, typed messages: `hello`, `ask`, `answer_chunk`, `answer_done`, `cancel`, `error`. Answers arrive in chunks so later stages can show real answers as they are produced |

### Out of scope

Local models, Claude (even mocked routing), memory, the main window, a settings screen, the notch overlay, voice, the new-project and GitHub flows, Calendar and Gmail. Each waits for its stage.

### Proposed layout

- `macos/` — Swift package. `OmnisCore` holds the router, registry, executor, protocol and service supervisor, all testable from the command line. `OmnisApp` holds the popup and hotkey.
- `backend/` — Python package run with `uv`. Service loop, protocol, mock handler.
- `tests/` lives beside each half (`macos/Tests`, `backend/tests`).

Assumption to confirm during the build: the simplest packaging that yields a proper `.app` (either an Xcode app target or a small bundling script around the Swift package).

### Dependencies

None from third parties. Swift uses system frameworks and the built-in test library. Python uses only the standard library, including its test runner.

### Privacy, permissions, RAM, battery, cost

- No network use. No API cost.
- A plain key combination needs no macOS permission prompt.
- The app runs outside the App Sandbox, because it must launch other apps and a script. Acceptable for personal use; revisit at the security review.
- Runtime files are written outside the repo, in `~/Library/Application Support/OMNIS/` (registry and audit log).
- Python is not running until the first "Ask". Idle RAM and CPU of the app, and the start-up delay of the service, are measured and reported, not promised.

### Tests and acceptance criteria

Automated:

- Router: the three commands resolve correctly; "voyager" ranks `VoyagerAI` first and still lists `Voyagers`; "chatgpt classic app" finds `ChatGPT Classic`; nonsense yields only the Ask row.
- Registry: entries with missing or relative paths are rejected; unknown kinds are rejected.
- Executor: builds a program plus argument list; a name containing shell characters cannot alter the command; nothing outside the registry can run.
- Protocol: both halves encode and decode every message; a version mismatch is reported cleanly.
- Service lifecycle: starts on demand, returns the mock reply in chunks, stops after the idle timeout, cancel works, a crash surfaces as an error in the popup and the next Ask recovers.

Manual:

- Hotkey works over a fullscreen app and on an external monitor.
- The three commands launch the right things.
- Light and dark mode both look right; keyboard-only use works; VoiceOver reads the field and rows.
- Quit leaves no Python process behind.

Independent review by the Verification Agent before the stage is called done.

### Decisions awaiting user approval

1. The scope above.
2. Presence: no Dock icon, plus a small menu-bar icon whose only item is Quit. Alternatives: a Dock icon, or no icon at all.
3. Registry sources: apps found in `/Applications` and `/System/Applications`, folders directly inside `~/projects`, plus the Ghidra launcher. Alternative: only entries listed by hand.
4. Writing runtime files to `~/Library/Application Support/OMNIS/`.
5. No third-party dependencies in this slice.

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
