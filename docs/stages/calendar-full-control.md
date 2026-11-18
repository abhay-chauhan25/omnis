# Calendar, step 3 — Changing, deleting, and everything else

**Status:** built, reviewed and review findings fixed on 2026-11-17. Waiting for the user's test. No change has yet been made to the real calendar. Decision record: ADR-0012.

## The commands

| Command | Kind | What it does |
|---|---|---|
| `calendar_events` | Read | Events between two dates, optionally only those containing a word. Each carries a short id such as `e3`. |
| `calendar_event_details` | Read | One event's notes, guests, alert, repeat setting and link. |
| `calendar_list` | Read | The calendars, which is the default, which are read-only. |
| `calendar_create_event` | Change | A new event, with optional notes, link, alert, repeat and calendar. |
| `calendar_update_event` | Change | Any of: title, time, day, all-day, place, notes, link, alert, repeat, calendar. |
| `calendar_delete_event` | Change | Removes an event, or a repeating event from one day onward. |
| `calendar_create_calendar` | Change | A new empty calendar. |
| `calendar_rename_calendar` | Change | A new name for a calendar. |
| `calendar_delete_calendar` | Change | Removes a calendar and every event in it. |

## How it works

1. `Conversation.offer` decides, from the user's own words, whether the model may prepare changes for this message and how far deleting may go.
2. Reading an event list gives each event a short id (`EventRefs`). The model never sees the calendar's own identifiers, and an id it invents matches nothing.
3. For a change, `engine.py` checks the model's request and sends it to the app. `BackendService.calendarTool` looks the event up, works out the event as it would be afterwards (`EventDraft.applying`), checks it against the calendars that exist (`CalendarChange.check`) and hands the window a `CalendarChange`. It has no way to carry one out.
4. The window shows a card built from `CalendarChange.rows`: for a change, old → new for each detail that would change.
5. The confirm button calls `ChatModel.confirm` → `Conversation.beginSaving` → `EventKitCalendar.apply`. That is the only path to the calendar. Before changing or deleting, `apply` finds the event again and stops if it no longer matches what the card showed.

## Rules

- Every change needs a click on its own card. A card works once.
- Deleting is offered only when the user's message asks for it; a whole calendar only when the message says to delete a calendar; never in a chat that holds a file.
- A repeating event is changed or deleted for that one day unless the user says all later ones too. How it repeats can only be changed for that day and all later ones.
- Complex repeat patterns, several alerts and very long notes are left as they are.
- Cards for deleting are red, say it cannot be undone, and for a calendar name the account and the number of events.
- Cards mention guests, who may be notified.
- The audit log records the kind of change and the outcome. No titles, times, places or calendar names.

## Tests

- Python 148, Swift 193, all passing.
- Live, real model, made-up calendar (`OMNIS_LIVE_TESTS=1 swift test --filter liveChange`): move, delete, rename with alert, new calendar all gave the right previews; a plain question prepared nothing; no answer claimed a change was made.

## Review findings

Independent review: pass with warnings. The confirmation rule holds and the backend cannot reach the calendar.

| Finding | Action |
|---|---|
| Delete tools were offered on any message with a common verb once the calendar had been read | Fixed. Stricter rule for deleting, enforced in the app too. |
| The delete-calendar card did not say how much would go or in which account | Fixed. |
| Guests were not mentioned | Fixed. |
| Complex repeat patterns and count-based ends could be flattened | Fixed. They are classed as custom and refused. |
| A second alert could be lost | Fixed. Refused. |
| Raw text from existing events shown on cards; long notes | Fixed. Cleaned; notes cut after 8 lines on the card; notes over 1,000 characters cannot be changed. |
| Very long and zero-length events could not be renamed | Fixed. |
| A new last repeat day alone was dropped; `calendar_list` with no arguments failed; a huge alert value raised an error | Fixed. |
| Calendar names could reach the audit log through error text | Fixed. |
| The model sometimes sends the old end with a new start | Found in live testing. Fixed: the length is kept. |
| A failed preview can be retried later by calendar name | Left as is. |

The fixes were not reviewed a second time.

## Not verified — to check by hand

Every write to the real calendar. In a throwaway calendar: create, change, move between calendars, delete; one day of a repeating event and "all later ones"; an all-day event; then rename and delete the throwaway calendar. Also whether guests are notified, which depends on the account.

## Observed once

In one live run a move request was refused and the next question timed out waiting for the model. It did not recur after the fix above.
