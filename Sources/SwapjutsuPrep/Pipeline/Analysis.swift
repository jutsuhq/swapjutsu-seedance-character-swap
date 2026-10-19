import CoreImage

/// What the people pass found.
struct Analysis {
    var cuts: [Int] = []
    /// Which way up each shot stands, from the plan.
    var uprights: [Upright] = []
    var perFrame: [[PersonDetection]]
    var tracklets: [Tracklet] = []
}

/// What the depth pass left in the cache: which frames have a map, how each maps onto its frame, and the person crops
/// by detection key. Crops have the same size and format as the full-frame maps.
struct DepthResult: Sendable {
    let frames: Set<Int>
    let size: CGSize
    /// By frame: a shot turned upright (`Upright`) places its maps differently from one filmed upright.
    let toFrame: [Int: CGAffineTransform]
    let crops: [String: DepthCropPlacement]
    let format: DepthFormat
    let modelLoad: Double
    let inference: Double
}

/// Who is who and who gets replaced.
struct Decision {
    let cuts: [Int]
    let uprights: [Upright]
    let perFrame: [[PersonDetection]]
    let tracklets: [Tracklet]
    let result: IdentityResult
    let identityOf: [String: Int]
    let targets: Set<Int>
    /// Best look of each identity, for thumbnails: largest detection with a face, else largest.
    let bestShot: [Int: PersonDetection]

    func shot(of frame: Int) -> Int { cuts.filter { $0 <= frame }.count }
    func upright(of frame: Int) -> Upright { uprights[shot(of: frame)] }
}

/// A detection in the render pass with its mask and identity.
struct PlacedPerson {
    let detection: PersonDetection
    let mask: CIImage
    let identity: Int
}
