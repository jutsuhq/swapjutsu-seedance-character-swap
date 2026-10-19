# 10 · Character cutout

> Optionally cuts the character images out onto plain grey before upload, so Seedance takes the person and not their background.

## At a glance

| | |
|---|---|
| Input | character images |
| Output | `<name>.cutout.jpg` next to each, made once, at upload |
| Runs on | Vision subject lifting |
| Code | `Sources/SwapjutsuPrep/Stages/Character/VisionCutout.swift`, `Sources/SwapjutsuApp/Model/JobFiles.swift` |
| Protocol | `BackgroundRemoving` |
| Tested by | `StageTests`, `JobStoreTests` |

## How it works

Only a subject that a body or face detector confirms is cut out, so a location reference keeps its scene. Grey #B0B0B0, no alpha (Seedance flattens transparency to black). Off by default.

## Next

A paid A/B run: does Seedance keep likeness better with cut-out characters?
