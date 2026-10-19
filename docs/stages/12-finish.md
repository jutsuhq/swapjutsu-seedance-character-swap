# 12 · Finish

> Puts the original soundtrack back under Seedance's video.

## At a glance

| | |
|---|---|
| Input | the render, the clip |
| Output | `<quality>-<id>.mp4` |
| Runs on | AVAssetWriter |
| Code | `Sources/SwapjutsuPrep/Stages/Encode/Mux.swift` (`muxAudio`) |
| Protocol | none |
| Tested by | `AudioTests`, `JobStoreTests` |

## How it works

Seedance's own audio is discarded; the clip's audio is muxed back at its original timing.
