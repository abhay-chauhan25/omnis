# Dashboard — the main window

**Status:** first version built on 2026-11-23 from a design the user approved ("make the dots golden, everything else looks good"). Not yet seen on screen by anyone but the user; independent review pending. Voice is deliberately not built: the user will decide on it separately.

Design mock: https://claude.ai/artifact/UhokCmEDyfwy1vFDrJLMAL (private to the user).

## What it shows

| Panel | Where the information comes from |
|---|---|
| Core | A turning sphere of golden points, drawn by the app. It swells while OMNIS is answering. |
| Today | The calendar, read by the app once calendar access has been allowed. Opening the dashboard never causes the permission prompt; an "Allow" button does. |
| Ask | Sends the question to the chat window, where the answer appears. |
| Launch | The registry, ordered by what was opened most in the last 30 days. |
| Claude usage | The five-hour and weekly figures Claude Code reports, with the points where ordinary chats stop. |
| Last 30 days | Questions per day, tokens and the busiest hour, counted from OMNIS's own activity record. |
| System | What is answering, whether a Claude session is open, web search, calendar access, running Claude Code sessions. |
| Recent activity | The activity record, in plain words. |
| Focus | A 25-minute countdown. |
| Quick capture | Appends a line to `~/Library/Application Support/OMNIS/notes.md`. |
| Projects | Registered projects, those with a Claude Code session running first, with how long it has run. |
| Mail | A placeholder saying it is not built. |

## How it works

- `OmnisCore/Dashboard.swift` turns existing records into what the panels show: `DashboardData` (activity, tiles, history, agenda), `SessionScanner` (running `claude` programs and their folders, from `ps` and `lsof`), `NotesStore`, `FocusTimer`. All tested.
- `OmnisApp/DashboardModel.swift` gathers it. It refreshes when the window opens and every 30 seconds while it is open, and not at all when it is closed.
- `OmnisApp/DashboardView.swift` draws it. `CoreView` draws the sphere 30 times a second only while the window is on screen, and holds still when Reduce Motion is on.
- The Dock icon and "Open Dashboard" in the menu-bar menu open it. Control+Space is still the chat window.

## Nothing new is recorded

The 30-day history, launch order and activity all come from the activity record OMNIS already kept. The only new files are `notes.md`, which the user writes, and nothing else.

## Tests

- Swift 219, Python 154, all passing. The window and its drawing have no automated tests.

## Limits and things not verified

- How it looks and feels on screen, at different window sizes, and the cost of the animation.
- The session scanner on the user's machine (it is tested against sample output).
- "Live project sessions" shows Claude Code sessions the user started themselves. Starting one from OMNIS is project mode, which is not built.
- Mail and voice are not built.
- Fonts are the system's; the mock used web fonts that are not installed on the Mac.
