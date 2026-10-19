import AppKit
import SwapjutsuDescribe
import SwiftUI

/// The composition root: every store is made here once and handed down through the environment.
/// A library type so an app bundle can host it; `Sources/Swapjutsu` is the executable for `swift run`.
public struct SwapjutsuApp: App {
    /// The local vision models' implementation (MLX), set by the executable before `main()`; the library itself
    /// never links MLX, so its tests don't build it.
    @MainActor public static var localVisionBackend: (any LocalVisionBackend)? {
        get { VisionModels.liveBackend }
        set { VisionModels.liveBackend = newValue }
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var credentials: Credentials
    @State private var jobs: JobStore
    @State private var draft = Draft()
    @State private var samples: SampleLibrary
    @State private var navigation: Navigation
    @State private var depth: DepthModel
    @State private var tracking: TrackingModel
    @State private var visionModels: VisionModels
    @State private var agents: AgentServer
    @State private var fixes: TargetFixes

    public init() {
        // `--smoke-test` opens the window with nothing that reaches the network or the person's data: no jobs, no
        // gallery request, no model load, no agent socket, and a Keychain item nothing writes (reading the real one can
        // ask for permission, which would hang an unattended launch).
        let isSmokeTest = SmokeTest.isRequested
        let credentials =
            isSmokeTest
            ? Credentials(comfy: ComfyKeyStore(secret: KeychainSecret(service: SmokeTest.keychainService)))
            : Credentials()
        let depth = DepthModel()
        let tracking = TrackingModel()
        let navigation = Navigation()
        let visionModels = VisionModels()
        let jobs = JobStore(
            providers: Providers.live(credentials), preparer: Preparers.pipeline(depth, tracking: tracking),
            restoresJobs: !isSmokeTest, agentBudget: { AgentPreferences().dailyBudget },
            agentLedger: AppPaths.agentLedger,
            describer: Describers.live(visionModels, isOn: !isSmokeTest))
        let fixes = TargetFixes(retracker: Retrackers.edgeTAM(tracking))
        let commands = AgentCommands(
            credentials: credentials, depth: depth, navigation: navigation, jobs: jobs, fixes: fixes)
        let agents = AgentServer(socket: AppPaths.agentSocket, handle: commands.run)
        _credentials = State(initialValue: credentials)
        _depth = State(initialValue: depth)
        _tracking = State(initialValue: tracking)
        _visionModels = State(initialValue: visionModels)
        _navigation = State(initialValue: navigation)
        _agents = State(initialValue: agents)
        _jobs = State(initialValue: jobs)
        _fixes = State(initialValue: fixes)
        _samples = State(initialValue: SampleLibrary(catalog: isSmokeTest ? SampleCatalog(base: nil) : SampleCatalog()))
        guard !isSmokeTest else {
            SmokeTest.ignoreSavedWindows()
            return
        }
        agents.run()
        // A new copy or a new macOS compiles for the Neural Engine on first load; better now than in the first prep.
        depth.warm()
        tracking.warm()
    }

    public var body: some Scene {
        WindowGroup("Swapjutsu") {
            RootView()
                .environment(credentials)
                .environment(jobs)
                .environment(draft)
                .environment(samples)
                .environment(navigation)
                .environment(depth)
                .environment(tracking)
                .environment(visionModels)
                .environment(agents)
                .environment(fixes)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onAppear { if SmokeTest.isRequested { SmokeTest.finish() } }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            // View › Toggle Sidebar (⌃⌘S), acting on the window's split view.
            SidebarCommands()
            CommandGroup(replacing: .appInfo) {
                Button("About Swapjutsu") { AboutPanel.show() }
                Button("Acknowledgements") { AboutPanel.showNotices() }
            }
            CommandGroup(after: .newItem) {
                Button("Choose Video…") { navigation.chooseVideo() }
                    .keyboardShortcut("o")
            }
            // The pages, as in the sidebar.
            CommandGroup(before: .sidebar) {
                ForEach(Array(Screen.pages.enumerated()), id: \.element) { index, screen in
                    Button(screen.title) { navigation.screen = screen }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
                Divider()
            }
            // Settings is a page of the window, not a window of its own.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { navigation.screen = .settings }
                    .keyboardShortcut(",")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Theme.registerFonts()
        // Swapjutsu.app has an Info.plist with the icon and starts as a regular app. The bare `swift run`
        // executable has neither: it starts as a background process with no Dock icon, so it gets both here.
        if Bundle.main.bundleIdentifier == nil {
            NSApplication.shared.setActivationPolicy(.regular)
            if let icon = Bundle.module.image(forResource: "AppIcon") {
                NSApplication.shared.applicationIconImage = icon
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
