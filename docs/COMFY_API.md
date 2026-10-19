# Generation on Comfy

The Mac does the prep. Generation is one ComfyUI workflow,
[`seedance-character-swap.api.json`](../Sources/SwapjutsuApp/Resources/Workflows/seedance-character-swap.api.json),
run on Comfy Cloud through the documented **Comfy API v2**
([overview](https://docs.comfy.org/api-reference/v2/overview),
[SDKs](https://docs.comfy.org/development/api-development/sdks)). One Comfy API key covers the job, the asset
storage and the Seedance partner node.

## The workflow

API format, the graph ComfyUI's "Save (API Format)" writes, so it also loads and runs in ComfyUI itself:

| Node | Class | Role |
|---|---|---|
| 1 | `LoadVideo` | `control.mp4` from `swapjutsu-prep`, `@Video1` |
| 2 (and 11, 12, … for more characters) | `LoadImage` | the characters, `@Image1…` |
| 3 | `ByteDance2ReferenceNodeV2` | Seedance 2.5 Draft (480p) or Seedance 2.5 (720p or 1080p); `task_type: edit`, so the output keeps the control clip's length and aspect ratio |
| 4 | `SaveVideo` | the result |
| 5 | `SaveText` | a draft's `draft_task_id` (output 1 of node 3) as a text output; removed for a final, since the node refuses a final with that output linked |

A draft is finalized with a second workflow,
[`seedance-draft-to-final.api.json`](../Sources/SwapjutsuApp/Resources/Workflows/seedance-draft-to-final.api.json):
`ByteDance2DraftToFinalVideoNode` with only `draft_task_id`, then `SaveVideo`. Seedance reuses the draft's prompt,
references, duration, aspect ratio and audio setting and renders 1080p; a draft can be finalized for 7 days. This is
the two-stage flow of Comfy's own `api_seedance2_5_draft_r2v` template.

Dynamic inputs are flattened with dots, as ComfyUI does it: `model` picks the option, then `model.prompt`,
`model.task_type`, `model.reference_videos.video_1`, `model.reference_images.image_1`, and so on.

The app fills in the uploaded assets and the prompt (`SeedanceWorkflow.make` in
`Sources/SwapjutsuApp/Model/Comfy.swift`) and sends it through `ComfyClient` (`Sources/ComfyKit`). To run it by hand, open it in ComfyUI and pick `control.mp4` and a
character image in nodes 1 and 2.

## The calls (Comfy Cloud, `https://cloud.comfy.org`)

All calls carry `Authorization: Bearer <Comfy API key>`. Every POST carries an `Idempotency-Key`, which is
single use: a duplicate is refused with `422 idempotency_key_reuse` and never runs twice.

`ComfyClient` follows the rules of Comfy's SDKs:

- One key per logical call, reused on every retry of it.
- A POST is retried only when it never reached the server (DNS, connect, TLS, offline) or on 429 with
  `Retry-After`. A 5xx after a POST is not retried, since the job may already exist.
- `Retry-After` (seconds or an HTTP date) is never shortened: up to `maxDelay` (30 s) it is waited out, a longer
  one comes back to the caller as `.busy`.
- A GET is also retried on 5xx and dropped connections, with exponential backoff.
- Polling starts at 0.5 s and backs off ×1.5 up to 5 s. Terminal statuses: `succeeded`, `failed`, `canceled`,
  `expired`.
- `extra_data` is left out when there is no partner key.
- Uploads stream from a temporary multipart file instead of loading the video into memory. The MIME type comes
  from the extension; an unknown one is sent as `application/octet-stream`, never guessed as JPEG.

The app adds one rule on top: a submit that failed after it may have reached Comfy (a 5xx, a dropped connection,
an unreadable reply) is "Check Comfy" in Jobs and is never resubmitted by itself. Once a request ID exists
it is saved in the job's `job.json` and reused until Comfy finished or failed it, so a failed poll, download or
export, or a relaunch, resumes it at no extra cost.

1. **Upload inputs:** `POST /api/v2/assets` as `multipart/form-data` with `file`, `content_type`, `file_path`
   and `tags=input` → `{"id": …}`. The limit is about 100 MB per request. The bytes are deduplicated
   server-side by their blake3 hash.
2. **Submit:** `POST /api/v2/jobs`
   `{"workflow": <graph>, "extra_data": {"api_key_comfy_org": <key>}}` → `201 {"id", "status": "queued"}`.
   Each upload is referenced in the graph as `{"__type": "core/ASSET", "info": {"id": "<asset id>"}}` in place
   of the file name. `extra_data.api_key_comfy_org` is what lets the partner node bill the same account.
3. **Poll:** `GET /api/v2/jobs/{id}` until `status` is `succeeded`, `failed`, `canceled` or `expired`.
   `outputs[]` lists the saved files (`node_id`, `content_type`, `id`).
4. **Download:** `GET /api/v2/assets/{output id}` → `url`, a signed link valid for about 6 h that needs no key.
   The app downloads it right away and muxes the original soundtrack back in (`<quality>-<id>.mp4`). For a draft it
   also reads node 5's text output, the `draft_task_id`.

Errors come in the envelope `{"error": {"code", "message"}}`: `insufficient_credits` (402), `invalid_workflow`
or `missing_asset` (422), `queue_full` or `rate_limited` (429 + `Retry-After`). Seedance's own codes arrive in
a failed job's `error.message`:

| Code | Meaning |
|---|---|
| `InvalidParameter.TaskTypeConstraint` | an edit needs a 4–30 s source clip |
| `InvalidParameter.TaskTypeMismatch` | the prompt doesn't read as an edit; use replace/change wording |
| `OutputAudioSensitiveContentDetected.PolicyViolation` | the generated audio was rejected (we replace the audio anyway) |

## Limits on `control.mp4` (Seedance 2.5)

- 409,600 to 8,295,044 pixels per frame at 480p/720p. 854×480 just passes (409,920). The node's
  `auto_downscale` handles big clips but not small ones, so the prep must not go below this.
- 4–30 s for an edit; every reference video at least 1.8 s.

## Account and price

- **Comfy Cloud Standard** ($20/month, or $16/month billed yearly) is required to run workflows on Cloud.
  Partner nodes draw from the same credit balance as the plan's monthly credits; top-ups are available.
  $1 = 211 credits for top-ups.
- **Seedance 2.5 with a video input:** 1.931 credits per 1,000 tokens at 480p and 720p, 2.112 at 1080p
  ([pricing](https://docs.comfy.org/tutorials/partner-nodes/pricing)). The node's price badge works out to
  roughly $0.88–1.76 for a 10 s 480p edit; the real bill for a 5 s 480p draft edit with a reference video (direct
  route) was 180 credits ($0.85), 36 credits a second, at the top of the badge. Drafts are estimated from that bill,
  finals from the top of the badge (the clip rendered plus the clip read) until one is billed.

## The direct route (Partner Nodes, `https://api.comfy.org`)

The default since Settings › Comfy got a route picker. `PartnerSeedanceClient` (`Sources/ComfyKit`) sends what
ComfyUI's `ByteDance2ReferenceNodeV2` and `ByteDance2DraftToFinalVideoNode` send, read from ComfyUI commit
`5cc4b870094c89090db54bd8d12649dcaf89f2ba` (0.41.0), and spends prepaid credits; no subscription. It takes the
node's settings from the bundled workflow, so both routes ask Seedance for the same thing.

- Headers: `X-API-KEY`, `Comfy-Env`, `Comfy-Usage-Source`, `Comfy-Core-Version: 0.41.0`; every POST carries one
  `Idempotency-Key` (`uuid4().hex`) on all its attempts. 408/5xx are retried 3 times, 429 up to 16 times,
  `409 idempotency_in_flight` is waited out, `Retry-After` is honored up to 150 s.
- Upload, per character image (an RGB PNG of at most 2048² pixels) and then `control.mp4`:
  `POST /customers/storage {file_name, content_type}` → `PUT` the bytes to `upload_url` →
  `POST /proxy/seedance/virtual-library/assets {url: download_url, hash: sha256, asset_type: "Video"}` (no type
  for an image) → `GET /proxy/seedance/assets/{id}` every 5 s until `Active` → `asset://{id}`.
- Create: `POST /proxy/byteplus/api/v3/contents/generations/tasks` with `model: dreamina-seedance-2-5-260628`,
  `content` (the prompt, the images as `reference_image`, the video as `reference_video`), `resolution`,
  `ratio: adaptive`, `duration: -1`, `omni_reference_task_type: edit`, `generate_audio`, `seed`, `watermark`,
  `output_format`, and `draft: true` for a draft → `{id}`. A draft's `draft_task_id` is that ID; its final sends
  `content: [{type: draft_task, draft_task: {id}}]`, `resolution: 1080p`, `watermark`.
- Poll: `GET /proxy/byteplus-seedance2/api/v3/contents/generations/tasks/{id}` until `succeeded`
  (`content.video_url`, downloaded without a key) or `failed`/`cancelled` (`error.code`). There is no cancel call.

Request IDs on this route are saved as `seedance:<task id>`, so a render resumes where it was sent after a
relaunch even if the route changed meanwhile. The price estimate is the same either way.

## Why not call the providers directly

The contest requires building on the Comfy Developer Platform. Comfy Router (`api.comfy.org/v2/models/…`) is
pay-per-use, but it takes video only as a public URL or a Seedance asset id and offers no upload. ComfyUI's
internal `/proxy/...` and `/customers/storage` routes are undocumented. Comfy API v2 is documented, uploads the
inputs itself and runs a workflow file that is part of the repo.

## Wan 2.2 Animate on your own ComfyUI

The open-source generator. Settings › Own ComfyUI points the app at a ComfyUI the person runs: this Mac,
another Mac or a GPU box on the network. The app talks to it over ComfyUI's own server API only; no runtime, model or
node is bundled, and the App Sandbox stays as it is (`network.client` covers the connection). Wan 2.2 Animate 14B
needs a capable machine: ComfyUI's tutorial asks for a GPU with enough memory and suggests a small size for a first
run. A render on it costs nothing, so the app quotes $0.

### The graph

[`wan-animate-character-swap.api.json`](../Sources/SwapjutsuApp/Resources/Workflows/wan-animate-character-swap.api.json)
is Comfy's own "Wan2.2 Animate" template (`templates/video_wan2_2_14B_animate.json` in
[Comfy-Org/workflow_templates](https://github.com/Comfy-Org/workflow_templates) at
`59a3b48bf369c5a15f29a1308bae3e279fa15505`; [tutorial](https://docs.comfy.org/tutorials/video/wan/wan2-2-animate))
in **Mix** (replacement) mode, its subgraphs flattened by hand into API format. Node input names were checked against
ComfyUI `c06bf5f569d268b80076e5f44126f87cdf835869` and comfyui_controlnet_aux
`a587a4c1594524c1d2de5cd1a86cd868ff448e1c`.

| Node | Class | Role |
|---|---|---|
| 1 | `UNETLoader` | `Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors` (the template's) or `wan2.2_animate_14B_bf16.safetensors`, picked in Settings |
| 2 | `LoraLoaderModelOnly` | `lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors`, strength 1: the 4-step LoRA |
| 3 | `ModelSamplingSD3` | shift 8 |
| 4 | `CLIPLoader` | `umt5_xxl_fp8_e4m3fn_scaled.safetensors`, type `wan` |
| 5, 6 | `CLIPTextEncode` | the person's wishes (or "The character moves naturally in the scene."), and the template's negative prompt |
| 7 | `VAELoader` | `wan_2.1_vae.safetensors` |
| 8, 10 | `CLIPVisionLoader`, `CLIPVisionEncode` | `clip_vision_h.safetensors`, crop `none`, on the character |
| 9 | `LoadImage` | the character: the reference image |
| 11, 12, 13 | `LoadVideo`, `GetVideoComponents`, `ImageScale` | `prepared.mp4` at 16 fps and the render size (lanczos, centre crop: a no-op, the app already sized it) |
| 14 | `DWPreprocessor` | face only (`detect_face`), for `face_video` |
| 15 | `DWPreprocessor` | body and hands, for `pose_video`; both at `resolution` = the short side, what the template's Pixel Perfect Resolution gives for frames already at the render size |
| 16, 17, 18 | `LoadVideo`, `GetVideoComponents`, `ImageScale` | prep's `mask.mp4` at 16 fps and the render size: replaces the template's Points Editor and SAM 2 |
| 19–22 | `ImageScaleBy` (area, ×1/32), `ImageScale` (nearest-exact, back to size), `ImageToMask`, `ThresholdMask` (0.05) | the mask in 32 px blocks, a block set when the person covers 5 % of it: core nodes standing in for KJNodes' `BlockifyMask` (block size 32) |
| 23, 24 | `EmptyImage` (black), `ImageCompositeMasked` | `background_video`: the source with the blocks blacked out, core nodes standing in for KJNodes' `DrawMaskOnImage` |
| 101 | `WanAnimateToVideo` | the first window: width, height, `length` up to 77, `continue_motion_max_frames` 5, `video_frame_offset` 0, with the reference, CLIP vision, face, pose, background and mask |
| 102–105 | `KSampler`, `TrimVideoLatent`, `VAEDecode`, `ImageFromBatch` | 6 steps, cfg 1, euler/simple, denoise 1; the reference latent trimmed (`trim_latent`), the continued frames dropped (`trim_image`) |
| 201–206 | the same, then `ImageBatch` | one extend window: `continue_motion` = the frames so far, `video_frame_offset` = the window before's; its new frames appended |
| 899 | `ImageFromBatch` | the frames cut to the source's length |
| 900, 901 | `CreateVideo` (16 fps), `SaveVideo` (mp4) | the result, without sound |

`WanAnimateWorkflow.make` (`Sources/SwapjutsuApp/Model/WanAnimate.swift`) fills in the uploaded names, the size, the
diffusion model, the prompt and a seed, drops nodes 201–206 for a clip of one window and repeats them renumbered
(301–306, 401–406, …) for each further window, the way the template's note says to copy its Video Extend group:
`batch_images` and `video_frame_offset` of each window go into the next.

`SaveVideo` gets both `format.codec` (ComfyUI's newer dynamic combo) and `codec` (the older plain one); ComfyUI drops
an input a node doesn't have.

**Custom nodes:** only [comfyui_controlnet_aux](https://github.com/Fannovel16/comfyui_controlnet_aux), for
`DWPreprocessor` (DWPose; it downloads `yolox_l.onnx` and `dw-ll_ucoco_384_bs5.torchscript.pt` from Hugging Face on
its first run). The template's other two packs are not needed: KJNodes' Points Editor and ComfyUI-segment-anything-2's
SAM 2 are replaced by prep's mask, KJNodes' `BlockifyMask` and `DrawMaskOnImage` by core nodes. Left out on purpose:
the template's `WanAnimate_relight_lora_fp16.safetensors` (it is in the template but not in the tutorial's model
list) and its `PixelPerfectResolution` (the app computes the same number).

### Frames, size and length

- **16 fps.** The template's Create Video runs at 16 fps and a 77-frame window is "around 4.8125 seconds" in the
  tutorial. The app resamples `prepared.mp4` and `mask.mp4` to 16 fps before the upload (`WanVideo.resample`, an
  `AVVideoComposition` with a 1/16 s frame duration), and at the render size, so the graph needs no resampling node.
- **Size:** the short side 480 (Final 480p) or 720 (Final 720p), the long side keeping the aspect ratio, both rounded
  to multiples of 16 (`WanAnimateToVideo`'s step): 1920×1080 becomes 848×480 or 1280×720. No 1080p.
- **Windows:** the first is up to 77 frames; each extend repeats the last 5 and adds up to 72; every length is 4k + 1;
  the last is only as long as what is left needs. A 4 s clip (64 frames) is one window of 65; a 30 s clip (480 frames)
  is 7 windows. The output is cut to the source's frame count, and the app puts the original soundtrack back as for
  Seedance (`muxAudio`, to the length of `control.mp4`).

### One person per render

Wan 2.2 Animate replaces one person with one reference image, and prep's `mask.mp4` is the union of every replaced
person, so a clip prepared with several targets can't be split into one pass per person without changing prep.
Create and agents refuse such a clip with the reason ("prepare it again with one person, or render it with
Seedance"), and the same for a clip prepared with a replaced background: Wan keeps the clip's own background.

### The calls (ComfyUI's server API)

`ComfyUIClient` (`Sources/ComfyKit/ComfyUIClient.swift`), read from ComfyUI's `server.py`:

1. **Upload:** `POST /upload/image`, multipart `image` (the file) + `type=input` + `overwrite=true`, for the two
   videos too. Names are `swapjutsu-<8 hex>-source.mp4`, `-mask.mp4`, `-character.<ext>`, so a dropped upload is
   simply sent again.
2. **Queue:** `POST /prompt {prompt, prompt_id, client_id: "swapjutsu"}` → `{prompt_id, number, node_errors}`. The app
   picks the `prompt_id` (a lowercase UUID; ComfyUI mints one if it is older). A 400 with `node_errors` (a missing
   model or node) fails the render with ComfyUI's words; nothing ran. `/prompt` has no idempotency key, so it is
   sent again only when it never reached the server; any other failure after it may have arrived is "Check
   ComfyUI" in Jobs, as for Seedance, and nothing resubmits by itself.
3. **Poll:** `GET /queue` (still waiting or running), then `GET /history/{prompt_id}`: `status.status_str` is `success`
   or `error`, `status.messages` carries `execution_error` (node, exception) or `execution_interrupted`, and
   `outputs["901"].images[0]` is the saved video (`filename`, `subfolder`, `type`). In neither: ComfyUI restarted or
   the queue was cleared; the render fails and can be sent again for free.
4. **Download:** `GET /view?filename=&subfolder=&type=output`.
5. **Cancel:** `POST /queue {delete: [id]}` while it waits, `POST /interrupt {prompt_id}` while it runs (only then:
   a ComfyUI from before targeted interrupts would stop whatever runs).
6. **Check** (Settings): `GET /object_info`, compared with the graph's node classes and the loaders' file lists
   (`UNETLoader.unet_name`, `LoraLoaderModelOnly.lora_name`, `CLIPLoader.clip_name`, `CLIPVisionLoader.clip_name`,
   `VAELoader.vae_name`), in either combo format ComfyUI writes. What is missing is listed with a link: the tutorial,
   comfyui_controlnet_aux, or the model's file on Hugging Face (Comfy-Org/Wan_2.2_ComfyUI_Repackaged,
   Comfy-Org/Wan_2.1_ComfyUI_repackaged, and Kijai's repos for the FP8 model and the LoRA, as the tutorial links them).

GETs, uploads and cancels are retried on a dropped connection or a 5xx with backoff; a 429's `Retry-After` is waited
out up to 30 s. An optional token (Settings, kept in the Keychain beside the Comfy key) goes as
`Authorization: Bearer` for a ComfyUI behind a reverse proxy; ComfyUI itself has no auth.

### Plain http, ATS and the sandbox

ComfyUI serves plain http. project.yml sets `NSAppTransportSecurity › NSAllowsLocalNetworking` and
`NSLocalNetworkUsageDescription` (macOS asks before the app first reaches another device on the network). Measured on
macOS 27 with a small bundled probe, with and without the key: http reaches `127.0.0.1`, `localhost`, `.local` names,
unqualified names and private (10/8, 172.16/12, 192.168/16), link-local and IPv6 ULA addresses; ATS refuses it for
other host names (`gpu.lan`, tailnet names), public addresses and 100.64/10 (Tailscale), which need https (a reverse
proxy). Settings says so under the address. The `swift run` executable has no Info.plist and no ATS: it reaches
everything over http, so dev runs need nothing.

### Agents

`quote` and `render` take `model: wan22Animate` (Seedance when left out) and the qualities `final480` and `final720`.
It goes through the same check in `JobStore.send` as every agent send: its estimate is $0, so it fits any `max_cost`
and any daily agent budget, $0 included, and adds nothing to the day's spending; a free render is let through even
when the day's paid sends already went over a lowered budget. `capabilities` says whether an own ComfyUI is set up
and passed its Check (`hasOwnComfyUI`), and `render` refuses Wan until it has, as Create does. Seedance requests keep the exact parameters they had, so old request ids still match.

### Manual test (needs a machine that can run it)

1. On the GPU box: install ComfyUI and comfyui_controlnet_aux, put the five model files in `models/` as the tutorial
   shows, start ComfyUI with `--listen`.
2. In Swapjutsu: Settings › Own ComfyUI, turn it on, enter `http://<box ip>:8188`, Check: it should say
   Ready. If not, the list says what to install.
3. Create: a 4–8 s clip with one person, prepared with the background kept, one character. Pick Wan 2.2 Animate,
   Final 480p, Generate. Jobs shows the prompt id; the result lands in Library with the original sound.
4. Cancel a second render while it waits and while it runs; ComfyUI's queue should drop or interrupt it.
5. A clip over 5 s exercises the extend windows; check the motion carries over at about 4.8 s.

To run the graph by hand in ComfyUI, open the JSON (Workflow › Open), pick the uploaded files in nodes 9, 11 and 16,
and Queue.
