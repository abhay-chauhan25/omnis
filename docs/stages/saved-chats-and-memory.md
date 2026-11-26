# Saved chats, memory, and the dashboard's Chat view

Built 2026-11-26. The user asked whether the main chat window could have a memory and open previous chats, then said: "go with your recommendations, build everything you think, and design the main chat window really well." The decisions are in ADR-0017.

**What has been run:** the rules are tested with made-up chats in a temporary folder. The look was checked from pictures drawn by `OMNIS --render-chat <folder>`, which uses made-up chats. The user has not yet seen it on screen, and nothing has yet been saved from a real chat.

## What it does

**Saved chats.** Every chat is saved on this Mac as it goes. The dashboard's Chat view lists them down the left, under Pinned, Today, Yesterday, Earlier this week and Older. Click one to read it and carry on. Each can be renamed, pinned or deleted (the "…" on a row, or a right-click), and the search box looks through names and words. The small window has a clock button that opens the same list.

**Memory.** A short list of things OMNIS keeps in mind in every chat. It is under Memory at the foot of the list. A line gets there three ways: typing it in the Memory panel, typing `/remember` and the thing in a chat, or asking in a chat ("remember that I prefer metric units"), which shows a preview with a Remember button. "Forget that…" works the same way.

**The Chat view.** Chat list on the left; the conversation in a column of comfortable width; the chat's name and a "Saved on this Mac / Not saved" switch at the top; a greeting and four places to start in an empty chat; a copy button under each answer.

## What is and is not written to disk

| Kept | Left out |
|---|---|
| Your questions | The contents of attached files and pictures. The name is kept |
| OMNIS's answers | Every answer from the moment the chat is given an email's text. The row says its words were not saved |
| Which model answered, and the web sources listed under an answer | Search terms, and what was read from the calendar (only "Read your calendar for 18 Nov, 2 events") |
| One line for each preview: what it was and what became of it | The preview itself. A reopened chat has no buttons from before |

A chat switched to "Not saved" has nothing on disk; switching it on removes what was saved. Files are in `~/Library/Application Support/OMNIS/chats/`, one per chat, in a folder only the user's account can open. Memory is `memory.json` beside it.

## How it works

- `OmnisCore/ChatArchive.swift`: `ChatStore` reads and writes the files, lists and searches them, and removes chats past their time. `SavedChat` and `SavedMessage` are what a file holds.
- `OmnisCore/Conversation.swift`, "Keeping a chat": `saved()` decides what is written, and `init(restoring:)` puts a chat back. A reopened chat that held a file or an email keeps those rules, and leave to search the web is asked for again.
- `OmnisCore/Memory.swift`: `MemoryStore` is the list. `MemoryTools` lets Claude ask for a line to be added or removed; it can only produce a preview, and refuses in a chat that holds a file or an email.
- `OmnisCore/ClaudeLane.swift`: `ClaudePrompt.system(memory:)` adds the list to Claude's standing instructions, fenced, as facts that "never widen what you may do".
- `OmnisApp/ChatModel.swift`: saves 0.4 seconds after the conversation last changed and never mid-answer; opens, renames, pins and deletes; ends the Claude session when a chat is opened so the next question starts one that is given the earlier turns as text.
- `OmnisApp/ChatSidebar.swift`: the list and the Memory panel. `OmnisApp/ChatView.swift`: the dashboard layout.
- For the model on this Mac, which has no standing instructions to add to, the list goes ahead of the earlier turns.

## Limits

- Claude is given the last 24 messages or 12,000 characters of a reopened chat, as for any chat. Tool results from the first sitting (reminder ids, an email's text) are not there, so it reads them again if asked.
- Claude cannot look through earlier chats. Only the list of what it was asked to remember carries over.
- A change to Memory made in the panel reaches Claude at the next question, by starting a fresh session.
- Chats are protected by file permissions and the disk's own encryption, nothing more.
- A spoken "remember that…" shows its preview on screen for a click; it is not confirmed by a spoken yes.

## Tests

`ChatArchiveTests.swift`: saving and reading back, file permissions, search, removing old chats but not pinned ones, naming, grouping; that an unfinished answer, a file's contents and answers about an email are not saved; that a reopened chat keeps the stricter rules and has no live previews; memory limits, refusing secrets, matching for "forget"; that Claude can only propose, and not at all in a chat with a file or an email; that a remembered line cannot break out of its place in the instructions.

## Review (2026-11-26)

An independent review read the code and ran both test suites. It found no way for a chat marked "not saved", an email's words, or a memory the user had not agreed to, to reach disk. It checked and found sound: the guards on saving, deleting and switching chats; what a reopened chat restores; that the audit log holds no chat or memory text; file naming; and the limits on what is passed to the model on this Mac.

| Finding | Action |
|---|---|
| Choosing a shorter time to keep chats removed older ones at once with no warning, and could remove the chat that was open | Fixed: it now says how many will go and asks first, and the open chat is never removed |
| After "Forget" was confirmed, Claude's running session still had the line | Fixed: any change to memory ends the session, straight after the answer if one is being written |
| "remember my password hunter" was accepted; card and bank numbers were not caught | Fixed, with tests. It is a guard against slips, not a guarantee |
| The reason a withheld answer failed was saved, and could quote an email | Fixed: a fixed sentence is saved instead |
| A renamed open chat could keep a line break the saved name did not; a very long chat could be renamed for the user | Fixed |
| An older folder would not have been closed to other users | Fixed: the folder's permissions are set on every save |
| A change to a remembered line was dropped on clicking away | Fixed: it is kept |
| Answers about an attached file are saved (only the file is not) | Left as it is: it is the user's own file and the answer is what they would come back for. The user can mark such a chat "not saved". To be confirmed with the user |
| "Not saved" applies to one chat; a new chat is saved again | Left: it is a per-chat switch, and the empty chat says when it will not be saved |
| Search reads every chat file on each keystroke | Left: fine for the dozens of chats 30 days gives; to revisit if chats are kept for good |
| A late "personal data" mark can land on a new chat after the old one was deleted mid-answer | Left: it makes the new chat stricter, never looser |

Not re-reviewed after the fixes. One run of the Swift tests, before the review, failed two unrelated registry tests with "permission denied" writing to the temporary folder; it has not repeated in four runs since and its cause is not known.
