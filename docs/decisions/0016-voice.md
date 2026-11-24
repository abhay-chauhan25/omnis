# ADR-0016 — Voice: "Hey OMNIS", spoken conversations, personality

- **Status:** Accepted for the conversation. The notch panel is proposed and not yet designed with the user.
- **Date:** 2026-11-24

## Problem / context

The user wants to say "Hey OMNIS", talk back and forth, give OMNIS a personality, and be asked "anything else?" until they say no.

## Options considered

| Topic | Options | Tradeoff |
|---|---|---|
| Hearing the phrase | Apple's on-device recognition listening for it; a dedicated wake-word engine; a key to talk | Apple's needs nothing installed beyond its own speech model and keeps sound on the Mac, but "Omnis" is not a word it knows. A dedicated engine is built for the job but is a third-party dependency with an account. A key is not hands-free. |
| Speaking | The Mac's own voices; a cloud voice | The Mac's are free and on-device; the best need a free download. Cloud voices are not allowed by the project's rules. |
| Confirming by voice | Clicks only; a spoken yes for some things | A spoken yes can come from anyone in the room or a recording. |

## User decision and date

2026-11-24:
- Apple's on-device recognition for the phrase; the speech model was downloaded with the user's go-ahead.
- Listening only while a switch is on.
- A female voice, the best quality installed.
- "That's all" ends the conversation, and the next one starts in a fresh chat.
- Personality: presets and the user's own words.
- A spoken yes may confirm: the web-search question, adding a reminder or an event, and sending a message. The user chose sending against the recommendation. Everything else needs a click.
- The dashboard's dots move with the voice. Away from the dashboard, a small panel from the notch is wanted; its design is still to be agreed.

## Consequences / risks

- While the switch is on the microphone is in use and macOS shows its orange dot. Everything heard is turned into text on the Mac; talk that does not begin with the phrase is discarded at once and never logged.
- Only the text of a request goes to Claude, as typed text does.
- A message can be sent on a spoken yes. OMNIS reads out who it is for and every word first, and only a short, clear yes straight after its question counts. Someone else in the room could still say it.
- The personality text is the user's own and is passed to Claude as tone only.
- Power use has been estimated, not measured with a live microphone.

## Revisit trigger

False wake-ups or missed ones are frequent; measured power use is too high; a spoken yes confirms something the user did not mean.
