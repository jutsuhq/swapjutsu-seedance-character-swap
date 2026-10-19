# 03 · People

> Separates every person in every frame, each with a clean mask, including the parts Vision alone loses.

![Every person gets their own mask](../assets/how-it-works/01-people.png)

## At a glance

| | |
|---|---|
| Input | frames of one shot |
| Output | one mask per person per frame, body rectangles |
| Runs on | Vision (GPU), one request per frame |
| Code | `Sources/SwapjutsuPrep/Stages/People/VisionPersonSegmenter.swift` |
| Protocol | `PersonSegmenting` |
| Cost | ~90 ms per frame; dominates prep (about 4 s per second of video) |
| Tested by | `FixtureTests` (mask stability), `StageTests` |

## The problem

- `VNGeneratePersonInstanceMaskRequest` separates people but leaves holes in patterned clothing, misses stretches of shirts and draws soft blobs on headrests.
- `VNGeneratePersonSegmentationRequest` (accurate) has clean edges but merges everyone and grabs nearby objects.

## How it works

Per person: the accurate matte inside that person's own claim, minus the other people's cores. The claim is the instance core at 0.35, closed by `closeRadius` = 6 % of the frame width (the edge extended first, for bodies cut by the frame), plus the Vision body rectangle when it covers the core. A tracklet survives only if ≥ `minConfirmed` = 20 % of its frames have a face or a body rectangle.

## Why this choice

Candidates measured: SAM 3.1 (mlx-vlm `sam3_1`, 8–10 s per frame) and EdgeTAM (Core ML, 0.2–0.45 s per frame), on top of Vision's first mask per shot.

## Limits and failure modes

- A thin sliver of the seat headrest joins the pilot's mask on a few frames.
- In the two-person clip, the other performer's hand is sometimes painted when it crosses the target.

## References

- Ravi et al., 2024. SAM 2: Segment Anything in Images and Videos. arXiv:2408.00714.
- Zhou et al., 2025. EdgeTAM: On-Device Track Anything Model. arXiv:2501.07256.
- SAM 3 / 3.1 (Meta, 2025): paper link to add.
- Apple: `VNGeneratePersonInstanceMaskRequest`, `VNGeneratePersonSegmentationRequest`.
