# 09 · Soundtrack

> Prepares the audio of `@Video1`: the voice only, pitched up, so Seedance follows the performance and lip sync without copying the original voice.

## At a glance

| | |
|---|---|
| Input | the clip's audio, the used range |
| Output | `.m4a` muxed into `control.mp4` |
| Runs on | AUSoundIsolation, AVAudioUnitTimePitch |
| Code | `Sources/SwapjutsuPrep/Stages/Audio/` |
| Protocol | `VoiceIsolating`, `PitchShifting` |
| Tested by | `AudioTests` |

## How it works

Vocals only (AUSoundIsolation; its delay is measured and removed), +3 semitones at the same duration.

## Why this choice

Alternatives: htdemucs as Core ML (better on singing, 80 MB), Rubber Band (pitch shifting), SAM-Audio (mlx-audio).

## References

- Rouard, Massa, Défossez, 2023. Hybrid Transformers for Music Source Separation. arXiv:2211.08553.
