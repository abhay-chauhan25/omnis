# ADR-0005 — What OMNIS remembers

- **Status:** Accepted
- **Date:** 2026-11-16

## Problem / context

`CLAUDE.md` §5 describes a memory pipeline but not what is stored without asking. This sets the policy; the schema and tooling are Stage 4.

## Options considered

| Option | For | Against |
|---|---|---|
| Save facts automatically | Memory fills up without effort | Wrong or private facts get stored silently |
| Save facts only after review (recommended) | Nothing is remembered that the user has not seen | Needs a review step |
| No memory until Stage 4 | Simplest | No policy to design against |

## Recommendation

Review before remembering.

## User decision and date

2026-11-16, accepted:

- A candidate fact becomes a memory only after the user approves it in a review list.
- Conversations are kept on this Mac only, for 30 days, and can be deleted at any time.
- Nothing is indexed (Downloads, email, repositories) without permission for that source.
- Graphify: the exact repository or link is still to be supplied by the user. It will be evaluated before anything is adopted.

## Consequences / risks

- Stage 4 needs a review screen in the main app.
- The audit log and the registry are not "memory" and are kept as they are.
- Until Stage 4 exists, conversations are not stored at all.

## Revisit trigger

Reviewing each fact becomes a burden, or the user wants a class of facts saved automatically.
