# 01 · Decode and normalise

> Reads the source once into frames every later stage agrees on: 24 fps, upright, even size, a resolution Seedance accepts.

## At a glance

| | |
|---|---|
| Input | the clip (or its 4–30 s range, cut by the app) |
| Output | frames at 24 fps, longest side ≤ 960 and ≥ 409,600 px, trimmed to 30 s |
| Runs on | VideoToolbox |
| Code | `Sources/SwapjutsuPrep/Stages/Decode/VideoSource.swift` |
| Protocol | none |
| Tested by | `StageTests`, `FixtureTests` |

## How it works

- 24 fps by taking the latest source frame per tick, never blending two frames.
- Small clips are scaled up to Seedance's minimum of 409,600 px.
