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

## Security review (2026-11-24)

An independent security review advised against giving the reader Full Disk Access as first built. The reader's own code was found careful and to fail closed, but two routes went round it.

| Finding | Action |
|---|---|
| Code could be loaded into the reader when it starts, and would have its access | Fixed. The reader is built with the hardened runtime and no exceptions. Tried on this Mac: a test library loads into OMNIS (which is not hardened) and does not load into the reader. The build fails closed if the setting is missing, and OMNIS refuses a reader without it. |
| The signing key can be used without asking, so any program running as the user could sign its own "reader" and inherit the grant | Decided 2026-11-24: the key moves to its own password-protected keychain and is replaced. `macos/scripts/protect-signing-key.sh` does it; the user has to run it, since it asks for a password. The build script now builds the reader only when the key is protected. Tried with a throwaway key: the build signs while unlocked, locks the keychain when it ends, and fails plainly when locked. **Not yet run on the real key.** |
| The same test library loads into OMNIS itself, which the reader then trusts | **Open.** OMNIS needs the hardened runtime, with each permission it uses re-tested. |
| A search can return verification codes and reset links like any other message | **Open. A policy for the user to choose** before the reading tools are built. |
| No record of who asked the reader what | Fixed. `helper/reader.log` records each request and each refused caller: the kind of question and counts, never whose messages or which words. |
| The trusted signature was read loosely from a settings file | Fixed. The reader runs only if it is exactly as signed, and only accepts the one exact form. |
| A message could be few characters and very many bytes | Fixed. Capped by bytes as well; hidden and direction-changing characters are dropped. |
| Any program could keep the reader running, or hold it up by sending slowly | Fixed. Only a recognised caller keeps it running; a request must arrive within six seconds. |
| The socket's folder could be swapped for a link | Fixed. It must be a real folder, the user's own, closed to others. |
| Messages set to send later were listed as sent; empty ones used up the limit | Fixed. |
| A second certificate with a similar name could be picked up by the build | Partly. The build now checks the fingerprint's form and uses the system's own signing tool by full path. It does not yet compare against a recorded fingerprint. |

## To try it (the user), once the open items above are settled

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
