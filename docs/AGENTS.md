# Agents

The app includes `swapjutsu`, an MCP server through which an agent such as Claude Code can operate it:

```bash
claude mcp add swapjutsu -- /Applications/Swapjutsu.app/Contents/Helpers/swapjutsu mcp
```

Agent access is off until you enable Settings › Agents › Allow agents; until then every tool returns `agents_off`.
If the app is not running, the first call starts it in the background.
[skills/swapjutsu/SKILL.md](../skills/swapjutsu/SKILL.md) describes how an agent should use it, and
[ARCHITECTURE.md](ARCHITECTURE.md#agents) how it is built.

## Tools

| Tool | Description |
|---|---|
| `capabilities` | App version, whether a Comfy key is saved, and the depth model's state |
| `show` | Opens a page (`create`, `jobs`, `library`, `settings`), a clip in Create or a result in Library, and brings the window forward |
| `prepare` | Prepares a `video` in one or more 4–30 s `ranges`, with `target`, `face_guide` and `control`; returns one clip per range. A `request_id` makes the call idempotent, including across relaunches |
| `clips` | Status of one clip or all, waiting up to 60 s for preparation: stage, progress, detected people with a face crop and screen share, warnings, and the paths of `control.mp4` and `review.mp4` |
| `set_characters` | Sets a character image per replaced person, Cut out characters and the prompt |
| `prepare_again` | Re-prepares a clip with a different `target`, `face_guide` or `control` |
| `quote` | Estimated cost of rendering a clip at `draft`, `final720` or `final1080`, and the remaining daily agent budget |
| `render` | Paid render of a prepared clip, with a `request_id` and a `max_cost` |
| `finalize` | Paid 1080p final of a finished draft within its 7-day window, with a `request_id` and a `max_cost` |
| `job_action` | Cancels or retries a render or a clip's preparation |
| `library_search` | Finished drafts and finals, newest first, with file paths, ids, quality, dates, length and prompt; supports `text` and `quality` filters and paging |

## Spending controls

Agents can spend only within Settings › Agents › Daily agent budget, which is $0 until you set it; until then they
can request quotes but not render. Before every paid request an agent makes, including retries, the app checks the
upper bound of the price estimate against the render's `max_cost` and against the remaining daily budget, counting
agent renders already in flight. A render that exceeds either limit waits in Jobs under "Waiting for you" with the
reason, and only you can send it. Your own renders do not count against the agent budget. Jobs shows which agent
started each clip or render, when, and the cost it allowed.

Agents cannot:

- **Delete anything.** No tool removes a clip, render or file; `job_action` only cancels or retries.
- **Cancel your renders.** `job_action` cancels only renders an agent started, and never retries a final
  whose draft already has another one.
- **Read credentials.** `capabilities` reports whether a Comfy key is saved, never the key itself.
- **Act while disabled.** Allow agents is checked on every command, so disabling it stops an agent at its next call,
  including on connections opened earlier.
- **Exceed your limits.** The budget check runs inside the app before every paid request, not in `swapjutsu`, so no
  client can bypass it.
