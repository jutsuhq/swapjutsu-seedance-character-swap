import Foundation

/// Settings › Prep: what a new clip starts with. Each clip keeps its own copy, changed on the clip.
enum PrepDefaults {
    static let targetKey = "prep.target"
    static let faceGuideKey = "prep.faceGuide"
    static let removeBackgroundKey = "prep.removeBackground"
    static let replaceBackgroundKey = "prep.replaceBackground"

    static var target: PrepTarget {
        UserDefaults.standard.string(forKey: targetKey).flatMap(PrepTarget.init(rawValue:)) ?? .main
    }
    static var faceGuide: Bool { UserDefaults.standard.bool(forKey: faceGuideKey) }
    static var removeBackground: Bool { UserDefaults.standard.bool(forKey: removeBackgroundKey) }
    static var replaceBackground: Bool { UserDefaults.standard.bool(forKey: replaceBackgroundKey) }
}
