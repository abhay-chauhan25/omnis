# OMNIS — Claude Code starter pack

OMNIS = **Orchestrated Multimodal Neural Intelligence System**.

This starter pack contains **planning and agent instructions only**; it does not install dependencies or implement the assistant.

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

## Planning templates
- `PROGRESS.md` — current stage, approved decisions, outstanding tasks, next steps.
- `docs/architecture/OPEN_QUESTIONS.md` — Stage 0 discussion prompts (not decisions).
- `docs/decisions/README.md` — architecture decision record template.
- `docs/stages/STAGE_TEMPLATE.md` — mandatory before/after-stage approval and teaching checklist.

## Multi-agent collaboration
Use the main Claude Code session as coordinator. Ask `architecture-planner` and `macos-ux` for **read-only** options first. Bring their proposals to the user for approval. After approval, delegate isolated implementation tasks to `local-inference`, `memory-graph`, and `integrations-security`. Have `verification-agent` independently review each meaningful implementation. Never run parallel edits against the same files. Subagent output is advice, not approval.
