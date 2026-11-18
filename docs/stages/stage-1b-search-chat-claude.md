# After Stage 1 — Web search, a new local model, the chat window, and the Claude lane

Built on 2026-11-17. Each part was approved by the user in conversation before it was built; the decisions are ADR-0007 to ADR-0010.

## What changed

| Part | Decision | Where |
|---|---|---|
| Web search | ADR-0008 | `macos/Sources/OmnisCore/WebSearch.swift`, `backend/omnis_backend/engine.py` |
| One local model, `gemma4:12b` | ADR-0007 | `backend/omnis_backend/engine.py`, `docs/benchmarks/model-bake-off.md` |
| Chat window with conversation memory | ADR-0010 | `macos/Sources/OmnisApp/Chat*.swift`, `macos/Sources/OmnisCore/Conversation.swift` |
| Claude lane with fallback to local | ADR-0009 | `backend/omnis_backend/claude.py`, `router.py`, `macos/Sources/OmnisCore/CloudLane.swift` |

## Teaching handoff

### 1. What was built

- The model can ask for a web search. The app runs it through SearXNG in Docker and shows numbered, clickable sources under the answer.
- `gemma4:12b` replaced both Qwen3 models after a measured comparison.
- The one-shot popup became a chat window that can be moved, stays open, and remembers the conversation for the session.
- A lane for Claude: public questions go to Claude when a key is saved and credit exists; otherwise the local model answers and says why.

### 2. Why this approach

- **The app acts, the model asks.** A search is the first thing a model can cause to happen. Keeping the action in Swift means the rule "the model can never do anything but ask" stayed true as that first capability arrived.
- **Choose models by measurement.** The first models were slow for a reason that only showed up under test. Published claims would not have revealed it.
- **Route by data, not difficulty.** What the user cares about is which information leaves the Mac. Making that the routing rule turns a preference into something the app can guarantee.
- **Fall back, but say so.** With no credit, the useful behaviour is to answer locally. The label keeps that honest.

### 3. How it works

A question typed into the chat window:

1. `ChatModel.send` works out the lane and whether web search is on, asks `UsageLedger` whether Claude is within budget, and sends the question with the earlier turns of the chat.
2. `BackendService` passes it to the Python service as one JSON line. If a Claude key is in the Keychain it was handed to the service when the service started.
3. `router.decide` picks local or Claude. Claude is chosen only if a client exists, the app allowed it, and it is not resting after a failure.
4. Local: `LocalEngine._local` talks to Ollama. Claude: `LocalEngine._cloud` picks the model (`claude.choose_model`), checks the worst-case cost against the limit, and talks to the Claude client.
5. If the model asks for a search, the engine yields a `ToolRequest`. The service sends `tool_request`; `BackendService.runTool` checks it is a web search and that web is on, then `SearXNGSearch` starts the container if needed and fetches results. They go back as `tool_result`, marked as untrusted text with today's date.
6. The answer streams back in pieces. The last message carries the model, route, token counts, cost, and any fallback reason.
7. `ChatModel` shows the line under the answer, records cost in `claude-usage.csv` if Claude answered, and writes numbers only to `audit.log`.

Rules enforced by the app, whatever the model or backend says:

- Only a web search can be requested; anything else is refused.
- No search when web is off for that question.
- Only `https` results are kept, and only listed sources can be opened.
- Links inside answer text are never clickable.
- A chat with any turn kept local stays local until a new chat.
- Claude is not allowed once the month's limit is reached.

### 4. How to run and test it

```sh
macos/scripts/bundle.sh
open macos/build/OMNIS.app
```

Docker Desktop must be running for web search. Press Control+Space.

| Try | Expect |
|---|---|
| `who wrote Pride and Prejudice`, then `when was she born?` | The follow-up is answered: it remembers |
| `who won the 2026 FIFA World Cup` | A search, then an answer with a Sources list |
| The globe button, then the same question | No search |
| `open ghidra`, Return | Ghidra opens; the window stays |
| Drag the top strip; click another app | It moves and stays open |
| Menu-bar icon → Claude API Key… | A field to save a key in the Keychain |

Tests:

```sh
cd backend && python3 -m unittest discover -s tests -t .
cd macos && swift test
cd macos && OMNIS_LIVE_TESTS=1 swift test --filter live     # real model, real search
```

### 5. What was verified, and what was not

Verified:

- 109 Python and 118 Swift tests.
- Live runs with the real model: a plain answer, a web search answer with sources, a follow-up that needs the earlier turn.
- The built app starting the search container, searching, and stopping it.
- The empty chat window, by screenshot.
- Independent review of the search, model switch and chat window: pass with warnings, findings fixed (see below).
- Independent review of the Claude lane: acceptable while it runs against a stand-in, not yet a pass for live use. Its findings are fixed (see below) but the fixes have not been reviewed again.

