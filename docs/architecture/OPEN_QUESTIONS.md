# OMNIS — questions for Stage 0

Nothing here is pre-approved. Ask in small groups rather than overwhelming the user.

## Experience and UI (discuss interactively before drawing or coding)
- Main app and shortcut popup: which should be MVP, or both?
- Visual references, light/dark behavior, typography, motion, density?
- Popup: input-only or conversation history? How does it expand and dismiss?
- Notch: hover, click, or both? What happens on external monitors/fullscreen?
- Voice: defer, push-to-talk, or wake-word later?

## System design
- Native SwiftUI + AppKit with Python backend, or alternatives?
- Ollama versus MLX runtime for first prototype; compare speed and battery after benchmarks.
- Which commands are deterministic, and how are ambiguous names resolved?
- Should the local model run on battery, or prefer cloud only when explicitly permitted?
- Which directories can OMNIS access, and where should project records live?

## Memory and integrations
- Exact Graphify repository/MCP intended; evaluate before adopting.
- What information is saved automatically versus only after review?
- Which first integrations: local project folders, GitHub, Gmail, Calendar?
- Which actions require per-action confirmation versus scoped prior approval?

## Claude and cost
- Verify API credits in provider console; do not assume subscription covers API calls.
- Which paper/document categories may be uploaded to Claude?
- Per-request and monthly budget caps, cloud opt-in, and fallback behavior?
