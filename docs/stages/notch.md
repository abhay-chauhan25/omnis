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

## Review findings (2026-11-24)

Independent review, by reading the code: not fit for a first run as first built. Each of these was fixed the same day; the fixes have not been reviewed again, and none has been seen running.

| Finding | Action |
|---|---|
| Clicking any button in the panel could leave it holding the keyboard, so typing went nowhere | Fixed. It takes the keyboard only for the ask box, and gives it back when it closes. |
| The resting strip was fully see-through, so hovering might never register; or it might swallow clicks on menu-bar items beside the notch | Fixed. There is an all-but-invisible patch behind the notch itself for the pointer to land on; the margins either side are truly clear, and narrower (14 points). |
| macOS might push the contents down by the notch's height a second time | Fixed. |
| Over a full-screen app, a preview was sent to a panel that could not be seen | Fixed. If the panel is not on the desktop in front, the chat window is used. |
| A long preview could be cut off at the bottom, hiding its buttons | Fixed. The estimate is more generous and previews scroll inside the panel. |
| The panel could stay open after typing in the ask box, and a waiting preview could not be put away | Fixed. It closes when typing stops, and a Hide button puts a waiting preview away once the conversation is over. |
| Resting the pointer on the notch could make macOS ask to control Spotify | First fix caused the hang described below. Now: Spotify is asked only after the user clicks "Show what's playing" once. |
| Music controls from the notch left no record | Fixed. |
| An old list could show a past event as "now" | Fixed. |
| The closed panel redrew on every word of an answer and every change in voice level | Fixed. It follows only the voice switch while closed. |
| VoiceOver could not reach the Stop button | Fixed. |
| A question typed while an answer was being written was lost | Fixed. It stays in the box. |
| No keyboard or VoiceOver way to open the panel; a new preview is not announced | Left as is. Everything in the panel is also in the dashboard and the chat window. |

## The hang on first use (2026-11-24)

The user's first hover froze OMNIS, with the spinning cursor. Cause: one of the review fixes above. To avoid making macOS ask about Spotify, the panel asked macOS whether OMNIS was already allowed to control it, using a system call that waits, and did so on the main thread. Sampling the frozen app showed the main thread stuck in exactly that call.

Fixed: the call is gone. Spotify is not spoken to from the notch until the user clicks "Show what's playing" there once; after that the track is shown each time, asked for by a separate program off the main thread.

Checked by running it, with the pointer moved onto the notch by a small program and the app sampled: the panel grows from 213 by 32 points to 460 by 292 within a second, stays that size while the pointer is there, and returns to 213 by 32 after it leaves. The main thread is idle throughout. OMNIS uses about 0.4% of a processor core with the panel closed and no more with it open.

That check covers opening and closing only. How the panel looks is still unseen.

## Redesign (2026-11-24)

The user saw the first version and called it plain and ugly, and sent a reference: a wide, low panel with a music card showing the cover and a strip of the week. Rebuilt along those lines, in OMNIS's own black and gold:

- A wide panel (720 points) with three cards: music (cover, song, artist, three controls), the week (month, seven days centred on today, a dot under days with events, the next event and reminders due), and OMNIS (the dots, the voice switch, two usage meters).
- Below: the ask box, and launch tiles with each app's or folder's real icon.
- A top band beside the notch with the name and which model answers.
- It springs open from the notch. The voice view is narrower (540 points), with a larger orb.
- The cover picture is fetched from Spotify's own picture servers and nowhere else, only once the user has clicked "Show music".
- The dots under the week come from a read of seven days of the calendar; only whether a day has something on is kept.

**The look can now be checked without a screen.** `OMNIS --render-notch <folder>` draws both views to PNG files with made-up contents and exits. Controls that macOS draws itself (the text box, the switch, the scrolling row of tiles) come out as yellow placeholders or blank in these pictures; that is the drawing tool, not the panel. The populated layout was checked this way and adjusted three times (a wrapping button, a card that overflowed, a cramped orb).

Not re-checked after the redesign: opening and closing by hover (checked before it, see above), the tiles row, the cover picture, and the real calendar's dots.

## Smoother, and closing at once (2026-11-24)

At the user's request: the panel now closes as soon as the pointer leaves it (it used to wait half a second), grows out of the notch with a spring and slips back with a short ease, and the window keeps its size until the panel has gone so the closing movement is not cut off. Tile icons are looked up once, not on every redraw. Not run on screen: the user's OMNIS was open.

## Tests

- Swift 300, Python 120, all passing. New: the next-event line and its "in 40 min"; reminders due today and overdue; reading the playing track; where the panel sits on a notched screen, a plain one, and one too small for it.

## Limits and things not verified

- Nothing about how it looks or feels has been seen.
- Whether it really stays off full-screen apps. It is set up the way macOS documents for that.
- Whether hovering works reliably in the notch area, and whether the panel gets in the way of menu-bar items beside the notch. The resting strip is 22 points wider than the notch on each side.
- The open panel's height is estimated from what it is showing, so a very long preview could be cut at the bottom; the chat window always shows it whole.
- Spotify is asked what is playing each time the panel opens.
- No keyboard shortcut opens it; VoiceOver users reach the same things through the dashboard and chat.
