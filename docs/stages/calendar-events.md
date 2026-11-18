# Calendar, step 2 — Creating events

**Status:** built, reviewed and review findings fixed on 2026-11-17. Waiting for the user's test, including the first real save. Decision record: ADR-0011; permission rule: ADR-0004.

## Approved scope (2026-11-17)

Creating new events only. The model proposes; the user sees a preview and nothing is saved until they click. New events go to the default calendar, shown on the preview. The preview card was built plain on the user's "build this now"; its look is open to change.

## How it works

1. `Conversation.offersEvents` decides whether the model may prepare an event for this message: only when the user's own words ask for one (`PersonalIntent.asksToAddEvent`), or follow straight on from asking, and never on a message that carries a file.
2. If so, the local model is offered a `calendar_create_event` tool (title, start, end, all-day, place).
3. `engine.py` checks what the model asked for (`_event_draft`) and sends a `tool_request` to the app.
4. `BackendService.proposeEvent` checks it again (`EventDraft.parse`) and hands the window a preview. It has no way to save. The model is told the preview is shown and nothing has been added.
5. The window shows the card (`EventCard`). "Add to Calendar" calls `ChatModel.confirm`, which calls `Conversation.beginSaving` and then `EventKitCalendar.create`. That is the only code in OMNIS that changes the calendar, and only that button reaches it.
6. Later turns tell the model what became of each preview (`Conversation.proposalNotes`).

## Rules

- No event is saved without a click on its own preview. A preview saves at most once.
- What the card shows is exactly what is saved: full title, full place, time, calendar.
- A newer preview withdraws ones still waiting under earlier answers.
- The same event twice in one answer is shown once; at most 5 previews per answer.
- The year is shown when it is not this year; a time in the past is flagged.
- Times the clocks skip are refused. Events longer than 31 days are refused.
- A chat with a preview stays on this Mac.
- OMNIS cannot change or delete existing events.
- The audit log records proposed, added, declined or failed. Never the title, time or place.

## Tests

- Python 138, Swift 171, all passing.
- Live, real model, no real calendar: `OMNIS_LIVE_TESTS=1 swift test --filter liveEvent`. Timed, ranged and all-day requests gave the right previews; a request with no day or time got a question; no answer claimed an event was added.

## Review findings

Independent review: pass with warnings. The confirmation gate holds: nothing the model, the backend, a file, a web page or a calendar entry produces can save an event.

| Finding | Action |
|---|---|
| The tool was offered on every question, so hostile text in a file or web page could bring up a preview | Fixed. Offered only on the user's own request or its follow-up, never with a file attached. |
| The card cut off long titles and places while the full text was saved | Fixed. Shown in full. More invisible characters are removed. |
| Two identical previews could appear in one answer | Fixed. |
| A failed save could not be retried; the permission message said "read" | Fixed. |
| The click-to-save rule had no automated test | Fixed. The rule moved into `Conversation.beginSaving`, with tests. |
| A preview under an answer with no words never reached later turns | Fixed. |
| A newer preview withdraws an unrelated one still waiting | Left as is; a choice for the user. |
| The calendar named on the card is looked up when the preview appears; the save uses the default at click time | Left as is. The "Added to" line names the real one. |
| A time that happens twice when the clocks go back uses the later one, with no hint | Left as is. |

The fixes were not reviewed a second time.

## Not verified

- A real save through EventKit, including how all-day events land in the Calendar app. No test writes to the real calendar.
- The card's look and its buttons, which need eyes on the screen.
