# swapjutsu-prep

The command-line tool runs the same on-device preparation as the app and writes everything Seedance needs into one
folder. It does not render: generation happens in the app or through [the agent tools](AGENTS.md).

## Build and run

The app downloads its models itself. `swapjutsu-prep` reads them from `Models/`, which the fetch script fills:

```bash
scripts/fetch-models.sh
swift build -c release
.build/release/swapjutsu-prep my-clip.mov
```

## Output

Written to `my-clip-prep/`:

| File | Contents |
|---|---|
| `control.mp4` | The person to replace, painted with colour-mapped depth over the original; sent to Seedance as `@Video1` |
| `review.mp4` | Every person tinted by identity, with the target highlighted |
| `identities/*.jpg` | One crop per person |
| `mask.mp4`, `prepared.mp4` | The target mask and the normalised original |
| `manifest.json` | Every decision, quality metrics, warnings and the Seedance prompt |

## Options

| Option | Effect |
|---|---|
| `--target main\|all\|2,3` | Who to replace: the main subject (default), everyone, or specific person numbers |
| `--control depth\|hybrid-hands\|hybrid-body` | How the target is drawn: all depth (default), the real hands kept, or the whole body kept except the head |
| `--max-seconds <4–30>` | Maximum clip length |
| `--replace-background` | Grey depth around the targets instead of the original, for a new location |
| `--keep-music` | Pitch-shift the whole mix instead of the isolated vocals |
| `--face-guide` | Draw face landmarks for lip sync where the face is at least 3 % of the frame height (off by default; Seedance may render them into the face) |
| `--no-review` | Skip `review.mp4` |
| `--out <dir>`, `--model <path>`, `--tracking-models <dir>` | Output folder and model locations |

`swapjutsu-prep --help` lists every option. Unknown options, malformed values and person numbers that do not exist
in the clip are rejected with an explanation.

What each stage does with these options is described in [stages/](stages/README.md).
