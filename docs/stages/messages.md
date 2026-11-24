# Messages

**Status:** in progress. The reader is built and tested with a made-up database, and tried on this Mac as far as it can go without permission. Nothing has read a real message. Reading tools for Claude, names from Contacts, and sending are not built yet. Decision record: ADR-0015.

## What is built

- **OMNIS Messages Reader**, a separate small app (`macos/build/OMNIS Messages Reader.app`), built by `bundle.sh` when the stable signing identity exists.
- It answers three questions and nothing else: the recent conversations, the latest messages in one conversation, and messages containing given words. At most 60 messages or 40 conversations per question, no further back than a year, each message cut at 1,200 characters.
- It opens the database read-only. Values are bound to fixed questions; nothing typed becomes part of one.
- Recent macOS stores a message's words in a packed form. They are found by position, with every step checked against the data's length. Apple's unarchiver is not used on it, because that data is written by other people.
- It stops by itself after two minutes with nothing to do.
- OMNIS starts it through macOS's own launcher, so macOS treats it as its own program. Each side checks the other's signature before anything is exchanged.

## Files

- `macos/Sources/OmnisHelperLink/` — the messages exchanged, the signature check, the socket.
- `macos/Sources/MessagesReaderCore/` — the database questions, the unpacking, the server.
- `macos/Sources/OmnisMessagesReader/main.swift` — the helper itself.
- `macos/Sources/OmnisCore/MessagesReaderClient.swift` — OMNIS's side.

## Tests and what was tried

- Swift: the unpacking against archives made by macOS itself, cut short at every length and with every byte flipped; the questions against a made-up database; injection attempts; limits; a caller with the wrong signature refused; a caller with the right one answered.
- On this Mac, with the real signatures: `OMNIS --check-messages-reader` started the reader, each recognised the other, and the reader reported that it has no access, as expected. An unsigned script that connected to it was told "not recognised".

## To try it (the user)

1. System Settings › Privacy & Security › Full Disk Access › add `macos/build/OMNIS Messages Reader.app` and switch it on.
2. Run `macos/build/OMNIS.app/Contents/MacOS/OMNIS --check-messages-reader`. It prints only how many recent conversations the reader can see.

## Not verified

- That macOS grants the reader's Full Disk Access to it alone when OMNIS starts it. This is how the launcher is documented to behave; the check above confirms it once access is given.
- The real database's tables. The questions are written from its known layout and have only run against a copy made for the tests.
- Whether the grant survives a rebuild of the reader.

## Still to build

- Reading tools for Claude, with names from Contacts.
- Sending, as a preview to confirm every time.
- A decision on protecting the signing key (ADR-0015).
