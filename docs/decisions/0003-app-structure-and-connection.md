# ADR-0003 — App structure and the app-to-backend connection

- **Status:** Accepted
- **Date:** 2026-11-16

## Problem / context

`CLAUDE.md` §3 suggests a Swift app with a Python orchestration service but asks that the split, the connection between the halves, and the process lifecycle be discussed first. OMNIS must be always reachable without always computing, and everyday launch commands should not need an AI model.

## Options considered

**Structure**

| Option | For | Against |
|---|---|---|
| A. Swift app + always-on Python service | Best AI, PDF and Claude libraries | Second process always running; simple launches wait on Python |
| B. All Swift | One process, lowest idle cost, simplest packaging | Fewer AI and PDF libraries, slower iteration |
| C. Web shell (Tauri or Electron) | Fast UI iteration | Not native; glass, notch and hotkey work get harder; higher idle RAM |
| D. Swift core + on-demand Python "brain" | Launches never touch Python; idle is one native app; AI work keeps Python's libraries | Two languages and a protocol between them |

**Connection (for A or D)**

| Option | For | Against |
|---|---|---|
| Child process over pipes, JSON messages | No network port; Python exits with the app | Harder to poke by hand |
| Local web server on a socket file | Standard tools for testing | Needs supervision against orphan processes |
| Local web server on a network port | Easiest to debug | Reachable by any local program; needs its own token check |

## Recommendation

Option D with a child process over pipes.

## User decision and date

2026-11-16, accepted:

1. **Structure: option D.**
   - The Swift app owns the UI, the rule-based router, the registry, permission checks, and the execution of every action.
   - The Python service is started only when a request needs AI, and stops when idle. It proposes actions and produces answers. It never executes actions itself.
2. **Connection: child process over pipes.** The app starts the Python service and exchanges JSON messages with it over standard input and output. No network port is opened.
3. **Requirement added by the user:** in the finished product the popup must be able to answer questions and display the answers inside the popup, not only launch things.

## Consequences / risks

- The safety boundary is structural: authorisation and execution live in Swift, outside any model (`CLAUDE.md` §6).
- macOS permission grants attach to the app, which is also the part that performs actions.
- The message protocol between the halves must be versioned, typed and tested on both sides. It must support streamed answers and cancellation so the popup can show an answer as it arrives.
- The popup layout must leave room to grow downward into an answer area (affects ADR-0002's "revisit" clause).
- Starting Python on demand adds a delay to the first AI request after idle. This must be measured, not assumed.
- Packaging later has to ship a Python runtime inside or beside the app. Deferred to Stage 7; during development the service runs from the repo with `uv`.
- The local model runtime and the number of local models are not decided here. They are measured in Stage 1.

## Revisit trigger

Start-up delay or reliability of the on-demand service is poor in the thin slice, or the protocol between the halves becomes a larger maintenance cost than the Python libraries save.
