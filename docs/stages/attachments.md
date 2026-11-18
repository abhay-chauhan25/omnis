# Image and file attachments

Built on 2026-11-17 at the user's request. The attach button was part of the chat window design in ADR-0010; the rules below follow ADR-0009.

## What was built

The chat window accepts images, PDFs and text files, up to four per message:

- the "+" button in the input bar,
- dragging a file onto the window,
- pasting a screenshot or copied files with Command-V.

## Rules

| Rule | Why |
|---|---|
| A message with a file is answered by the model on this Mac, never by Claude | A file is personal data (ADR-0009) |
| A chat that has had a file stays local until a new chat | A later question would otherwise carry the file, or answers about it, elsewhere |
| No web search in a chat that has had a file | The model could put text from the file into a search |
| A document's text is fenced and marked as material, not instructions | A file must not be able to direct the assistant |
| The audit log records counts only | File names can be private |

## How it works

1. `ChatModel.attach` hands each file to `AttachmentLoader.load`, off the main thread.
2. The loader follows a shortcut to the real file, refuses anything that is not an ordinary file, and never reads more than 30 MB.
   - A picture is scaled so its longest side is at most 1568 pixels and stored as JPEG.
   - A PDF has its text read page by page, stopping once 60,000 characters are found. A PDF with no text is treated as a scan: its first two pages are passed as pictures.
   - A text file is read as text. Rich-text and binary files are refused.
3. `AttachmentLimits.fit` keeps the total document text in one message to 60,000 characters and tells the user what was cut or left out.
4. `ChatModel.send` sets the lane to local and web search off, and marks the chat.
5. The files travel to the Python service with the question. `engine._message` puts document text inside a fence and passes pictures to the model.
6. The most recent files travel with later questions in the same chat, so follow-ups work.

## Verified

- 138 Swift and 118 Python tests.
- With the real model, through the whole chain: a number read from a picture of text, a follow-up about the same picture, and a fact drawn from a document.
- Independent review: pass with warnings. Findings and actions are below.

Not verified:

- How attached files look in the window.
- Memory and speed with a full-size document. A document switches the model to a larger reading window (24,576 tokens against 8,192), which costs memory and may reload the model. Neither was measured.

## Review findings

| Finding | Action |
|---|---|
| A chat whose file had dropped out of the history could search the web with answers about the file still in view | Fixed before the review reported. The app remembers the chat has had a file |
| A shortcut to an endless or oversized file bypassed the size check | Fixed. The real file is checked, only ordinary files are read, and reading is bounded |
| Large files were read on the main thread | Fixed. Reading happens in the background with a "Reading" note |
| A long PDF was read in full before being cut | Fixed. Reading stops once enough text is found |
| Several documents together could exceed what the model can read, and be cut silently | Fixed. The total is limited and the user is told |
| Command-V was detected by key position, so it failed on other keyboard layouts | Fixed |
| A copied picture that came with a web address was pasted as text | Fixed |
| A document could contain the fence's closing line and add text that looked like it came from outside | Fixed. Fence-like lines inside a document are defused |
| Rich-text markup was accepted as text | Fixed. It is refused |
| A very detailed picture could exceed the message size and fail late | Fixed. It is re-encoded smaller, or refused with a reason |

## Known limits

- The model reads text in pictures well and charts well. It is weaker on bare visual judgements: it called a plain red square brown.
- Text inside a picture is not fenced the way a document is. With no tools available in a file chat, the most a hostile picture can do is skew the answer.
- Only the first 60,000 characters of documents are read, and only the first two pages of a scanned PDF.
- Word documents and spreadsheets are not supported.
- Files cannot be sent to Claude. That would need the per-file confirmation of ADR-0006.
