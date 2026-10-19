# 08 · Control video

> Renders `control.mp4`, the `@Video1` Seedance edits: the target painted with coloured depth over the original, everyone else untouched.

![The control video Seedance sees](../assets/how-it-works/06-control.png)

## At a glance

| | |
|---|---|
| Input | frames, target masks, other people's masks, depth and its shot scales, landmarks |
| Output | `control.mp4`, `mask.mp4`, `review.mp4` |
| Runs on | Core Image and one Metal kernel on the GPU, VideoToolbox H.264 |
| Code | `Sources/SwapjutsuPrep/Stages/Render/ControlRenderer.swift`, `Stages/Masks/ControlMasks.swift`, `Stages/Masks/OccluderMasking.swift`, `Stages/Depth/DepthEdges.swift`, `Stages/Encode/` |
| Protocol | `ForegroundMasking` (extra protected mask per frame; `OccluderMasking` by default) |
| Tested by | `StageTests`, `FixtureTests`, `DepthEdgesTests`, `ControlMasksTests`, `OccluderMaskingTests` |

## How it works

Inferno-coloured depth inside the edit region, the original frame everywhere else; optional face landmarks (lip-sync
guide, `--face-guide`, off by default). The face is always covered: Seedance's public endpoint refuses real faces
unless the person passes a liveness check, and depth carries the motion without the identity.

**Face guide.** Vision's landmark polylines in white, line width 1/480 of the frame width, drawn on the painted
person before it is blended into the frame, so they stay inside the painted target and never reach the original or
grey background. They are drawn only on a face whose landmarks span at least `faceGuideMinHeight` = 3 % of the frame
height ([04](04-faces.md)): on smaller faces the nine polylines crowd into a few pixels. The service prompt explains
the lines only when some frame got them, and `manifest.json` records `faceGuide {frames, minFaceHeight}` (nil with
the guide off and in older manifests). It is off by default because in a real Seedance 2.5 render with the guide,
the "never draw them" sentence and a face close-up, the lines were drawn onto the face in nearly every frame.

