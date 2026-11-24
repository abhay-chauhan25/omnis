# Project mode

**Status:** all stages built on 2026-11-24. Core logic tested; the advisor tested live. **The Project view itself has not been seen on screen, and no real project has been set up**: both need the user. Independent review pending. Decision record: ADR-0014.

## What was built

1. **Project setup.** "Set up a project called X" in the chat. Claude proposes it through one OMNIS tool; a preview card lists the folder, the GitHub repository and whether it is public or private (always asked), and the steps. On "Create Project" OMNIS runs fixed steps itself: create the folder with a README, start git, first commit, create the GitHub repository and push, open it in the editor.
2. **Project view.** A Dashboard / Project switch at the top of the main window. Project replaces the panels with terminals on the left and OMNIS on the right.
3. **Terminals.** Each is the real Claude Code, started in the project's folder. New session, resume the last one, or start from a written brief. Tabs, with a "+" for more.
4. **Advisor.** A side chat that can read the project's files and answer questions. "Put in terminal" places its suggested prompt in the terminal's input for the user to read and send.
5. **Following along.** The latest steps and task list of the project's most recent session, and the files git reports as changed. The advisor is given the same summary with each question.

## How it works

- `OmnisCore/ProjectSetup.swift`: `ProjectPlan` (checked name, folder must not exist, stated visibility), `ProjectSetup.perform` (the fixed steps, each a program with arguments, never a shell).
- `OmnisCore/ProjectSession.swift`: the options a session starts with (`arguments`), the safe command list, starting through the login shell (`launch`), reading session files (`SessionTranscripts`), changed files, and which files the advisor may read (`ProjectFiles.mayRead`).
- `OmnisCore/ClaudeService.swift`: the `advisor` profile: read tools only, secret files refused by Claude Code itself, reads outside the folder refused by OMNIS, no settings or connected tools loaded, nothing saved.
- `OmnisApp/ProjectModeModel.swift` and `ProjectModeView.swift`: the terminals (SwiftTerm), tabs, the advisor chat and the activity panels. The activity is refreshed every 5 seconds, only while the view can be seen.

## Rules

- A session may change files in its project folder and run: git status, diff, log, show, branch, add and commit; ls and pwd; and the usual build and test commands. Everything else, including pushing and installing, Claude Code asks for in the terminal.
- The advisor cannot change anything, run anything or read outside the project, and does not read `.env` files, keys and similar.
- A new project is created only from a confirmed preview, once. A failed set-up is not re-run, because part of it may exist; the card says where it stopped.
- Quitting OMNIS with sessions running asks first.

## Tests

- Swift 238, Python 154, all passing. Covered: plan checks, the setup steps and their order, stopping on failure, the session options (a brief cannot become an option), the safe list, reading session files, what the advisor may read, and the confirm-once rule.
- Live (`OMNIS_LIVE_TESTS=1 swift test --filter liveAdvisor`): the advisor read a file in a test project, refused a file outside it, refused `.env` (after a first run in which it read one, which led to the fix), did not reveal the secret when asked to search for it, and changed nothing.
- Checked by hand with the real program: with the session options, an agent edited and created files in its folder and was refused a read outside it.

## Limits and things not verified

- **The Project view on screen:** how the terminal draws Claude Code, typing, copy and paste, resizing, tabs, the brief popover.
- **A real project set-up:** no repository has been created by this code. The first run is the user's.
- Whether "search" by the advisor is blocked from secret files by Claude Code, or only declined by the model in the test.
- Sub-agents' work is not listed step by step in the activity panel, only that one was started.
- Sessions use whatever model the user's Claude Code is set to; there is no model picker in the Project view.
- No usage warning beyond the meter in the header.
- Closing a tab ends its session without asking.
