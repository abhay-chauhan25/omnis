# OMNIS — Claude Code starter pack

OMNIS = **Orchestrated Multimodal Neural Intelligence System**.

The repo holds the planning documents, agent instructions, and the working app so far: a chat window that launches apps and projects, answers questions with a model running on this Mac, and searches the web when a question needs it.

## Contents
- `CLAUDE.md` — project vision, requirements, collaboration/approval rules, architecture proposals, security constraints, staged plan.
- `.claude/agents/` — six scoped Claude Code subagent definitions.

## Getting started
1. Extract this archive into the **root of a new OMNIS project folder**.
2. Open a terminal in that folder and start Claude Code (`claude`).
3. Ask: **“Read CLAUDE.md and the agent definitions. Start Stage 0 discovery only. Do not write code or make design choices until we discuss and approve them. First, help me co-design the UI and confirm the architecture.”**
4. Confirm the installed Claude Code version recognizes the agent definitions; review their tool permissions. Agent files are intentionally conservative, but any actual tool execution must follow the approval rules in `CLAUDE.md`.
5. Approve stages one at a time; ask for the required end-of-stage teaching walkthrough.

## Notes
- The architecture and stack are **proposals**, not pre-approved decisions.
- Claude API access is **not required** to start. Use mocks until the user explicitly enables billing.
- No Gemini or OpenAI API integration is planned.
- For Graphify, provide the exact repository or MCP URL before choosing a tool.

## Running OMNIS

Needs Xcode 26 and Python 3.11 or newer. Two more things are optional, and OMNIS says so in plain words when one is missing:

- **Claude Code**, signed in with a Claude plan, for answers from Claude (the default).
- **Ollama with the local model**, for answering on this Mac: `ollama pull gemma4:12b` (7.7 GB).
- **Docker Desktop, running**, for web search on this Mac. OMNIS starts and stops its own search container. Claude uses its own search.

```sh
macos/scripts/bundle.sh          # builds macos/build/OMNIS.app
open macos/build/OMNIS.app
```

Press Control+Space to show or hide the chat window. Type a question and press Return, or type the name of an app or project to open it. Drag the window by its top strip; it stays open until you hide it with Esc or the close button, and it remembers the conversation until you start a new chat or quit.

Questions are answered by Claude by default, through Claude Code signed in with your own Claude plan (run `claude` once in Terminal and sign in). Claude can act only through OMNIS: it has no file or shell access, and every calendar change is shown as a preview that needs your click. If Claude Code is not installed, OMNIS answers on this Mac.

In the input bar, the globe turns web search on or off. **Model** and **Effort** each open a slider; Auto lets OMNIS choose. The Model slider also holds the **Off the grid** switch, which answers everything with the model on this Mac. The same from the keyboard: `/model sonnet`, `/effort high`, `/local on`, `/local off`. The top strip shows how much of your Claude plan is used; ordinary chats stop using Claude at 80% of the five-hour window or 70% of the week and offer to answer on this Mac.

The Dock icon opens the dashboard, OMNIS's main window. Its **Project** switch shows Claude Code terminals for one of your projects, with OMNIS beside them as an advisor that can read the project's files. Asking OMNIS to "set up a project called …" creates the folder, the git repository and the GitHub repository from a preview you confirm; that needs `git` and a signed-in `gh`.

Launchers, aliases, project folders and the editor are set in `~/Library/Application Support/OMNIS/registry.json`, created on first run. Beside it, `audit.log` records what OMNIS did (never what was typed or answered).

Tests:

```sh
cd macos && swift test
cd backend && python3 -m unittest discover -s tests -t .
cd macos && OMNIS_LIVE_TESTS=1 swift test --filter live    # uses the real models, real web search and your Claude plan
```

Layout: `macos/` is the Swift app (`OmnisCore` for logic, `OmnisApp` for the popup). `backend/` is the Python service the app starts on demand.

## Planning templates
- `PROGRESS.md` — current stage, approved decisions, outstanding tasks, next steps.
- `docs/architecture/OPEN_QUESTIONS.md` — Stage 0 discussion prompts (not decisions).
- `docs/decisions/README.md` — architecture decision record template.
- `docs/stages/STAGE_TEMPLATE.md` — mandatory before/after-stage approval and teaching checklist.

## Multi-agent collaboration
Use the main Claude Code session as coordinator. Ask `architecture-planner` and `macos-ux` for **read-only** options first. Bring their proposals to the user for approval. After approval, delegate isolated implementation tasks to `local-inference`, `memory-graph`, and `integrations-security`. Have `verification-agent` independently review each meaningful implementation. Never run parallel edits against the same files. Subagent output is advice, not approval.
