# 06 · Targets

> Decides who gets replaced, automatically.

## At a glance

| | |
|---|---|
| Input | identities |
| Output | `manifest.targets`, in order (`@Image1…`) |
| Runs on | CPU |
| Code | `Sources/SwapjutsuPrep/Pipeline/` |
| Protocol | none |
| Tested by | `FixtureTests` |

## How it works

Main: the identity with the most screen presence. Everyone: every identity that passed the false-positive filter. Explicit ids from the CLI.
