import ComfyKit
import SwiftUI

/// Settings › Own ComfyUI: the address of a ComfyUI the person runs, an optional token for one behind a
/// reverse proxy, the diffusion model to load, and Check, which reads its `/object_info` for what Wan 2.2 Animate needs.
struct OwnComfySettings: View {
    @Environment(Credentials.self) private var credentials
    @AppStorage(OwnComfy.enabledKey) private var isEnabled = false
    @AppStorage(OwnComfy.urlKey) private var address = OwnComfy.defaultURL
    @AppStorage(OwnComfy.diffusionKey) private var diffusion = WanModels.fp8
    @AppStorage(OwnComfy.checkedKey) private var checked = ""
    @State private var token = ""
    @State private var failure: String?
    @State private var check: CheckState = .idle
    @FocusState private var focus: Field?

    private enum Field { case address, token }

    private enum CheckState: Equatable {
        case idle, checking
        case done(WanAnimateCheck)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SettingsSection(
                title: "Own ComfyUI (open source)",
                footer: "Renders Wan 2.2 Animate on a ComfyUI you run: this Mac, another Mac or a GPU box on your "
                    + "network. Wan 2.2 Animate 14B needs a capable machine; ComfyUI's docs say a GPU with enough "
                    + "memory. Swapjutsu only talks to ComfyUI over its API; ComfyUI isn't part of the app."
            ) {
                SettingsRow(
                    label: "Use my ComfyUI", detail: "Adds Wan 2.2 Animate to Create's render step once Check passes",
                    isFirst: true
                ) {
                    Toggle("Use my ComfyUI", isOn: $isEnabled).settingsSwitch()
                }
                SettingsRow(label: "Address", detail: addressDetail) {
                    TextField(OwnComfy.defaultURL, text: $address)
                        .focused($focus, equals: .address)
                        .themedField(isFocused: focus == .address)
                        .frame(width: 240)
                        .onSubmit(runCheck)
                }
                SettingsRow(
                    label: credentials.hasOwnComfyToken ? "Replace token" : "Token",
                    detail: credentials.hasOwnComfyToken
                        ? "Saved in your Keychain, sent as a bearer token" : "Optional, for a ComfyUI behind a proxy"
                ) {
                    HStack(spacing: Theme.Spacing.small) {
                        SecureField("none", text: $token)
                            .focused($focus, equals: .token)
                            .themedField(isFocused: focus == .token)
                            .frame(width: 160)
                            .onSubmit(saveToken)
                        Button("Save", action: saveToken)
                            .buttonStyle(.secondaryAction)
                            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                        if credentials.hasOwnComfyToken {
                            Button("Remove", role: .destructive) { write("") }.buttonStyle(.secondaryAction)
                        }
                    }
                }
                SettingsRow(label: "Diffusion model", detail: WanModels.label(diffusion)) {
                    SegmentedControl(
                        selection: $diffusion, options: [(WanModels.fp8, "FP8 scaled"), (WanModels.bf16, "BF16")],
                        isCompact: true
                    )
                    .fixedSize()
                }
                SettingsRow(label: "Check", detail: checkDetail) {
                    Button(
                        check == .checking ? "Checking…" : "Check", systemImage: "checkmark.circle", action: runCheck
                    )
                    .buttonStyle(.primaryAction)
                    .disabled(check == .checking || OwnComfy.parse(address) == nil)
                }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.note)
                    .foregroundStyle(Theme.danger)
            }
            if case .done(let result) = check, !result.isReady { missing(result) }
            SettingsSection(
                title: "Setting it up",
                footer: "Install the comfyui_controlnet_aux custom nodes (DWPose; it downloads its pose models on the "
                    + "first run) and put the models in ComfyUI's models folder, as the tutorial shows. Start ComfyUI "
                    + "with --listen to reach it from this Mac."
            ) {
                linkRow("Tutorial", "docs.comfy.org · Wan2.2 Animate", WanModels.tutorial, isFirst: true)
                linkRow("Models", "Hugging Face · Comfy-Org/Wan_2.2_ComfyUI_Repackaged", WanModels.repackaged)
                linkRow("Custom nodes", "GitHub · comfyui_controlnet_aux", WanModels.controlnetAux)
            }
        }
        .onChange(of: address) {
            check = .idle
            checked = ""
        }
    }

    private var addressDetail: String {
        guard let url = OwnComfy.parse(address) else { return "Not a valid http(s) address" }
        if OwnComfy.needsHTTPS(url) {
            return "macOS allows plain http only to this Mac, .local names and private addresses; use https here"
        }
        return "ComfyUI's address, port included"
    }

    private var checkDetail: String {
        switch check {
        case .idle:
            OwnComfy.isReady(enabled: true, address: address, checked: checked)
                ? "Passed: Wan 2.2 Animate is in Create's render step" : "Asks ComfyUI which nodes and models it has"
        case .checking: "Reading /object_info…"
        case .failed(let reason): reason
        case .done(let result):
            result.isReady
                ? "Ready: every node and model is there"
                : "\(result.missingNodes.count + result.missingModels.count) missing, listed below"
        }
    }

    /// What Check didn't find, with where to get each.
    private func missing(_ result: WanAnimateCheck) -> some View {
        SettingsSection(title: "Missing on your ComfyUI") {
            ForEach(Array(result.missingNodes.enumerated()), id: \.element) { index, node in
                linkRow(node.name, "Node · \(node.source)", node.link, isFirst: index == 0)
            }
            ForEach(Array(result.missingModels.enumerated()), id: \.element) { index, file in
                linkRow(
                    file.name, "Model · models/\(file.folder)", file.download,
                    isFirst: index == 0 && result.missingNodes.isEmpty)
            }
        }
    }

    private func linkRow(_ label: String, _ detail: String, _ link: URL?, isFirst: Bool = false) -> some View {
        SettingsRow(label: label, detail: detail, isFirst: isFirst) {
            if let link {
                Link(destination: link) { Label("Open", systemImage: "arrow.up.right") }
                    .buttonStyle(.secondaryAction)
            }
        }
    }

    private func runCheck() {
        guard let url = OwnComfy.parse(address) else { return }
        check = .checking
        let client = ComfyUIClient(baseURL: url, token: credentials.ownComfyToken)
        Task {
            do {
                let result = try WanAnimateCheck.evaluate(try await client.objectInfo())
                // The picked model stays when it is there; otherwise the one the server has.
                if !result.diffusionModels.contains(diffusion), let first = result.diffusionModels.first {
                    diffusion = first
                }
                check = .done(result)
                checked = result.isReady ? url.absoluteString : ""
            } catch {
                check = .failed("Couldn't reach ComfyUI: \(error.localizedDescription)")
                checked = ""
            }
        }
    }

    private func saveToken() {
        write(token)
        if failure == nil { token = "" }
    }

    private func write(_ value: String) {
        do {
            try credentials.saveOwnComfyToken(value)
            failure = nil
            // Another token may not get through; Check again.
            checked = ""
            check = .idle
        } catch {
            failure = error.localizedDescription
        }
    }
}
