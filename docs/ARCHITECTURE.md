# Architecture

Swapjutsu is a native macOS app (Swift, SwiftUI) that replaces a person in a video with a character: everything
up to the generation request runs on the Mac, and the generation runs on Seedance 2.5. This repository holds the
first part, the prep library and its command-line tool; the app is built on top of it.

## Requirements

- macOS 15 or later on Apple Silicon. Measured on an idle M4 with 16 GB: 3–5 s of processing per second of video,
  250–500 MB of memory, about 100 MB of model weights (depth and tracking).
- A Comfy API key for generation. By default Seedance 2.5 is called directly through Comfy's Partner Nodes API
  (`PartnerSeedanceClient`, prepaid credits); Settings › Comfy can switch to the workflow on Comfy Cloud
  (`ComfyClient`, API v2, needs a subscription). `SeedanceRoutes` sends new renders the chosen way and resumes a
  saved one on the route its `seedance:` request ID names. The prep itself needs no account and no network.

## Modules

ComfyKit knows nothing about the app; it holds the Comfy clients, each with Codable models, typed errors and an
injected `URLSession`. `ComfyClient` is the Comfy API v2 contract (the retry and idempotency rules of Comfy's own
SDKs), which works against Comfy Cloud, a Comfy API deployment or self-hosted ComfyUI behind comfy-api-proxy by
changing `baseURL`. `PartnerSeedanceClient` calls Seedance 2.5 directly through Comfy's Partner Nodes API, with the
partner node's request and response shapes in `SeedanceModels`, so ComfyKit does know Seedance's wire format.
`ComfyUIClient` is a self-hosted ComfyUI's own API, for Wan 2.2 Animate. The app owns the workflows, the prompts and
the routing, and maps them onto `GenerationProvider`.

