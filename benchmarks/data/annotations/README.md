# Ground-truth target masks

Hand-checked masks of the swap target on frames where the target is ambiguous or Apple Vision fails, so the mask
benchmark can say which mask is right instead of how close it is to Vision. The protocol is in section 5 of
[`../../README.md`](../../README.md).

- `index.json`: `model` names the segmenter that drew the masks (`mlx-community/sam3.1-bf16`), and `frames` has one
  entry per annotated frame. `clip` is the clip's name, `frame` the frame index of the prep's `prepared.mp4`
  (decoded in order from 0), `target` the identity number the prep tracks, `size` the `prepared.mp4` size as
  `[width, height]`, `mask` the PNG, `points` the prompts as `[x, y, label]` in `prepared.mp4` pixels (1 = target,
  0 = not the target), `box` an optional `[x0, y0, x1, y1]` prompt (unused, always `null`), and `note` why the frame
  was chosen.
- `<clip>/<frame>.png`: a 1-bit mask at `prepared.mp4` size, white = target. An entry without prompts has an empty
  mask: the target is not in the frame.

The masks come from SAM 3.1's interactive head on the single frame (no tracking, no memory), with small enclosed
holes filled. Every mask was checked by eye on an overlay, and prompts were added until it was right. All 66 masks
reproduce exactly from their stored prompts.

The frame indices refer to preps made with the first 12 s of each clip at 24 fps and at most 960 px on the long
side. A prep made again with a different size or frame rate needs new annotations.

## What counts as the target

- The whole person: skin, hair (the question is the right person, not the strands), clothing, worn things
  (glasses, headset, jewellery, wig) and everything they hold (a cup, a phone in their own hand).
- Hands and arms that belong to the target are in, also when they reach in front of someone else or out of the
  frame.
- Not the target: seats, headrests, car interior, walls, props on the set, other people and their hands, phones or
  cameras held by others, and anything in front of the target that occludes it (a camera, another person's hand,
  on-screen text). Occluded parts are left out, not guessed.
- Where the image gives no answer (crushed blacks below the driver in driver-car), the mask follows SAM.

## Clips

Annotated on the cached preps of 2026-10-17.

| Clip | Frames | What they test |
|---|---|---|
| pilot-cockpit | 8 | the seat headrest Vision and EdgeTAM include; the clean frames 18–42 and 72 |
| driver-car | 8 | Vision spilling onto the seat and car interior under the arm |
| crowd-interaction | 9 | the target among 25 detected people; cameras and phones in front |
| dance-duo | 8 | two people crossing hands; frame 5 has the target with no mask from either |
| retro-dance-trio | 9 | Vision on the neighbours, and empty from frame 216 |
| studio-duo | 8 | a look-alike split by Vision; wide and close shots |
| blonde-hair-swap | 8 | light hair against trees and a lamp; frame 260 is the end card with no person |
| orange-jacket | 8 | hands reaching to the camera; text overlays in front |
