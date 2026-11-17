# ADR-0002 — Popup design

- **Status:** Accepted
- **Date:** 2026-11-16

## Problem / context

The popup is the first surface (ADR-0001). Its position, hotkey, typing behaviour, and look had to be agreed before any UI is built (`CLAUDE.md` §0.2, §4).

## Options considered

| Topic | Options | Tradeoff |
|---|---|---|
| Position | Centre bar; drop from the notch; panel under a menu-bar icon | Centre is familiar and identical on every monitor. Notch gives one identity with the later overlay but has no home on external monitors. Menu-bar panel is simplest but small. |
| Hotkey | Normal key combination; double-tap of a modifier | A combination needs no special permission. A double-tap needs Input Monitoring because every keypress must be watched. |
| Typing | Launcher style with live matches; command style with a full sentence then Enter | Live matches make near-duplicates visible (for example `VoyagerAI` and `Voyagers`). Command style is closer to chat but hides ambiguity until after Enter. |
| Style | Native macOS 26 glass following light/dark; custom always-dark panel | Native costs less to build and stays consistent with the system. Custom gives a stronger identity. |
| Motion | None; subtle; expressive | Subtle gives feedback without delay. |

## Recommendation

Centre bar, a normal key combination, launcher style, native glass, subtle motion.

## User decision and date

2026-11-16, accepted:

- **Position:** centre bar. A floating panel over whatever is on screen; it does not switch apps or desktops.
- **Hotkey:** Control+Space, changeable in settings later.
- **Typing:** launcher style. Matches appear as you type, arrow keys choose, Enter runs the top match.
- **After a launch:** the popup closes at once. It stays open only to show an error.
- **Style:** native macOS 26 glass, following light and dark mode.
- **Motion:** subtle. A quick fade with a slight scale.

## Consequences / risks

- macOS assigns Control+Space to "Select the previous input source" by default, and that shortcut is enabled on this Mac. If more than one keyboard input source is in use, the two will collide. Either the system shortcut is turned off in System Settings or OMNIS uses another combination.
- Launcher style needs fast matching on every keystroke, so matching in the thin slice stays rule-based with no model call.
- Exact sizes, fonts, row layout, and animation timing are still to be reviewed on a running prototype before they are final.
- Later surfaces (main app, notch overlay) get their own design rounds.

## Revisit trigger

The hotkey collides in daily use, or the centre bar proves awkward once answers longer than a launch result are shown in it.
