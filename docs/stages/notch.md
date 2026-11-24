# The notch panel

**Status:** built on 2026-11-24 from the design the user approved in conversation. Its placement and content rules are tested. It has not been seen on screen by anyone: the assistant cannot see windows, and OMNIS was running an older build at the time, so it was not even started. Its look, its hover behaviour and its behaviour in full-screen apps are all for the user to check.

## What the user chose

- Opens when the pointer rests on the notch, and by itself during a spoken conversation when the dashboard is not on screen.
- Everyday contents: the next event, reminders due today, music controls, Claude usage, the voice switch, an ask box, and launch tiles.
- A small light beside the notch while voice is on.
- Only on the MacBook's own screen. Hidden over full-screen apps.

## What was built

- An overlay window owned by OMNIS, hung from the top edge and centred on the notch. It is not a change to the notch itself. On a Mac with no notch it sits at the top centre.
- **Voice view:** the dots moving with the voice, what state the conversation is in and what is being heard, a Stop button while OMNIS speaks, and any preview or question waiting on the user, with the same buttons as in the chat. A preview shown here is the one a spoken yes would confirm; one that needs a click can be clicked here.
- **Everyday view:** opens after the pointer has rested on the notch for a fifth of a second, and closes half a second after it leaves, unless the ask box is in use. Esc closes it.
- Asking from the box opens the chat window with the answer, as the dashboard's ask bar does.
- With the lid shut and only an external screen, there is no panel, and previews go to the chat window instead.

## How it works

- `macos/Sources/OmnisCore/Notch.swift` — what to show (next event, reminders due, the playing track) and where the panel goes. No window code; tested directly.
- `macos/Sources/OmnisApp/NotchModel.swift` — when it opens and closes. Everything else it shows is borrowed from the dashboard, chat and voice models, so it cannot disagree with them.
- `macos/Sources/OmnisApp/NotchView.swift` — the two views.
- `macos/Sources/OmnisApp/NotchWindowController.swift` — the window: finds the built-in screen and its notch, follows screen changes, tracks the pointer.

## What it reads, and when

- Only when it opens: the dashboard's own refresh (at most twice a minute), what Spotify is playing, and reminders. Nothing is polled while it is closed.
- Reminders are read only if OMNIS is already allowed to; the panel never makes macOS ask for a permission.

## Tests

- Swift 300, Python 120, all passing. New: the next-event line and its "in 40 min"; reminders due today and overdue; reading the playing track; where the panel sits on a notched screen, a plain one, and one too small for it.

## Limits and things not verified

- Nothing about how it looks or feels has been seen.
- Whether it really stays off full-screen apps. It is set up the way macOS documents for that.
- Whether hovering works reliably in the notch area, and whether the panel gets in the way of menu-bar items beside the notch. The resting strip is 22 points wider than the notch on each side.
- The open panel's height is estimated from what it is showing, so a very long preview could be cut at the bottom; the chat window always shows it whole.
- Spotify is asked what is playing each time the panel opens.
- No keyboard shortcut opens it; VoiceOver users reach the same things through the dashboard and chat.
