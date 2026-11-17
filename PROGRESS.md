# OMNIS — Progress

Last updated: 2026-11-16

## Current stage

**Stage 0 — Discovery and architecture.** Approved 2026-11-16. No product code, no installs, no API use.

- [x] 0a Housekeeping: agent roster, README, `.gitignore`, this file, Git rules in `CLAUDE.md`
- [ ] 0b Round 1: product scope and MVP
- [ ] 0b Round 2: UI co-design
- [ ] 0b Round 3: architecture (stack, local runtime)
- [ ] 0b Round 4: security, memory, cost
- [ ] Decision records written and accepted
- [ ] Stage 1 plan approved

## Approved decisions

| Date | Decision |
|---|---|
| 2026-11-16 | Begin Stage 0 as a planning-only stage. |
| 2026-11-16 | Commits use the existing Git identity (Abhay Chauhan, GitHub noreply email). |
| 2026-11-16 | Verified work is committed and pushed to `origin/main` without asking each time. Messages are 3–6 words, with no co-author or tool attribution. |
| 2026-11-16 | Agent roster: architecture-planner, macos-ux, local-inference, memory-graph, integrations-security, verification-agent. The main session builds and coordinates. |

Nothing about the stack, models, UI, memory, or integrations is decided yet. Everything in `CLAUDE.md` §3–§9 is still a proposal.

## Completed

- 2026-11-16: Read all project docs and agent definitions; checked the local environment.
- 2026-11-16: Stage 0a housekeeping.

## Open decisions (Stage 0b agenda)

1. MVP surface (popup, main app, or both) and stage order. Proposal on the table: build one thin slice first (popup → rule-based router → project registry → open a project in VS Code) before any model work.
2. Stack: Swift app plus Python service, all-Swift, or a web-tech shell.
3. Local runtime: Ollama, MLX, or llama.cpp; one local model or two.
4. Permission model: what needs per-action confirmation and what gets scoped standing approval.
5. UI direction: popup behaviour, main window layout, visual style, motion, status display.
6. Memory: what is saved automatically versus after review; Graphify evaluation.
7. Claude: budgets, which data may be uploaded, exact model IDs.

## Questions waiting on the user

- MVP: popup, main app, or both? Does the thin-slice-first order appeal?
- Two or three apps whose look and feel you like; light/dark and animation preferences.
- The exact Graphify repo or link.
- Is the Claude API funded today, or mocks only?
- Personal use only, or something to distribute? OK to install full Xcode at the app stage?

## Requirements not yet covered by the docs

- Distribution and signing (personal use versus shareable build).
- What "multimodal" means in v1. The base Qwen3 4B/8B models are believed to be text-only; to be verified.
- What handing off to Claude Code or a chat app concretely does.
- Whether conversation history is kept.
- Launch at login.
- Editors other than VS Code.
- A set of real tasks to evaluate routing against.

## Environment notes (checked 2026-11-16)

- Apple M4 Pro, 24 GB RAM, about 507 GB free, macOS 26.5.1.
- Present: Git, Python 3.13, uv, VS Code `code` command, Docker, Homebrew, Node.
- Missing: full Xcode (only Command Line Tools, Swift 5.10), Ollama, GitHub `gh` CLI. Each needs approval before install.
- Verification Agent is pinned to Sonnet; the other agents inherit the session model. Revisit for the security-heavy stages.

## Next step

Stage 0b Round 1: settle the MVP and stage order, then move to UI co-design.
