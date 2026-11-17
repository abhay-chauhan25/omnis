# OMNIS — Claude Code starter pack

OMNIS = **Orchestrated Multimodal Neural Intelligence System**.

The repo holds the planning documents, agent instructions, and the working app so far: a popup that launches apps and projects and answers questions with models running on this Mac.

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

Needs Xcode 26 and Python 3.11 or newer. For real answers it also needs Ollama with the two models (`ollama pull qwen3:4b` and `ollama pull qwen3:8b`); without Ollama the popup still launches things and gives mock replies.

```sh
macos/scripts/bundle.sh          # builds macos/build/OMNIS.app
open macos/build/OMNIS.app
```

Press Control+Space, type, and press Enter. Esc closes the popup. Quit from the menu-bar icon or the Dock.

Questions are answered on this Mac. Start a question with `claude:` to route it to Claude (a labelled stand-in until live use is approved) or `local:` to keep it local whatever it says.

Launchers, aliases, project folders and the editor are set in `~/Library/Application Support/OMNIS/registry.json`, created on first run. Actions are recorded in `audit.log` beside it.

Tests:

```sh
cd macos && swift test
cd backend && python3 -m unittest discover -s tests -t .
cd macos && OMNIS_LIVE_TESTS=1 swift test --filter live    # uses the real models
```

Layout: `macos/` is the Swift app (`OmnisCore` for logic, `OmnisApp` for the popup). `backend/` is the Python service the app starts on demand.

## Planning templates
- `PROGRESS.md` — current stage, approved decisions, outstanding tasks, next steps.
- `docs/architecture/OPEN_QUESTIONS.md` — Stage 0 discussion prompts (not decisions).
- `docs/decisions/README.md` — architecture decision record template.
- `docs/stages/STAGE_TEMPLATE.md` — mandatory before/after-stage approval and teaching checklist.

## Multi-agent collaboration
Use the main Claude Code session as coordinator. Ask `architecture-planner` and `macos-ux` for **read-only** options first. Bring their proposals to the user for approval. After approval, delegate isolated implementation tasks to `local-inference`, `memory-graph`, and `integrations-security`. Have `verification-agent` independently review each meaningful implementation. Never run parallel edits against the same files. Subagent output is advice, not approval.
