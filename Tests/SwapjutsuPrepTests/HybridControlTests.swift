import CoreImage
import Foundation
import Testing

@testable import SwapjutsuPrep

/// The hybrid controls: the footage shows through on the hands or the body, never on the head, and colored depth
/// stays exactly as it was.
struct HybridControlTests {
    let side = 128
    var extent: CGRect { CGRect(x: 0, y: 0, width: side, height: side) }

    @Test func aFrameWhereVisionFoundAHandHasAHandMask() throws {
        var vision = [UInt8](repeating: 0, count: 16)
        vision[5] = 255
        #expect(Pipeline.handBytes(tracked: nil, vision: vision) == vision)
        // The tracker lost the hand there: Vision's drawing still makes it.
        let lost = [UInt8](repeating: 0, count: 16)
        #expect(try #require(Pipeline.handBytes(tracked: lost, vision: vision))[5] == 255)
        var tracked = lost
        tracked[9] = 200
        let both = try #require(Pipeline.handBytes(tracked: tracked, vision: vision))
        #expect(both[5] == 255 && both[9] == 200)
        #expect(Pipeline.handBytes(tracked: lost, vision: nil) == nil)
    }

    @Test func theHeadKeepsNoFootage() throws {
        let control = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: extent)
        let original = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: extent)
        let person = CIImage(color: .white).cropped(to: extent)
        let zone = HeadZone(face: CGRect(x: 52, y: 72, width: 24, height: 24), identity: 0)
        let heads = try #require(HeadZone.mask([zone], person: person, extent: extent))
        let feather = Pipeline.hybridFeather(extent, mode: .hybridBody)
        for mode in [ControlMode.hybridBody, .hybridHands] {
            let real = try #require(
                Pipeline.realMask(
                    mode: mode, subject: person, edit: person, hands: person, heads: heads, feather: feather))
            let out = rgba(Pipeline.hybrid(control: control, original: original, real: real))
            let zoneMask = rgba(heads)
            var inside = 0
            for y in 0..<side {
                for x in 0..<side where zoneMask[y][x][0] > 0 {
                    inside += 1
                    #expect(out[y][x][1] == 0, "\(mode) footage at \(x),\(y)")
                }
            }
            #expect(inside > 400)
            // Far from the head, the body is the footage.
            #expect(out[side - 1 - 10][10] == [0, 255, 0, 255], "\(mode)")
        }
    }

    @Test func withoutAFaceTheHeadIsTheTopOfTheMask() throws {
        // A person with an arm out to the left: the box's middle is off the head, the mask's top is not.
        let side = 12
        var cells = [Bool](repeating: false, count: side * side)
        for y in 0..<2 { for x in 6...7 { cells[y * side + x] = true } }
        for y in 2..<12 { for x in 0...9 { cells[y * side + x] = true } }
        let zone = try #require(
            HeadZone.fallback(
                person: MaskGrid(side: side, cells: cells), size: CGSize(width: 120, height: 120), identity: 1))
        #expect(abs(zone.face.midX - 70) < 1)
        #expect(zone.face.maxY > 110)
        #expect(
            HeadZone.fallback(
                person: MaskGrid(side: 4, cells: Array(repeating: false, count: 16)),
                size: CGSize(width: 8, height: 8), identity: 1) == nil)
    }

    @Test func handsOnlyWhereTheHandMaskIs() throws {
        let person = CIImage(color: .white).cropped(to: extent)
        let hand = CIImage(color: .white).cropped(to: CGRect(x: 20, y: 20, width: 20, height: 20))
            .composited(over: CIImage(color: .black).cropped(to: extent))
        let real = try #require(
            Pipeline.realMask(
                mode: .hybridHands, subject: person, edit: person, hands: hand, heads: nil, feather: 4))
        let mask = rgba(real)
        #expect(mask[side - 1 - 30][30][0] > 200)
        #expect(mask[side - 1 - 100][100][0] == 0)
        #expect(
            Pipeline.realMask(
                mode: .hybridHands, subject: person, edit: person, hands: nil, heads: nil, feather: 6) == nil)
    }

    /// A hand in a pocket below an olive cuff: the region drawn from the joints covers all three, the footage shows
    /// on the skin only.
    @Test func theCuffAndThePocketStayColoredDepth() throws {
        let skin: [UInt8] = [190, 135, 111]
        let (olive, denim): ([UInt8], [UInt8]) = ([142, 116, 67], [56, 64, 64])
        // Rows top-down: the cuff over rows 30..<50, the hand 50..<80 and x 40..<70, the pocket round it.
        func paint(_ x: Int, _ y: Int) -> [UInt8] {
            if (30..<50).contains(y), (36..<74).contains(x) { return olive }
            if (50..<80).contains(y), (40..<70).contains(x) { return skin }
            return denim
        }
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        var drawn = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let k = y * side + x
                pixels.replaceSubrange(4 * k..<4 * k + 3, with: paint(x, y))
                // Vision's drawing: the hand, and from the wrist a stroke into the cuff.
                if (44..<66).contains(x), (40..<78).contains(y) { drawn[k] = 255 }
            }
        }
        let model = try #require(HandSkin(samples: HandSkin.samples(rgba: pixels, mask: drawn)))
        let original = CIImage(
            bitmapData: Data(pixels), bytesPerRow: side * 4, size: CGSize(width: side, height: side), format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())
        let region = HandSkin.grown(gray(drawn), by: 12)
        let hand = bytes(model.mask(region, frame: original))
        #expect(hand[60 * side + 55] == 255)
        #expect(hand[40 * side + 55] == 0 && hand[85 * side + 55] == 0 && hand[60 * side + 35] == 0)

        let control = CIImage(color: CIColor(red: 1, green: 0, blue: 1)).cropped(to: extent)
        let everywhere = CIImage(color: .white).cropped(to: extent)
        let handImage = gray(hand)
        let real = try #require(
            Pipeline.realMask(
                mode: .hybridHands, subject: everywhere, edit: everywhere, hands: handImage, heads: nil,
                feather: Pipeline.hybridFeather(extent, mode: .hybridHands)))
        let out = rgba(Pipeline.hybrid(control: control, original: original, real: real))
        // Cuff and pocket a few pixels from the hand stay the control's magenta; the hand's middle is the footage.
        for (x, y) in [(55, 44), (55, 47), (37, 60), (55, 84), (73, 65)] {
            #expect(out[y][x][0] > 240 && out[y][x][1] < 15 && out[y][x][2] > 240, "\(x),\(y) \(out[y][x])")
        }
        #expect(Array(out[65][55].prefix(3)) == skin)
    }

    /// The GPU's skin test agrees with the pixel one on every colour of a grid through RGB, the hue's wrap included.
    @Test func theSkinMaskIsTheSkinTest() throws {
        let width = 32 * 32
        var pixels = [UInt8](repeating: 255, count: width * 32 * 4)
        for k in 0..<(width * 32) {
            (pixels[4 * k], pixels[4 * k + 1], pixels[4 * k + 2]) = (
                UInt8(k % 32 * 8 + 3), UInt8(k / 32 % 32 * 8 + 3), UInt8(k / 1024 * 8 + 3)
            )
        }
        let size = CGSize(width: width, height: 32)
        let frame = CIImage(
            bitmapData: Data(pixels), bytesPerRow: width * 4, size: size, format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())
        let everywhere = CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size))
        for model in [
            HandSkin(hue: 126, hueSpread: 4, chroma: 30, luma: 150),
            HandSkin(hue: 178, hueSpread: 6, chroma: 12, luma: 60),
        ] {
            let mask = renderRGBA(model.mask(everywhere, frame: frame), width: width, height: 32, context: CIContext())
            var (agree, total) = (0, 0)
            for k in 0..<(width * 32) {
                let p = HandSkin.ycc(pixels, k)
                // Pixels within a level of a bound may go either way.
                let near = [
                    abs(HandSkin.angle(HandSkin.hue(p), model.hue) - HandSkin.reach * model.hueSpread) < 1,
                    abs(HandSkin.chroma(p) - HandSkin.palest * model.chroma) < 1.5,
                    abs(p.y - HandSkin.darkest * model.luma) < 1,
                ].contains(true)
                guard !near else { continue }
                total += 1
                if (mask[4 * k] > 127) == model.isSkin(p) { agree += 1 }
            }
            #expect(Double(agree) / Double(total) > 0.995, "\(model): \(agree)/\(total)")
        }
    }

    /// The tracker strayed onto the bare belly above the hand: that patch of skin is cut off from the hand and goes,
    /// the hand stays; with nothing to anchor to, the largest patch stays.
    @Test func aStrayPatchOfSkinIsDropped() {
        let width = 32
        var mask = [UInt8](repeating: 0, count: width * width)
        var anchor = mask
        for y in 20..<28 { for x in 10..<20 { mask[y * width + x] = 255 } }
        for y in 4..<8 { for x in 12..<16 { mask[y * width + x] = 255 } }
        for y in 22..<26 { for x in 12..<18 { anchor[y * width + x] = 255 } }
        for kept in [
            HandSkin.attached(mask, width: width, anchor: anchor), HandSkin.attached(mask, width: width, anchor: nil),
        ] {
            #expect(kept[24 * width + 15] == 255)
            #expect(kept[6 * width + 14] == 0)
            #expect(kept.filter { $0 > 0 }.count == 80)
        }
        #expect(HandSkin.attached([UInt8](repeating: 0, count: 16), width: 4, anchor: nil).allSatisfy { $0 == 0 })
    }

    /// A wrist Vision put far off on the belly makes the hand three times the shot's size: that detection goes.
    @Test func aHandWithAWristFarOffIsDropped() {
        func hand(size: CGFloat) -> HandCue.Hand {
            HandCue.Hand(
                wrist: CGPoint(x: 100, y: 100 - size),
                fingers: (0..<5).map { f in
                    [CGPoint(x: 90 + 5 * CGFloat(f), y: 100), CGPoint(x: 90 + 5 * CGFloat(f), y: 120)]
                })
        }
        let detected = [10: [hand(size: 30)], 11: [hand(size: 32)], 12: [hand(size: 90)], 13: [hand(size: 28)]]
        let kept = Pipeline.plausible(detected, shot: { _ in 0 })
        #expect(kept.keys.sorted() == [10, 11, 13])
        #expect(Pipeline.plausible([12: [hand(size: 90)]], shot: { _ in 0 }).keys.sorted() == [12])
    }

    @Test func depthModeIsUnchanged() throws {
        let person = CIImage(color: .white).cropped(to: extent)
        #expect(
            Pipeline.realMask(
                mode: .depth, subject: person, edit: person, hands: person, heads: nil, feather: 6) == nil)
        #expect(PrepOptions().control == .depth)
        // The brief of a depth run encodes as before, so old manifests and new ones read the same.
        let brief = ServicePrompt(people: 1, background: .replace, seconds: 7)
        let json = try #require(String(data: try JSONEncoder().encode(brief), encoding: .utf8))
        #expect(!json.contains("control"))
        let hybrid = ServicePrompt(people: 1, background: .replace, seconds: 7, control: .hybridHands)
        #expect(hybrid.text() != brief.text())
        #expect(hybrid.text().contains("real hands"))
        #expect(hybrid.text().contains(ServicePrompt.hands) && !brief.text().contains(ServicePrompt.hands))
        #expect(try JSONDecoder().decode(ServicePrompt.self, from: try JSONEncoder().encode(hybrid)) == hybrid)
    }

    private func gray(_ mask: [UInt8]) -> CIImage {
        CIImage(
            bitmapData: Data(mask), bytesPerRow: side, size: CGSize(width: side, height: side), format: .L8,
            colorSpace: nil)
    }

    private func bytes(_ mask: CIImage) -> [UInt8] {
        let pixels = renderRGBA(mask, width: side, height: side, context: CIContext())
        return (0..<(side * side)).map { pixels[4 * $0] }
    }

    private func rgba(_ image: CIImage) -> [[[UInt8]]] {
        let pixels = renderRGBA(image, width: side, height: side, context: CIContext())
        return (0..<side).map { y in
            (0..<side).map { x in Array(pixels[(y * side + x) * 4..<(y * side + x) * 4 + 4]) }
        }
    }
}
