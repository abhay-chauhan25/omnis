# ADR-0018 — OMNIS's own voice, a second listen for the wake phrase, and answering offline

- **Status:** Accepted
- **Date:** 2026-11-28

## Problem / context

Three complaints after the user had talked to OMNIS for a few days:

1. **The voice was cold, and would not change.** OMNIS spoke in the Mac's System Voice so that a Siri voice could be used. On this Mac the system hands apps "Evan (Enhanced)" whatever is picked in System Settings, and no Siri or Premium voice is visible to apps at all.
2. **"Hey OMNIS" was missed about half the time, and "Yo Omi" and "Hey Omi" never worked.** The wake phrase was found by reading what Apple's speech recogniser wrote. Played 39 clean clips of the phrases, it wrote "Yo Omi" as "You owe me", "Hey Omi" as "Hey, all me" or "Kaomi", and "Hey Omnis" as "Hey, Omniz": spellings OMNIS did not accept, and some no list of spellings could safely accept.
3. **Without wifi a question failed**, and only then offered the model on this Mac.

## Options considered

**The voice**

| Option | For | Against |
|---|---|---|
| Keep Apple's voices, fix how the System Voice is followed | No new parts | The voices apps are given here are flat; a Siri voice is not on offer |
| Kokoro, an open speech model run on this Mac (chosen) | Much more natural; nothing leaves the Mac; first sentence ready in about 0.35 s on the M4 | Two Python packages, about 800 MB on disk, 0.5 to 0.8 GB of memory while voice is on |
| A cloud voice | The most expressive | Paid, sends every answer to another company, against the Claude-only rule |

**Hearing the wake phrase**

| Option | For | Against |
|---|---|---|
| Accept more spellings | Tiny change | "You owe me" cannot be a wake phrase; the list never ends |
| Replace Apple's recogniser with Whisper | One listener | Whisper does not give words as they are said, which talking over OMNIS and the on-screen words depend on |
| Keep Apple's recogniser and let Whisper listen again when it may have misheard (chosen) | Nothing else changes; 39 of 39 clips heard; costs nothing unless something like the phrase was said | A second model; "Yo homie" and sometimes "Hey Naomi" are heard as the phrase |
| A dedicated keyword spotter | Built for the job, very light | A third kind of model to add and tune; not tried |

**No internet**

| Option | For | Against |
|---|---|---|
| Fail, then offer this Mac (as before) | The user always chooses | Not usable by voice; every question fails first |
| Switch by itself and say so (chosen) | Works at once; nothing is hidden | The model on this Mac is weaker, and gets some things wrong |

## Decision

- **Voice.** A separate helper program (`backend/omnis_speech`) makes the sound with Kokoro, a sentence at a time, and OMNIS plays it. Two voices are offered, as the user chose: **Adam** (the default) and **Heart**. The Mac's System Voice and Apple's best installed voice stay as choices, and the Mac's voice is used by itself whenever the helper is missing or fails, so an answer is never lost.
- **Wake phrase.** Apple's recogniser still listens. When it has not written the phrase but what it wrote could be a mishearing (it begins with "hey", "yo", "you" and the like, or holds most of the name), the same few seconds of sound are given to Whisper, which has been told the names. Only if Whisper writes the phrase does OMNIS wake; anything else it writes is dropped.
- **Offline.** OMNIS is told by macOS when the connection goes. While it is gone, questions are answered by the model on this Mac, the chat shows "Offline · on this Mac", a notice says so, and a spoken answer begins "I'm offline, so I'm answering on this Mac" the first time. When the connection returns, questions go to Claude again. Web search is not tried while offline.
- **Manner.** "Warm and chatty" is now the manner unless the user picks another, and it says more about what warm means.

## What this keeps to

- **Nothing leaves the Mac.** The helper is started with offline mode set, loads only files already on disk, and is given nothing of the user's environment. Its models are downloaded once by `backend/scripts/setup-speech.sh`, each checked against a fingerprint.
- **Sound is not kept.** The last 15 seconds the microphone heard are held in memory, only while voice is on, so there is something to listen to again. They are emptied when listening stops and are never written to disk.
- **Not always computing.** The helper runs only while voice is switched on. Whisper runs only when something like the phrase was heard. Kokoro is let go after five minutes without speaking.
- **Never a silent swap.** Answering on this Mac is shown and said each time it starts.

## Consequences

- Voice now needs a one-time setup. Without it everything works as before, in the Mac's voice.
- Memory in use while voice is on is 0.5 to 0.8 GB more than before, above the 500 MB the project hoped to idle at. With voice off it is unchanged.
- A sentence that sounds like the phrase ("Yo homie") wakes OMNIS.
- The model on this Mac is weaker than Claude: in a rehearsal it got a date sum wrong. It has no mail, Spotify or Messages tools.
- First words offline take about 7 seconds when the model has to be loaded, about 1.3 seconds after.

## Open questions

- None of this has been heard by the user or tried with a microphone.
- Whether talking over OMNIS still works with the new voice: the Mac's echo cancelling is relied on as before, but has not been tried with it.
- Battery use with the helper running has not been measured.
- The user's own recording of the four phrases could not be read (macOS protects the Voice Memos folder); it should be run through `OMNIS --check-speech <file>` once it is copied elsewhere.
