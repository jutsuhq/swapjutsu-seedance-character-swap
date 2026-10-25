import SwiftUI

/// The Comfy API key, in the Keychain, the route renders take, and what Seedance 2.5 costs through it. The person's
/// own ComfyUI for Wan 2.2 Animate has its own tab (`OwnComfySettings`).
struct ComfySettings: View {
    @Environment(Credentials.self) private var credentials
    @AppStorage(RenderRoute.key) private var route = RenderRoute.direct
    @State private var key = ""
    @State private var isSaved = false
    @State private var failure: String?
    @State private var isConfirmingRemove = false
    @FocusState private var isFocused: Bool

    private static let keysPage = URL(string: "https://platform.comfy.org/profile/api-keys")
    private static let billingPage = URL(string: "https://platform.comfy.org/profile/billing")

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SettingsSection(
                title: "Comfy API key",
                footer: "Kept in your login Keychain. Both routes use it and pay from your Comfy credits. Prep "
                    + "needs no key."
            ) {
                SettingsRow(label: "Status", detail: status, isFirst: true) {
                    HStack(spacing: 6) {
                        Circle().fill(credentials.hasComfyKey ? Theme.accent : Theme.warning).frame(width: 7, height: 7)
                        Text(credentials.hasComfyKey ? "Saved" : "Not set")
                            .font(Theme.Typography.strong)
                            .foregroundStyle(credentials.hasComfyKey ? Theme.text : Theme.warning)
                    }
                }
                SettingsRow(label: credentials.hasComfyKey ? "Replace key" : "Key") {
                    HStack(spacing: Theme.Spacing.small) {
                        SecureField("comfyui-…", text: $key)
                            .focused($isFocused)
                            .themedField(isFocused: isFocused)
                            .frame(width: 240)
                            .onSubmit(save)
                        Button(isSaved ? "Saved" : "Save", action: save)
                            .buttonStyle(.primaryAction)
                            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                SettingsRow(label: "Get a key", detail: "platform.comfy.org › Profile › API keys") {
                    HStack(spacing: Theme.Spacing.small) {
                        if let page = Self.keysPage {
                            Link(destination: page) { Label("Open", systemImage: "arrow.up.right") }
                                .buttonStyle(.secondaryAction)
                        }
                        if credentials.hasComfyKey {
                            Button("Remove", role: .destructive) { isConfirmingRemove = true }
                                .buttonStyle(.secondaryAction)
                        }
                    }
                }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.note)
                    .foregroundStyle(Theme.danger)
            }
            SettingsSection(
                title: "Route",
                footer: "Direct calls Seedance through Comfy's Partner Nodes API and spends prepaid credits; no "
                    + "subscription. Comfy Cloud runs the bundled workflow and needs a Standard subscription or "
                    + "higher. A change applies to new renders; ones on their way finish where they started."
            ) {
                SettingsRow(label: "Renders go", detail: route.detail, isFirst: true) {
                    SegmentedControl(
                        selection: $route, options: [(.direct, "Direct, using credits"), (.cloud, "Comfy Cloud")],
                        isCompact: true
                    )
                    .fixedSize()
                }
                SettingsRow(label: "Buy credits", detail: "platform.comfy.org › Profile › Billing") {
                    if let page = Self.billingPage {
                        Link(destination: page) { Label("Open", systemImage: "arrow.up.right") }
                            .buttonStyle(.secondaryAction)
                    }
                }
            }
            SettingsSection(
                title: "Seedance 2.5",
                footer: "Estimates for a 10 s clip: drafts from Comfy's bill, finals from the node's price badge; "
                    + "Comfy's transactions show the real cost. A draft can be finalized at 1080p for 7 days, with the same motion."
            ) {
                SettingsRow(
                    label: "Runs on", value: route == .direct ? "api.comfy.org · Partner Nodes" : "Comfy Cloud · API v2",
                    isFirst: true)
                ForEach(GenerationModel.seedance25.qualities, id: \.self) { quality in
                    SettingsRow(label: quality.title, value: SeedancePrice.text(seconds: 10, quality: quality))
                }
            }
            SettingsSection(
                title: "Wan 3.0",
                footer: "Estimates for a 10 s clip: Comfy bills the control video's seconds and the render's. Clips of "
                    + "up to 15 s; no draft."
            ) {
                SettingsRow(label: "Runs on", value: "api.comfy.org · Partner Nodes", isFirst: true)
                ForEach(GenerationModel.wan30.qualities, id: \.self) { quality in
                    SettingsRow(label: quality.title, value: GenerationModel.wan30.priceText(seconds: 10, quality: quality))
                }
            }
        }
        .onChange(of: key) { isSaved = false }
        .confirmationDialog("Remove the Comfy key?", isPresented: $isConfirmingRemove) {
            Button("Remove Key", role: .destructive) { write("") }
        } message: {
            Text("Renders stop until a key is saved again. Renders on their way resume once it is.")
        }
    }

    /// "Ends in …a1b2": enough to tell keys apart without showing one.
    private var status: String {
        guard let saved = credentials.comfyKey else { return "Add a key to render; prep works without one." }
        return "Ends in …\(saved.suffix(4))"
    }

    private func save() {
        write(key)
        if failure == nil {
            key = ""
            isSaved = true
        }
    }

    private func write(_ value: String) {
        do {
            try credentials.saveComfyKey(value)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}
