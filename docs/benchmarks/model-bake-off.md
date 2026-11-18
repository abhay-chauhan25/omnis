# Local model bake-off

Run on 2026-11-17 with `backend/scripts/bakeoff.py`. The decision it led to is ADR-0007.

- Machine: Apple M4 Pro, 24 GB RAM, macOS 26.5.1. Ollama 0.40.16.
- Every model was loaded on its own and unloaded before the next.
- Reasoning was switched off wherever a model allowed it.
- Web searches were real, through SearXNG.

## Why it was run

The Stage 1 models (`qwen3:4b`, `qwen3:8b`) reason before every answer and cannot be told not to. Offering them a search tool made things worse: they deliberated about whether to use it.

| Question (previous model, already loaded) | Tool offered | Tool not offered |
|---|---|---|
| What is the capital of France? | 8.3 s | 1.9 s |
| define entropy in one sentence | 37.1 s | 7.6 s |
| who wrote Pride and Prejudice | 11.4 s | 2.8 s |
| what is the latest version of macOS | 33.5 s, one search | 8.1 s |

## Round one: speed, search decisions, images

Ten everyday questions, each asked with and without the search tool. Six should not need a search; four should. Then two image questions with three checkable facts each.

| Model | Memory | Plain question | Search question | Searched when it should (of 4) | Searched when it should not | Image facts (of 6) |
|---|---|---|---|---|---|---|
| `gemma4:12b` | 7.7 GB | 0.3 to 1.2 s | 3.8 to 4.6 s | 4 | 0 | 6 |
| `gemma4:e4b` | 9.4 GB | 0.1 to 0.5 s | 2.1 to 2.5 s | 4 | 0 | 6 |
| `qwen3.5:4b` | 4.1 GB | 0.3 to 0.8 s | 3.3 to 4.8 s | 4 | 0 | 6 |
| `qwen3.5:9b` | 7.7 GB | 0.3 to 1.3 s | 1.1 to 4.0 s | 1 | 0 | 6 |
| `qwen3:4b-instruct` | 3.9 GB | 0.5 to 0.9 s | never searched | 0 | 0 | no image input |
| `qwen3:4b` (previous) | 3.9 GB | 3.4 to 16.3 s | 19 to 63 s | 4 | 1 | no image input |

Dropped after this round:

- `qwen3:4b-instruct` never searched and stated stale facts as current.
- `qwen3.5:9b` searched once in four and, on one question, wrote "I searched for" without having searched.

The image questions used two clean, simple pictures (a bar chart and a status table). They show the models can read an image, not how they cope with a cluttered one.

## Round two: 26 current-information questions

The correct answer to each question was established separately by web search before the models' answers were read. Each answer was then graded by hand.

| Model | Correct | Partly correct | Said it was not sure | Wrong | Typical time |
|---|---|---|---|---|---|
| `gemma4:12b` | 23 | 0 | 1 | 2 | 4.4 s |
| `gemma4:e4b` | 19 | 3 | 1 | 3 | 1.9 s |
| `qwen3.5:4b` | 11 | 1 | 0 | 14 | 2.4 s |

How each one failed:

- `gemma4:12b`: two answers said a 2026 event had not happened yet, without searching. One honest "not sure".
- `gemma4:e4b`: took whichever figure appeared in a result without checking it was the latest (an old interest rate, an old Python version).
- `qwen3.5:4b`: skipped the search six times and answered from stale memory, invented a subscription plan, and five times searched and still said it did not know.

## `gemma4:12b` after the change of instructions

The instructions were changed to state today's date, to say that past-dated events have happened, and to search for anything current. The same 26 questions were then run three more times, with a pause between searches.

| Run | Search engines answering | Searched | Correct | Notes |
|---|---|---|---|---|
| Before the change | All | 24 of 26 | 23 | The baseline above |
| After, run 1 | None (all refusing) | 26 of 26 | not gradable | Every answer said it could not check the web; none invented a result |
| After, run 2 | Bing and Yahoo only | 26 of 26 | 20 | Both "has not happened" answers fixed. Three new wrong answers, all about dates |
| After, run 3 (date added to the results) | Bing and Yahoo only | 25 of 26 | 20 | Interest rate fixed. Two answers came back blank |

What this shows:

- The change did what it was for: the model now searches for everything current, and no longer says that past events have not happened.
- Runs 2 and 3 are not like-for-like with the baseline. Three engines were refusing requests after heavy testing, and the two that answered returned older pages for several questions.
- Run to run, this model gets between 20 and 23 of 26 right, about 77 to 88 percent. Its remaining mistakes are about dates: judging which of two results is newer, and trusting a page that describes something as still to come.
- Blank replies happen now and then. OMNIS now asks once more when that happens.

## Limits

- Each question was asked once per model per run.
- 26 questions is a small sample, and all were about public facts.
- The verified answers are themselves from web search. Three were less certain than the rest (a Ghidra version, Japan's prime minister, exact point releases).
- Nothing here tests personal-data tasks such as summarising email or creating calendar events.
- Energy use was not measured.

## Side effect of the testing

A few hundred searches in one afternoon got this network refused by Brave, Google and DuckDuckGo for some hours. Five more engines were then switched on, test runs now pause six seconds between searches, and the app reports the refusal in plain words when it happens.
