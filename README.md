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

- **Ollama with the local model**, for answers: `ollama pull gemma4:12b` (7.7 GB). Without it the window still launches things.
- **Docker Desktop, running**, for web search. OMNIS starts and stops its own search container.

```sh
macos/scripts/bundle.sh          # builds macos/build/OMNIS.app
open macos/build/OMNIS.app
```

Press Control+Space to show or hide the chat window. Type a question and press Return, or type the name of an app or project to open it. Drag the window by its top strip; it stays open until you hide it with Esc or the close button, and it remembers the conversation until you start a new chat or quit.

In the input bar, the globe turns web search on or off and the menu chooses where a question is answered: Auto, Local, or Claude. Typing `offline:`, `local:` or `claude:` before a question does the same for one message.

Questions are answered on this Mac unless a Claude API key has been saved from the menu-bar icon. With a key, public questions go to Claude; anything kept local stays local, and if Claude cannot be used OMNIS answers locally and says why. The live Claude connection also needs the `anthropic` Python package, which is not installed by default.

Launchers, aliases, project folders and the editor are set in `~/Library/Application Support/OMNIS/registry.json`, created on first run. Beside it, `audit.log` records what OMNIS did (never what was typed or answered) and `claude-usage.csv` records what Claude has cost.

Tests:

```sh
cd macos && swift test
cd backend && python3 -m unittest discover -s tests -t .
cd macos && OMNIS_LIVE_TESTS=1 swift test --filter live    # uses the real model and real web search
```

Layout: `macos/` is the Swift app (`OmnisCore` for logic, `OmnisApp` for the popup). `backend/` is the Python service the app starts on demand.

## Planning templates
- `PROGRESS.md` — current stage, approved decisions, outstanding tasks, next steps.
- `docs/architecture/OPEN_QUESTIONS.md` — Stage 0 discussion prompts (not decisions).
- `docs/decisions/README.md` — architecture decision record template.
- `docs/stages/STAGE_TEMPLATE.md` — mandatory before/after-stage approval and teaching checklist.

## Multi-agent collaboration
Use the main Claude Code session as coordinator. Ask `architecture-planner` and `macos-ux` for **read-only** options first. Bring their proposals to the user for approval. After approval, delegate isolated implementation tasks to `local-inference`, `memory-graph`, and `integrations-security`. Have `verification-agent` independently review each meaningful implementation. Never run parallel edits against the same files. Subagent output is advice, not approval.
