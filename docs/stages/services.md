# Services: Reminders, GitHub, Spotify

**Status:** built on 2026-11-24. Tested with stand-ins, and with real Claude for reminders and GitHub. **Not yet run against the user's real Reminders or Spotify**, which need their permission prompts. Reviewed; review findings fixed, fixes not re-reviewed. Gmail, Messages and the browser are not built: each needs a decision from the user first.

The user asked for Gmail (one account), GitHub, Messages, Spotify, the browser and Reminders. These three were built first because they need no new accounts, keys or broad permissions.

## What each does

| Service | Reading | Changing | How |
|---|---|---|---|
| Reminders | List open reminders, optionally one list | Add, mark as done, delete: each a preview the user confirms. Deleting needs the user's own message to say delete | Apple's EventKit, as for the calendar. macOS asks for permission on first use |
| GitHub | Pull requests waiting for the user's review, their open pull requests, issues assigned to them | None. Reading only | The `gh` tool the user is signed in to |
| Spotify | What is playing | Play, pause, next, previous, and opening a search: done at once, no preview | Fixed AppleScript lines sent to the Spotify app. macOS asks for permission to control it on first use |

Spotify playback is carried out without a preview because it is harmless and undone with one click, like launching an app (ADR-0004's "launch freely" tier). OMNIS cannot yet choose and play a particular song: that needs Spotify's web service and a developer key.

These tools are offered to Claude only. The model on this Mac has the calendar tools but not these.

## How it works

- `OmnisCore/AssistantTools.swift`: the pattern every service follows. A model can only ask. `run` returns text for a read, "done" for a harmless action, or an `ActionProposal` for a change. `perform` is called only from the user's click.
- `OmnisCore/Services.swift`: `RemindersTools` (with `EventKitReminders`), `GitHubTools`, `SpotifyTools`.
- `ClaudeService.serviceAsked` passes a tool call to its service, after Claude Code asks permission for it as for every tool.
- `Conversation` holds the proposals (`add`, `beginAction`), the chat shows them as `ActionCard`, and `ChatModel.confirmAction` carries one out.
- `backend/omnis_backend/claude_tools.py` lists the tools for Claude. It still does nothing itself.

## Rules

- Every change to the user's data is a preview that needs a click, once. A failed one can be tried again.
- Text from outside (reminder titles, pull request titles, track names) is marked as information, flattened to one line, and cannot imitate the marker that ends it.
- Nothing a model writes is ever put into an AppleScript or a command line. Spotify actions are picked from a fixed list; a search term travels as one encoded argument.
- GitHub commands are fixed searches. Nothing here can create, merge, close or comment.
- The audit log records which service was used and the kind of change, never titles or content.

## Tests

- Swift 251, Python 154, all passing.
- Live (`OMNIS_LIVE_TESTS=1 swift test --filter liveServices`): with a made-up reminders list, Claude listed reminders, prepared "call the bank tomorrow at 9am" and "mark the milk one as done" as previews without changing anything, and read GitHub through the real `gh`.

## Review findings

Independent review: pass with warnings. No path reaches a change without the user's click, and no model text reaches an AppleScript or a command.

| Finding | Action |
|---|---|
| GitHub lists of about nine or more items were cut off before being read and reported as empty | Fixed. Output is read in full, and a list that cannot be read is said to be unreadable, never empty. |
| "Delete the milk reminder" was refused in a fresh chat: the delete rule only knew calendar wording | Fixed. Services have their own rule: the user's message must say delete, cancel or remove, whatever is being deleted. |
| A tool for a service not set up on this Mac answered with a calendar error | Fixed. It says the service is not available. |
| Marking done or deleting acted on a reminder without checking it still matched the card | Fixed. If its title has changed, or it has gone, nothing is done. |
| A timed reminder also gets an alert, and a reminder with no list goes to the default list; the card showed neither | Fixed. Both are on the card. |
| A track name containing "|" was misread; a search with accented letters might not open | Fixed. |
| Reading reminders or GitHub marks the chat as holding personal information, which also widens when calendar changes are offered | Left as is. A click is still needed for any change. |
| Pausing a closed Spotify opens it | Left as is. |

## Limits and things not verified

- The real Reminders app: reading, adding, completing and deleting through EventKit have not run.
- Spotify: no AppleScript has been sent to the real app. The permission prompt and the exact wording of its replies are untested.
- GitHub shows at most 15 of each kind and no notifications.
- There is no dashboard panel for any of these yet.

## Still to decide: Gmail, Messages, browser

See the questions put to the user on 2026-11-24.
