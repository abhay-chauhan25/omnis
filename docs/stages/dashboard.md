# Dashboard — the main window

**Status:** first version built on 2026-11-23 from a design the user approved ("make the dots golden, everything else looks good"). Reviewed; review findings fixed, fixes not re-reviewed. Not yet seen on screen by anyone but the user. Voice is deliberately not built: the user will decide on it separately.

Design mock: https://claude.ai/artifact/UhokCmEDyfwy1vFDrJLMAL (private to the user).

## What it shows

| Panel | Where the information comes from |
|---|---|
| Core | A turning sphere of golden points, drawn by the app. It swells while OMNIS is answering. |
| Today | The calendar, read by the app once calendar access has been allowed. Opening the dashboard never causes the permission prompt; an "Allow" button does. |
| Ask | Sends the question to the chat window, where the answer appears. |
| Launch | The registry, ordered by what was opened most in the last 30 days. |
| Claude usage | The five-hour and weekly figures Claude Code reports, with the points where ordinary chats stop. |
| Usage statistics | For all time, the last 7 days or the last 30: a calendar of busy days, total tokens, favourite model, sessions, streaks and the longest session. Read from the summary Claude Code keeps for its own statistics screen (`~/.claude/stats-cache.json`), which holds totals only and no conversation text. It covers all Claude Code use on this Mac, not only OMNIS. A line below it gives OMNIS's own 30-day count from its activity record. |
| System | What is answering, whether a Claude session is open, web search, calendar access, running Claude Code sessions. |
| Recent activity | The activity record, in plain words. |
| Focus | A 25-minute countdown. |
| Quick capture | Appends a line to `~/Library/Application Support/OMNIS/notes.md`. |
| Projects | Registered projects, those with a Claude Code session running first, with how long it has run. |
| Mail | A placeholder saying it is not built. |

## How it works

- `OmnisCore/Dashboard.swift` turns existing records into what the panels show: `DashboardData` (activity, tiles, history, agenda), `SessionScanner` (running `claude` programs and their folders, from `ps` and `lsof`), `NotesStore`, `FocusTimer`. All tested.
- `OmnisApp/DashboardModel.swift` gathers it. It refreshes when the window comes onto the screen and every 30 seconds while it can be seen. When it is closed, minimised, covered by other windows or on another desktop, nothing is refreshed or drawn.
- `OmnisApp/DashboardView.swift` draws it. `CoreView` draws the sphere 24 times a second only while the window can be seen, and holds still when Reduce Motion is on.
- The Dock icon and "Open Dashboard" in the menu-bar menu open it. Control+Space is still the chat window.

## What is recorded

The 30-day history, launch order and activity all come from the activity record OMNIS already kept. Two things are added to that record: a line each time the dashboard reads the calendar on appearing (with the number of events, and not shown under Recent activity), and a line each time a note is captured (never its text). The one new file is `notes.md`, which the user writes.

## Review findings

Independent review: pass with warnings. Privacy, permissions and the absence of voice were confirmed.

| Finding | Action |
|---|---|
| Launch tiles failed until the chat window had been opened once, with no feedback | Fixed. The list of things to launch is loaded when the dashboard appears, and the result is shown under the tiles. |
| The ask bar sent "open …" to a model, could overwrite a half-typed chat message, and could send a file waiting in the chat | Fixed. A clear launch request is launched at once; the chat's own text and files are left alone. |
| Drawing and refreshing continued while the window was covered or on another desktop | Fixed. Both stop whenever the window cannot be seen. |
| The Dock icon did not restore a minimised dashboard | Fixed. |
| Refreshing parsed the activity record on the main thread, slowly | Fixed. Done off the main thread with one date reader. |
| The dashboard's own calendar read appeared as "Read your calendar" | Fixed. |
| The 80% and 70% marks were written twice in the code | Fixed. |
| The clock can lag by up to 30 seconds | Left as is. |
| A Claude Code session in a sub-folder of a project is listed on its own | Left as is. |

## Tests

- Swift 224, Python 154, all passing. The window and its drawing have no automated tests.

## Limits and things not verified

- The usage statistics depend on a file whose layout belongs to Claude Code and may change. It is as fresh as the last time Claude Code updated it, which can lag behind today. If it cannot be read, the panel says there are no statistics.

- How it looks and feels on screen, at different window sizes, and the cost of the animation.
- The session scanner on the user's machine (it is tested against sample output).
- "Live project sessions" shows Claude Code sessions the user started themselves. Starting one from OMNIS is project mode, which is not built.
- Mail and voice are not built.
- Fonts are the system's; the mock used web fonts that are not installed on the Mac.

## Chat in the dashboard (asked for by the user, 2026-11-26)

The dashboard's view switch has a fourth choice, **Chat**: the same conversation as the small window, in a column wide enough to read. It is the same chat, not a copy, so everything in it works as it does there.

- The small window has a new button (arrows pointing outward, beside the close button) that hides it and opens the conversation in the dashboard.
- In the dashboard, "Small window" at the top left of the chat does the reverse.
- A question typed into the dashboard's own ask box is now answered there, in Chat view, instead of opening the small window.

Built from the existing chat view and view switch, with no new look of its own. **Not seen on screen by anyone yet, and not run past the user as a design first**: say if the placement or the look should change.

## OMNIS knows what it is (2026-11-26)

The user was told "I can't check it with the tools I have" when asking how many files could be attached. Claude is now given the facts about OMNIS itself: what it does, the limits on attached files, where it lives, the typed commands, and what it does not do. It is told to answer such questions from those facts and never to talk about "its tools".
