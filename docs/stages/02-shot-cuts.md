# 02 · Shot cuts

> Finds the cuts, so tracking, depth scale and identities restart at each shot instead of smearing across it, and which way up each shot stands.

## At a glance

| | |
|---|---|
| Input | frames |
| Output | shot boundaries, each shot's turn (`Upright`, `Manifest.Shot.orientation`) |
| Runs on | Vision feature print + RGB histogram |
| Code | `Sources/SwapjutsuPrep/Stages/Shots/VisionShotDetector.swift`, `ShortShots.swift`, `Pipeline/Pipeline+Shots.swift`, `Stages/Orientation/` |
| Protocol | `ShotDetecting`, `OrientationProbing` |
| Tested by | `FixtureTests` (duo-cuts: 6 shots, pilot-story: 8), `ShortShotsTests`, `UprightTests` |

## How it works

A cut when the whole-frame feature print jumps by more than `cutDistance` = 0.6 **or** the RGB histogram by more than `cutColour` = 0.05 (inside a shot it stays under 0.01).

A shot shorter than `minShotFrames` = 4 (a sixth of a second) is a false cut: a flash or a transition frame. It joins its neighbour, at the clip's start or end the only one, mid-clip the longer one. The shortest real shot on the fixtures is 8 frames.

### Shots filmed sideways

A selfie filmed with the phone sideways can be saved with its pixels turned a quarter and no rotation tag, so decode
cannot stand it up. Vision's person masks and identity prints are made for people standing: on a test clip (a 9.4 s
walking selfie, head pointing left) the one person split into two identities at frame 100 and the target was
painted on 56 % of the frames; the same clip turned upright by hand gave 100 %.

Shots and turns are planned in one decode before the other passes (`ShotPlan`), since people, tracking and depth
need a shot's turn from its first frame. Each shot's first frame and every `orientationProbeEvery` = 24 frames are
probed (`VisionOrientationProbe`):

- Faces: Vision's face detector finds faces at any roll and reports it, so the roll of each face (confidence ≥ 0.5,
  not within 20° of a diagonal) votes for the quarter turn that stands it up. On that clip the roll was 77–113°
  wherever a face showed, so 90° clockwise.
- Body pose, only for a shot with no face: the four turns of three of its frames, counting joints over 0.3
  confidence; a person lying on their side gets about half the joints (8 against 18 on that clip).
- Human rectangles do not help: Vision found the same body at the same confidence in all four turns.

The probe's requests run on the CPU: it runs while the depth model loads, and behind a Neural Engine compile the
first face request waited 5–10 s; on the CPU the whole probe takes 0.3–0.5 s on a 5–15 s clip.

A shot is turned when one turn gets at least `orientationMinVotes` = 1 (about one clear face) and
`orientationMargin` = 2 × the votes for the shot as filmed. People, faces and appearance are then found on the
turned frame, EdgeTAM tracks the turned frames (`UprightTracking`) and the depth model sees them turned; masks,
boxes, landmarks and depth placements are turned back, so `control.mp4`, `mask.mp4` and `prepared.mp4` keep the
source's frame. Identity thumbnails are written upright.

## Limits and failure modes

A shot is turned as a whole: a phone rotated mid-shot keeps the turn most of the shot votes for. A sideways shot with
no face and a pose Vision cannot read stays as filmed.

The two-frame shot in `pilot-story` (cuts at frames 137 and 139), a fast generated transition, is absorbed by `minShotFrames`. The neighbour is picked by length, not by look; comparing the short shot's frames with both neighbours would pick better on a transition.

## References

- Souček, Lokoč, 2020. TransNet V2: An effective deep network architecture for fast shot transition detection. arXiv:2008.04838.
