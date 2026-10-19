import Foundation

/// `LocalizedError` so the app shows the description instead of "PrepError error 5".
public enum PrepError: Error, CustomStringConvertible, LocalizedError, Equatable {
    case noVideoTrack(URL)
    case readFailed(String)
    case writeFailed(String)
    case tooShort(seconds: Double)
    case noPerson
    case model(String)
    /// An option out of range, caught before any work starts.
    case invalidOption(String)
    /// `--target` / `.ids` named people the clip doesn't have.
    case unknownTargets(requested: [Int], available: Int)

    public var description: String {
        switch self {
        case .noVideoTrack(let url): "No video track in \(url.lastPathComponent)"
        case .readFailed(let reason): "Could not read the video: \(reason)"
        case .writeFailed(let reason): "Could not write the video: \(reason)"
        case .tooShort(let seconds): String(format: "The clip is %.1f s; Seedance needs at least 4 s", seconds)
        case .noPerson: "No person found in the clip"
        case .model(let reason): "Depth model: \(reason)"
        case .invalidOption(let reason): reason
        case .unknownTargets(let ids, let count):
            "No person \(ids.map(String.init).joined(separator: ", ")) in this clip; it has \(count) (1–\(count))"
        }
    }

    public var errorDescription: String? { description }
}
