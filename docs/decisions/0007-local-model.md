# ADR-0007 — One local model: gemma4:12b

- **Status:** Accepted
- **Date:** 2026-11-17
- **Changes:** the two-model plan in `CLAUDE.md` §2 and §3 and in `docs/stages/stage-1.md`

## Problem / context

Stage 1 used `qwen3:4b` and `qwen3:8b`. That build of Qwen3 reasons before every answer and cannot be told not to. Short answers took 2 to 16 seconds, and answers that needed a web search took 19 to 63 seconds. The user also wants image input, which those models do not have.

## Options considered

Measured on this Mac. Round one: ten everyday questions, each with and without the search tool offered, plus two image questions. Round two: 26 questions needing current information, each answer graded against an answer verified separately by web search. Full figures are in `docs/benchmarks/model-bake-off.md`.

| Model | Memory | Search answer | Round two, correct of 26 | Images | Outcome |
|---|---|---|---|---|---|
| `gemma4:12b` | 7.7 GB | about 4.4 s | 23 | Yes | Chosen |
| `gemma4:e4b` | 9.4 GB | about 1.9 s | 19 | Yes | Fastest, but picked stale figures from results |
| `qwen3.5:4b` | 4.1 GB | about 2.4 s | 11 | Yes | Skipped searches and invented facts |
| `qwen3.5:9b` | 7.7 GB | 1 to 4 s | not run | Yes | Dropped after round one: searched once in four, claimed a search it had not made |
| `qwen3:4b-instruct` | 3.9 GB | never searched | not run | No | Dropped after round one |
| `qwen3:4b` (previous) | 3.9 GB | 19 to 63 s | not run | No | Replaced |

## Recommendation

`gemma4:12b` alone.

## User decision and date

2026-11-17, accepted: switch to `gemma4:12b` as the single local model, with reasoning switched off. The six other models were deleted with the user's approval.

## Consequences / risks

- One model answers both of the router's local lanes, so nothing is swapped in and out of memory. The question of whether two local models are worth it is closed: they are not.
- 7.7 GB of memory while loaded, against 3.9 GB before.
- Its two wrong answers in round two came from assuming a 2026 event had not happened yet. The instructions now state the date and that past-dated events have happened.
- The bake-off tested question answering only. Summarising email, drafting replies and creating calendar events are untested and must be tested before this model is trusted with them.
- The licence shown on the model's library page was not named; it must be read before any use beyond personal use.

## Revisit trigger

A model that is clearly better on the same tests at similar memory, poor results on personal-data tasks, or memory pressure in daily use.
