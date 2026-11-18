# ADR-0011 — Calendar through EventKit, read-only first

- **Status:** Accepted
- **Date:** 2026-11-17

## Problem / context

The calendar is the first personal-data integration. The user asked whether an Apple Calendar MCP server exists, then said to use whichever way is best, to start read-only, and to move to writing events once reading works.

## Options considered

| Option | Tradeoff |
|---|---|
| EventKit, called directly by the Swift app | Apple's own interface. No dependency, no extra process, no network. macOS shows its own permission prompt. Covers every account the Calendar app shows (iCloud, Google, Exchange). |
| A third-party Apple Calendar MCP server | Works, but adds someone else's code with calendar access, usually driven through AppleScript, plus a process to run and keep updated. Nothing it offers is missing from EventKit. |
| Google Calendar API | Needs an OAuth app and network access, and covers only Google accounts. |

## Recommendation

EventKit directly. The model is given a tool that asks for the events between two dates; the Swift app does the reading, as with every other action (ADR-0003).

## User decision and date

2026-11-17: "Do what you think is the best way to get calendar information, start read-only to make sure it works, then let's go to writing events."

## Consequences / risks

- macOS has no read-only permission level for calendars. Reading needs "full access", which also allows writing at the system level. That OMNIS only reads is enforced by OMNIS's own code: the calendar interface it uses has a single read operation.
- Calendar information is personal (ADR-0009). It is answered only by the local model. Once the calendar has been read in a chat, that chat stays on this Mac and cannot search the web.
- Whether a question is about the calendar is decided by a word pattern in the app. A missed question goes to Claude when a key exists; Claude cannot see the calendar, so nothing leaks, but the answer is useless. The pattern is deliberately wide.
- The Swift app is the only place that enforces "no web after a calendar read" across later messages of a chat. The Python service cannot tell that an earlier message came from the calendar.
- The app is signed for this Mac only, so macOS may ask for calendar permission again after a rebuild.
- Creating events is a separate step with its own plan, preview and confirmation (ADR-0004).

## Revisit trigger

A need EventKit cannot meet, such as a calendar account the Calendar app cannot show.
