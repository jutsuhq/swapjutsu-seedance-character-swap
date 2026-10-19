# 11 · Generation

> Seedance 2.5 edits `@Video1` with the characters `@Image1…`: a cheap 480p draft, then a 1080p final with the same motion, or a final straight away.

![One prompt from everything the Mac read](../assets/how-it-works/05-prompt.png)

## At a glance

| | |
|---|---|
| Input | `control.mp4`, character images, prompt |
| Output | the rendered video |
| Runs on | Comfy Cloud, API v2 |
| Code | `Sources/SwapjutsuApp/Model/Comfy.swift`, `Resources/Workflows/` |
| Protocol | `GenerationProvider` |
| Cost | `SeedancePrice`: drafts from a real bill, finals from the node's price badge |
| Tested by | `ComfySeedanceTests`, `JobStoreTests` |

## How it works

`ByteDance2ReferenceNodeV2` in edit mode; a draft also saves its `draft_task_id`, which `ByteDance2DraftToFinalVideoNode` renders at 1080p within 7 days. See `docs/COMFY_API.md`.

**References** (`JobFiles.uploads`), in `@Image` order: the characters (cut out with Cut out characters), the new
place when the background is replaced, a face close-up for each character whose face is small
([04](04-faces.md)), then the other references. The close-ups are saved as `inputs/face-<name>.jpg`, made again
only when the character is newer, so jobs need no new fields. Characters numbers the extra references after the
close-ups.

**Service prompt** (`ServicePrompt`, `Sources/SwapjutsuPrep/Support/`). Four parts, without scene-specific
beats, since nothing here describes the video:

1. One entity line per image: `@Image1 — CHARACTER, the replacement CHARACTER.` (CHARACTER 1, 2, 3 with several
   people, in image order), each close-up as `CHARACTER's FACE: a close-up of the same CHARACTER from @Image1; it
   defines their recognizable face …`, the new place as `LOCATION`, the extra references as `REFERENCE`.
2. "Video edit.": `@Video1` is a motion guide. The colored-depth person is the performer. With the background
   replaced, the grey depth is the setting; with it kept, every other pixel is the original footage. The colors are
   guidance only. The silhouette gives the pose and body, not the shape of the clothes. Keep the take (or the edit,
   cut for cut), the camera, the framing and the timing, with the length in seconds.
3. A numbered REPLACE item per character, by place or by screen presence as before, with its close-up for the face,
   then one for the grey depth when the background is replaced.
4. The vocals line when `@Video1` has them, an identity lock that ties each face to its close-up, and a closing line
   that keeps everything else.

Prep stores what the prompt is made from in `manifest.json` (`seedance.brief`), and `Job.effectivePrompt` writes it
again with the close-ups and extra references the upload numbers. The person's wishes still follow it. A manifest
from before the brief keeps its old prompt, with one sentence per close-up. In a test render (Seedance 2.5 edit,
our control without face lines, a face close-up, this structure) no control colours leaked, the pleated skirt swung,
and the face was close to the reference. Seedance 2.5 takes up to 30 reference
images (ComfyUI `seedance2_reference_limits` for `dreamina-seedance-2-5-260628`; the default for older models is
9). Past 30 the close-ups are left out first.

![A cheap draft, then the final](../assets/how-it-works/07-render.png)

## References

- Seedance 2.x technical report: link to add.
- docs.comfy.org: ByteDance2ReferenceNodeV2, ByteDance2DraftToFinalVideoNode.
