# ADR-0014 — Project mode: real Claude Code terminals, OMNIS as advisor

- **Status:** Accepted
- **Date:** 2026-11-24

## Problem / context

The user wants to start and work on coding projects from the OMNIS dashboard: set a project up (folder, git, GitHub, editor), then work on it with Claude Code agents they can see and direct, with OMNIS helping on the side.

## Options considered

| Topic | Options | Tradeoff |
|---|---|---|
| What a "terminal" is | OMNIS's own panes showing a session's work as structured cards; the real Claude Code in an embedded terminal | Own panes let OMNIS understand and steer everything, but are not Claude Code. A real terminal gives the user everything Claude Code has and direct control, but OMNIS cannot read or drive the screen. |
| Running several agents | Claude Code's built-in sub-agents inside one session; OMNIS starting separate sessions in separate copies of the code | Built-in is proven and needs nothing from OMNIS. Separate sessions give true side-by-side work at much more cost. |
| What a session may do unasked | Ask for everything; edits and a safe command list free, the rest asked; anything inside the folder | The middle choice keeps work moving while pushes, installs and anything unusual still stop for the user. |
| Drawing a terminal | Write one; use SwiftTerm | A terminal is a large, subtle piece of work. SwiftTerm is the usual open-source choice on the Mac. |

## User decision and date

2026-11-23 and 24: real embedded terminals, with OMNIS as a read-only advisor beside them. Built-in sub-agents to begin with. Edits and safe commands free inside the project folder; anything more must ask. One terminal to start and a "+" for more. Project mode has no usage limits. All stages to be built.

**Changed 2026-11-24:** the user decided a project session should carry no restrictions from OMNIS. Sessions now start as the user's normal Claude Code, with whatever permission settings they already have. The earlier rule (edits and a safe command list free, the rest asked) no longer applies. The advisor's limits are unchanged.

## Consequences / risks

- **First third-party dependency in the app:** SwiftTerm (MIT), which brings swift-png, a small hashing library (Apache 2.0) and Apple's argument parser. Used only for the terminals.
- A project session is the user's own Claude Code: it loads their settings, memory files and connected tools, and saves its sessions, unlike OMNIS's own chats. Permission questions are asked by Claude Code in the terminal, not by OMNIS cards.
- What a session may do without asking is decided by the user's own Claude Code settings, not by OMNIS.
- OMNIS does not stand between the user and a session. It can place text in a terminal's input but never sends it.
- The advisor is a separate, locked-down session: it can read files in the one project folder, except files that usually hold secrets, and can do nothing else.
- "What the session is doing" is read from Claude Code's own session files, whose layout may change. If it does, that panel shows less; the terminals are unaffected.
- Setting up a project creates a GitHub repository and pushes to it. It is only ever done from a preview the user confirms, and public or private is always asked.
- With no usage limits, several agents can use the weekly allowance quickly. The meter stays visible.

## Revisit trigger

The embedded terminal proves unreliable with Claude Code's interface; built-in sub-agents are not enough; the user wants OMNIS to drive sessions.
