# Calendar, step 1 — Reading

**Status:** built, reviewed and review findings fixed on 2026-11-17. Waiting for the user's test with the real calendar. Decision record: ADR-0011.

## What was built

Ask about your schedule in the chat window and OMNIS reads the calendar and answers. It can only read.

## How it works

1. `ChatModel.send` checks the question with `PersonalIntent.mentionsCalendar`. A match is kept on this Mac from the start.
2. The app sends the question to the Python service with `calendar: true`. The local model is then offered a `calendar_events` tool that takes a start and an end date.
3. When the model asks for dates, `engine.py` checks them (`_calendar_dates`) and sends a `tool_request` to the app. Python never touches the calendar.
4. `BackendService.readCalendar` turns the dates into whole days in the user's time zone (`CalendarFormatter.range`), reads through `EventKitCalendar`, and sends back one line per event (`CalendarFormatter.text`).
5. The model answers from those lines. The chat is marked as holding personal information: it stays local and web search is off for the rest of it.

Files: `macos/Sources/OmnisCore/CalendarAccess.swift`, `BackendService.swift`, `BackendProtocol.swift`, `Conversation.swift`; `macos/Sources/OmnisApp/ChatModel.swift`, `ChatView.swift`; `backend/omnis_backend/engine.py`, `protocol.py`, `service.py`.

## Rules

- Calendar questions are answered by the local model, never Claude.
- After a calendar read, no web search in that answer or that chat.
- The model sees title, start, end, calendar name and location. Notes and attendees are not read.
- Titles and places can be written by other people. They are flattened to one line, shortened to 160 characters, fenced, and the model is told not to follow instructions in them.
- At most 3 reads per answer, 63 days per read, 60 events per read.
- The audit log records the number of events, never their content.

## Tests

- Python 131, Swift 156, all passing.
- One live test with the real model and a made-up calendar: `OMNIS_LIVE_TESTS=1 swift test --filter liveCalendar`.

## Review findings

Independent review: pass with warnings. No write path found, and no way for calendar text to reach Claude or a web search in normal use.

| Finding | Action |
|---|---|
| Pressing Stop in the instant after a read could leave the chat unmarked, so a later question could go to Claude with calendar text in its history | Fixed. The chat is marked through a direct callback that does not depend on the answer still being read. |
| Many natural schedule questions were not recognised | Fixed. The pattern is wider, with the missed phrasings as tests. |
| Invalid dates from the model were dropped or shortened silently | Fixed. The model is told what was wrong and can ask again. |
| An all-day event on a 25-hour day read as "Sun 1 Nov to Sun 1 Nov" | Fixed. |
| Characters that reorder text on screen were not removed from titles | Fixed. |
| Only the Swift app enforces "no web after a calendar read" in later messages | Left as is and recorded in ADR-0011. |
| Some public questions ("what is the F1 schedule") are forced local | Left as is. The cost is a weaker answer; the opposite mistake is worse. |
| A permission prompt left unanswered for 50 seconds fails that answer | Left as is. The next question works once permission is given. |

The fixes were not reviewed a second time.

## Limits and things not verified

- Reading the real calendar has not been tested: it needs the user's click on the macOS prompt.
- Times are always shown in 24-hour form with day-month dates, whatever the Mac's settings.
- `EventKitCalendar` and `ChatModel` have no automated tests.
- macOS may ask for permission again after the app is rebuilt.

## Next

Creating events, with a preview and a confirmation every time. A plan comes first.
