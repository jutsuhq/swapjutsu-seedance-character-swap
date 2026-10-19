import SwiftUI

/// The brand mark, the pages, the model plate and Settings.
struct Sidebar: View {
    @Binding var selection: Screen
    @Environment(JobStore.self) private var jobs

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            BrandMark()
                .padding(.horizontal, 6)
                .padding(.bottom, 18)
            ForEach(Screen.pages) { row(for: $0) }
            Spacer(minLength: 0)
            SeedanceBadge()
                .padding(.bottom, Theme.Spacing.small)
            row(for: .settings)
        }
        .padding(.horizontal, 10)
        .padding(.top, 36)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }

    /// Create counts clips waiting for a first render, Jobs the work on its way.
    private func badge(for screen: Screen) -> Int {
        switch screen {
        case .create: jobs.readyCount
        case .jobs: jobs.activeCount
        default: 0
        }
    }

    private func row(for screen: Screen) -> some View {
        SidebarRow(
            title: screen.title, systemImage: screen.systemImage, isSelected: selection == screen,
            badge: badge(for: screen)
        ) { selection = screen }
    }
}

/// Where Jutsu Studio shows the account plate: what renders can use right now. Seedance's dot turns yellow once a
/// Comfy key is saved; Wan 2.2 Animate shows once the own ComfyUI passed its Check. Prep needs neither.
private struct SeedanceBadge: View {
    @Environment(Credentials.self) private var credentials
    @AppStorage(OwnComfy.enabledKey) private var ownComfyEnabled = false
    @AppStorage(OwnComfy.urlKey) private var ownComfyURL = OwnComfy.defaultURL
    @AppStorage(OwnComfy.checkedKey) private var ownComfyChecked = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            line(
                "Seedance 2.5", isOn: credentials.hasComfyKey,
                detail: credentials.hasComfyKey ? "Comfy key saved" : "No Comfy key: add one in Settings")
            if OwnComfy.isReady(enabled: ownComfyEnabled, address: ownComfyURL, checked: ownComfyChecked) {
                line("Wan 2.2 Animate", isOn: true, detail: "Your ComfyUI passed its Check")
            }
            Text("Prep runs free on this Mac")
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.faint)
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: Theme.Radius.field)
        .accessibilityElement(children: .combine)
    }

    private func line(_ title: String, isOn: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isOn ? Theme.accent : Theme.warning)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(Theme.Typography.strongNote)
                    .foregroundStyle(Theme.text)
            }
            Text(detail)
                .font(Theme.Typography.meta)
                .foregroundStyle(isOn ? Theme.muted : Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
