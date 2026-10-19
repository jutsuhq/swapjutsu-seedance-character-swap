# Testing

## Running

```bash
swift test --disable-default-traits # unit tests and synthetic audio/video checks, without building MLX
SWAPJUTSU_FIXTURES=1 swift test     # plus the end-to-end clips, ~5 min in debug
```

No test needs MLX (the local prompt writer, the package's `MLX` trait, on by default), and its Metal kernels take
most of a cold build; `--disable-default-traits` leaves it out, as CI does. That run drops `Package.resolved`, so
`git checkout Package.resolved` before you commit.

The default run includes video encoding and speech isolation and takes tens of seconds, plus compilation on a
cold build. To repeat a test without source changes, use `swift test --skip-build --filter <test-name>`.
CI caches `.build` per Xcode version, architecture, package manifest and commit, restoring the latest compatible
build for a new commit; keeping one permanent cache key would leave it frozen at the first saved build.

Unit tests cover identity clustering (people seen together never merge, lookalikes stay apart, flicker
tracklets join the nearest person, ordering by screen presence), tracklet splitting on a clothing-colour jump,
histogram distance bounds, mask-grid orientation, the per-shot depth scale, the depth person crop (box, padding at the frame edge, the
full-frame fallback, reuse of last frame's crop, the fit onto the full-frame scale, the feather only inside the frame,
and a portrait crop's map landing back on its own frame pixels), the edge-aware depth at the silhouette (the smeared
band and the ring take the person's depth, trusted depth and unpainted pixels stay bit-identical, a person cut off by
the frame border keeps depth up to it, a striped frame adds no relief to flat depth, the frame's colour steers each
band pixel at that pixel, a part thinner than the erosion keeps its own depth, no target leaves depth untouched), depth
smoothing along the optical flow (Vision's backward flow points from each pixel to where it was, on a landscape and
a portrait frame; the confidence rejects a vector leaving the frame, a forward/backward disagreement and a luma
mismatch; a cut, a gap, a frame without a target, a change of targets and a missing flow each restart from the
frame's own depth; a 2× jump of the model's scale comes through as one scale of the new frame, damped, and a lasting
one within 16 frames; motion is followed on a landscape and a portrait frame while untrusted pixels keep their own
depth), the control video's three masks (another person nearer at the contact is in front with the threshold halfway
between, farther is behind, a close call or too little contact is beside without reading depth, a far person, the
target under another identity and a fragment are no occluder; the edit radius is one per target and shot, from extent
or motion, clamped; a person in front takes their nearer pixels from the subject matte and the edit region and
nothing outside it, an object mask does the same),
the +3 semitone pitch shift
(440 Hz → 523 Hz, same length), and voice isolation (system speech over a chord and a hi-hat: music alone drops
more than 20 dB, SDR −2.6 → +5.4 dB, the voice within 5 ms of the original, measured both ways by the test
itself), the mux (the sound track's edit list skips exactly the AAC encoder's 2112 priming samples, so ffmpeg
and Seedance hear it on time; a passthrough export left 960, 48 ms late), a clip without sound, and the stage
seams: depth and mask caches (raw values, truncation fails), upscaling a small clip to Seedance's minimum, options
refused up front, a run driven by a stand-in segmenter ending in exactly `noPerson`, cancellation stopping a
run within 2 s with no control video left, and mask tracking with a stand-in tracker on a two-shot, two-person
clip: a frame Vision missed shows up in `mask.mp4`, each shot is seeded afresh, losing one target falls back to
Vision for that target only, and no tracker (or one that cannot load) keeps Vision's masks. `StageTests` runs
serialized: the depth pass waits for the people pass on a blocking condition, and several prep runs at once can
starve the concurrency pool.

App and ComfyKit tests cover the Comfy API contract against a stubbed session (auth, idempotency, retries,
`Retry-After`, errors, polling, multipart), the bundled workflow, files dropped in Create and the image limits,
the Keychain with throwaway items (which item a build uses and the environment
override), trim ranges (4–30 s, apart, one job each), the price estimate, and the job lifecycle with a stand-in prep and provider: a failed poll resumes the same request, a relaunch resumes a render
without submitting, an unknown submit is never retried by itself, cancel reaches the provider, stopping a render the provider can't cancel keeps its request and Retry polls it
without submitting, a job.json that can't be written before the send sends nothing, and a sent request's ID
that can't be written is shown and saved again until it lands, a draft is
finalized from its task alone and only within 7 days, a version 1 `job.json` comes back as a clip with its render,
a range is cut when the job copies its inputs, and every job gets its own folder and copies of its inputs.
The depth model is loaded once with a stand-in loader: a prep starting during warm-up waits on the same load (one
call, the same instance), a failed load is reported and tried again, and choosing another model loads that one.
Model installs use stand-in files and downloads: a file of the wrong size or hash fails the check, a damaged copy
is fetched again (and its compiled model dropped) before it is loaded, matching checkout files are copied rather
than downloaded, and a damaged download never replaces the copy; the depth and EdgeTAM pins name a fixed revision.

