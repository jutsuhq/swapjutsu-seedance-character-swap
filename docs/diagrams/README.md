# How-it-works diagrams

One HTML page per diagram, 1200 × 675, in the app's colors and display font (`diagram.css`). The PNGs in
`docs/assets/how-it-works/` are rendered from them at 2× and are what the README, the docs and posts use.

```bash
scripts/render-diagrams.sh               # all of them
scripts/render-diagrams.sh 03-motion     # one
```

Rendering needs Google Chrome. The frames in `img/` come from real jobs in `~/Movies/Swapjutsu` (prepared clip,
control video, Seedance draft, character inputs); the beats on `03-motion` are `PoseBeats` on the cloister clip, and
the prompt on `05-prompt` is `ServicePrompt` filled through `swapjutsu-describe --replay`.

| Page | Shows |
|---|---|
| `00-overview` | the whole flow: clip in, six steps on the Mac, the render, the result |
| `01-people` | shot cuts, a mask per person, identities across cuts |
| `02-tracking` | EdgeTAM on the Neural Engine, its memory and the Vision fallback |
| `03-motion` | the pose tracker's timed beats and what the vision model writes from them |
| `04-character` | the character image read into the prompt's fields, the face close-up |
| `05-prompt` | the prompt, colored by where each part comes from |
| `06-control` | the control video, the vocals, a replaced background |
| `07-render` | draft, final and finish, with the price of each resolution |
| `08-agents` | the MCP server and the daily agent budget |
