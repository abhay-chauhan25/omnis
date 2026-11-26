# Voice

**Status:** built on 2026-11-24. The rules of the conversation are tested. The microphone, the recogniser and the speaking voice have not been run by the assistant, which has no microphone: they compile, and the recogniser was tried on recorded speech. The first real conversation is the user's to try. Decision record: ADR-0016.

## What was built

- A voice switch in the dashboard's top bar. Clicking it opens the switch, the personality (five presets and a box for your own words) and which voice is in use.
- With the switch on, OMNIS listens for "Hey OMNIS". A chime, then it takes what you say next, or what you said in the same breath.
- Your words go into the chat as if typed and are answered the same way, with a note asking Claude to reply in speech: short, no lists or addresses.
- The answer is read aloud, then "Anything else?". A follow-up needs no wake phrase. "That's all", "no", or eight seconds of silence ends it, and the next conversation starts in a new chat.
- A spoken yes can confirm the web-search question, a new reminder, a new event, and sending a message. OMNIS reads out what it is about to do first. Only a short, clear yes counts; anything else, or silence, confirms nothing and leaves the preview on screen. Other changes are announced as "on screen for you to confirm".
- The dashboard's dots swell with OMNIS's voice while it speaks and with yours while it listens. Esc, or the Stop button, cuts an answer short.
- When a preview needs your eyes, the chat window is brought forward.
- OMNIS does not listen while it speaks.

## How it works

1. `VoiceEngine` (`macos/Sources/OmnisApp/VoiceEngine.swift`) feeds the microphone to Apple's `SpeechAnalyzer` and speaks with `AVSpeechSynthesizer`. Both run on the Mac.
2. `UtteranceBuffer` and `VoicePhrases` (`macos/Sources/OmnisCore/Voice.swift`) turn the recogniser's stream into "this was said", find the wake phrase, and recognise endings and yes or no.
3. `VoiceFlow` holds the rules: what state the conversation is in and what to do next. It neither listens nor speaks, so it is tested directly.
4. `VoiceModel` connects the three to the chat: it sends the request with `ChatModel.askSpoken`, watches for the answer, and carries out a spoken yes through the same functions a click uses.

## What was measured

- Apple's English speech model was not on this Mac and was downloaded.
- On recorded speech made with the Mac's own voices, "Hey Omnis" was heard as "Hey, Omnis" three times in four and "Hey, Omnes" once; both are accepted, along with a few other near misses.
- 72 seconds of speech were turned into text in 0.9 seconds. That suggests a cost of a percent or two of one processor core while someone is talking. This is an estimate from recordings, not a measurement of the app listening.

## Review findings (2026-11-24)

Independent review, by reading the code: not fit for a first live use as first built. Each of these was fixed the same day; the fixes have not been reviewed a second time, and none has been tried with a microphone.

| Finding | Action |
|---|---|
| The end of OMNIS's own question ("...go ahead?") could be heard as a yes and send a message | Fixed three ways. Its questions now end "Yes or no?", which is neither. After it speaks, only speech that begins after it stopped is believed. Nothing half-heard is believed until a settled stretch has gone by. |
| Switching off mid-sentence left an ending pending, which wiped the next answer | Fixed. Switching off forgets everything about the conversation. |
| Ending a conversation cleared the chat at once, taking a preview or an answer the user was still reading | Fixed. The chat is left alone; the next "Hey OMNIS" starts the new one, and never clears what is typed but not sent. |
| Switching off during start-up could leave the microphone on; switching quickly could start it twice | Fixed. A start that is no longer wanted lets go of the microphone, and a second start is refused. |
| The conversation could wait for ever: a search question answered by a click, a chat cleared from the window, a voice that never reports finishing | Fixed. The state is rechecked on entering "thinking", a missing chat ends the wait, and both waiting and speaking have a time limit. |
| "Done" was said before a send or a reminder had gone through, and for a question that was dropped | Fixed. "Done" is said only when the change reports that it worked; a failure is said as one. A question asked while a typed one is being answered gets "I am still answering the last question". |
| Plugging headphones in or out stopped the listening without saying so | Fixed. Listening starts again on the new microphone. |
| "Other talk is thrown away at once" was not true in the seconds after OMNIS asks something | The wording was corrected. In those seconds whatever is said is taken as the reply and goes to Claude. |
| With several previews in one answer only the first is read out | Left as is. A yes confirms only the one that was read. |
| Esc stops an answer only while the dashboard is in front | The notch panel has a Stop button; there is still no key for it when another app is in front. |
| The personality is not applied off the grid | Left as is. |

A second review confirmed the fixes above by reading the code, and found no path by which OMNIS's own voice could become a spoken yes. It found more, fixed the same day and not reviewed again:

| Finding | Action |
|---|---|
| Headphones connecting while OMNIS was speaking left the conversation stuck | Fixed. The answer is cut short and listening carries on. |
| Any loud sound kept "Anything else?" open without end | Fixed. Only recognised words give the speaker more time. |
| Switching off and on very quickly could leave the switch on with a dead microphone | Fixed. |
| The limit on waiting for an answer was pushed back by anything overheard | Fixed. |
| Opening an app by voice is answered "Okay" even if it could not be opened; a preview declined on screen is spoken as "That did not work" | Left as is. |

### "That chat was closed" (found by the user, 2026-11-24)

Every spoken question was answered "Sorry, that did not work. That chat was closed." Cause: asking one question changes the chat several times in a row, and the voice code looked at each change using the picture of the chat as it was when the change was announced. One of those earlier pictures, looked at a moment late, had no answer in it yet, and that was taken to mean the chat had been cleared. Fixed: the chat is always read as it stands.

Reproduced and confirmed with a new development aid, `OMNIS --rehearse-voice "line one|line two"`, which runs a spoken conversation with no microphone, no sound and no windows, and prints both sides. The answers are real. With the old code it printed the error; with the fix it answered "what is two plus two?", remembered it for "and times ten?", ended on "that's all", and started the next conversation fresh.

The rehearsal does not cover the microphone, the recogniser or the speaking voice.

### "That's all" did not end the conversation (reported by the user, 2026-11-24)

The user said "that's all" and was asked "Anything else?" again. The exact words the recogniser produced are not known: nothing heard is kept. The likeliest cause is that an ending had to be the whole of what was heard, written one particular way, so "Okay, that's all for now", or an apostrophe written differently, was sent to Claude as a request.

Changed: apostrophes and fillers ("okay", "yeah", "um") are ignored; a short remark (six words or fewer) containing an ending phrase ends the conversation; a few ways a short "no" is misheard are accepted. A longer sentence is still a request. Rehearsed against real Claude with three wordings; each ended the conversation.

Also added, so there is always a way out whatever is heard: an End button beside the voice status on the dashboard and in the notch's voice view.

If it happens again, the words as OMNIS heard them are in the chat window as the user's own message; that text is what is needed to pin it down.

## Talking, not taking turns (2026-11-26)

The user asked for voice to feel like a conversation: fast answers, and no waiting to be asked. They approved all of these.

| Change | How |
|---|---|
| The first words come about a second after you stop | An answer is said sentence by sentence while it is still being written (`SpokenStream`), not after it is finished. In rehearsal the first sentence came 0.7 to 1.4 s after the question |
| A quick model for talk | A spoken question is answered by Haiku at low effort. "Think about", "think through", "deep dive" or "decide" still gets Opus at high effort. A model or effort picked by hand is used as picked |
| Claude is ready before you finish | Claude Code is started on the wake sound, not on the question |
| A shorter wait for the end of what you say | A pause of 0.8 s (was 1.1), then up to 0.5 s (was 0.9) for the recogniser's final wording |
| No more "Anything else?" | After an answer OMNIS just listens for eight seconds. Say the next thing, or "that's all", or nothing. A soft sound marks the end |
| Talk over it | Start talking while OMNIS is answering and it stops, drops the rest of that answer, and listens. A yes-or-no question cannot be talked over, so nothing said over it is ever taken for a yes |
| Opening things | "Open Spotify for me" and the like are matched without a model and answered "Opening Spotify". Looser wording goes to Claude, which has a tool for it (`docs/stages/services.md`) |
| Pace | Three speaking speeds in the voice settings |

### How talking over works

While OMNIS talks, the recogniser is still running. What it hears is compared with what OMNIS is saying (`VoiceEcho`): if most of the last few words are not its own, or one of them is "stop", "wait" or "OMNIS", that is the user. Its own voice coming back through the microphone is made of its own words, so it is ignored.

To hear less of itself in the first place, OMNIS turns on the Mac's echo cancelling from the first answer until the conversation ends. It is off the rest of the time, because macOS turns other sound down a little while it is on. The switch "Let me talk over OMNIS" in the voice settings turns both off, which is exactly how voice behaved before.

Stopping an answer part-way ends Claude's session, as the Stop button always has. It is started again at once, with the conversation so far, while the user is still talking.

### Review findings (2026-11-26)

An independent review read the change before it was committed. All of these were fixed.

| Finding | Fix |
|---|---|
| Talking over OMNIS stayed allowed when echo cancelling had failed or been reset by new headphones, so it could cut itself off | Allowed only while echo cancelling is actually on; it is put back after the microphone changes |
| What was sent on after talking over OMNIS began with OMNIS's own words | Its own words at the start are left out |
| By voice, a launcher (which runs a program) could be started, a bare name was enough, and the first of two near-equal names was opened | By voice the words must ask ("open ..."), launchers are never started, and two that fit about equally go to Claude to ask which |
| A late word about a sentence that had been cut off could be taken for a new one, ending speech early | Cut-off sentences are kept a while so they cannot be confused |
| Turning echo cancelling on and off quickly could be mistaken for new headphones | Each change is counted |
| The web-search question could be asked after half a sentence | Only whole sentences are said before it |
| Opening apps was allowed unless refused | Refused unless allowed, and allowed only in a chat with no file |

