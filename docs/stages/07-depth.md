# 07 · Depth

> Estimates relative depth for every frame, which the control video paints onto the target so Seedance follows the body's shape and motion.

## At a glance

| | |
|---|---|
| Input | frames (own decoder, beside the people pass) |
| Output | `work/depth`, raw half floats; the targets' smoothed final depth per frame (`<frame>.smooth`) and the optical flow (`<frame>.flow`); one scale per shot |
| Runs on | Core ML, Neural Engine |
| Code | `Sources/SwapjutsuPrep/Stages/Depth/DepthAnything.swift`, `ShotDepthRange.swift`, `DepthCrop.swift`, `DepthEdges.swift`, `OpticalFlow.swift`, `DepthSmoothing.swift`; `Pipeline/DepthPass.swift`, `FlowPass.swift`, `Pipeline+Smoothing.swift` |
| Protocol | `DepthEstimating` |
| Cost | ~36 ms per frame beside segmentation (M4, 2026-10-17); model load 0.04 s warm, ~6 s on a cold Neural Engine compile (idle M4; once per model path and app path), much longer queued behind another compile; the app loads it once in the background at launch and keeps it (~59 MB peak footprint); flow smoothing: optical flow ~14–18 ms per frame pair beside segmentation, then 10–14 ms per target frame on the critical path (~1–3 s net per 12 s clip, no extra peak memory) |
| Tested by | `FixtureTests` (depth flicker), `StageTests`, `DepthSmoothingTests` (flow direction landscape and portrait, confidence, history resets, scale alignment, disocclusion fallback), `DepthCropTests` (crop box, fallback, fit, placement of a portrait crop), `LocalModelTests` (one load shared by warm-up and prep), `ModelFilesTests` (integrity check, re-fetch) |

## The problem

An image depth model flickers frame to frame.

Most of the flicker is the model's own normalisation, not noise on the surface: Depth Anything returns relative
inverse depth, rescaled per image, and the least-squares scale between two consecutive frames of duo-cuts ranges
0.5–1.3×. Painted on a fixed shot scale, the whole person brightens and darkens from one frame to the next (duo-cuts
frames 209 → 210). The per-pixel motion-compensated change (0.063 of the shot scale on duo-cuts) is barely above
the change of the target's mean depth (0.056), which is that jitter.

## How it works

- Depth Anything V2 Small (Apple's Core ML conversion, F16). Portrait frames are turned sideways for the landscape input (518 × 392): upright and padded instead, the person gets about 0.42× the model pixels and flatter depth (#57).
- Per frame, the 2nd–98th percentile of depth under the target; per shot, one fixed scale from the 10th percentile of the lows and the 90th of the highs.
- At the silhouette the model's depth mixes in the background over the last few pixels; the control video replaces
  those and the dilation ring with the person's own depth nearby, guided by the frame (#15, `DepthEdges.swift`;
  see [08 · Control video](08-control-video.md)). Depth inside the matte past the far end of the shot's scale
  (a gap between hand and body the matte closed) is treated the same way, so it does not paint near-black: on the
  studio-duo clip near-black pixels inside the matte went from 4,621 to 218 over 120 frames. The shot scale and the
  flicker metric use the unfiltered depth.
