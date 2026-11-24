# Claude as the default — regular mode

**Status:** built on 2026-11-23, tested live against Claude, pushed. Independent review pending. The window's new controls have not been looked at on screen. Decision record: ADR-0013.

## What was built

- Claude answers by default, through Claude Code signed in with the user's own Claude plan.
- One Claude session per chat. It closes after 25 minutes without a question, and a chat whose window has been closed for 25 minutes starts fresh.
- Model and Effort controls: two small labels in the input bar that open a slider. The same from the keyboard: `/model auto|haiku|sonnet|opus`, `/effort auto|low|medium|high`, `/local on|off`.
- A usage reading in the top strip (`5h 8% · 7d 2%`). Ordinary chats stop using Claude at 80% and 70% and offer a button to answer on this Mac.
- "Off the grid" switches everything to the local model.

## How it works

1. `ChatModel.ask` decides between Claude and this Mac, checks the usage limits, and picks the model and effort (`ClaudeRouter`).
2. `ClaudeService` starts `claude` once per chat (`ClaudeConfig.arguments`): no built-in tools but web search, none of the user's settings, memory files or connected tools, nothing saved to disk, and a permission prompt on every tool call.
3. Claude learns which calendar tools exist from `backend/omnis_backend/claude_tools.py`. That program can do nothing: it only hands back text.
4. Before each tool call Claude Code asks `ClaudeService.toolAsked`. A web search is allowed or refused by the globe switch. A calendar tool goes through `CalendarTools`, the same checks the local model goes through: a read is carried out and its text handed back; a change becomes a preview card.
5. Usage figures arrive from Claude Code as it works and are shown and enforced by `UsageLimits`.

## Measured (2026-11-23, Claude Code 2.1.330)

| | Claude (Haiku) | Local model |
|---|---|---|
| Memory while a chat is open | about 260 MB | 7.7 GB |
| Plain answer | about 1 s | 0.3 to 1.2 s |
| Calendar read or change | about 1 s | 6 to 15 s |
| Web search answer | 5 to 13 s | 4 to 6 s |
| Starting a session | about 4 s, once per chat | about 5 s model load |

## Tests

- Python 154, Swift 211, all passing. The Claude service is tested against a stand-in program, so tests use none of the plan.
- Live, on the plan, with a made-up calendar: `OMNIS_LIVE_TESTS=1 swift test --filter liveClaude`. Reading, a follow-up move with no day named, delete, create, search, search switched off, a refused file request and a switch to Sonnet all behaved; no answer claimed a change was made; nothing was left on disk.

## Review findings

Independent review: pass with warnings. The tool gate was found sound: nothing is allowed without the access checks, a result forged by the model is dropped, and a late request cannot use the next question's permissions.

| Finding | Action |
|---|---|
| Keeping file and shell tools out rested on one option | Fixed. They are also refused by name, and a session that reports any tool OMNIS did not ask for is closed and not used. |
| Quitting could leave Claude Code running | Fixed. Quitting waits for it to go, and forces it if needed. |
| A hung answer would wait for ever | Fixed. Given up on after 150 seconds of silence. |
| `/local off` did nothing after "Answer on this Mac instead" | Fixed. |
| A calendar read failed if a time was sent with the date | Fixed. |
| `claude:` typed while off the grid was silently ignored | Fixed. A notice says so. |
| Any error mentioning "limit" was called a usage limit; error text had no length cap | Fixed. |
| The first question of a run goes through even above a limit, because usage is not known until Claude Code reports it | Left as is. One question at most. |
| A long answer is not cut off when it crosses a limit | Left as is. |
| If OMNIS crashes, Claude Code may keep running until it notices | Not checked. |

The fixes were re-run live but not reviewed a second time.

## Limits and things not verified

- The sliders, usage reading and "answer on this Mac" button have not been seen on screen.
- Whether the effort setting changes mid-chat is accepted by Claude Code but its effect was not measured.
- Attached pictures are sent to Claude in the standard form; not tried live.
- The retired API-key lane is still in the code, unused. Removing it is a clean-up step.
- Project mode is not built.
- The numbered source marks the local model uses do not apply to Claude's answers; the Sources list is still shown.

## Change, 2026-11-24: what Auto chooses

Decided by the user. With Model and Effort on Auto, Claude answers with Sonnet at medium effort. A message that says "deep dive", "think" or "decide" is answered by Opus at high effort. Haiku is used only when picked. A model or effort the user picked is used as picked. The line under an answer now also says the effort.

Checked live in one chat (`OMNIS_LIVE_TESTS=1 swift test --filter liveAuto`): Sonnet answered the first question, Opus the second ("Think: ..."), Sonnet the third, by Claude Code's own count of which model produced words on each turn. Claude Code accepted each change of effort; what difference the effort makes to an answer was not measured.

Any message containing the word "think", such as "I think it's at 5", uses Opus, which uses the plan's allowance faster.
