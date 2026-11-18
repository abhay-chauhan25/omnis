# ADR-0006 — Claude use, spending limits, and battery

- **Status:** Accepted; amended by ADR-0008 (search terms leave the Mac) and ADR-0009 (routing and fallback)
- **Date:** 2026-11-16

## Problem / context

Claude is the only planned cloud provider. API credits are expected around 2026-11-23 but are not verified. Limits and upload rules must exist before any live call.

## Options considered

| Topic | Options | Tradeoff |
|---|---|---|
| Default | Local-only until asked; cloud whenever routing suggests it | Local-only never surprises; automatic cloud gives better answers but sends data out |
| Uploads | Confirm per file; allow per folder; allow all | Per file is safest and slowest |
| Over budget or unavailable | Fall back to a local model silently; say so and offer a choice | Silent fallback can hand a hard task to a weak model |
| Battery | Allow local models on battery; forbid them | Forbidding saves energy but makes OMNIS useless away from power |

## User decision and date

2026-11-16, accepted:

- Local-only is the default. Any request that would go to Claude is labelled before and after.
- A file is uploaded only after a confirmation for that file.
- Starting limits: 1 USD per request and 20 USD per month, warnings at 50% and 80%, then a hard stop.
- If Claude is unavailable or over budget, OMNIS says so and offers a choice. It does not substitute a weaker model silently.
- Claude stays mocked until credits are verified in the Anthropic Console and the user approves live use.
- Local models may run on battery. Background indexing pauses on battery.

## Consequences / risks

- Balances are never inferred from local estimates; they come from billing information.
- Exact Claude model IDs are checked against the live service when live use is approved.
- Battery cost of local models is measured in Stage 1, and the decision is revisited if it is high.

## Revisit trigger

Credits arrive, measured battery cost is high, or the limits prove wrong in use.
