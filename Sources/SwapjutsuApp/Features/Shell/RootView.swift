import SwiftUI

/// Jutsu Studio's shell: a hand-built sidebar that folds away, and one page at a time. Pages send the person
/// elsewhere through `Navigation` rather than knowing about each other.
struct RootView: View {
    @Environment(Navigation.self) private var navigation
    /// Kept per window across launches; the titlebar button and View › Toggle Sidebar (⌃⌘S) change it.
    @SceneStorage("sidebarCollapsed") private var isSidebarCollapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView(columnVisibility: columnVisibility) {
            Sidebar(selection: $navigation.screen)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 300)
        } detail: {
            Group {
                switch navigation.screen {
                case .create: CreateView()
                case .jobs: JobsView()
                case .library: LibraryView()
                case .settings: SettingsView()
                }
            }
            .background(Theme.background)
        }
        // Beside the window buttons, where the system toggle sits in apps with a toolbar.
        .overlay(alignment: .topLeading) {
            SidebarToggle(isCollapsed: isSidebarCollapsed) {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { isSidebarCollapsed.toggle() }
            }
            .padding(.leading, 78)
            .padding(.top, 5)
            .ignoresSafeArea(.container, edges: .top)
        }
        .frame(minWidth: 900, minHeight: 680)
        #if DEBUG
            // `SWAPJUTSU_SIDEBAR=hidden` starts with the sidebar folded, for screenshots.
            .onAppear {
                if let value = ProcessInfo.processInfo.environment["SWAPJUTSU_SIDEBAR"] {
                    isSidebarCollapsed = value == "hidden"
                }
            }
        #endif
        .debugAutopilot()
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { isSidebarCollapsed ? .detailOnly : .all },
            set: { isSidebarCollapsed = $0 == .detailOnly })
    }
}

/// The titlebar button that shows and hides the sidebar, as in Jutsu Studio.
private struct SidebarToggle: View {
    let isCollapsed: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isHovering ? Theme.text : Theme.muted)
                .frame(width: 26, height: 22)
                .background(isHovering ? Theme.well : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isCollapsed ? "Show sidebar (⌃⌘S)" : "Hide sidebar (⌃⌘S)")
        .accessibilityLabel(isCollapsed ? "Show Sidebar" : "Hide Sidebar")
    }
}
