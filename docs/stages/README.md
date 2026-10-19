# The workflow, stage by stage

One page per stage of the workflow, from the source clip to the finished video: what it does, how it works, why
this approach and not another, the numbers that back it, and the papers and models it builds on.
[`PIPELINE.md`](../PIPELINE.md) is the short overview; [`ARCHITECTURE.md`](../ARCHITECTURE.md) has the code
structure and the swappable stage protocols.

| # | Stage | Where | Default |
|---|---|---|---|
| 01 | [Decode and normalise](01-decode.md) | Mac | VideoToolbox |
| 02 | [Shot cuts](02-shot-cuts.md) | Mac | Vision feature print + histogram |
| 03 | [People](03-people.md) | Mac | Vision instances + matte |
| 04 | [Faces](04-faces.md) | Mac | Vision landmarks |
| 05 | [Tracking and identity](05-tracking-identity.md) | Mac | mask IoU, appearance, average linkage |
| 06 | [Targets](06-targets.md) | Mac | most screen presence, or everyone |
| 07 | [Depth](07-depth.md) | Mac | Depth Anything V2 Small, Core ML |
| 08 | [Control video](08-control-video.md) | Mac | Core Image |
| 09 | [Soundtrack](09-soundtrack.md) | Mac | AUSoundIsolation + TimePitch |
| 10 | [Character cutout](10-character-cutout.md) | Mac | Vision subject lifting |
| 11 | [Generation](11-generation.md) | Comfy Cloud | Seedance 2.5 |
| 12 | [Finish](12-finish.md) | Mac | AVAssetWriter |

## Writing a page

- Every number names the clip, the date, the machine and the build (Debug or release), and how to reproduce it.
- Every threshold says what was measured to pick it and what breaks either side.
- "Why this choice" compares real alternatives on what matters for Seedance's control video (quality on our
  clips, speed on Apple silicon, on-device, license), not in general.
- References: authors, year, title, and an arXiv or DOI link; models with their exact file and license. Check
  every link before merging.
