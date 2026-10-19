import AppKit
import CoreText
import SwiftUI
import os

private let logger = Logger(subsystem: "com.jutsustudio.swapjutsu", category: "DesignSystem")

/// Design tokens. Dark only: the window forces `.preferredColorScheme(.dark)`.
///
/// Jutsu Studio's layout with Comfy's colors, flat: no gradients anywhere. The electric yellow `accent` is for
/// everything clickable and the brand mark; surfaces sit on Comfy's plum ink instead of neutral black.
enum Theme {
    // MARK: Colors

    /// Comfy ink (`#211927`) darkened, so the yellow keeps its punch on large areas.
    static let background = Color(rgb: 0x120D16)
    /// The sidebar, one step lighter than the page.
    static let sidebar = Color(rgb: 0x19121E)
    static let text = Color(rgb: 0xF0EFED)
    /// Secondary text, warm white at 0.62.
    static let muted = Color(rgb: 0xF0EFED).opacity(0.62)
    /// Labels, meta lines and hints.
    static let faint = Color(rgb: 0xF0EFED).opacity(0.48)
    static let stroke = Color.white.opacity(0.09)
    /// Inset areas: empty states, inputs.
    static let well = Color.white.opacity(0.04)
    /// Raised surfaces: panels, job rows.
    static let card = Color.white.opacity(0.055)
    /// Pills and secondary buttons.
    static let glass = Color.white.opacity(0.08)
    static let glassHover = Color.white.opacity(0.11)
    static let glassPressed = Color.white.opacity(0.14)
    static let glassStroke = Color.white.opacity(0.2)
    /// The active sidebar row.
    static let selection = Color.white.opacity(0.09)
    static let track = Color.white.opacity(0.08)
    /// Behind tags drawn on top of video frames.
    static let scrim = Color.black.opacity(0.55)
    /// Comfy yellow `#F2FF59`.
    static let accent = Color(rgb: 0xF2FF59)
    static let accentGlow = accent.opacity(0.25)
    /// Text and icons on `accent`: Comfy ink.
    static let ink = Color(rgb: 0x211927)
    static let inkWash = Color(rgb: 0x211927).opacity(0.12)
    static let danger = Color(rgb: 0xFF3B3B)
    static let warning = Color(rgb: 0xFABC25)
    static let info = Color(rgb: 0x9C8CFF)

    // MARK: Layout

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
        static let page: CGFloat = 28
        static let pageTop: CGFloat = 12
    }

    /// A little rounder than Jutsu Studio, like Comfy's cards.
    enum Radius {
        static let small: CGFloat = 8
        static let row: CGFloat = 10
        static let field: CGFloat = 12
        static let media: CGFloat = 14
        static let card: CGFloat = 20
    }

    // MARK: Type

    static let displayFontName = "BarlowCondensed-ExtraBold"

    /// The system-font sizes the UI uses; display text goes through `Font.display`.
    enum Typography {
        /// Hints, meta lines, captions under a field.
        static let meta = Font.system(size: 11)
        static let strongMeta = Font.system(size: 11, weight: .semibold)
        /// Secondary lines: descriptions, notes under media.
        static let note = Font.system(size: 12)
        static let strongNote = Font.system(size: 12, weight: .semibold)
        static let body = Font.system(size: 13)
        /// Row and option labels.
        static let label = Font.system(size: 13, weight: .medium)
        static let strong = Font.system(size: 13, weight: .semibold)
        static let rowTitle = Font.system(size: 14, weight: .semibold)
    }

    /// Registers the bundled display font for this process; SwiftUI falls back to the system font silently, so a
    /// failure is logged.
    static func registerFonts() {
        guard let url = Bundle.module.url(forResource: "BarlowCondensed-ExtraBold", withExtension: "ttf") else {
            logger.error("Display font missing from the bundle")
            return
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            logger.error("Display font failed to register: \(String(describing: error?.takeRetainedValue()))")
        }
    }
}

extension Color {
    /// `0xRRGGBB` in sRGB.
    init(rgb: UInt32) {
        self.init(
            .sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }
}

extension Font {
    /// Barlow Condensed ExtraBold for page titles and other display text; body text stays the system font.
    static func display(_ size: CGFloat) -> Font {
        .custom(Theme.displayFontName, size: size)
    }
}
