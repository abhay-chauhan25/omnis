# ADR-0013 — Claude by default, through Claude Code on the user's own plan

- **Status:** Accepted. Replaces ADR-0009 (routing by data) and the dollar budgets of ADR-0006. The API-key lane is retired.
- **Date:** 2026-11-23

## Problem / context

The API credits the earlier plan relied on did not arrive. The local model works but is slow on multi-step requests and holds 7.7 GB while loaded. The user wants OMNIS to stay running and stay light, and decided that personal information may be sent to Claude.

## Options considered

| Option | Tradeoff |
|---|---|
| Claude Code, run without a terminal, signed in with the user's Claude plan | No extra cost. About 260 MB while a chat is open. Shares the plan's limits with the user's own coding. Whether the plan's terms cover driving it from a personal app is not stated anywhere found. |
| Claude API with a key | Clear terms, no training on data by default, separate from the plan's limits. Costs money per use; credits did not arrive. |
| Local model only | Fully private and free. Slow, heavy, weaker at tools. |
| A rented GPU server | Data leaves the Mac anyway, weaker model, highest cost and effort. |

## User decision and date

2026-11-23: use Claude Code on the Max plan. Claude is the default; the local model is a switch for working off the grid. Ordinary chats stop using Claude at 70% of the weekly allowance and 80% of the five-hour allowance, then offer the local model. A project mode with no limits comes later. Claude's built-in web search is used in Claude mode. The user was told of the open question about the plan's terms and chose to go ahead.

## Consequences / risks

- Personal information (calendar, attached files, later email) is sent to Anthropic when Claude is in use. The user turned off Model Improvement in their Claude privacy settings; with it off, data is kept 30 days.
- OMNIS remains the only way Claude can act. Sessions are started with no file or shell tools, none of the user's Claude Code settings or connected tools, nothing saved to disk, and every tool call asks OMNIS first. Calendar changes still need the user's click.
- "No web search after the calendar is read" no longer applies in Claude mode; it still applies on this Mac.
- OMNIS depends on Claude Code's command-line behaviour, which can change between versions. Tested with 2.1.330.
- If the plan's terms turn out not to allow this use, the fallback is the API key or the local model.

## Revisit trigger

Anthropic says this use is not allowed; a Claude Code update breaks it; the plan's limits get in the way of the user's own work.