In the app, data flows one way. `SwapjutsuApp` makes `Credentials`, `JobStore`, `Draft` and `SampleLibrary` once
and puts them in the environment. Views read them and call their methods: prep, renders, a clip's files and Library's
Export (`ResultExporter`) go through the model layer, never a view. A few Settings panes act directly: Storage
measures and clears the downloaded examples, Own ComfyUI's Check asks the server through `ComfyUIClient`, and the
Finder, pasteboard and save panel hand files to the system. Create edits the `Draft`, and submitting copies one `JobSpec` value per trim range, so later
edits never reach a running job. Pages send the person to another page's clip or result through `Navigation`. `JobStore` gets its providers as a factory, so tests swap the backend without a key. `DepthModel` and `TrackingModel` (one `LocalModel` each, over the pinned files in `ModelFiles`) check the app's copy against its SHA-256 pins, fetch it again when it is missing or damaged, load it once in the background at launch (a new copy compiles for the Neural Engine on its first load) and lend that one instance to every prep. Each
feature folder holds its screen and the subviews only it uses; anything shared lives in `DesignSystem/`, and how a
model value reads on screen (a stage's title and color) sits next to the view that shows it.

```
SwapjutsuPrep (library, this repo)          swapjutsu-prep (CLI, this repo)
  Pipeline/      run order, PrepStages,         strict argument parsing → Pipeline.run
                 options, caches, manifest
  Stages/        one folder per stage (below)
  Support/       MaskGrid, imaging, errors, Manifest

ComfyKit (library, this repo)               SwapjutsuApp (SwiftUI library, this repo)
  ComfyClient    Comfy API v2: assets, jobs,    App/         composition root: makes the stores once
                 polling, retries               Model/       Draft, JobSpec, Job, JobStore, providers
  PartnerSeedanceClient, SeedanceModels         Services/    Credentials (Keychain), agents
                 Seedance 2.5 via Partner Nodes Features/    Shell, Create, Jobs, Library, Settings
  ComfyUIClient  a self-hosted ComfyUI's API    DesignSystem/ tokens, styles, shared components
  Workflow       API-format graph, asset refs
  Models         Asset, Job, ComfyError
  JSONValue      typed JSON for workflow inputs
```

The `Swapjutsu` executable target is one `main.swift` that calls `SwapjutsuApp.main()`, so `swift run` and an app
bundle host the same library.

### Who owns the work

`JobStore` stays the one facade the windows and agents call; behind it, three small owners hold what must not be
lost or applied twice.

- **`JobWork`** keeps every background task by its owner and kind: a clip's prep, its description and the reading of
  its prompt by the clip, a render by the render. Removing or canceling a clip stops its description; a model's
  answer is applied only when the clip is still listed and its description wasn't edited meanwhile
  (`Job.descriptionRevision`), and a removed clip's `job.json` is never written again. `JobWork` also owns the one
  slot for heavy local work: prep, a description and the reading of a render's prompt each take it before their
  first `await` and give it back when they end, so a vision model never shares the RAM with prep's depth and tracking
  models. Canceling the owner cancels the detached work inside.
- **`RenderInputSnapshot`**, kept on each `Render` at its send: the prompt the generator got, the uploaded images and
  the clip's characters by path inside the job folder (nothing there is overwritten, so nothing is copied), the prep
  revision (`Job.prepRevision`) and the backend (`RenderBackend`: the generator, and for Wan the ComfyUI address and
  diffusion model; no secret). Library shows a result with its own characters and hides the control video of an
  earlier prep, a resubmit sends the same inputs (or says the clip was prepared again), and resuming or canceling a
  Wan render goes to the server it was sent to. Renders saved before the snapshot read the clip and Settings as they
  are now. Videos are not copied per render.
- **`AgentLedger`**, what agents' sends took of the daily budget. Its entry for a send is a reservation written
  atomically before the paid request: when the write fails the render fails with the reason and nothing is sent. On
  launch it adds back any send a render lists that it lacks, so a write that reached `job.json` but not the ledger
  can't lose spend.

### The prompt writer: any vision model behind one protocol

The entity, appearance and beat parts of the prompt are written by a vision model on the Mac, before prep, in three
layers:

```
SwapjutsuDescribe (library)                     SwapjutsuMLX (library, linked only by the executable)
  VisionLanguageModel   protocol: name,           MLXVisionBackend   download from Hugging Face, load
                        availability, respond,    MLXVisionModel     MLXVLM ChatSession, unload frees RAM
                        unload
  LocalVisionBackend    protocol: download, model
  Describer             the harness: prompts, fallback chain, JSON parsing, unload
  DescriptionPrompts    the prompts measured in the bake-off
  SystemVisionModel     Apple's FoundationModels, macOS 27
  OpenAICompatible…     any chat-completions API with images (OpenAI, OpenRouter, LM Studio, Ollama)
SwapjutsuPrep/Support/SceneDescription           the result: characters, place, motion, as editable text
SwapjutsuPrep/Support/ServicePrompt              fills the prompt from it; the person's wishes win
```

A provider only moves text and images; the harness owns the prompts and reads the answers, so a new local model or
API is one type conforming to `VisionLanguageModel`. `Describer` asks the models in order, falls through on an
unavailable model, an error, a refusal or an answer without the JSON asked for (a cut-off object is salvaged pair by
pair), and unloads every model it asked before prep loads depth and tracking. The app sees only the protocols:
`VisionModels` (Settings › Prompt) builds the chain from the choice (a downloaded local model, Apple's model, an API,
or off) with Apple's model as the fallback, and `JobStore` runs the description in the heavy work slot it shares with
prep (`JobWork`) and stores it in `JobSpec.description`, where the clip's Prompt step shows it for editing. `Sources/Swapjutsu/main.swift` injects
`MLXVisionBackend`, so no library or test target depends on MLX. `swift test` still compiles it: it builds every
target of the package, the `Swapjutsu` and `swapjutsu-describe` executables included, so a cold run builds MLX once
before the tests start. The app and `swapjutsu-describe` run the MLX model in a
child process of their own executable (`--vision-worker`, `WorkerVisionModel`), one per description: an MLX error,
such as a Metal command buffer that hit the GPU timeout while another app kept the GPU busy, calls `fatalError`, and
a scoped MLX error handler can't save the process (the next call on the broken arrays fails a precondition). The
child dies instead, `Describer` falls through to Apple's model, and ending the child on unload gives prep the
memory back. `swift run swapjutsu-describe` runs the
same harness from the command line.

Each local model is pinned like the Core ML ones: `VisionModelPins.swift`, written by
[scripts/pin-vision-models.py](../scripts/pin-vision-models.py), holds its Hugging Face commit and the size and
SHA-256 of every file. `MLXVisionBackend` downloads that commit, `VisionModels` hashes every file off the main actor
and discards the download if one differs, and only then writes the `.complete` marker, which names the snapshot
folder. A marker for another commit doesn't count, so moving a pin downloads the new commit.

Other angles of a character (`JobSpec.views`: three-quarter, side, back or a turnaround sheet) upload after the face
close-ups and are bound to their character in the prompt. The person adds them on the character's card. Prep records
the targets' face height (`Manifest.Quality.faceHeight`); under 64 px at 480p the render step offers Final 720p with
its price, never by default.

The window has three pages, one job each:

| Page | What happens there | Spends credits |
|---|---|---|
| Create | a new clip: pick a video (or, once the person turns them on, one of Higgsfield's public examples; until then the app sends Higgsfield nothing), cut it into 4–30 s ranges, prepare each as its own clip. A clip, in steps: check the control video, put a character image on each person prep found (extra images are extra references; background removal is per clip, applied at upload), the prompt, then a Draft 480p or a Final 720p/1080p with the price; finalize a draft at 1080p; prepare again with other options | renders only |
| Jobs | only the work on its way (prep, renders) and what stopped: Cancel, Resume, Dismiss | no |
| Library | every finished draft and final; a click opens the result's page (player, versions, characters, prompt, export) | no |

### The prep: stages behind protocols

Every step that another tool could do is a protocol in `Pipeline/Stages.swift`, with the macOS-native
implementation as the default in `PrepStages.standard`. A replacement conforms to one protocol and is passed in
`PrepStages`; the pipeline and the other stages don't change (`StageTests.aSwappedSegmenterDrivesTheRun` runs the
pipeline with a stand-in segmenter and depth model).

| Stage | Protocol | Default (folder) | Runs on | Drop-in candidates |
|---|---|---|---|---|
| Decode | — | `VideoSource` (Decode) | VideoToolbox | — |
| Shot cuts | `ShotDetecting` | `VisionShotDetector` (Shots) | Vision feature print + histogram | TransNet V2 |
| People | `PersonSegmenting` | `VisionPersonSegmenter` (People) | Vision instances + matte + bodies + faces, one request | SAM 3.1 |
| Faces | `FaceLocating` | `VisionFaceLocator` (People) | Vision landmarks, head-region retry | MediaPipe face mesh |
| Appearance | `AppearanceDescribing` | `MaskedAppearance` (Appearance) | Vision feature print as `[Float]` + HSV histogram | a face/person embedding, if colour proves too weak |
| Tracklets | — | `Tracker` (Tracking) | mask IoU + colour split | — |
| Mask tracking | `MaskTracking` | `EdgeTAMTracker` (Tracking) | EdgeTAM (Core ML, Neural Engine), seeded from Vision per shot and target; Vision's masks where it loses the target | SAM 3.1 (20–45× slower) |
| Identity | `IdentityClustering` | `AgglomerativeIdentity` (Identity) | average linkage with cannot-link | — |
| Depth | `DepthEstimating` | `DepthAnything` (Depth) | Core ML, Neural Engine | Video Depth Anything (temporally consistent; MLX port is Python-only today) |
| Control frames | — | `ControlRenderer` (Render) | Core Image on the GPU | — |
| Encode, mux | — | `VideoWriter`, `muxAudio` (Encode) | VideoToolbox H.264, AVAssetWriter AAC | — |
| Voice | `VoiceIsolating` | `AppleVoiceIsolator` (Audio) | AUSoundIsolation | htdemucs as Core ML (john-rocky/CoreML-Models, 80 MB), better on singing |
| Pitch | `PitchShifting` | `TimePitch` (Audio) | AVAudioUnitTimePitch | Rubber Band |
| Character cutout | `BackgroundRemoving` | `VisionCutout` (Character), used by the app's **Cut out characters** option | Vision subject lifting; only a subject a body or face detector confirms, so location references keep their scene | SAM 3.1, BiRefNet |

The run, with what runs at the same time:

```
decode ─┬─ shots → people → faces → appearance → tracks → identity → targets → mask tracking ─┐
        └─ depth: own decoder, model loads meanwhile ──────────────────────────────────────────┴─ depth scale per shot
decode → control / mask / review frames → encode ─┐
audio: used range → voice → pitch ────────────────┴─ mux → manifest.json
```

1. **People and depth, in parallel.** Two decoders read the clip at once. The people pass runs Vision (GPU) and
   writes the normalised original; the depth pass loads the model and runs it (Neural Engine) on every frame.
   Masks go to `work/masks` as LZ4-compressed 8-bit frames, depth to `work/depth` as raw half floats.
   Detections (96 × 96 mask grid, colour histogram, embedding, face landmarks) stay in memory.
2. **Decide.** Drop unconfirmed tracklets, cluster identities, pick targets (unknown ids fail here).
3. **Track the targets.** Decode again; EdgeTAM follows each target through each shot from its first Vision mask
   there and stores its soft masks beside Vision's. A shot takes them as a whole, or keeps Vision's when the
   tracker lost a target Vision still saw for half a second, overlaps Vision under 0.5, threw, or could not load
   (`manifest.tracking` says which and why). The result, one mask per target per frame including frames only the
   tracker found, is what the depth scale, the render and the quality metrics read. Then fix one depth scale per
   shot from the targets' cached depth only.
4. **Render.** Decode again; compose the control, mask and review frames from the caches. Mux the pitched vocals
   into `control.mp4` and the original into `prepared.mp4`. Write `manifest.json`.

Every loop checks for cancellation; encoders and the mux fail after 20 s without progress instead of waiting
forever; a cancelled or failed run deletes its half-written videos and `work/`.

Output of a run:

| File | For |
|---|---|
| `control.mp4` | Seedance `@Video1` |
| `prepared.mp4` | the normalised original, for comparison and the final mux |
| `mask.mp4` | the target mask (debug, other models) |
| `review.mp4` | everyone tinted by identity; the target brighter |
| `identities/<id>.jpg` | best crop of each person, for the target picker |
| `manifest.json` | shots, identity per frame, identities, targets, quality metrics, warnings, the Seedance prompt, timings |

### The app (planned)

- **Import** a clip (drag and drop, Photos) and trim it into 4–30 s ranges (`Draft+Ranges`). Each range is cut
  (re-encoded, so the first frame is exact) when the job copies its inputs (`JobFiles.adopt`).
- **Review** runs the prep in the background, then shows the identities as thumbnails with the main character
  preselected, and `review.mp4`. Nothing to click when the default is right; one click to change the target.
- **Character** takes an image (or later a video identity reference: Seedance `multi_reference`, `@Video2`).
- **Render** uploads `control.mp4` + the images and submits a Seedance 2.5 edit with the manifest prompt and the
  person's wishes: a **Draft** (480p, its `draft_task_id` saved) or a **Final** (720p or 1080p). **Finalize** sends
  only a draft's task to the Draft to Final node, which renders it at 1080p with the draft's motion, within 7 days.
  A clip keeps every render (`Render`), so drafts and finals sit side by side.
- **Export** replaces Seedance's audio with the original soundtrack (`muxAudio`).
- Job state lives on disk, one folder per job (`<time> <title> <id>`): `inputs/` (copies of the clip and the
  characters, the source cut to its range), the prep output, `job.json` (version 2: the prep stage and every render
  with its stage, provider request ID, draft task and files; written atomically at every step; a version 1 record
  comes back as a clip with its one render) and per render `seedance-<request>.mp4` and
  `<quality>-<id>.mp4`. The request ID is saved before polling, so a relaunch or a failed download or export
  resumes the same request and never resubmits a paid one.
- Agents render through the same calls. Every paid send goes through `JobStore.send`: an agent's only when the top of
  the estimate fits the render's `maxCost` and what is left of the day's agent budget (Settings › Agents), else the
  render waits for the person in Jobs. A render's `origin` in `job.json` keeps the agent's request and its sends.

### Agents

```
agent (Claude Code, …)
  └─ MCP over stdio ─→ swapjutsu mcp      Swapjutsu.app/Contents/Helpers/swapjutsu, unsandboxed, no state
      └─ JSON lines ─→ agent.sock         in the app group's container
          └──────────→ AgentServer        the sandboxed app: Allow agents checked on every command
              └──────→ AgentCommands      AgentPrep, AgentRenders, AgentLibrary
                  └──→ JobStore, Credentials, DepthModel, Navigation: the same calls the windows make
```

- **Modules.** `SwapjutsuAgent` is the contract both ends share: the commands and answers (`AgentProtocol`,
  `AgentPrep`, `AgentRender`, `AgentLibrary`), one JSON object per line (`AgentWire`), the blocking `AgentClient` and
  where the socket is (`AgentSocket`). `SwapjutsuMCP` is the MCP server `swapjutsu mcp` runs: JSON-RPC 2.0 over
  stdio, written out by hand (`MCPServer`), one tool per command (`Tool`, `ToolDefinitions`: snake_case arguments, the
  app's camelCase JSON back), `AppConnection` to find and start the app, `Inbox` for files. In the app,
  `AgentServer` and `AgentListener` own the socket and `AgentCommands` does the work through the same stores and
  calls as the windows.
- **The socket.** `~/Library/Group Containers/<TEAM_ID>.com.jutsustudio.swapjutsu/agent.sock`, the one folder both
  the sandboxed app and an unsandboxed process reach, mode 0600, there only while Allow agents is on. `swapjutsu`
  works its path out from the app group in `../../Info.plist`; it keeps no state, opens the socket for each command,
  starts the app in the background when nothing answers, and after `show` lets the app become active
  (`yieldActivation`). The socket is plain POSIX on both ends (`AgentListener`, `AgentClient`): a `sockaddr_un`
  holds 103 bytes of path, which this one outgrows at a user name of 24 characters, and Network.framework's
  `NWListener` then reports ready while listening nowhere. Darwin takes an address longer than `sockaddr_un` when its
  `sun_len` says so, so both ends size it to the path (`AgentSocket.withAddress`), up to 252 bytes, with no chdir;
  past that both refuse with `socket_path_too_long`, and Settings › Agents shows why.
- **Files go over the socket.** macOS keeps `swapjutsu` out of the group container (App Data protection: its writes
  there fail with EPERM, without a prompt), and the sandboxed app may not open an agent's paths. So `swapjutsu` sends
  each video and image a tool names as an `upload` (a JSON line, then exactly `size` raw bytes, up to 4 GiB), the app
  writes it into `inbox/<request_id>/` next to the socket, and the command names that copy. What the app hands back
  (clips, crops, `review.mp4`, results) is in the jobs folder, `~/Movies/Swapjutsu`, which `swapjutsu` can read.
- **The guard is in the app.** `swapjutsu` passes commands on and enforces nothing. The app reads Allow agents again
  for every command and upload, from the saved setting only in a bundled app (`AgentPreferences`: a launch argument
  can't turn it on), so turning it off refuses the next command even on an open connection. Every paid send, retries
  included, goes through `JobStore.send`, which lets an agent's through only within its `maxCost` and what is left of
  the day's agent budget ($0 until the person sets one); otherwise the render waits for the person. No command
  deletes anything, and no answer carries a credential: `capabilities` says whether a Comfy key is saved, never the
  key. A `request_id` stored in `job.json` makes `prepare`, `render` and `finalize` safe to repeat across relaunches.

## Packaging

```
Package.swift: SwapjutsuApp library ─→ project.yml (XcodeGen): Swapjutsu.app ─→ scripts/release.sh: Swapjutsu-X.Y.Z.dmg
  + SwapjutsuPrep, ComfyKit               main.swift, Info.plist, icon,            Developer ID, notarized and
                                          entitlements, signing                     stapled app inside a notarized DMG
```

- **Package.** All the code is in the Swift package. `swift build` and `swift test` need no Xcode project, and the
  `Swapjutsu` executable target (one `main.swift`) runs the app unbundled and unsandboxed for development.
- **App.** [project.yml](../project.yml) wraps the same `main.swift` and the `SwapjutsuApp` product in an app
  target: bundle IDs (`com.jutsustudio.Swapjutsu`, `.debug` for Debug), version and build number, the icon, the
  document types, arm64 only, the hardened runtime and the entitlements. `xcodegen generate` writes
  `Swapjutsu.xcodeproj`, `build/Info.plist` and `build/Swapjutsu.entitlements`; none of them is committed.
  [scripts/build-app.sh](../scripts/build-app.sh) builds it ad-hoc signed. A tool target builds the package's
  `swapjutsu-cli` (the `SwapjutsuMCP` library: `swapjutsu mcp` for agents) into `Contents/Helpers/swapjutsu`,
  hardened and unsandboxed, signed with the app.
- **Release.** [scripts/release.sh](../scripts/release.sh) archives the Release build, exports it with Developer ID,
  checks the signature, architecture, entitlements and version, notarizes and staples the app, packs it into a DMG
  with `hdiutil`, signs, notarizes and staples the DMG and launches it once (`--smoke-test`). The manual
  [release workflow](../.github/workflows/release.yml) runs the same script on a tag and leaves a draft GitHub
  release. Steps and secrets: [CONTRIBUTING.md](../CONTRIBUTING.md#releasing).

The app runs in the App Sandbox with network client access, read-write access to what the person drops or picks
(with app-scoped bookmarks for a custom depth model) and to `~/Movies`. Where data lives:

| What | Where |
|---|---|
| Settings (UserDefaults) | the container: `~/Library/Containers/com.jutsustudio.Swapjutsu/Data/Library/Preferences` |
| Models and downloaded examples | the container: `~/Library/Containers/com.jutsustudio.Swapjutsu/Data/Library/Application Support/Swapjutsu` |
| Jobs (inputs, prep output, renders, `job.json`) | `~/Movies/Swapjutsu`, outside the container, so they stay where the person can find them |
| Comfy API key | the login Keychain: `com.jutsustudio.swapjutsu.comfy.team` in a team-signed build, readable by every build of that team without a prompt; `….comfy.dev` in an ad-hoc build or `swift run` (CONTRIBUTING.md › The Comfy key) |
| Agent socket, only while Settings › Agents › Allow agents is on | the app group's container: `~/Library/Group Containers/<TEAM_ID>.com.jutsustudio.swapjutsu/agent.sock`, mode 0600 (any home whose socket path fits in 252 bytes) |
| Files agents hand over (`swapjutsu` sends their bytes over the socket before each command, up to 4 GiB each; the app writes them) | next to the socket: `…/<TEAM_ID>.com.jutsustudio.swapjutsu/inbox/<request_id>/`, adopted into the job folder like a drop and cleared once no clip reads them |

A Debug build uses `com.jutsustudio.Swapjutsu.debug` and so its own container; the unbundled executable has no
container and uses `~/Library/Application Support/Swapjutsu` directly, its agent socket included.

The bundle IDs and the app group come from one setting, `APP_ID_PREFIX` in project.yml. The group carries the
signing team (`$(DEVELOPMENT_TEAM).$(APP_ID_PREFIX).swapjutsu`, also written to Info.plist as `SwapjutsuAppGroup`,
where the app and `swapjutsu` read it): outside the App Store, macOS creates a group container only for a group that
starts with the team ID the app is signed with. An ad-hoc build has no team and so no agent socket; test agents with
the unbundled executable or a build signed with `DEVELOPMENT_TEAM` ([CONTRIBUTING.md](../CONTRIBUTING.md#agents)).

## Decisions

- **Native Vision and Core ML, no Python.** Prep is free, offline, and ships inside the app. The reference
  workflow needs Python, Replicate and a tunnel.
- **Automatic first.** Target selection, identities and quality checks are automatic; the review screen is for
  overriding, not a required step. Quality problems surface as manifest warnings.
- **Seedance 2.5 only for generation, for now.** Local models (mlx-video's LTX-2 / Wan2.x) have no
  video-to-video control path, so they cannot consume `control.mp4`. A local Wan 2.2 Animate port to MLX is a
  later, separate project.

## Open items

| Item | Why | Options |
|---|---|---|
| Vocals over a loud music bed or singing | AUSoundIsolation is tuned for speech; htdemucs separates singing better | htdemucs as Core ML ([john-rocky/CoreML-Models](https://github.com/john-rocky/CoreML-Models), 80 MB, MIT), downloaded on first use; compare against Replicate `cjwbw/demucs` `vocals.wav` |
| Temporally consistent depth | per-frame depth still flickers a little on close-ups (0.046 on the two-person clip) | Video Depth Anything Small (Apache-2.0) — MLX port exists only in Python ([mlx-vlm](https://github.com/Blaizzy/mlx-vlm)); port to mlx-swift or keep the shot scale |
| SAM 3.1 vs Vision masks | text-promptable, tracks objects as well as people | mlx-vlm `sam3_1` (Python, ~3.4 GB); compare on the fixtures, keep the better one |
| Identical clothing | colour identity fails for uniforms | face-identity embedding or MobileCLIP |
| Seedance prices | drafts follow a real bill (36 credits/s); finals are the top of the node's price badge | compare one 720p and one 1080p final with Comfy's transactions |
| Multi-person replacement | `--target all` paints every person, but which image goes to which person is only by screen-presence order in the prompt | per-person depth tint or separate passes per person; test on Seedance |
| Profile faces | face coverage 0.59 on a pilot in profile with sunglasses | body-pose head keypoints as lip-sync fallback |
