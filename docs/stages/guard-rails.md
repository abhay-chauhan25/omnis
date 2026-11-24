# Guard rails: the search question and the Activity view

**Status:** built and reviewed on 2026-11-24; review findings fixed. Not yet seen on screen.

## What was built

- **The search question.** In a Claude chat that has been given something personal (an attached file, the calendar, reminders, GitHub), the first web search does not run on its own. The answer pauses and a card asks "Allow web searches in this chat?", showing the first search. The answer holds for the rest of the chat; a new chat asks again. Decided by the user: ask once per chat, and only once something personal has been sent.
- **Other outward lookups follow the same rule.** A service can name tools that send model-chosen words outside (`outwardTools`). Spotify's search is the only one today.
- **Not everything counts as personal.** A service says whether its reads are personal (`holdsPersonalData`). What Spotify is playing is not.
- **Fuller record.** Requests that OMNIS refuses or holds back are now written to the audit log by tool name and reason, along with the user's answer to the search question.
- **Activity view.** A third mode in the dashboard, next to Dashboard and Project. Filters (All, Changes, Reads, Searches, Refused), a text filter, entries grouped by day, repeats counted, and a button that shows the log file in Finder.

## How it works

1. `ChatModel.ask` tells `ClaudeService` whether the chat already holds something personal (`ClaudeRequest.sensitive`) and what the user has said so far (`searchConsent`). Both live in `Conversation` and are cleared by a new chat.
2. Claude Code asks OMNIS before every tool. `ClaudeService.outward` lets the lookup through if nothing personal has been sent or the user has allowed it, refuses it if they declined, and otherwise holds it and sends `.searchConsentNeeded` to the window.
3. A personal read partway through an answer flips the same switch, so a later search in that answer is held.
4. `ChatModel.answerSearchAsk` records the click and calls `ClaudeService.answerSearchConsent`, which lets the held lookup go or refuses it.
5. With no click in five minutes the one search is refused and nothing is decided; the next search asks again. Stopping the answer does the same.
6. `ClaudeService.onGate` reports refusals. `ActivityLog` turns audit records into lines; `ActivityView` shows them.

The local model is unchanged: a chat that holds something personal does not search at all.

## Tests

- Swift 251, Python 119, all passing. New: the question is asked once and its answer holds; a personal read mid-answer triggers it; an unanswered question lapses without ending the answer; stopping while it is open sends nothing; a service's own search follows the rule; refusals are recorded by name and reason only; the log's wording, filters, day grouping and repeat counts.
- No live test was run for this stage.

## Review findings

Independent review: pass with warnings. No way was found for a lookup to leave a personal chat without the user's go-ahead.

| Finding | Action |
|---|---|
| A tool's name comes from the model and was written to the log as given | Fixed. Only a short plain name is kept; anything else is recorded as "an unrecognised tool". |
| The "asked" line read "waiting for you" for ever | Fixed. It reads "asked you". |
| Row identities shifted once the log passed 4,000 records | Fixed. A row is known by its time and place. |
| The list was filtered twice per drawing, with a new date formatter each time | Fixed. |
| Day headings were not marked as headings for VoiceOver | Fixed. |
| A reminder change or a failed request might hand the model personal text without marking the chat | Checked. The text given to the model for a preview is fixed wording. Error text is not checked. |
| A second search asked for while the first waits is refused and may be retried | Left as is. Nothing leaves the Mac. |

## Limits and things not verified

- The card and the Activity view have not been seen on screen.
- Whether Claude Code itself gives up on a permission request that waits several minutes is not known. It has only been tried against the stand-in.
- Asking once per chat means later searches in that chat are not shown before they run. That was the user's choice.
- The Activity view shows the latest 4,000 records.
- `ChatModel` and the views have no automated tests; they live in the app target.
