# 05 · Tracking and identity

> Joins masks into tracklets inside a shot, then tracklets into people across cuts, so "person 1" is the same person all clip long.

![EdgeTAM tracks the person on the Neural Engine](../assets/how-it-works/02-tracking.png)

## At a glance

| | |
|---|---|
| Input | masks per frame, shots |
| Output | identities with their frames and a thumbnail |
| Runs on | CPU |
| Code | `Sources/SwapjutsuPrep/Stages/Tracking/Tracker.swift`, `Stages/Appearance/MaskedAppearance.swift`, `Stages/Identity/AgglomerativeIdentity.swift` |
| Protocol | `AppearanceDescribing`, `IdentityClustering` |
| Tested by | `IdentityTests`, `FixtureTests` |

## How it works

- Tracklets: best mask IoU > `trackIoU` = 0.2 with the previous frame; split on a clothing-colour jump > `trackSplitColour` = 0.25.
- Appearance: Vision feature print plus an HSV histogram inside the mask.
- Identity: distance = 0.2 × print + 0.8 × colour, average-linkage merges below `mergeDistance` = 0.33; tracklets seen in the same frame can never merge; a warning within 0.05 of the threshold.

- Mask tracking (after the targets are picked): `EdgeTAMTracker` seeds each target in each shot from its first
  Vision mask there and follows it frame by frame with EdgeTAM's memory bank (the seed plus the six most recent
  frames). Its soft masks replace Vision's for the whole shot, frames Vision missed included, unless the tracker
  lost the target for `TrackingTuning.lostFrames` = 12 frames in a row while Vision still saw it, or overlapped
  Vision by less than `minAgreement` = 0.5 on average; then that target keeps Vision's masks in that shot.
  `manifest.tracking` lists every target shot with its source, fallback reason, recovered and lost frames and
  agreement. `--no-tracking` (or no models) keeps Vision's masks everywhere. Code:
  `Stages/Tracking/EdgeTAMTracker.swift`, `Pipeline/Pipeline+Tracking.swift`; protocol `MaskTracking`.

## Why this choice

Measured on the two-person clip: feature print 0.85 same person vs 0.76 different (pose and framing dominate); colour histogram 0.095 same vs 0.27 different. Hence the 0.2 / 0.8 weights.

## Limits and failure modes

Identical clothing (uniforms) defeats colour; planned upgrade: a face embedding as a third term.
