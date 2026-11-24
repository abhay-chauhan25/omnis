# ADR-0015 — Messages are read by a separate helper, not by OMNIS

- **Status:** Accepted for the helper. The question of protecting the signing key is open.
- **Date:** 2026-11-24

## Problem / context

macOS keeps messages in a database that only a program with Full Disk Access can read. That permission also opens mail, browser data and other apps' files, and anything a program starts inherits it. OMNIS starts Claude Code terminals in project mode, and reads text written by other people, which can try to steer a model.

## Options considered

| Option | Tradeoff |
|---|---|
| Give OMNIS Full Disk Access | One switch. Every program OMNIS starts could then read messages, mail and browser data. |
| A small separate reader holds it | OMNIS and its terminals get nothing extra. One more program to build, and each side must be sure who the other is. |
| Sending only, no reading | No extra access at all. OMNIS could not answer "what did Sam say". |

## User decision and date

2026-11-24: no Full Disk Access for OMNIS; build the separate reader; "I want to make sure messages are secure". Contacts may be used to match names to numbers.

## Consequences / risks

- The reader answers three fixed questions, opens the database read-only, and takes no text from a model beyond a conversation's identifier and search words.
- OMNIS and the reader each check the other's code signature with the system before a byte is exchanged. An unsigned program that connects is told nothing.
- That check is only as strong as the signing key. The key is in the login keychain and `codesign` may use it without asking, so a program already running as the user that set out to imitate OMNIS could sign itself as OMNIS. This also applies to the permissions OMNIS already holds. Options: keep the key in its own keychain that is unlocked only while building; or an Apple Developer ID.
- OMNIS is not built with the hardened runtime, so a program could in principle start OMNIS with its own code loaded into it. Turning the hardened runtime on needs entitlements for calendar, reminders, photos and controlling other apps, and has to be tested against each.
- The messages a chat asks for are sent to Claude, like anything else read for an answer.

## Revisit trigger

macOS stops treating the reader as its own program; the Messages database changes shape; the signing key is moved.
