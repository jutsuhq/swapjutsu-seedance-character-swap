import Observation
import SwiftUI

/// The page on screen and what each page has open, so one page can send the person to a clip or a result on another
/// without knowing how that page is built.
@MainActor
@Observable
final class Navigation {
    var screen = Screen.create
    /// The clip Create shows (`nil`: a new clip), and the render its player should open on.
    var clip: UUID?
    var render: UUID?
    /// The result Library has open; `nil` shows the grid.
    var result: UUID?
    /// The video picker is open on Create's new clip.
    var isChoosingVideo = false
    /// The tab Settings shows.
    var settingsTab = SettingsTab.comfy

    /// Opens a clip in Create, on `render` if given; `nil` opens a new clip.
    func open(_ clip: UUID?, render: UUID? = nil) {
        self.clip = clip
        self.render = render
        screen = .create
    }

    /// File › Choose Video… (⌘O): the new clip, with the picker open.
    func chooseVideo() {
        open(nil)
        isChoosingVideo = true
    }

    func settings(_ tab: SettingsTab) {
        settingsTab = tab
        screen = .settings
    }

    func library(_ result: UUID?) {
        self.result = result
        screen = .library
    }
}
