import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case comfy, ownComfy, prep, prompt, storage, agents

    var id: Self { self }

    var title: String {
        switch self {
        case .comfy: "Comfy"
        case .ownComfy: "Own ComfyUI"
        case .prep: "Prep"
        case .prompt: "Prompt"
        case .storage: "Storage"
        case .agents: "Agents"
        }
    }
}

/// Settings, as in Jutsu Studio: a tab switcher over themed cards of rows. Comfy is the paid side, Own ComfyUI the
/// person's own server for Wan 2.2 Animate, Prep the free one on this Mac, Prompt who describes the characters for the prompt, Storage what the app keeps on disk, Agents
/// whether AI agents may drive the app.
struct SettingsView: View {
    @Environment(Navigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                title: "Settings",
                subtitle: "Your Comfy key for Seedance 2.5, your own ComfyUI for Wan 2.2 Animate, how new clips are "
                    + "prepared, and where results go.")
            SegmentedControl(selection: $navigation.settingsTab, options: SettingsTab.allCases.map { ($0, $0.title) })
                .fixedSize()
                .padding(.bottom, Theme.Spacing.xLarge)
            ScrollView {
                Group {
                    switch navigation.settingsTab {
                    case .comfy: ComfySettings()
                    case .ownComfy: OwnComfySettings()
                    case .prep: PrepSettings()
                    case .prompt: DescriberSettings()
                    case .storage: StorageSettings()
                    case .agents: AgentSettings()
                    }
                }
                // Rows stay readable on a wide window instead of stretching label and control apart.
                .frame(maxWidth: 640, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Theme.Spacing.page)
            }
        }
        .pagePadding()
    }
}
