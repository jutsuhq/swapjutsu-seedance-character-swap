import AppKit
import Foundation

/// `--smoke-test`: `scripts/smoke-launch.sh` launches a built app once and expects it to start and quit cleanly.
/// The app opens its first window as usual but restores no jobs, loads no model and makes no request, so it is safe
/// on a Mac with real jobs in ~/Movies/Swapjutsu.
enum SmokeTest {
    static let argument = "--smoke-test"
    static let launchedLine = "smoke-test: launched"
    /// A Keychain service nothing writes, so `Credentials` finds no key without reading the real one.
    static let keychainService = "com.jutsustudio.swapjutsu.smoke-test"

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    /// Opens the first window afresh instead of the windows saved at the last quit: a saved window that can't be
    /// restored leaves the app with no window at all, and the launched line would never come. Registered, not set,
    /// so nothing is written to the app's defaults.
    static func ignoreSavedWindows() {
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }

    /// Reports the launch once the window has had a few run-loop turns to lay out, then quits with status 0.
    @MainActor
    static func finish(after delay: Duration = .seconds(3)) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            FileHandle.standardOutput.write(Data((launchedLine + "\n").utf8))
            NSApplication.shared.terminate(nil)
        }
    }
}
