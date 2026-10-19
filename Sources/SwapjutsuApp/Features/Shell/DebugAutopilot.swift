import AppKit
import SwiftUI

extension View {
    /// Debug builds only: `SWAPJUTSU_AUTOPICK=<n>` picks the n-th Higgsfield example (`SWAPJUTSU_PREPARE=1`: and prepares it),
    /// `SWAPJUTSU_SCREEN=<page>` opens a page (`SWAPJUTSU_RESULT=1`: the newest result, `SWAPJUTSU_CLIP=<n>`: the
    /// n-th clip, `SWAPJUTSU_WINDOW=<w>x<h>`: the window's size), for screenshots and smoke runs without clicking.
    /// Release builds get the view unchanged.
    @ViewBuilder func debugAutopilot() -> some View {
        #if DEBUG
            modifier(DebugAutopilot())
        #else
            self
        #endif
    }
}

#if DEBUG
    private struct DebugAutopilot: ViewModifier {
        @Environment(Draft.self) private var draft
        @Environment(Navigation.self) private var navigation
        @Environment(JobStore.self) private var jobs
        @Environment(SampleLibrary.self) private var samples

        func body(content: Content) -> some View {
            content.task { await run() }
        }

        private func run() async {
            let environment = ProcessInfo.processInfo.environment
            // `SWAPJUTSU_WINDOW=1280x820` sizes the window, for screenshots at a known width.
            let size = environment["SWAPJUTSU_WINDOW"]?.split(separator: "x").compactMap { Double($0) } ?? []
            if size.count == 2 {
                // Again for a few seconds: the saved frame is restored after the window first shows.
                Task {
                    for _ in 0..<10 {
                        try? await Task.sleep(for: .seconds(1))
                        NSApplication.shared.windows.first(where: \.canBecomeMain)?.setFrame(
                            NSRect(x: 0, y: 0, width: size[0], height: size[1]), display: true)
                    }
                }
            }
            if let page = environment["SWAPJUTSU_SCREEN"].flatMap(Screen.init(rawValue:)) { navigation.screen = page }
            // `SWAPJUTSU_CLIP=<n>` opens the n-th clip in Create.
            if let value = environment["SWAPJUTSU_CLIP"], let index = Int(value), jobs.jobs.indices.contains(index) {
                navigation.open(jobs.jobs[index].id)
            }
            // `SWAPJUTSU_RESULT=1` opens the newest result's page.
            if environment["SWAPJUTSU_RESULT"] != nil { navigation.library(LibraryEntry.all(in: jobs.jobs).first?.id) }
            guard let value = environment["SWAPJUTSU_AUTOPICK"], let index = Int(value) else {
                return
            }
            await samples.loadIfNeeded()
            guard samples.current.indices.contains(index) else { return }
            await draft.apply(samples.current[index])
            try? await Task.sleep(for: .seconds(3))
            // `SWAPJUTSU_PREPARE=1` also prepares it; without, the example only fills the new clip, for screenshots.
            guard environment["SWAPJUTSU_PREPARE"] != nil else { return }
            let queued = draft.specs.map { jobs.enqueue($0) }
            navigation.open(queued.first?.id)
        }
    }
#endif
