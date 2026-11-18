# ADR-0010 — The popup becomes a chat window

- **Status:** Accepted
- **Date:** 2026-11-17
- **Supersedes in part:** ADR-0002 (position, closing behaviour, one question at a time)

## Problem / context

The popup of ADR-0002 was a centre bar that answered one question and closed when another app was clicked. The user wants to place it anywhere, keep it open, and hold a conversation in it, and supplied a reference image of a chat-style popup.

## Options considered

| Topic | Options | Tradeoff |
|---|---|---|
| Staying open | Close on click-away; stay until closed | Staying open suits conversation, at the cost of screen space |
| Memory | One question; conversation for the session; saved history | Session memory needs no storage design. Saved history belongs with Stage 4 |
| Launching | Separate launcher; same input box | One box is simpler, but needs a rule for when Enter launches |
| Controls | Typed prefixes only; buttons in the input bar | Buttons are discoverable; prefixes stay for speed |

## User decision and date

2026-11-17, accepted ("all recommended"):

- Movable by its top strip, resizable, floats above other windows, remembers its place and size. First appears in the centre at about 430 by 620 points.
- Stays open until closed. Control+Space shows and hides it; Esc and the close button hide it. Hiding keeps the conversation.
- Conversation memory for the session, cleared by the new-chat button or by quitting. Nothing is written to disk.
- Chat layout: the user's messages in a tinted bubble on the right, answers on the left with lists, headings and code blocks, sources and the model line under each answer.
- Input bar with a web-search toggle, a lane menu (Auto, Local, Claude), and send, which becomes stop while answering.
- Launching from the same box: matches appear in a strip above the input. Enter launches only when the wording clearly asks for it (a verb such as "open", a full name, or an alias); otherwise Enter sends the text and the up arrow selects a match. The window stays open after a launch.
- The same glass, light and dark following the system, the same subtle fade. No microphone or pop-out button.

Still unchanged from ADR-0002: the Control+Space hotkey, native glass, subtle motion.

## Consequences / risks

- The app owns the conversation and sends earlier turns with each question. The Python service remembers nothing.
- History is limited to recent turns so a long chat cannot exceed what the model can read.
- A failed answer and its question are left out of the history sent to the model.
- Only the empty window has been seen by the developer side; messages, sources and the launch strip are confirmed by tests and by the user.

## Revisit trigger

The user's feedback on look and feel, or the arrival of saved history in Stage 4.
