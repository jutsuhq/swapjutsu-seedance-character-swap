---
name: swapjutsu
description: Swap a person in a video for a character with the Swapjutsu app on this Mac, through its swapjutsu MCP server. Use when asked to replace someone in a clip with a character image, to render or finalize a Seedance character swap, or to find, open or reuse Swapjutsu results.
---

# Swapjutsu

Swapjutsu prepares a video on this Mac for free (shots, people, depth, voice), then renders the swap with Seedance on
Comfy, paid from the person's Comfy credits. You drive the app through the `swapjutsu` MCP server:

```bash
claude mcp add swapjutsu -- /Applications/Swapjutsu.app/Contents/Helpers/swapjutsu mcp
```

Every tool answers with JSON. A failure is a tool error with `code`, `message`, `retryable` and `next`: do what `next`
says rather than guessing.

## How to work

1. **Capabilities first.** Call `capabilities`. If any tool returns `agents_off`, ask the person to turn on
   Settings › Agents › Allow agents in Swapjutsu, then try again. `hasComfyKey: false` means renders can't run until
   the person saves a Comfy API key in Settings; prep still works. A `depthModel` of `missing` is fetched by the first
   prep.
2. **Prep is free, so look before you choose.** `prepare` the video with a `request_id` of your own (repeat it to
   retry safely; the same id returns the same clips, also after a relaunch). Ranges are 4–30 s each, one clip per
   range. Then wait with `clips` (`wait_seconds` up to 60, call again while `stage` is `waiting` or `preparing`).
3. **Check the people before choosing a target.** A prepared clip lists `people`: each with an `id`, a face `crop`
   (a JPEG you can look at), their `screenShare` and whether they are replaced (`isTarget`); `review.mp4` shows who was
   found and the masks. Read the `warnings`. If prep picked the wrong person, `prepare_again` with `target` set to the
   right person ids (or `main` / `all`). That is free too.
   **Control.** `control` on `prepare` or `prepare_again` picks what paints the replaced people in `control.mp4`:
   `depth` (the default, colored depth), `hybrid-hands` (colored depth with their real hands from the footage, for
   exact hands and fingers) or `hybrid-body` (the real person but for the head, for the exact pose; the source's
   clothes may carry into the render). Start with `depth`; try `hybrid-hands` when a render's hands come out wrong.
   `clips` reports it as `controlMode`.
4. **Set the characters.** `set_characters` with one image per replaced person (`person` ids from `clips`, images at
   least 300 px a side, sides within 1:2.5), optionally `remove_background` and a `prompt` with the person's wishes.
   Nothing is spent.
5. **Quote before you render.** `quote` the clip at the quality you mean to render. `high` is the number every limit
   is checked against; `budget.remaining` is what is left of today's agent budget. Tell the person the estimate.
6. **Drafts first.** `render` with `quality: draft` (480p, about 2 min, cheapest), a new `request_id` and a `max_cost`
   no lower than the quote's `high`. Follow it with `clips` or by repeating the same `render` request. Show the draft
   to the person (`show` with `result`, or the `result` path). Only when they like it, `finalize` it at 1080p (same
   motion, within the draft's 7 days, `finalizableUntil`), with its own `request_id` and `max_cost`. Render a
   `final720` or `final1080` straight from the clip only when the person asks for it.
7. **Respect "Waiting for you".** A render whose estimate is over your `max_cost` or over what is left of the daily
   agent budget is made but not sent: its `stage` is `waiting` and `detail` says why. The budget is $0 until the person
   sets one in Settings › Agents. Don't try to get around it with another request: tell the person, who can send it
   in Swapjutsu › Jobs with one click, or raise the budget. A render in stage `unknown` or one the person started is
   theirs to retry (`needs_person`).
8. **Find what was made.** `library_search` lists finished drafts and finals, newest first, with the video's `file`
   path (in `~/Movies/Swapjutsu`, with the clip's own soundtrack), the render and clip ids, quality, when it was made,
   the clip's length and its prompt (cut to 200 characters). Filter with `text` and `quality`; page with `limit` and
   `nextCursor` → `cursor`. `show` opens a `screen`, a `clip` in Create or a `result` in Library for the person.

## Rules

- **Never ask for credentials.** You never see the Comfy key and never need it; if `hasComfyKey` is false, the person
  saves it in Settings › Comfy themselves.
- **Files are uploaded by `swapjutsu`.** Give the tools absolute paths of files on this Mac (`video`, `image`); the
  binary sends their bytes into the app, which can't open your paths itself. A file may be up to 4 GiB. Files the app
  gives back (`control`, `review`, `crop`, `file`, `result`) are in `~/Movies/Swapjutsu` and readable as they are.
- **Nothing deletes.** `job_action` cancels or retries; removing results is the person's call, in the app.
- **One render at a time per clip.** A second one is refused (`busy`) until the first finishes.
- **Reuse ids exactly.** A `request_id` repeated with other parameters is refused (`request_conflict`); use a new one
  for a new request.
