# Email (reading only)

Built 2026-11-26. The user added their school Outlook account to the Mail app and asked for OMNIS to read it. They chose: the inbox of that one account, attachment names only, 90 days unless they name a date, a one-sentence spoken summary with the sender, and they are content for email text to go to Claude.

**Not verified: none of this has been run against the Mail app.** The assistant did not read the user's mailbox. The scripts compile, and everything around them is tested with a stand-in for Mail. The user's first question about their email is the first real run.

## What it does

| Tool | What Claude gets |
|---|---|
| `mail_list` | The newest emails in the inbox: sender, subject, when, read or unread, each with an id like `m3`. Filters: unread only, sender contains, subject contains, since, until, how many (15, at most 25) |
| `mail_read` | One email by its id: sender, subject, when, the names of its attachments, and its text up to 6,000 characters |

Nothing else. There is no way to send, reply, delete, move, flag or mark anything, and what is in an attachment is never read.

## How it works

OMNIS asks the Mail app, the way it asks Spotify: two fixed scripts run by `osascript` (`MailTools` in `macos/Sources/OmnisCore/Mail.swift`). macOS asks once whether OMNIS may control Mail. There is no password, no Full Disk Access and no helper program, and OMNIS does not talk to Microsoft.

The list script fetches five things about the newest 500 emails (2,000 when the user named an older date) in a few requests to Mail. Sorting and filtering by date, sender and subject happen in OMNIS, so nothing a model writes is ever part of a request to Mail. Mail is given only the account's name and, to read one email, that email's number.

## Rules

- **One account.** The first time, if exactly one account is switched on in Mail, OMNIS remembers its name and reads only its inbox from then on, and says so. Switching another account on later does not widen what is read. `/mail forget` makes it choose again.
- **Only when asked.** Email is read only once the user's own words have brought up email in that chat.
- **Ninety days,** unless the user's own words name a date. A model cannot reach further back on its own say-so.
- **Other people's words.** An email's text is handed over marked as information, never instructions. From the moment a chat is given an email, in that answer and for the rest of the chat, nothing can be sent, deleted or opened, no project can be set up, and a search outside asks first, once. These are the rules of a chat that holds a file.
- **No spoken yes.** In a chat that holds an email or a file, a preview is never confirmed by voice. It waits on screen for a click, because what is proposed may have come from that text.
- **Codes are hidden.** An email that is there to carry a sign-in code, a PIN, a temporary password or a reset link is not passed on, and neither is a subject that carries the code.
- **The log** records that the inbox was read and how many emails were listed. Never who, what or which account.

## Review findings (2026-11-26)

An independent review read the change before it was committed. Fixed:

| Finding | Fix |
|---|---|
| The 90-day limit was only a request to the model | Enforced: further back needs the user's own words to name a date |
| A spoken "yes" could confirm a reminder or event proposed in a chat that holds email | No spoken yes in a chat that holds an email or a file |
| An account name beginning with a dash would be read by `osascript` as an option | `--` ends the options before any value |
| If the inbox holds more than was looked at, the list was silently partial; and the newest were assumed to come first | The model is told when only the newest N were looked at; the script checks which end of the inbox is newest |
| Code hiding ran after the text was cut for length; missed "use 482913 to sign in", PINs and temporary passwords; hid ordinary "course code:" emails | Checked on the whole text; wording added; bare "code:" dropped |
| The account's name was in an error message | Removed. It is said once, when the account is first chosen |
| The account was chosen without a word | The first list says which account was chosen and how to change it |
| A slow Mail could outlast the time allowed | The whole script is inside one 40-second limit |

Known and left:

- The ids (`m1`, `m2`) are shared by every chat and last ten minutes. A second list, in any chat, replaces them.
- In a chat that holds an email, Claude can still pause, skip or change the volume in Spotify, and can still prepare a reminder or event preview for the user to click.
- Once email has been brought up in a chat, Claude may read it again later in that chat without being asked again.
- If Mail is closed, asking about email opens it.
- Not checked against Mail itself: that the school account's inbox is called "Inbox", that reading a message does not mark it read, and how long a large inbox takes.

## Tests

`ServicesTests`: the list and its filters, the 90-day limit, the pinned account, ids, reading one, attachment names, hidden codes, the fence around the text, that the scripts contain no verb that changes anything, and the rules for a chat given an email.
