# ADR-0012 — Full calendar control, every change confirmed

- **Status:** Accepted. Changes ADR-0004 for the calendar: deleting moves from "blocked" to "preview and confirm". Changes ADR-0011: OMNIS no longer only reads.
- **Date:** 2026-11-17

## Problem / context

After reading and creating events worked, the user asked for changing and deleting, and for OMNIS to be able to do anything with the calendar.

## Options considered

| Option | Tradeoff |
|---|---|
| Every command, each change shown as a preview and carried out only on a click | Slower by one click. A misread request, or text planted in an event title, can at worst put a card on screen. |
| Every command, carried out at once | Fastest. One misunderstanding by a small local model can delete an event, a series or a whole calendar, on every device, with no undo. |
| Changes at once, deletions confirmed | A middle path. A wrong move or rename can still be made silently. |

## User decision and date

2026-11-17: "add changing and deleting events, give it full access to everything in calendar, so it can do anything with calendar. All possible commands. Add all."

Built as the first option. The user asked for every capability; they did not ask for confirmation to be removed, and ADR-0004's rule for changes to the user's own data was kept. Removing confirmation is a separate decision for the user.

## What "every command" covers

Read events (with a search word), read one event's details, list calendars. Create, change and delete an event, including notes, link, alert, repeat and which calendar. Create, rename and delete a calendar.

Not possible through Apple's interface: inviting or removing guests, travel time, attachments. Reminders are a separate system and are not included.

## Consequences / risks

- "No code path exists" for deletion (ADR-0004) is no longer true for the calendar. The protection is now the confirmation click, plus the rules below.
- Deleting is offered to the model only when the user's own message says delete, cancel or remove; a whole calendar only when that message says to delete a calendar; nothing is deleted in a chat that holds a file. The app enforces this as well as the backend.
- Deleting a calendar in an online account deletes it on every device. The preview names the account and the number of events found.
- Changing or deleting an event with guests may notify them. The preview says so. This is an effect that leaves the Mac.
- Details OMNIS cannot show in full are never rewritten: repeat patterns beyond daily, weekly, monthly or yearly; events with several alerts; notes over 1,000 characters.
- The code that changes the real calendar has no automated tests, because tests must not touch the user's calendar.

## Revisit trigger

The user wants changes without confirmation, or a real change does something the preview did not show.
