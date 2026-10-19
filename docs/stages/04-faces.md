# 04 · Faces

> Finds face landmarks on the target, for identity confirmation and the optional lip-sync guide; finds the face in each character image for its close-up.

## At a glance

| | |
|---|---|
| Input | frames, person boxes |
| Output | face landmarks per target frame |
| Runs on | Vision |
| Code | `Sources/SwapjutsuPrep/Stages/People/VisionFaceLocator.swift` |
| Protocol | `FaceLocating` |
| Tested by | `FixtureTests` (face coverage) |

## How it works

Vision landmarks on the whole frame, then an upscaled head-region search for small or turned faces.

**Face size.** `FaceLandmarks.height` is how tall the landmarks stand, brows to chin (Vision's points stop short of
the forehead). The face guide draws only faces of at least `Tuning.faceGuideMinHeight` = 3 % of the frame height
(see [08](08-control-video.md)).

**Character close-ups** (`FaceCloseUp`, `Stages/Character/`). A full-body reference gives the face about 8 % of the
image height, and with that image alone the rendered face matched it less. When a render is
uploaded, `VNDetectFaceRectanglesRequest` finds the largest face in each character image. If that face is under
`maxFaceShare` = 35 % of the image height and at least `minFace` = 64 px, a square of `scale` = 2.2 × the face box's
longer side, centred on the face and shifted inside the image, goes along as one more reference. It is scaled to
1024–2048 px on a side. It is cut from the character file, never from its cutout. An image without a human face (a
cat, a place) gets none: Vision finds no face in the two cat references of the velvet-cats job.

## Benchmarks

Face coverage on the fixtures: 0.00–0.98.

Target face height (`FaceLandmarks.height`) over the frame height, 2026-10-17, M-series, Debug, with `--face-guide`
and the threshold at 0 (all faces drawn): blonde cloister 3.4–5.5 % (33–53 px of 960, 138 frames), studio-duo first
5 s 4.8–13.0 %, velvet-dancer first 7 s 3.8–9.5 %, crowd-interaction first 5 s (`--target all`) 3.6–13.2 %. The
lines stayed distinct down to 33 px. The prep log prints the range on every run with the guide.
