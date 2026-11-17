# ADR-0001 — MVP surface and stage order

- **Status:** Accepted
- **Date:** 2026-11-16

## Problem / context

`CLAUDE.md` §9 proposes building the backend and local models first (Stage 1) and the app shell second (Stage 2). That order leaves nothing to use until Stage 2, and it does not test the connection between the app and the backend until then. We also had to choose which surface comes first: the hotkey popup, the main app, or both.

The commands used every day are simple launches: "open Ghidra", "open ChatGPT Classic", "open the Voyager project in VS Code". None of them needs an AI model.

## Options considered

**First surface**

| Option | For | Against |
|---|---|---|
| Popup only | Fastest route to something used daily | No settings or history screen at first |
| Main app only | Room for dashboard, memory review, settings | Slow to reach daily use |
| Both at once | Feels complete | About twice the UI design before anything runs |

**Build order**

| Option | For | Against |
|---|---|---|
| Thin slice first: popup → rule-based router → registry → launch | Usable early; proves the app-to-backend connection; no model download | Model speed and memory stay unmeasured a little longer |
| Documented order: backend and models, then shell | Measures the riskiest unknown first | Nothing to click until Stage 2 |

## Recommendation

Popup first, as a thin slice, then the documented stages.

## User decision and date

2026-11-16, accepted:

1. Start with a simple popup. All surfaces are still in scope for the product: main app, popup, notch overlay, and the rest of `CLAUDE.md` §4.
2. Build the thin slice first. Once it proves the app-to-backend connection, return to the documented stages and do each one properly.

Resulting order:

| Step | Content |
|---|---|
| Stage 0 | Discovery and architecture (in progress) |
| Thin slice | Popup → rule-based router → app and project registry → launch an app or open a project in VS Code. No AI model. |
| Stages 1–7 | As listed in `CLAUDE.md` §9, each with its own approval. Parts already covered by the thin slice are extended, not rebuilt. |

## Consequences / risks

- The stack and the app-to-backend connection must be decided before the thin slice, because the slice is built on them and is meant to be kept.
- Full Xcode is needed for the thin slice, earlier than Stage 2.
- The popup's look and behaviour must be co-designed before the thin slice.
- The slice has to stay thin. Anything beyond launching apps and projects waits for its proper stage.
- Local model speed, memory, and battery cost are not measured until Stage 1.

## Revisit trigger

The thin slice shows that the chosen app-to-backend connection is unreliable or too heavy at idle.
