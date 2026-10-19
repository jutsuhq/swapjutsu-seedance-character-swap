# Pipeline

What happens to a clip from import to the finished video, and where each step runs. Every step links to its page in
[`stages/`](stages/README.md), with the method, the measurements and the references.

## The idea

![How Swapjutsu works](assets/how-it-works/00-overview.png)

The person to replace is painted with coloured depth; every other pixel of the original stays untouched. Seedance
gets this control video as `@Video1` and the character as `@Image1`, and redraws only the painted region: same
camera, background and timing, a different person.

```
clip + character images + place image (optional) + your prompt (optional)
   │
   ├─► prep, on the Mac ───────────► control.mp4 (@Video1) + face close-ups + manifest.json
   ├─► description, on the Mac ────► who is who, outfit, outer layers, camera, timed moves
   └─► prompt ─────────────────────► one prompt, your instructions folded in
                                         │
                                         ▼
                Seedance 2.5 edit ─► 480p draft ─► approved ─► 1080p final
                final video = generated picture + the original soundtrack
```

## Steps

| # | Step | Where | What | Page |
|---|---|---|---|---|
| 1 | Normalise | Mac | 24 fps, upright, longest side ≤ 960 px and at least 409,600 px in total, at most 30 s | [01](stages/01-decode.md) |
| 2 | Shot cuts | Mac | Feature-print jump > 0.6 or RGB-histogram jump > 0.05; sideways shots turned upright for analysis | [02](stages/02-shot-cuts.md) |
| 3 | People | Mac | Vision person instances (up to 4) merged with the accurate person matte, one mask per person | [03](stages/03-people.md) |
| 4 | Faces | Mac | Vision landmarks on the frame, then an upscaled head search for small or turned faces | [04](stages/04-faces.md) |
| 5 | Tracking and identity | Mac | EdgeTAM (Core ML) inside a shot; tracklets matched across cuts by mask colour | [05](stages/05-tracking-identity.md) |
| 6 | Targets | Mac | Identity 1 = most screen presence; or everyone, or chosen ids | [06](stages/06-targets.md) |
| 7 | Depth | Mac | Depth Anything V2 Small (Core ML), one colour scale per shot | [07](stages/07-depth.md) |
| 8 | Control video | Mac | Target painted with depth inside a skeleton-based silhouette; objects in front kept on top | [08](stages/08-control-video.md) |
| 9 | Soundtrack | Mac | Vocals only (AUSoundIsolation), +3 semitones, same length | [09](stages/09-soundtrack.md) |
| 10 | Character cutout | Mac | Optional: character images lifted onto plain grey (Vision) | [10](stages/10-character-cutout.md) |
| 11 | Generation | Comfy or own ComfyUI | Seedance 2.5 edit, draft first; or Wan 2.2 Animate | [11](stages/11-generation.md) · [Wan](COMFY_API.md#wan-22-animate-on-your-own-comfyui) |
| 12 | Finish | Mac | The original soundtrack muxed back onto the result | [12](stages/12-finish.md) |

The description and the prompt are written by the prompt writer, a local vision model behind one protocol:
[ARCHITECTURE.md](ARCHITECTURE.md#the-prompt-writer-any-vision-model-behind-one-protocol). How the prompt is put
together: [11](stages/11-generation.md#how-it-works).

## Control modes

`--control` in [`swapjutsu-prep`](CLI.md), or the clip's settings in the app. Details in
[08](stages/08-control-video.md).

| Mode | What Seedance sees of the person |
|---|---|
| `depth` (default) | Depth only |
| `hybrid-hands` | Depth, plus the real skin of the hands and the luma of sleeve folds near the camera |
| `hybrid-body` | The whole body as filmed, except the head |

With a replaced background, everything outside the people becomes blurred grey depth: the camera motion and the
coarse layout stay, the old scene's details go.

## Key decisions

| Decision | Why | Page |
|---|---|---|
| Two Vision requests per person | Instances separate people but leave holes; the matte fills bodies but merges everyone | [03](stages/03-people.md) |
| Colour, not feature prints, for identity | On the two-person clip, colour separated people (0.095 same vs 0.27 different); feature prints did not (0.85 vs 0.76) | [05](stages/05-tracking-identity.md) |
| One depth scale per shot | Per-frame scaling flickers; per shot, the target's mean depth changes 0.003–0.046 between frames | [07](stages/07-depth.md) |
| A silhouette from the skeleton | Leaves room for an outer layer the performer does not wear, such as a robe | [08](stages/08-control-video.md) |
| The face hidden behind depth | Seedance's public endpoint refuses real faces; depth carries motion without identity | [08](stages/08-control-video.md) |
| Vocals only, pitched up | Keeps lip sync without passing on the original voice or music | [09](stages/09-soundtrack.md) |

Code structure and the swappable stage protocols: [ARCHITECTURE.md](ARCHITECTURE.md). Tests and measured results:
[TESTING.md](TESTING.md).
