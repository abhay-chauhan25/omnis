# Thin slice — Popup launcher with a proven backend connection

## Approval checkpoint (before work)

**Status: APPROVED by the user on 2026-11-16**, with one change: the app has both a Dock icon and a menu-bar icon.

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
2. Presence: decided as a Dock icon plus a menu-bar icon.
3. Registry sources: apps found in `/Applications` and `/System/Applications`, folders directly inside `~/projects`, plus the Ghidra launcher. Alternative: only entries listed by hand.
4. Writing runtime files to `~/Library/Application Support/OMNIS/`.
5. No third-party dependencies in this slice.

## Implementation log

### Changes made

- `backend/omnis_backend/`: `protocol.py` (message format and validation), `service.py` (read loop, cancel, idle stop), `handlers.py` (mock answer), `__main__.py` (entry point).
- `macos/Sources/OmnisCore/`: `Registry.swift`, `Matcher.swift`, `Executor.swift`, `AuditLog.swift`, `BackendProtocol.swift`, `BackendService.swift`.
- `macos/Sources/OmnisApp/`: `OmnisMain.swift`, `AppDelegate.swift`, `HotKey.swift`, `PopupController.swift`, `PopupModel.swift`, `PopupView.swift`, `AppEnvironment.swift`.
- `macos/scripts/bundle.sh`: builds `macos/build/OMNIS.app` with an ad-hoc signature.
- Outside the repo: `~/Library/Application Support/OMNIS/registry.json` holds the Ghidra launcher and the "voyager" alias. Personal paths are kept out of the repo.

### Tests executed and results

- Swift: 52 tests, all passing (`cd macos && swift test`).
- Python: 26 tests, all passing (`cd backend && python3 -m unittest discover -s tests -t .`).
- Measured on this Mac with the app idle: 0% CPU, 0 idle wakeups, about 20 MB memory footprint, no Python process until the first question. Loading the registry (138 entries) took about 10 ms.
- Independent review, twice: pass with warnings both times. The second pass checked the fixes for the first and found one of them incomplete. Findings and actions are listed below. The final fix (last two rows) is covered by tests but was not reviewed a third time.

### Review findings

| Finding | Action |
|---|---|
| A question over 1 MB left the popup waiting forever | Fixed. Questions over 100,000 characters are refused, and an error with no request id now ends every waiting request. |
| Requests could be orphaned if the service had exited but not yet been cleaned up | Fixed. The stopped process is settled before a new one starts. |
| Enter on a partial match can run a launcher script ("gh" runs Ghidra) | Open. A product decision for the user. |
| A failed service start gave no clue why | Fixed. The service's last error output goes into the audit log. |
| A late launch failure wiped what was being typed | Fixed. |
| Registry reloaded from disk on every open | Measured at about 10 ms. Left as is. |
| VoiceOver was not told when an answer finished | Fixed. Rows also expose an activate action. |
| Settings folder was readable by other users of this Mac | Fixed. Folder is private, as are both files. |
| Text from the service was shown without a length limit | Fixed. Capped at 500 characters. |
| Second review: a request could still be left waiting if a write to the service failed | Fixed. A request is assigned to the process before the write, and a failed write stops the process so the request is retried once or failed. |
| Found while testing that fix: a service that starts but never replies kept a request waiting | Fixed. A started service has 10 seconds to say hello or it is stopped. |

### Deviations and why

- The Ask row is always the last row, not only when nothing matches. A question can share a word with an app name, and it must still be askable.
- Menus hold "Open OMNIS" as well as Quit, so the popup is reachable if the hotkey is ever unavailable. An Edit menu exists because paste does not work in a text field without one.
- The Python service runs with plain `python3`, not `uv`. It has no dependencies, so `uv` adds nothing yet.
- A stated kind ("... app", "... in VS Code") puts entries of that kind first. A small score boost was not enough to beat an alias.
- The Dock and menu-bar icons are placeholders (the default app icon and a system symbol). Icon design is a later UI discussion.
- App discovery looks two levels deep so that the `Utilities` folder is included.

### Known limits

- There is no time limit on an answer once the service has said hello. A real model that stalls mid-answer would wait until Esc. To be set in Stage 1 against measured model speeds.
- Enter on a partial match runs whatever is on top, including a launcher script.
- If a launcher script fails after starting, the failure is only in the audit log.

### Not verified

Nothing below could be checked without hands on the keyboard and eyes on the screen:

- How the popup looks, including the glass effect, in light and dark mode.
- Control+Space, over a fullscreen app and on an external monitor.
- The three real launches (Ghidra, ChatGPT Classic, VoyagerAI in VS Code).
- VoiceOver and keyboard-only use.

## Teaching handoff

1. **What was built.** A menu-bar and Dock app whose only window is a centre bar. It launches apps, projects and custom launchers by rule-based matching, and passes anything else to a Python service that currently returns a canned reply.
2. **Why this approach.** Launching never needs a model, so it stays in Swift and is instant. The Python service exists only for AI work, so it is started on demand and stops when idle. Swift decides and executes; Python can only send text back.
3. **How it works.**
   - Control+Space → `HotKey` → `PopupController.show()`, which reloads the registry and shows the panel.
   - Each keystroke → `PopupModel.queryChanged()` → `QueryParser` strips filler words → `Matcher.rank` scores every registry entry → rows.
   - Enter on an entry → `Executor.launch(entryID:)` looks the id up in the registry, builds a `LaunchPlan`, and `SystemLaunchPerformer` carries it out. The popup closes first.
   - Enter on the Ask row → `BackendService.ask` starts `python3 -m omnis_backend` if needed, writes one JSON line, and streams `answer_chunk` lines back into the popup.
   - Every launch and question writes one line to `audit.log`. Typed text is never logged.
4. **How to run and test it.** See the README section "Running the thin slice".
5. **What was verified.** See "Tests executed" and "Not verified" above.
6. **Security, memory, battery, cost.** No network, no API cost, no macOS permission prompts. The app is not sandboxed. Launchers inherit the app's environment. Idle cost was measured as near zero.
7. **Try next.** Edit `registry.json` to add a launcher or alias and reopen the popup; the change is picked up on the next open.
8. **Decisions needed.** Whether Enter on a partial match should be allowed to run a launcher script. Then Round 4 and the Stage 1 plan.
