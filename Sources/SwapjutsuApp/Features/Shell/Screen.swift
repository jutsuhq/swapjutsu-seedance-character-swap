/// The pages of the window, in sidebar order: make clips (prep, characters, render), watch what's running, keep the
/// results.
enum Screen: String, CaseIterable, Identifiable {
    case create, jobs, library, settings

    var id: Self { self }
    static let pages: [Screen] = [.create, .jobs, .library]

    var title: String {
        switch self {
        case .create: "Create"
        case .jobs: "Jobs"
        case .library: "Library"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .create: "sparkles"
        case .jobs: "square.stack.3d.up"
        case .library: "film"
        case .settings: "gearshape"
        }
    }
}