CI (`.github/workflows/test.yml`) builds and tests without the MLX trait on every push to `main` and every pull
request, on the `xcode-27` runner. The fixture clips and the depth model are not in the repo, so the fixture run
stays local.

## Fixture clips

The clips are not committed. [fixtures.json](../Tests/SwapjutsuPrepTests/Fixtures/fixtures.json) lists each one
with what it is and the expected answer, checked by eye on `review.mp4`. Put the files (or symlinks) in
`Tests/SwapjutsuPrepTests/Fixtures/` under those names. For each clip the test checks:

- the shot cuts, ±1 frame;
- which people are on screen in each shot: some one-to-one naming of the found identities must explain every
  labelled shot, so a person split in two or two people merged into one fails;
- the expected main character is identity 1;
- a clip without people fails with `noPerson` instead of painting an object.

| Clip | What makes it hard |
|---|---|
| `duo-cuts.mov` | two performers, 6 shots, two cuts between near-identical framings on the same backdrop, close-ups of each |
| `walk-back.mp4` | one person walking away, no face at all, coat flapping |
| `pilot-cockpit.mp4` | profile with sunglasses, a cup at the mouth, seat headrests next to the person |
| `driver-car.mp4` | hands crossing the steering wheel, the person cut off by the frame bottom |
| `pilot-story.mp4` | 9 generated shots; the same pilot returns after five cuts; shots with no person |
| `no-person.mp4` | a car, nobody in it |

## Measured results

The tracker, depth and control-video experiments are written up in [benchmarks/README.md](../benchmarks/README.md).

M4, 16 GB, `swift build -c release`, 2026-10-16; all 6 fixture tests pass.

| Clip | Frames | Shots | People | Target presence | Mask stability | Face coverage | Depth flicker | Time |
|---|---|---|---|---|---|---|---|---|
| duo-cuts | 231 | 6 | 2 | 0.75 | 0.966 | 0.97 | 0.046 | 49.5 s |
| walk-back (12 s) | 288 | 1 | 1 | 1.00 | 0.963 | 0.00 | 0.003 | 45.7 s |
| pilot-cockpit | 241 | 1 | 2 ¹ | 1.00 | 0.969 | 0.59 | 0.008 | 40.3 s |
| driver-car | 209 | 1 | 2 ¹ | 1.00 | 0.949 | 0.98 | 0.023 | 36.3 s |
| pilot-story | 241 | 9 | 3 | 0.52 | 0.987 | 0.98 | 0.006 | 46.2 s |
| no-person | — | — | 0 | — | — | — | — | `noPerson` |

¹ The second identity is a short fragment (5 frames of a seat, 10 frames of a hand; 0.6 % of screen area). It is
  never the target and is not painted in the control video.

- **Target presence:** share of frames with the target on screen. **Mask stability:** mean IoU of the target
  mask between consecutive frames. **Face coverage:** share of target frames with face landmarks (lip sync).
  **Depth flicker:** mean frame-to-frame change of the target's mean depth on the shot scale (0–1).
- Speed: about 4 s per second of video; person segmentation (~90 ms a frame) dominates. Maximum resident set
  size of the CLI: 210–260 MB. These runs predate EdgeTAM tracking and depth crops; with them a prep takes 3–5 s
  per second of video and 250–500 MB ([benchmarks 7.21](../benchmarks/README.md#721-depth-on-a-crop-around-small-people)).

## Known issues

- A thin sliver of the seat headrest joins the pilot's mask on a few frames (from the body rectangle).
- In the two-person clip, the other performer's hand is sometimes painted when it crosses the target.
- Two very short shots (frames 137 and 139) in `pilot-story` may be spurious cuts on a fast generated transition;
  they cost nothing but a depth-scale reset.
- `walk-back` has no face, so the manifest warns that lip sync may drift. That warning is correct.