Three masks per frame (#56, `ControlMasks`):

- **Subject matte**: the targets' masks from `TargetMasks` (EdgeTAM where it kept the shot, else Vision), minus the
  protected pixels. `DepthEdges` trusts depth only here. `mask.mp4` is this matte grown by `maskDilation` = 0.6 % of
  the width, as before.
- **Edit region**: the painted area, each target's matte grown by one radius per target and shot (`EditRegion`):
  the larger of `editExtent` = 0.6 % of the target's median box height in the shot and `editMotion` = ½ of its
  75th-percentile box movement per frame, clamped to `maskDilation` … `editMaxDilation` = 0.6–1.0 % of the frame
  width. The ceiling keeps the ring inside `DepthEdges`' reach (ring + erosion ≤ 2 % of the width), so it still
  gets the person's depth. One radius per shot means the region never changes size from frame to frame on its own;
  it moves only with the matte. Where protected pixels took part of the matte, the region is grown again from what
  stays visible, so no painted ring is left on the occluder.
- **Protected foreground**: pixels that keep the original frame over the depth. Two sources:
  - Other people, from Vision's masks on the target's frames. Each other person whose box comes near the target,
    whose detection has a face or body rectangle, whose identity has a face somewhere in the clip, and whose mask is
    at least `occlusionMinArea` = ¼ of the target's (smaller is a fragment: a hand Vision split off the target, a
    headrest taken for a person) is ordered against the target (`Occlusion.order`) on the 96² occupancy grid: the
    median depth of their cells within `occlusionBand` = 2 cells of the target (including cells both claim) against
    the target's cells within 2 cells of them. Nearer by over `occlusionDepthTolerance` = 10 % of the shot's depth
    span is *front*, farther by as much *behind*, else *beside*. A person covering over half the target is the
    target under another identity and is skipped. Only *front* protects, and only from the second frame in a row,
    so a one-frame call cannot flash. Then, per pixel, their mask (grown by `maskDilation`, so its soft edge leaves
    no painted rim) counts where the depth is nearer than halfway between the two medians, with a soft step 5 % of
    the span wide (`occlusionRamp`). Depth only orders and trims a mask; it never makes one.
  - Objects (door, steering wheel, microphone): `PrepStages.foreground` (`ForegroundMasking`), one frame-sized
    mask per frame, protected wherever it lies inside the edit region. `OccluderMasking` finds them without a click
    (on by default, `Tuning.occluders`, `--no-occluders`): on a grid of 240 cells on the long side, cells inside the
    edit region that are no person to Vision and nearer than the target body's median depth, opened by a cell, form
    components; one is kept when it covers 0.4 % of the target's cells, its median depth is 15 % of the body's depth
    spread in front of the body's cells within 4 cells of it, and 30 % of it was a candidate on the frame before.
    The kept cells are cut at full resolution by Vision's person matte and the depth, so the target's own hand never
    goes. A mask prompted in the app (#58) can replace it through the same protocol. With the background replaced,
    a kept object is grey depth like the rest of the old scene, as people in front are.

  *Beside* and *behind* paint over the other person as before. Vision's person masks reach a few pixels into a
  touching neighbour (each is the shared person matte inside the instance's closed core), so keeping a side-by-side
  neighbour's pixels showed the target's own edge as a light outline; the first version did that and was dropped.

Depth at the silhouette (#15). The model sees the frame at 518 × 392 and smooths across the person's outline, so
the last 3–6 px inside the matte carry the background's depth: painted raw, a thick dark outline. Before the
palette, on the placed float depth (same `toFrame`, same scale), `DepthEdges` replaces those pixels and the
dilation ring:

- Trusted samples: the target matte eroded by `depthEdgeErosion` = 1 % of the width (5.4 px at 540 wide). The
  frame border is not an edge: the matte is clamped before eroding, so a person cut off by the frame keeps their
  depth up to it.
- Each painted pixel that is not trusted takes a joint bilateral average of trusted depth within
  `depthEdgeReach` = ±2 % of the width (13 × 13 taps, Gaussian in distance with σ = half the reach), weighted by
  colour similarity in the frame (√RGB, `depthEdgeColourSigma` = 0.1, floored at 1 % so a ring pixel, which has the
  background's colour, still averages the person's depth). Only trusted samples count, so no background depth
  enters; a colour edge on the body (hair, a print, a shadow) only reweights the person's own values. The result
  is a convex combination of input depths: the scale is unchanged.
- Trusted depth and everything outside the dilated mask pass through bit-identical, so the body's relief and its
  inner depth edges (an arm in front of the coat) cannot pick up the frame's texture.
- A part thinner than twice the erosion (a finger, a coat tail) has no trusted sample; it takes the nearest depth
  sampled in the matte within reach, as the old ring did.
- One Metal compute kernel run through `CIImageProcessorKernel`, compiled from source at first use (SwiftPM builds
  no `.metallib`), so it stays inside the Core Image graph that renders the frame.

This replaces the former correction (ring = max filter of the masked depth, interior eroded by 2 px), which hid
the outer half of the dark band but left a thin dark line just inside the edge and a doubled contour where the ring
met the interior. Stacking the old ring on the filter measured slightly flatter at the rim but looks the same and
costs both.

## Benchmarks

Edge-aware depth (#15, M4, 2026-10-17, Debug CLI, one pass each): rim dip (depth 1–4 px inside the edge minus
9–12 px inside) −0.020 → −0.008 on walk-back, −0.018 → −0.005 on duo-cuts, −0.069 → −0.031 on blonde-hair-swap,
−0.020 → +0.002 on studio-duo; edge step (|Laplacian| over ring and edge band) −28 %, −12 %, −26 %, −32 %; edge
shimmer −3 to −20 %; body continuity, depth flicker and peak memory unchanged. Cost of the filter alone, graph and
kernel rendered and waited for: +1.2–1.4 ms a frame at 540 × 960, +2.6–3.8 ms at 1080 × 1920.

Three masks (#56, M4, 2026-10-17, Debug CLI with EdgeTAM, one pass each): the foreground photographer on crowd-interaction
stays in front on 28 frames where main painted him as part of the target, and the partner's sleeve on dance-duo
frame 93; ground-truth IoU of the subject matte unchanged or up on every annotated frame; studio-duo's `control.mp4`
bit-identical to main; painted-area flicker within ±5 % of main; render pass +0.05 to +3.7 s per clip in Debug.

## Limits and failure modes

- Three masks (#56): one order per other person and frame. Interleaved arms (her hand over his chest while his is
  over hers) get one answer; the minority part is painted as before. The order needs a Vision mask of the other
  person: where Vision merges them into the target or misses them, nothing is protected. On crowd-interaction the
  target matte (EdgeTAM) still covers the press camera and some arms.
- Object occluders need Vision to call them no person: an object the person matte takes for part of the body
  (pilot-cockpit's headrest, a wheel rim between the hands) is painted as before. On the benchmark preps it found
  pilot-cockpit's seat cover and a phone held in front of the target on crowd-interaction, and nothing on the
  clips without occluders.
- The edit region's floor is the old radius, the ceiling 1 % of the width; on full-body shots at 540 wide the
  radius sits at the ceiling (5.4 px), so the painted silhouette is about 2 px wider all round than before and
  small gaps (between an arm and the coat) close a little earlier.

- Depth the matte trusts but the model got wrong stays: background seen through a gap the matte covers (between the
  chin and a raised hand on studio-duo), hair the model reads as far (blonde-hair-swap). Next to such a gap, a band
  pixel whose colour is close to the wall's (skin on an orange wall) can pick up a little of its dark depth.
- In-prep cost is not pinned down: single runs put the render pass 2–15 ms a frame slower, a repeat pair went the
  other way; the filter alone costs 1.2–3.8 ms.

## Next

- Object occluders Vision counts as a person (a headrest): a prompt from the app (#58), or an object segmenter.
- Edit region per swap type (a wider costume) and judged on Seedance drafts against the baseline (#18).
