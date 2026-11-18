# ADR-0008 — Web search through SearXNG

- **Status:** Accepted
- **Date:** 2026-11-17
- **Amends:** ADR-0006 ("local-only is the default")

## Problem / context

A local model knows nothing after its training date and had no way to look anything up. The user wants quick answers to current questions, summarised from the web.

## Options considered

| Option | For | Against |
|---|---|---|
| SearXNG in Docker on this Mac | Free, no account, no key | Relies on public search engines, which can refuse requests |
| Brave Search API | Official and stable | Free tier replaced by a small monthly credit; needs a card |
| Tavily free tier | Built for feeding models | Needs an account and a key |
| Claude's own web search | No container, no refusals | 10 USD per 1,000 searches on top of tokens |
| No search | Fully offline | Cannot answer anything current |

## User decision and date

2026-11-17, accepted:

- SearXNG in Docker, started on the first search and stopped after five idle minutes.
- The model decides when to search. A "searched the web" line is always shown, and web search can be turned off for a question.
- The Swift app performs the search. The Python service and the model can only ask for one.
- Sources listed under an answer are clickable, `https` only. Links inside answer text stay unclickable.
- SearXNG is also the search provider for the Claude lane, to avoid the per-search fee.

Amendment to ADR-0006: models still run on this Mac, but search terms now leave it and go to the search engines.

## Consequences / risks

- Search engines throttle bursts. A few hundred test searches in one afternoon got this network refused by three engines for a while. Five more engines were switched on so that one refusing does not mean no results, and test runs now pause between searches.
- When every engine refuses, the user is told so in plain words.
- Docker must be running. If it is not, the answer says that web search is unavailable.
- Search results are untrusted text. They are capped in size, marked as untrusted for the model, and can never trigger an action. A model can still be misled by what a page says; that risk is not removed.
- Only excerpts are read, not whole pages.

## Revisit trigger

Refusals in ordinary use, answers that are too thin without full pages, or a wish to drop the Docker requirement.