Not verified:

- **The real Claude connection.** It has never run: the `anthropic` package is not installed and there is no credit. Everything around it is tested with a stand-in.
- How messages, sources and the launch strip look in the window.
- VoiceOver.
- Energy use.

### 6. Review findings

| Finding | Action |
|---|---|
| "Searched the web" was shown when the search had failed | Fixed. Only searches that returned results are counted |
| Sources could appear for an answer that never received them, if the search was slow | Fixed. The app gives up before the backend does, and a late result is dropped |
| A "+" in a question was lost ("C++" searched for "C") | Fixed |
| A very long chat could exceed the message size limit and break the chat | Fixed. History is limited on both sides, in whole exchanges |
| History could begin with an answer whose question was cut off | Fixed |
| Quitting during the first search could leave the container running | Fixed |
| A hand-edited search settings file was overwritten without a copy | Fixed. A backup is kept |
| A search result could be attached to a different request the model had made | Fixed |
| Polite launch wording ("can you open safari") was sent as a message | Fixed |
| The window could be stranded off-screen after a monitor was unplugged | Fixed |
| A redirect from the search service could send a query elsewhere | Fixed. Redirects are refused |
| What was searched for was never shown | Changed. The search terms are shown while searching and under the sources |

Claude lane review:

| Finding | Action |
|---|---|
| After two searches, the follow-up request left out the tool definition, which the real service rejects | Fixed. The tool stays defined and Claude is told it may not call it again. The stand-in now rejects the bad shape too |
| Cost was recorded only when an answer finished normally | Fixed. Cost is reported and recorded after every Claude turn, so a stopped, refused, failed or fallen-back answer still counts |
| A request already billed could be sent again after a backend restart | Fixed. A billed request is never resent automatically |
| Deleting or damaging the usage file reset the month's spending | Fixed. The total is kept in a second place and the larger figure is used. If the file cannot be written, Claude is not allowed |
| The key was passed in the environment, where other programs of the same user can read it | Fixed. It is sent as a message over the pipe and held in memory. Nothing Anthropic-related is inherited from the environment |
| With a key saved but the library missing, answers were local with no explanation | Fixed. The line under the answer says why |
| An answer cut off at the length limit looked complete | Fixed. It says it was cut off |
| Saving a new key deleted the old one first | Fixed. The old key survives a failed save, and the failure is shown |
| Everyday questions containing "architecture" or "proof", or about the Opus audio format, chose a dearer model | Fixed |
| "with Claude Code" was read as a request for Claude | Fixed |

Open after the Claude lane review:

- The real connection is still unrun. The library's handling of the effort setting, of replayed reasoning blocks, and of a low-credit error can only be confirmed by a live call.
- The cost of a turn that is stopped mid-way is not known to OMNIS until the service reports it, which it does not for an interrupted stream. Such a turn is not counted.
- Prices are built in and dated. They must be checked against the live list before going live.
- An answer given locally because Claude was unavailable does not mark the chat as local. Its text can be sent to Claude as history later. This matches ADR-0009 (it was a public question), and it needs the user's confirmation.

Left as they are, with reasons:

- The search container's image is not pinned to a fixed version. Search engines change often and the project's updates follow them.
- The search service's port on this Mac has no password. It is reachable only from this Mac.
- A search still runs to completion after the user presses stop.
- Tables and nested lists in answers are shown as typed.
- The app target has no automated tests; its logic is tested through the core library.

### 7. Security, memory, battery and cost

- **Leaves the Mac:** search terms, to the search engines. With a Claude key saved: public questions and that chat's history, to Anthropic.
- **Never leaves the Mac:** anything in a chat with a turn kept local; the audit log; the usage record.
- **Memory:** 7.7 GB while the local model is loaded, nothing when idle. The search container uses about 150 MB while running.
- **Cost:** nothing without a key. With one, the estimate is about 1 USD a month for everyday questions on the smallest Claude model, measured only once real use begins.
- **A known weakness:** a web page can still mislead the model about facts. It cannot make the app do anything.

### 8. What you should understand or try next

- Compare the same current-events question with web on and web off.
- Read `~/Library/Application Support/OMNIS/audit.log` after a few questions: it should hold no question or answer text.
- This model gets roughly 77 to 88 percent of current-events questions right. Check anything that matters against its sources.

### 9. Decisions needed

- Installing the `anthropic` package and going live with Claude, once credit is verified.
- What comes next: image and PDF input, the main window (Stage 2), or the first personal-data integration.
