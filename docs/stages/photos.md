# Photos, reading only

**Status:** built on 2026-11-24. Tested with a stand-in library, and once live through Claude with a made-up picture. Not yet run against the real photo library: that needs the macOS permission prompt, which is the user's to answer.

## What was built

- Claude can ask OMNIS to list photos by date range, album, favourites or screenshots (`photos_search`), to list album names (`photos_albums`), and to look at up to four photos (`photos_show`).
- A listing says only when each photo was taken and whether it is a favourite or a screenshot. Where it was taken is never included (decided by default; the user was asked and did not choose otherwise).
- A photo handed to Claude is a smaller copy (longest side 1,568 pixels), stored again as a JPEG, which drops the location and camera details kept inside the original.
- One answer is shown four photos at most, however the requests are split.
- Showing a photo marks the chat as holding personal information, so the search question applies (`guard-rails.md`).
- The line under the answer says "Looked through your photos" and "Showed 2 photos to Claude". Both are in the audit log; no dates, albums or pictures are.

## How it works

1. `PhotosTools` (`macos/Sources/OmnisCore/Photos.swift`) follows the same pattern as the other services. It talks to a `PhotoLibrary`; the real one, `PhotoKitLibrary`, uses Apple's PhotoKit.
2. Claude names photos by short ids (`p1`, `p2`) that OMNIS made up in the listing. The library's own identifiers never reach the model, and an id that was not listed loads nothing.
3. `ClaudeService` passes the pictures back with the tool's reply (`_images`), and `backend/omnis_backend/claude_tools.py` hands them to Claude Code as pictures. That program still reads nothing itself.

## Permission

macOS has no read-only level for Photos: the one permission also covers changes. OMNIS asks for it the first time a photo is wanted, and contains no code that adds, changes or deletes a photo. Like every permission OMNIS holds, it is shared with programs OMNIS starts, including project-mode terminals.

## Tests

- Swift 256, Python 120, all passing. New: listings carry dates only and never the library's identifiers; bad dates are refused; pictures are made smaller; unknown ids load nothing; four per answer; showing a photo makes the next search ask.
- Live, once: `OMNIS_LIVE_TESTS=1 swift test --filter livePhotos`. Claude was handed a plain red test picture through OMNIS and said it was red.

## Review findings

Independent review: pass with warnings. Nothing was found that changes a photo, and location does not survive the smaller copy (now tested).

| Finding | Action |
|---|---|
| An id from an earlier chat could still be used to look at a photo | Fixed. An id works for ten minutes after a search listed it. |
| Loading a photo kept only in iCloud could wait for ever | Fixed. Given up on after 30 seconds; answered once only. |
| A picture dropped on the way was not mentioned to the model | Fixed. It is told how many were left out. |
| Any tool's reply could have carried pictures | Fixed. Only `photos_show` can. |
| Album names are given to the model, and a name can say where photos were taken | Left as is, for the user to decide. |

## Limits and things not verified

- The real library has not been read. Albums, favourites, screenshots and photos kept only in iCloud are untried.
- Photos cannot be searched by what they show; Apple does not offer that search to other apps. Claude narrows by date or album and then looks.
- Videos and Live Photos are not included.
- The chat does not show thumbnails of what was sent, only the count.
- Offered to Claude only, not to the model on this Mac.
