# ADR-0017 — Saved chats and what OMNIS remembers

- **Status:** Accepted
- **Date:** 2026-11-26

## Problem / context

A chat lived only in memory: it was gone when a new one was started, when the window had been hidden for 25 minutes, or when OMNIS quit. Nothing carried over from one chat to the next. The user asked for both: to open previous chats, and for OMNIS to have a memory. ADR-0005 had already set the policy (facts only after review, conversations on this Mac for 30 days); this records how it was built and the choices made on the way.

## Options considered

**Where chats are kept**

| Option | For | Against |
|---|---|---|
| OMNIS saves the words itself, one file a chat (chosen) | Works for Claude and for the model on this Mac; OMNIS decides exactly what is written | The earlier turns are passed back as text, so tool results from the first sitting are gone |
| Claude Code's own saved sessions and `--resume` | Full context returns | Nothing for chats answered on this Mac; Claude Code decides what is on disk, including email text and file contents |

**What is saved from a chat that held something private**

| Option | For | Against |
|---|---|---|
| Save everything | Simplest; chats read back whole | Email text and file contents end up on disk, against the rules already set for them |
| Do not save such chats at all | Nothing private on disk | The user's own questions are lost too |
| Save the chat, leave the private part out (chosen) | The thread is kept; the email's words and the file are not | A reopened chat has gaps, marked as such |

**How memory fills**

| Option | For | Against |
|---|---|---|
| OMNIS saves facts by itself | No effort | Wrong or private facts build up unseen (rejected in ADR-0005) |
| Each fact approved by the user (chosen) | Nothing is remembered that the user has not seen | One click a fact |

## Recommendation

OMNIS saves chats itself with the private parts left out, and memory is a short list where every line is put there or approved by the user.

## User decision and date

2026-11-26. The assistant set out the options and its recommendations; the user answered "go with your recommendations, build everything you think, and design the main chat window really well." Decided:

- Chats are saved on this Mac, one file each, readable only by the user's account. Nothing is uploaded.
- Not written to disk: the contents of attached files and pictures (names only), and the words of any answer written once the chat has been given an email. Previews are saved as one line of text saying what became of them.
- A chat can be marked "not saved"; anything already saved of it is removed.
- Chats are kept 30 days after they were last used, as ADR-0005 says. The user can choose 90 days or "until I delete them", and a pinned chat is kept until it is deleted. This widens ADR-0005, which had 30 days only.
- Memory: a list of at most 50 short sentences. A line gets there by the user typing it (the Memory panel or `/remember`), or by Claude proposing it and the user clicking Remember. Nothing is proposed in a chat that holds a file or an email. Passwords, codes and keys are refused.
- The list is added to what Claude is told at the start of a session, marked as facts and not as permissions. It therefore goes to Claude with the user's questions.
- The design of the dashboard's Chat view was left to the assistant, to be judged by the user on screen.

## Consequences / risks

- Chats on disk are a new store of personal text. It is protected by file permissions only, like the audit log, not encrypted beyond the disk's own encryption.
- A reopened chat is held to the strictest rules it had, and agreement to search the web is asked for again.
- Claude cannot look through earlier chats itself; only the user can, in the list. Memory is the only thing that carries over.
- The Graphify-style project graph in `CLAUDE.md` §5 is not part of this and is still to be discussed.

## Revisit trigger

The user wants OMNIS to search earlier chats by itself, wants email answers kept, or finds approving each fact a burden.
