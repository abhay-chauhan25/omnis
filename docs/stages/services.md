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

## Playing by name, and opening apps (2026-11-26)

**Spotify: "play Bohemian Rhapsody", "play my gym playlist".** Two halves:

- *Finding it* is a search of Spotify's catalogue through Spotify's web service (`SpotifyAccount`). Spotify requires every such connection to belong to an app registered by a developer, and since February 2026 the owner needs Spotify Premium. So the user registers their own app once at developer.spotify.com/dashboard, with the redirect `http://127.0.0.1:43821/callback`, and types `/spotify <client ID>` in OMNIS. The browser opens Spotify's sign-in; OMNIS waits on this Mac for it to come back, and keeps the sign-in in the Keychain. `/spotify off` forgets it.
- *Playing it* is done by the Spotify app on this Mac, as pause and next already are.

Because of that split, the sign-in first asked Spotify only for permission to read (the user's playlists and saved music). Since 2026-11-26 it also asks to control playback, for one thing only: adding a song to what plays next, which the Spotify app cannot be asked to do. It still cannot change, save or delete anything in the user's library. The words searched for go to Spotify, so `spotify_play` follows the same ask-once rule as a web search in a chat that holds personal information.

What reaches the Spotify app is only ever an address Spotify itself issued (`spotify:track:` and 22 letters and digits), handed to a fixed script as an argument. A playlist is looked for among the user's own first. If the wrong song plays, Claude is given the other matches and can play one of those.

This approach was chosen by the assistant from the user's request for "full access to Spotify" and is open to change. The alternative, with no developer app, is to let Claude find a Spotify link by web search; it is slower and less reliable.

**Opening apps and projects (`apps_open`).** A plain "open Safari" has always been matched and opened with no model. The wording the instant match accepts is now looser ("can you open Safari for me"), and for anything looser still Claude has a tool that takes a name and opens whatever it matches in the user's saved list. It cannot open a launcher (which runs a program), anything outside the list, or anything at all in a chat that holds a file.

**Queue, shuffle, repeat, volume, Liked Songs (2026-11-26, asked for by the user).** Shuffle, repeat and volume are fixed scripts run by the Spotify app; a volume level is a whole number from 0 to 100 handed over beside the script. "Add X to the queue" (`spotify_queue`) goes through Spotify's web service and needs the extra permission above, so a connection made before this needs `/spotify reconnect` once. Liked Songs are played as one list by its address in the Spotify app; if the app does not start it, the newest liked song is played and OMNIS says so. Only a song can be queued, not an album. None of this has been run against Spotify.

Review findings, all fixed (2026-11-26): Spotify being busy while a sign-in was renewed threw the sign-in away (now only Spotify refusing it does, and renewals happen one at a time); any page in the browser could end a sign-in in progress by calling the callback address (now turned away, and the wait goes on); the browser was opened even if this Mac could not listen for the reply (now only once it is listening).

Not verified: nothing here has been run against Spotify itself, because that needs the user's own Spotify developer app. Safari and other apps that macOS keeps outside the Applications folder are not in the saved list, so they cannot be opened by name yet.

## Still to decide: Gmail, Messages, browser

See the questions put to the user on 2026-11-24.
