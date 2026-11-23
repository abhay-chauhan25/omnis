# ADR-0009 — Route by what data a request touches

- **Status:** Accepted; replaced by ADR-0013 (Claude through Claude Code)
- **Date:** 2026-11-17
- **Replaces:** the "local-only by default" rule of ADR-0006 and the routing-by-difficulty plan in `CLAUDE.md` §3

## Problem / context

Running a model locally costs memory and battery; a cloud model costs almost nothing on the Mac. The user wants personal information (email, calendar, files) kept off the cloud, and is content for public questions (web search, general knowledge, coding problems) to go to Claude.

## Options considered

| Option | For | Against |
|---|---|---|
| Everything local | Most private, works offline | Heavy on memory and battery; weaker answers |
| Route by difficulty (the original plan) | Good answers for hard tasks | Says nothing about privacy |
| Route by data touched | Privacy becomes a guarantee; light on the Mac for most use | Needs a clear rule for typed text |
| Everything to Claude | Lightest and best answers | Personal data leaves the Mac |

## User decision and date

2026-11-17, accepted:

1. Anything that uses a personal data source runs on the local model, always. The cloud lane is never given those tools or that data.
2. A plain typed question goes to Claude by default.
3. The lane is always visible, and the user can force local.
4. Once a conversation touches personal data, the whole conversation stays local until a new chat is started.
5. OMNIS picks the Claude model itself: a small, cheap one by default, a stronger one when the request needs it.
6. If Claude cannot be used (no key, no credit, over budget), OMNIS answers locally and says so. This replaces "never fall back": the fallback is allowed because it is always labelled.
7. The limits of ADR-0006 stay: 1 USD per request, 20 USD per month, warnings at 50% and 80%.

## Consequences / risks

- Until an API key is saved, nothing changes: everything is answered locally.
- Typed or pasted personal text is not detected automatically. The user forces local for it; a prompt for text that looks personal is a later option.
- The lanes share one window, so rule 4 is what prevents an innocent follow-up carrying personal content to the cloud.
- Model choice and budgets are enforced by OMNIS, not by the model.
- Live use still needs verified credits and the user's explicit approval. Until then the lane is built and tested against a mock.

## Revisit trigger

Real usage costs after the first weeks, a leak of personal text into the cloud lane, or poor local results on personal tasks.
