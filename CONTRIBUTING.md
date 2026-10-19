# Contributing

Start with [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the module layout. For anything larger than a small fix,
open an issue first.

## Setup

macOS 15+ on Apple Silicon with Xcode 27 (Swift 6.4).

```bash
scripts/fetch-models.sh             # the depth and tracking models, not committed
xcrun swift build
xcrun swift build --product Swapjutsu && .build/debug/Swapjutsu
```

`xcrun swift` runs the Swift of the selected Xcode (`xcode-select -p`). A bare `swift` can resolve to another
toolchain first on your `PATH` (Swiftly, a downloaded `.xctoolchain`) that is older than Xcode 27 or no longer
installed; the package needs tools 6.2.

The app bundle is generated from [project.yml](project.yml) with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`): `scripts/build-app.sh [Debug|Release]` builds `build/<config>/Swapjutsu.app`.
`Swapjutsu.xcodeproj`, `Info.plist` and the entitlements are generated, not committed; change `project.yml`, not the
build settings in Xcode.

The build script caches XcodeGen's spec in `build/xcodegen-cache.json`, regenerating the project when its inputs
change. Keep `build/DerivedData` between builds so Xcode can reuse compiled modules.

## Tests

```bash
xcrun swift test                          # unit tests and synthetic audio/video checks
SWAPJUTSU_FIXTURES=1 xcrun swift test     # plus the end-to-end clips, ~5 min
scripts/smoke-launch.sh build/Release/Swapjutsu.app   # launches a built app once and quits
```

The fixture clips are not in the repo; [docs/TESTING.md](docs/TESTING.md) lists them and the measured results. The
[Test workflow](.github/workflows/test.yml) runs the unit tests on demand.

## Agents

The app listens for agents on a Unix socket only while Settings › Agents › Allow agents is on (off by default).

The unbundled executable, unsandboxed and listening in Application Support, also takes the setting as a launch
argument for that launch, the quick way to try it:

```bash
xcrun swift build --product Swapjutsu && .build/debug/Swapjutsu -allowAgents YES
printf '{"version":1,"command":"capabilities"}\n' | nc -U ~/Library/Application\ Support/Swapjutsu/agent.sock
```

A bundled app ignores `-allowAgents YES`: anything that can launch it, an agent included, could otherwise turn agents
on. It reads only the setting saved in its own defaults, so turn on the Settings › Agents switch. `defaults write` from
a shell doesn't reach it: the setting is in the sandbox container, which macOS keeps other apps out of.

A sandboxed build listens in its app group's container,
`~/Library/Group Containers/<TEAM_ID>.com.jutsustudio.swapjutsu/agent.sock`, and needs a build signed with your team:
`DEVELOPMENT_TEAM=<TEAM_ID> scripts/release.sh --skip-notarize`. An ad-hoc build
(`scripts/build-app.sh`, or `release.sh` without `DEVELOPMENT_TEAM`) has no team ID, so the sandbox won't create its
group container, and Settings › Agents says so. Switching one bundle ID between ad-hoc and team-signed builds makes
macOS ask once whether the new build may use the container the other one created.

### swapjutsu

Agents reach the app through `swapjutsu mcp`, a stdio MCP server ([Sources/SwapjutsuMCP](Sources/SwapjutsuMCP)). The
app bundles it at `Swapjutsu.app/Contents/Helpers/swapjutsu`, not in `Contents/MacOS`, where on a case-insensitive
disk it would be the same file as `Swapjutsu`; for the same reason the package's product is `swapjutsu-cli`. It is
not sandboxed and is signed with the app's identity; `release.sh` checks both. It finds the socket from its own
place: the group in `../../Info.plist` (`SwapjutsuAppGroup`), and starts that app in the background when nothing
answers. Unbundled, it uses the `swift run` socket, so the two work together without setup:

```bash
xcrun swift build && .build/debug/Swapjutsu -allowAgents YES &
claude mcp add swapjutsu-dev -- "$PWD/.build/debug/swapjutsu-cli" mcp
```

`SWAPJUTSU_AGENT_SOCKET=<path>` points it at any other socket. The unbundled app reads the same variable, so a second
development copy can run next to the first without taking over its socket. A bundled app that is running but doesn't
answer within 10 s of its launch gets `agents_off`: the app doesn't listen at all while agents are off.

**Files.** The sandboxed app may not open an agent's paths, and macOS keeps `swapjutsu` out of the app group's
container (App Data protection: its writes there fail with EPERM, without a prompt). So `swapjutsu` sends the bytes of
every video and image a tool names over the socket (`upload`: a JSON line, then exactly `size` raw bytes; `Inbox` in
SwapjutsuMCP), the app writes them into `inbox/<request_id>/` next to the socket (`AgentUpload.swift`), and the command
names that copy. A file may be up to 4 GiB (`AgentInbox.maxFileSize`); both ends check. The app takes files only from
there (`AgentPrep.swift`), adopts them as it does a drop (`JobFiles`), and removes inbox folders no
clip reads any more once they are an hour old. The prep tools reuse Create's paths and limits: ranges are checked by
the trim strip's rules, characters go through `JobStore.addReferences`, and a refusal comes back as an agent error
(`bad_request`, `file_refused`, `not_prepared`, `busy`, `no_such_clip`, `request_conflict`). A `prepare` stores its
`request_id`, the agent's parameters and the client's name (`clientInfo` from initialize) in each clip's `job.json`
(`origin`), which is how a repeated request finds its clips after a relaunch.

**Renders.** `quote`, `render`, `finalize` and `job_action` (`AgentRenders.swift`) go through the same `JobStore` calls
as Create, with an origin on the render (`RenderOrigin` in `job.json`: client, `request_id`, time, `maxCost`,
parameters). The spending check is in `JobStore.send`, the only way into a paid submit, so it covers a new render, a
finalize and every retry: a person's send goes as asked, an agent's goes only when the estimate's upper bound
(`SeedancePrice.cents`, to the cent) is within its `maxCost` and within what is left of today's agent budget, and
otherwise the render stays in the `waiting` stage with the reason. Each send an agent's check lets through is recorded
on the render (`sends`) and counts against that day by the upper bound, from the moment it is let through, so renders
on their way count; it is given back if the request never reached the provider. A retry of a render that has a
provider request resumes it and is free, so it isn't checked. An agent can't retry a render whose submit may have
landed (`unknown`) or one a person started (`needs_person`). The budget (`agentDailyBudget`) is read like Allow
agents, from the saved setting only in a bundled app (`AgentPreferences`); the unbundled executable also takes
`-agentDailyBudget 5`.

**Library.** `library_search` and `show` (`AgentLibrary.swift`) read what Library shows: `LibraryEntry.all`, the
finished renders newest first, filtered by `text` (every word in the title, the version's name or the prompt) and
`quality`, a page of `limit` at a time. The cursor is the last result's render id, so a render that finishes meanwhile
(it goes to the top) doesn't shift the pages after it. `show` with a `result` opens Library on that render, and Library
drops its Drafts/Finals filter if it hides it; a render that isn't finished opens on its clip in Create.

**The socket's path.** Both ends size the socket address to the path (`AgentSocket.withAddress`), so a group
container under a long home folder works up to 252 bytes; NWListener can't, which is why `AgentListener` is plain
POSIX. Past the limit the app shows `socket_path_too_long` in Settings › Agents and `swapjutsu` answers with the same
code without starting the app. `AgentServerTests` listens under a fake long home to keep this working.

### Trying the tools unbundled

The unbundled app and `swapjutsu-cli` need no signing. Keep them off your real jobs and any running development copy,
with `SWAPJUTSU_COMFY_KEY` unset and no key saved for the development build, so nothing can be paid for:

```bash
xcrun swift build
export SWAPJUTSU_JOBS=$(mktemp -d) SWAPJUTSU_AGENT_SOCKET=$(mktemp -d)/agent.sock
.build/debug/Swapjutsu -allowAgents YES &
.build/debug/swapjutsu-cli mcp   # then initialize, tools/call prepare, clips, set_characters, quote, render…
```

Each stdin line is one JSON-RPC message, for example:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"dev","version":"1"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"library_search","arguments":{"limit":5}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"show","arguments":{"result":"<render id>"}}}
```

`library_search` lists what is in `SWAPJUTSU_JOBS`: a folder with a `job.json` whose render has `"stage":"done"` and a
`result` file name shows up after a relaunch, no render needed. Quit the app by its PID when done.

### Testing against a signed build

The sandbox, the app group container, activation after `show` and the uploads' route around App Data protection only
happen in a signed bundle, so check agent changes there once before a release:

1. `DEVELOPMENT_TEAM=<TEAM_ID> scripts/release.sh --skip-notarize` (a Developer ID build without notarization) and
   copy `build/export/Swapjutsu.app` to `/Applications`; quit any other copy with the same bundle ID first.
2. Open it and turn on Settings › Agents › Allow agents; Settings › Agents shows "Listening", or why not. Set a small
   daily agent budget only if you mean to test a paid render.
3. `claude mcp add swapjutsu-signed -- /Applications/Swapjutsu.app/Contents/Helpers/swapjutsu mcp`, or the stdio
   lines above piped into that binary. Check `capabilities`; quit the app and check that the next call starts it in
   the background; `show` a page and a result and check that the window comes to the front; `prepare` a video
   from your Downloads (an upload through the socket) and `library_search`.
4. Turn Allow agents off and check that the next call says `agents_off`.

## The Comfy key

Which Keychain item a build uses depends on how it is signed (`ComfyKeyStore.select` in
[Credentials.swift](Sources/SwapjutsuApp/Services/Credentials.swift)):

- **Signed with a team** (`DEVELOPMENT_TEAM` set, Release or Debug): `com.jutsustudio.swapjutsu.comfy.team` in the
  login Keychain. Its access list admits any app, and macOS still checks the item's partition list, which it sets to
  the saving app's team ID. Every build signed by that team reads the key without a prompt, however often it is
  rebuilt; an ad-hoc build or another vendor's app would have to ask for the password.
- **Without a team** (`scripts/build-app.sh`, `release.sh` without `DEVELOPMENT_TEAM`, `swift run`): its own item,
  `com.jutsustudio.swapjutsu.comfy.dev`, so it never asks for the signed builds' key. That item trusts only the exact
  build that saved it, so a rebuild asks for the password when it needs the key. To skip the Keychain, set the key in
  the environment, which then wins over the item:

  ```bash
  SWAPJUTSU_COMFY_KEY=<key> .build/debug/Swapjutsu
  ```

Launching never reads a key: the app only asks whether an item exists, which never prompts. The key is read when a
render starts or Settings › Comfy shows it. The agent `capabilities` command reports `hasComfyKey` from that check,
`--smoke-test` looks for an item nothing writes, and the unit tests save throwaway items of their own.

The data protection keychain would share the key by access group, but on macOS it needs a provisioning profile: a
Developer ID build with only the app group entitlement gets `errSecMissingEntitlement` (-34018), and one that claims
`keychain-access-groups` is killed at launch.

## Releasing

[scripts/release.sh](scripts/release.sh) archives a Release build (arm64, hardened runtime, App Sandbox), exports it
signed with Developer ID, notarizes and staples the app, puts it with an Applications link into
`build/Swapjutsu-<version>.dmg`, signs, notarizes and staples the DMG, checks both with Gatekeeper, launches the app
from the DMG once with [scripts/smoke-launch.sh](scripts/smoke-launch.sh) and writes the DMG's `.sha256` and
`build/Swapjutsu-<version>-dSYMs.zip`. It stops at the first failed step. `scripts/release.sh --help` lists the
options.

Keep the dSYMs zip with every published release: a crash report can only be symbolicated with the dSYMs of the build
that produced it.

### One-time setup

1. Apple Developer Program membership. In Xcode › Settings › Accounts › Manage Certificates, add a **Developer ID
   Application** certificate (or create it at developer.apple.com and import it with its private key into the login
   keychain). `security find-identity -v -p codesigning` must list `Developer ID Application: <name> (<TEAM_ID>)`.
2. Create an app-specific password at [account.apple.com](https://account.apple.com) › Sign-In and Security, then
   store the notarization credentials in the keychain once:
   ```bash
   xcrun notarytool store-credentials swapjutsu-notary --apple-id <apple-id-email> --team-id <TEAM_ID>
   ```
   An App Store Connect API key works instead: `NOTARY_KEY=AuthKey_<KEY_ID>.p8 NOTARY_KEY_ID=… NOTARY_ISSUER=…`
   replaces `NOTARY_PROFILE`.
3. `brew install xcodegen`, or the version the release workflow pins:
   `export PATH="$(scripts/install-xcodegen.sh build/tools):$PATH"`.

The certificate and the password stay in your keychain; nothing from this setup goes into the repo.

### Build

1. In [project.yml](project.yml), set `MARKETING_VERSION` to the new version (`X.Y.Z`) and increment
   `CURRENT_PROJECT_VERSION`. The script refuses a build number that is not higher than in the previous `v*.*.*` tag.
   If `Package.resolved` changed since the last release, run `scripts/third-party-notices.sh` so the app ships the
   licenses of what it now links. Merge to `main`.
2. On an up-to-date `main`:
   ```bash
   DEVELOPMENT_TEAM=<TEAM_ID> NOTARY_PROFILE=swapjutsu-notary scripts/release.sh
   ```
   `--skip-smoke` only on a Mac without a logged-in GUI session. `scripts/release.sh --skip-notarize` makes a local
   test DMG (ad-hoc signed, or Developer ID with `DEVELOPMENT_TEAM`) that Gatekeeper rejects on other Macs: never
   publish it.
3. Check what it left in `build/` (the script runs the same checks; these confirm the files you upload):
   ```bash
   spctl -a -vv -t open --context context:primary-signature build/Swapjutsu-X.Y.Z.dmg   # accepted, Notarized Developer ID
   xcrun stapler validate build/Swapjutsu-X.Y.Z.dmg
   spctl -a -vv build/export/Swapjutsu.app
   xcrun stapler validate build/export/Swapjutsu.app
   (cd build && shasum -a 256 -c Swapjutsu-X.Y.Z.dmg.sha256)
   ```
   Then copy the DMG to a Mac that never had a dev build, open it, drag the app to Applications and launch it:
   Gatekeeper must open it without a warning.

### Publish

```bash
git tag vX.Y.Z && git push origin vX.Y.Z
gh release create vX.Y.Z --draft --title "Swapjutsu X.Y.Z" --generate-notes \
  build/Swapjutsu-X.Y.Z.dmg build/Swapjutsu-X.Y.Z.dmg.sha256 build/Swapjutsu-X.Y.Z-dSYMs.zip
```

Run the post-release checklist on the DMG attached to the draft, then publish it. The checklist is the manual
sandbox checks no script covers, [listed on epic #32](https://github.com/jutsuhq/swapjutsu-seedance-character-swap/issues/32#issuecomment-6230282594):
drops and the file picker in Create and Characters, a custom depth model kept after a relaunch, the model download
in the release container, export and Reveal in Finder, and the Comfy key kept in the Keychain after a relaunch.

### The release workflow

[.github/workflows/release.yml](.github/workflows/release.yml) does the Build and the `gh release create` above on a
GitHub macOS runner. It is manual while the repo is private, because macOS minutes are billed. After the version bump
is merged, push the tag and run the workflow on it:

```bash
git tag vX.Y.Z && git push origin vX.Y.Z
gh workflow run release.yml --ref vX.Y.Z
```

It fails unless it runs on a tag that matches `MARKETING_VERSION`. It imports the certificate into a temporary
keychain, notarizes with an App Store Connect API key, installs XcodeGen with
[scripts/install-xcodegen.sh](scripts/install-xcodegen.sh) (pinned version and SHA-256; to update it, change
`VERSION` and `SHA256` there) and leaves a draft release with the DMG, its `.sha256` and the dSYMs zip. Check the
DMG as in step 3 and run the checklist before publishing the draft.

Repository secrets (Settings › Secrets and variables › Actions):

| Secret | Value |
| --- | --- |
| `APPLE_TEAM_ID` | The 10-character Team ID. |
| `DEVELOPER_ID_P12_BASE64` | The Developer ID Application certificate with its private key, exported from Keychain Access as `.p12`, base64-encoded. |
| `DEVELOPER_ID_P12_PASSWORD` | The password chosen at export. |
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | From App Store Connect › Users and Access › Integrations › Team Keys. |
| `ASC_KEY_P8` | The contents of `AuthKey_<KEY_ID>.p8`. A key with the **Developer** role is enough for notarization. |

Set them from the files rather than pasting values into a shell, then delete the exported `.p12`:

```bash
base64 -i developer-id.p12 | gh secret set DEVELOPER_ID_P12_BASE64
gh secret set DEVELOPER_ID_P12_PASSWORD   # prompts for the value
gh secret set ASC_KEY_P8 < AuthKey_<KEY_ID>.p8
```

## Branches and PRs

- Branch per issue: `issue-<number>-<slug>`.
- One issue per PR, `Closes #<number>` in the description.
- Commit messages: imperative subject, a body that explains why.