### Crash when AirPods connected (found by the user, 2026-11-26)

OMNIS quit a minute after the user put AirPods in. The system log showed why: the microphone had changed to one channel at 24 kHz, and OMNIS asked the audio engine to listen in the form it had before (six channels at 48 kHz, left from echo cancelling). Apple's engine reports that by raising an Objective-C exception, which Swift cannot catch; it unwound through Swift code and the app crashed on the next click.

Fixed three ways. A new audio engine is made each time listening starts or changes, so nothing is remembered of a microphone that has gone. The microphone's form is no longer asked for: the tap takes what it is given and converts from that. And every call into the audio engine goes through a few lines of Objective-C (`OmnisObjC`) that catch such an exception and hand it back as an ordinary error. After a microphone change, listening is tried three times over a few seconds before voice gives up and says why.

Not verified: this has not been run with AirPods by the assistant. The exception guard itself is tested.

### Its own words leaking in after being talked over (reported by the user, 2026-11-26)

The user tried talking over OMNIS. With AirPods it worked well. On the speakers, what was sent on sometimes had a few of OMNIS's own words in it, which changed how the request was understood.

The recogniser is now asked for the moment each word was said. When the user talks over OMNIS, the time is noted at which its voice could last be heard (a quarter of a second after it was stopped). A word said before then is kept only if it is not one of the words OMNIS was saying; every word after then is kept. Leaving out a fixed number of words at the start, as before, is used only if the words come with no times.

A word of the user's said over OMNIS that happens to be one OMNIS was also saying is lost. Not verified with a microphone by the assistant.

### A Siri voice (asked for by the user, 2026-11-26)

The user asked for Siri (Voice 1). Apple does not offer Siri voices to apps by name: none is in the list an app can choose from. The one way to talk in one is to use whatever is set as the Mac's System Voice, through Apple's older speaking interface. So the voice settings now offer "The Mac's System Voice (Siri)", which is the default, beside "Best other voice installed", and a "Hear it" button. The user picks Siri (Voice 1) in System Settings, Accessibility, Spoken Content, System Voice.

The System Voice says one sentence at a time, so OMNIS keeps the rest in line itself. Not verified: nobody has heard it yet, and it is not known whether the pace setting or the moving dots work with a Siri voice.

### More ways to start (asked for by the user, 2026-11-26)

"Yo OMNIS", "Yo Omi" and "Hey Omi" now start a conversation as "Hey OMNIS" does. The short name is held to a stricter rule than the long one, because it is closer to ordinary words: only after "hey" or "yo", and only as a word of its own.

### Finding faults

`OMNIS --voice-trace <file>` writes what voice hears, says and does to a file, with times. It holds spoken words, so it is written only when OMNIS is started that way, and the file should be deleted afterwards. How long the first words took is also in the Activity log (`voice_timing`), as a number and nothing else.

## Tests

- Swift 296, Python 120, all passing. New: the wake phrase and its near misses; endings and yes or no as whole utterances only; answers tidied for speech; the personality text; which previews a spoken yes may confirm; a whole conversation from wake to "that's all"; silence; unclear answers; the search question; switching off; and the recogniser's real pattern of growing and settled results.

## Limits and things not verified

- No real conversation has been held. Untried: the microphone, the permission prompts, how well a real voice is heard in a real room, whether OMNIS hears the tail of its own voice, and the dots' movement.
- Whether macOS also asks for the Speech Recognition permission is not known; the wording for it is in place.
- Power use with a live microphone is not measured.
- Only basic voices are installed. A better one is a free download in System Settings (Accessibility, Spoken Content, System Voice, Manage Voices); OMNIS picks the best English female voice it finds. It cannot download one itself.
- English only.
- A spoken yes cannot tell your voice from anyone else's.
- Away from the dashboard the conversation is shown in the notch panel (`notch.md`), which has not been seen on screen.
- Off the grid, voice works but the personality is not applied.
- **Not run with a microphone (2026-11-26):** speaking in sentences through the real voice, talking over OMNIS, and echo cancelling. The rules are tested and the conversation was rehearsed against real Claude without sound. Whether echo cancelling works with this Mac's speakers, whether the recogniser copes with it, and how much other sound is turned down, are all unknown until the user tries. If OMNIS cuts itself off, or goes deaf after its first answer, turn off "Let me talk over OMNIS" and say so.
- The shorter pause may cut in on someone who stops to think mid-sentence. The two numbers are at the top of `VoiceEngine`.
- Talking over OMNIS while it is between sentences and still thinking is not heard.
