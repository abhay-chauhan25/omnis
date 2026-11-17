# ADR-0004 — Permission tiers for actions

- **Status:** Accepted
- **Date:** 2026-11-16

## Problem / context

`CLAUDE.md` §6 requires least privilege and explicit approval for side effects, but leaves open which actions need a confirmation each time and which can run freely.

## Options considered

| Option | For | Against |
|---|---|---|
| Confirm everything | Safest | Makes everyday launches tedious, so confirmations get clicked through |
| Tiers by how far the effect reaches (recommended) | Friction only where a mistake is costly | Each new action must be placed in a tier |
| Standing approvals per integration | Least friction | One wrong model output can cause an outside effect unnoticed |

## Recommendation

Tiers by reach.

## User decision and date

2026-11-16, accepted:

| Tier | Examples | Rule |
|---|---|---|
| Read and launch | Open an app or project, read a calendar, read a file | No confirmation |
| Local change | Create a folder, initialise Git, write a file | Preview, then confirm |
| Leaves the Mac | Create a GitHub repo, push, send email, edit a calendar event | Confirm every time. No standing approval |
| Destructive | Delete files, force-push, rewrite history | Blocked in the first version |

Launching on a partial match stays as built (the top match runs on Enter) until the user asks for it to change.

## Consequences / risks

- Every action type declares its tier in code, and the Swift app enforces it. The model cannot change a tier.
- Repository visibility is always asked, never assumed.
- "Blocked" means no code path exists, not a hidden setting.

## Revisit trigger

A tier proves too strict or too loose in daily use, or a new integration does not fit a tier.