- Temporal smoothing along the optical flow (#17, `OpticalFlow.swift`, `DepthSmoothing.swift`). A third decoder
  beside the people pass runs Vision's optical flow (revision 1) both ways between consecutive frames at 320 px on
  the longest side and stores the backward field with a confidence per pixel: 0 where the vector leaves the frame
  or the forward flow does not bring it back (|F + G|² > 0.01 (|F|² + |G|²) + 0.5 px²: disocclusions), else
  exp(−(Δluma / 0.05)²) (computed on the GPU). After tracking, each target frame's final depth (full frame with the
  crops merged) is brought onto the previous smoothed frame's scale (least squares over trusted pixels of the whole
  frame, refitted without the worst fifth), blended with that frame warped by the flow (weight up to 0.6 × the
  confidence, falling off as exp(−(r / τ)²) with r the difference and τ = 0.1 of the target's depth spread), and
  moved a quarter of the way back to its own scale: the scale becomes an exponential average of the model's, so a
  lasting change comes through within a few frames. History resets at a cut, after a frame without a target or
  without depth, when the set of targets changes, and where a frame has no flow or no fit; untrusted pixels keep
  their own depth. The shot scale is measured on the smoothed depth, the render paints it, and the edge refinement
  runs on it afterwards, on the current mask (smoothing after it would trail the previous silhouettes).
  `--no-depth-smoothing` (`Tuning.depthSmoothing = 0`) turns flow and smoothing off.
- The app (`DepthModel`) checks its copy against pinned SHA-256s, fetches a damaged one again, loads the model once, at utility priority, at launch and right after fetching it, and hands that one instance to every prep through `PrepStages.standard(tuning:depth:)`; a prep that starts during the load waits on the same task. Settings › Prep and the Prep step show "Optimizing the depth model for this Mac, once" meanwhile. The CLI loads it per run.
- Person crops (#14). A second loop on its own decoder follows the people pass a few frames behind and, for the
  2 largest people of each frame, runs the model again on a crop around them: the person box padded by 8 % of its
  size plus 4 % of the frame width, grown to an aspect between the frame's and the model input's (so the model
  squeezes it no more than the whole frame), kept inside the frame. A crop larger than 60 % of the frame is skipped;
  last frame's crop is reused while the person stays inside it. Each crop is fitted onto the full-frame map under the
  person's mask (least squares, `full ≈ scale · crop + shift`; depth is relative), so the shot scale and the frame
  consistency stay those of the full-frame pass, and blended in with a 2 %-of-width feather at crop edges inside the
  frame. A shot uses crops only when every target detection in it has one; otherwise the whole shot keeps the
  full-frame depth, so the relief never switches mid-shot. The shot scale is measured on the merged values under the
  target masks, which lie inside the crop's padding.

## Why this choice

Alternatives: Video Depth Anything (temporally consistent; would need a Core ML conversion of our own), Depth Pro.

Temporal consistency (#17): flow smoothing on top of the image model, rather than Video Depth Anything converted to
Core ML. It needs no new model, runs in the prep's existing Vision/Metal stack, keeps the crops and the edge
refinement as they are, and halves the measured shimmer. Its ceiling: it can only damp what the flow can follow; a
video model would be consistent where the flow gives up (fast fingers, disocclusions) and would not need the scale
alignment. If Seedance (#18) shows remaining shimmer, the next step is Video Depth Anything Small (Apache-2.0)
converted to Core ML with 32-frame windows.

Neural Engine (`computeUnits = .all`) rather than GPU (`.cpuAndGPU`), also on a cold Mac (#12). The GPU loads the
model in 0.37 s instead of ~6 s on a cold compile, but depth takes 52–59 ms a frame instead of 35–38 ms and shares the
GPU with Vision segmentation, so a prep takes 12–26 % longer (duo-cuts 39.3 → 44.0 s, walk-back 41.4 → 52.3 s): more
than the one-time compile it would save, which the app already spends at launch.

## Benchmarks

Depth flicker (mean frame-to-frame change of the target's mean depth, 0–1): 0.003–0.046 on the fixtures; duo-cuts 0.056 after the scale fix; Countryside Duo 0.016 (2026-10-16, Debug).

Depth inference beside segmentation, `.all` vs `.cpuAndGPU`: duo-cuts 35–36 vs 52–59 ms a frame, walk-back (12 s)
37–38 vs 52 ms; prep total 36.3–39.3 vs 44.0 s and 41.4 vs 52.3 s (M4, 2026-10-17, Debug CLI, `--no-review`).
Model load: 6.2 s cold / 0.04 s cached on `.all`, 0.37 s / 0.04 s on `.cpuAndGPU`.

Person crops (#14, M4, 2026-10-17, Debug CLI, `--no-review`, one pass each): on the five fixtures no shot qualifies
(the target fills 0.68–1.0 of the frame in most frames, or a crop is missing in part of the shot), so `control.mp4`
of duo-cuts and walk-back is pixel-identical to before. On walk-back-small (walk-back at half size on a plain
canvas, the figure ~20 % of the frame height) the shot takes crops with 4.8× the model pixels on the target: arms
separate from the coat and the legs get their own depth instead of fading to "far"; relative relief +22 %, depth
flicker 0.0390 → 0.0398. On countryside-duo (gallery, target median 0.15 of the frame) 3 of 4 shots take crops at 1.8–2.1× the
model pixels: relief +15 %, depth flicker 0.0207 → 0.0202, mask stability unchanged, prep 48.5 → 47.6 s. Prep time
−4.5 to +2.6 % over all runs; peak RSS up to +216 MB with crops.

Flow smoothing (#17, M4, 2026-10-17, Debug CLI, `--no-review`, 12 s except duo-cuts, tracked runs): motion-compensated per-pixel
residual (manifest `depthResidualRaw` → `depthResidual`) 0.064 → 0.030 on duo-cuts, 0.031 → 0.016 on walk-back,
0.022 → 0.011 on studio-duo, 0.040 → 0.022 on blonde-hair-swap (−44 to −53 %); depth flicker 0.0565 → 0.0249,
0.0234 → 0.0127, 0.0185 → 0.0094, 0.0264 → 0.0118. Relief (spatial spread and |Laplacian| of the painted depth in
the eroded target, read back from `control.mp4`) unchanged within ±6 %; the mean depth follows the per-frame one
with a correlation of 0.96–0.99 and 0–1 frame of lag. No ghosting in the side-by-side of duo-cuts (fastest motion).

Upright input for portrait frames (#57, M4, 2026-10-17, Debug CLI, `--no-review --no-tracking`, 12 s, one pass
each): the frame kept upright and padded to the 4:3 input, against the sideways turn, on walk-back, dance-duo and
retro-dance-trio. Relief under the target −4 / −13 / −15 % upright; depth flicker 0.0120 → 0.0097, 0.0303 → 0.0244,
0.0236 → 0.0229; raw per-pixel residual 0.0317 → 0.0377, 0.0659 → 0.0819, 0.0444 → 0.0254; masks and ground-truth
IoU unchanged (0.579, 0.408); time and peak RSS within the noise of a busy machine. In the stills upright paints the
coat and legs of walk-back nearly flat and a hand reaching to the camera as far as the body. Sideways kept.

## Limits and failure modes

- Crops only pay off on a small target: on all five fixtures the crop path is skipped (the gallery clips, with
  targets around 0.15–0.3 of the frame, are where it applies). A shot needs a crop on every
  target frame, so a person who walks into frame from close by keeps the full-frame depth for the whole shot.
- A whole limb the model sees as background (the velvet clip's outstretched arms against a white wall, frames
  84 and 156) stays near-black: only its last pixels within `depthEdgeReach` of the body's depth are filled
  (112,394 to 101,406 near-black pixels over 168 frames). Filling it needs depth along the limb from the body
  (a geodesic fill over the matte) or a sharper model there, not a wider edge band.
- Crops run for the 2 largest people per frame; a third target makes its shots fall back to the full frame.
- Smoothing damps only what the flow follows: where the confidence is 0 (fast fingers, disocclusions, motion blur)
  or the depth jumps by more than τ, a pixel keeps its per-frame depth and its shimmer. The flow runs at 320 px, so
  thin fast parts are the first to fall back.
- The scale fit runs over the whole frame; on a close-up the person is most of it, so a real change of the
  person's depth (stepping towards the camera) is first taken for model jitter and comes through at a quarter per
  frame (about one frame of lag on the mean depth, measured).
- The residual metric uses the same flow and confidence as the smoothing, so it rewards any blend along that
  flow; relief and lag are checked separately, and Seedance is the real judge (#18).
- Disk: the flow (0.4 MB a frame at 320 × 180 half floats) and the smoothed depth (frame size, 1 MB a frame at
  960 × 540) stay in `work/` until the run ends: about 1 GB for 30 s at 960 × 540.
- The crop loop runs the model on frames of shots that end up not using crops (walk-back: 120 crops, all unused);
  that is hidden behind segmentation but costs Neural Engine time and memory (+79 MB peak RSS on walk-back).

## References

- Yang et al., 2024. Depth Anything V2. arXiv:2406.09414.
- Chen et al., 2025. Video Depth Anything: Consistent Depth Estimation for Super-Long Videos. arXiv:2501.12375.
- Model: huggingface.co/apple/coreml-depth-anything-v2-small (Apache-2.0).

## Next

Epic #22: warm-up (#11), GPU fallback (#12, measured and dropped), target crop (#14, small targets gain), edge-aware depth at the silhouette (#15, done: dark rim gone, edge step −12 to −32 %), optical-flow smoothing (#17, done: per-pixel shimmer −44 to −53 %, no ghosting), upright portrait input (#57, measured and dropped: −4 to −15 % relief), judged on Seedance (#18); if it is
not enough, Video Depth Anything Small converted to Core ML.
