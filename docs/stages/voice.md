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

## Tests

- Swift 294, Python 120, all passing. New: the wake phrase and its near misses; endings and yes or no as whole utterances only; answers tidied for speech; the personality text; which previews a spoken yes may confirm; a whole conversation from wake to "that's all"; silence; unclear answers; the search question; switching off; and the recogniser's real pattern of growing and settled results.

## Limits and things not verified

- No real conversation has been held. Untried: the microphone, the permission prompts, how well a real voice is heard in a real room, whether OMNIS hears the tail of its own voice, and the dots' movement.
- Whether macOS also asks for the Speech Recognition permission is not known; the wording for it is in place.
- Power use with a live microphone is not measured.
- Only basic voices are installed. A better one is a free download in System Settings (Accessibility, Spoken Content, System Voice, Manage Voices); OMNIS picks the best English female voice it finds. It cannot download one itself.
- English only.
- A spoken yes cannot tell your voice from anyone else's.
- Away from the dashboard there is sound but no picture yet. The notch panel is not built.
- Off the grid, voice works but the personality is not applied.
