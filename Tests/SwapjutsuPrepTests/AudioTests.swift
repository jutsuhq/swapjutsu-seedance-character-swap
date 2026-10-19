import AVFoundation
import CoreImage
import Testing

@testable import SwapjutsuPrep

struct AudioTests {
    private let plain = Soundtrack(voice: nil, pitch: TimePitch())

    @Test func soundtrackIsPitchedThreeSemitonesAtTheSameLength() async throws {
        let dir = try scratch("audio")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rate = 44_100.0, seconds = 2.0
        let source = dir.appendingPathComponent("tone.m4a"), output = dir.appendingPathComponent("pitched.m4a")
        try writeTone(440, seconds: seconds, rate: rate, to: source)

        #expect(try await plain.prepare(source, seconds: seconds, semitones: 3, output: output, work: dir))
        let (frequency, length) = try measure(output)
        #expect(abs(frequency - 440 * pow(2, 3 / 12)) < 6, "got \(frequency) Hz")  // 523.3 Hz
        #expect(abs(length - seconds) < 0.05)
    }

    /// A long source is cut to the clip before decoding, not after.
    @Test func onlyTheUsedRangeIsPrepared() async throws {
        let dir = try scratch("range")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("long.m4a"), output = dir.appendingPathComponent("cut.m4a")
        try writeTone(440, seconds: 12, rate: 44_100, to: source)
        #expect(try await plain.prepare(source, seconds: 5, semitones: 3, output: output, work: dir))
        let (_, length) = try measure(output)
        #expect(abs(length - 5) < 0.1, "got \(length) s")
    }

    @Test func aClipWithoutSoundGetsNoSoundtrack() async throws {
        let dir = try scratch("silent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await silentClip(in: dir)
        #expect(
            !(try await plain.prepare(video, seconds: 1, semitones: 3, output: dir.appending(path: "a.m4a"), work: dir))
        )
    }

    /// Speech over a chord and a hi-hat: the voice comes through on time, the music does not. The lag is measured
    /// here, both ways, independently of the isolator's own alignment.
    @Test func voiceIsKeptOnTimeAndMusicDropped() throws {
        let isolator = try #require(AppleVoiceIsolator(), "AUSoundIsolation is missing")
        let dir = try scratch("voice")
        defer { try? FileManager.default.removeItem(at: dir) }
        let speech = try spoken("We will be landing in about twenty minutes, so please fasten your seatbelts.", in: dir)
        let music = try #require(AVAudioPCMBuffer(pcmFormat: speech.format, frameCapacity: speech.frameLength))
        music.frameLength = speech.frameLength
        let rate = Float(speech.format.sampleRate)
        var noise = SplitMix(seed: 7)
        for i in 0..<Int(music.frameLength) {
            let t = Float(i) / rate
            let chord = [220, 277, 330, 440].reduce(Float(0)) { $0 + 0.15 * sin(2 * .pi * Float($1) * t) }
            let hat = t.truncatingRemainder(dividingBy: 0.5) < 0.05 ? noise.next() * 0.4 : 0
            music.floatChannelData?[0][i] = chord + hat
        }
        let mix = try #require(AVAudioPCMBuffer(pcmFormat: speech.format, frameCapacity: speech.frameLength))
        mix.frameLength = speech.frameLength
        for i in 0..<Int(mix.frameLength) {
            mix.floatChannelData?[0][i] = (speech.floatChannelData?[0][i] ?? 0) + (music.floatChannelData?[0][i] ?? 0)
        }

        let voice = try isolator.isolate(mix)
        let lag = envelopeLag(samples(voice), samples(speech), rate: Double(rate))
        #expect(abs(lag) < 0.005, "voice is \(lag * 1000) ms off")
        #expect(sdr(voice, speech) > sdr(mix, speech) + 3, "SDR \(sdr(mix, speech)) → \(sdr(voice, speech)) dB")
        let musicOnly = try #require(AppleVoiceIsolator()).isolate(music)
        #expect(rms(musicOnly) < rms(music) / 10, "music only dropped to \(rms(musicOnly) / rms(music))")
    }

    /// The mux writes the edit list players and ffmpeg follow: the audio starts exactly after the AAC encoder's
    /// 2112 priming samples, and plays in step with the source. A passthrough export left 960 there, so ffmpeg
    /// (and Seedance) heard the voice 48 ms late while AVFoundation still played it on time.
    @Test func muxedSoundIsOnTime() async throws {
        let dir = try scratch("mux")
        defer { try? FileManager.default.removeItem(at: dir) }
        let speech = try spoken("Fasten your seatbelts, please.", in: dir)
        let audio = dir.appending(path: "speech.m4a")
        do {
            // Closed (and finalised) when it goes out of scope, before the mux reads it.
            let file = try AVAudioFile(
                forWriting: audio,
                settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1])
            try file.write(from: speech)
        }
        let video = try await silentClip(in: dir, seconds: Double(speech.frameLength) / 48_000)
        let output = dir.appending(path: "muxed.mp4")
        try await muxAudio(video: video, audioSource: audio, output: output)

        let editStart = try audioEditListStart(output)
        #expect(editStart == 2112)
        let decoded = try await decodeAudio(output, rate: 48_000)
        let lag = envelopeLag(decoded, samples(speech), rate: 48_000)
        #expect(abs(lag) < 0.005, "muxed voice is \(lag * 1000) ms off")
    }

    /// A Higgsfield gallery clip with HE-AAC v2 sound (22 kHz mono base layer) failed the mux with "Cannot Encode
    /// Media"; any source rate and channel count now comes out as 48 kHz stereo.
    @Test func lowRateMonoSoundIsMuxed() async throws {
        let dir = try scratch("mux-mono")
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appending(path: "tone.m4a")
        try writeTone(440, seconds: 1, rate: 22_050, to: audio)
        let video = try await silentClip(in: dir)
        let output = dir.appending(path: "muxed.mp4")
        try await muxAudio(video: video, audioSource: audio, output: output)
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        let basic = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(basic.mSampleRate == 48_000 && basic.mChannelsPerFrame == 2)
    }

    /// Seedance refuses a video below 23.8 fps. With B-frames the decode offset ended up in the last frame's
    /// duration, so a 5 s control video ran 5.08 s and read as 23.6 fps.
    @Test func muxedVideoKeepsItsFrameRate() async throws {
        let dir = try scratch("mux-fps")
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appending(path: "noise.mp4")
        let writer = try VideoWriter(url: video, size: CGSize(width: 64, height: 64), fps: 24, context: CIContext())
        let noise = try #require(CIFilter(name: "CIRandomGenerator")?.outputImage)
        for frame in 0..<48 {
            let shifted = noise.transformed(by: CGAffineTransform(translationX: CGFloat(frame), y: 0))
            try writer.append(shifted.cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)))
        }
        try await writer.finish()
        let audio = dir.appending(path: "tone.m4a")
        try writeTone(440, seconds: 2, rate: 48_000, to: audio)
        let output = dir.appending(path: "muxed.mp4")
        try await muxAudio(video: video, audioSource: audio, output: output)
        // AVFoundation trims to the edit list and reads 24 fps either way; the track's media duration is what
        // ffprobe and Seedance divide the frame count by.
        let seconds = try #require(try MP4File(output).videoMediaSeconds())
        #expect(abs(seconds - 2) < 0.01, "48 frames span \(seconds) s")
    }

    /// Seedance returns a 5 s edit as fewer frames holding all the motion; `length` spreads them back out so the
    /// original sound meets the lips, and the sound runs the full length.
    @Test func aShortRenderIsStretchedToTheControlLength() async throws {
        let dir = try scratch("mux-stretch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await silentClip(in: dir, seconds: 1.875)
        let audio = dir.appending(path: "tone.m4a")
        try writeTone(440, seconds: 3, rate: 48_000, to: audio)
        let output = dir.appending(path: "muxed.mp4")
        try await muxAudio(video: video, audioSource: audio, output: output, length: CMTime(value: 2, timescale: 1))
        let asset = AVURLAsset(url: output)
        let picture = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let sound = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        #expect(abs(try await picture.load(.timeRange).duration.seconds - 2) < 0.03)
        #expect(abs(try await sound.load(.timeRange).duration.seconds - 2) < 0.05)
    }

    @Test func aSilentClipIsNotDescribedAsHavingAudio() {
        let pipeline = Pipeline(options: PrepOptions(), modelURL: URL(filePath: "/dev/null"))
        #expect(pipeline.seedancePrompt(people: 1, hasAudio: true).contains("vocals"))
        #expect(!pipeline.seedancePrompt(people: 1, hasAudio: false).contains("vocals"))
    }

    private func scratch(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swapjutsu-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func silentClip(in dir: URL, seconds: Double = 1) async throws -> URL {
        let url = dir.appending(path: "silent.mp4")
        let writer = try VideoWriter(url: url, size: CGSize(width: 64, height: 64), fps: 24, context: CIContext())
        for _ in 0..<Int((seconds * 24).rounded(.up)) {
            try writer.append(CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)))
        }
        try await writer.finish()
        return url
    }

    /// Seconds by which `a` lags `b` (negative: leads), from 1 ms energy envelopes within ±250 ms.
    private func envelopeLag(_ a: [Float], _ b: [Float], rate: Double) -> Double {
        let window = max(1, Int(rate / 1000))
        func envelope(_ x: [Float]) -> [Float] {
            stride(from: 0, to: x.count - window, by: window).map { i in
                (x[i..<(i + window)].reduce(0) { $0 + $1 * $1 } / Float(window)).squareRoot()
            }
        }
        let ea = envelope(a), eb = envelope(b), reach = 250, n = min(ea.count, eb.count) - reach
        guard n > reach else { return .infinity }
        let best =
            (-reach...reach).max { l, r in
                func score(_ lag: Int) -> Float { (reach..<n).reduce(0) { $0 + ea[$1 + lag] * eb[$1] } }
                return score(l) < score(r)
            } ?? 0
        return Double(best) / 1000
    }

    private func decodeAudio(_ url: URL, rate: Double) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
            ])
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var data = Data(count: CMBlockBufferGetDataLength(block))
            data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: base)
            }
            data.withUnsafeBytes { samples += $0.bindMemory(to: Float.self) }
        }
        return samples
    }

    /// `media_time` of the first edit of the sound track: where a player that follows the edit list starts.
    private func audioEditListStart(_ url: URL) throws -> Int? {
        let file = try MP4File(url)
        guard let trak = file.track("soun"), let edts = trak.first(where: { $0.type == "edts" }),
            let elst = file.boxes(edts.body).first(where: { $0.type == "elst" })
        else { return nil }
        // version/flags (4), entry count (4), then segment_duration (4) and media_time (4) for version 0.
        return file.u32(elst.body.lowerBound + 12)
    }

    private func writeTone(_ hz: Double, seconds: Double, rate: Double, to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) { samples[i] = Float(0.5 * sin(2 * .pi * hz * Double(i) / rate)) }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            ])
        try file.write(from: buffer)
    }

    /// `text` read by the system voice, mono at 48 kHz.
    private func spoken(_ text: String, in dir: URL) throws -> AVAudioPCMBuffer {
        let url = dir.appendingPathComponent("speech.wav")
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["--file-format=WAVE", "--data-format=LEF32@48000", "-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return buffer
    }

    private func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let x = samples(buffer)
        return (x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))).squareRoot()
    }

    /// How much of `estimate` is `reference` rather than anything else, in dB, at the best gain.
    private func sdr(_ estimate: AVAudioPCMBuffer, _ reference: AVAudioPCMBuffer) -> Float {
        let x = samples(estimate), y = samples(reference), n = min(x.count, y.count)
        var xy: Float = 0, yy: Float = 0
        for i in 0..<n {
            xy += x[i] * y[i]
            yy += y[i] * y[i]
        }
        let gain = xy / max(1e-9, yy)
        var signal: Float = 0, error: Float = 0
        for i in 0..<n {
            signal += gain * y[i] * gain * y[i]
            error += (x[i] - gain * y[i]) * (x[i] - gain * y[i])
        }
        return 10 * log10(signal / max(1e-9, error))
    }

    /// Frequency from zero crossings over the steady middle second, and duration.
    private func measure(_ url: URL) throws -> (Double, Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        let rate = file.processingFormat.sampleRate
        let start = Int(rate * 0.5), end = Int(rate * 1.5)
        var crossings = 0
        for i in (start + 1)..<end where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
        return (Double(crossings) / 2 / ((Double(end - start)) / rate), Double(file.length) / rate)
    }
}

/// Reproducible noise in −1…1, so the test input is the same on every machine.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Float((z ^ (z >> 31)) >> 40) / Float(1 << 24) * 2 - 1
    }
}

/// Just enough of the ISO box tree to check what AVFoundation hides behind edit lists.
private struct MP4File {
    let data: Data

    init(_ url: URL) throws { data = try Data(contentsOf: url) }

    func uint(_ at: Int, _ bytes: Int) -> Int { data[at..<(at + bytes)].reduce(0) { $0 << 8 | Int($1) } }
    func u32(_ at: Int) -> Int { uint(at, 4) }

    func boxes(_ range: Range<Int>) -> [(type: String, body: Range<Int>)] {
        var result: [(String, Range<Int>)] = []
        var at = range.lowerBound
        while at + 8 <= range.upperBound {
            // size 1: a 64-bit size follows the type (AVAssetWriter's mdat); size 0: up to the end.
            var size = u32(at), header = 8
            if size == 1 {
                size = uint(at + 8, 8)
                header = 16
            } else if size == 0 {
                size = range.upperBound - at
            }
            guard size >= header, at + size <= range.upperBound else { break }
            result.append((String(decoding: data[(at + 4)..<(at + 8)], as: UTF8.self), (at + header)..<(at + size)))
            at += size
        }
        return result
    }

    /// The children of the first `trak` whose handler is `handler` ("soun", "vide").
    func track(_ handler: String) -> [(type: String, body: Range<Int>)]? {
        guard let moov = boxes(0..<data.count).first(where: { $0.type == "moov" }) else { return nil }
        for trak in boxes(moov.body) where trak.type == "trak" {
            let children = boxes(trak.body)
            guard let mdia = children.first(where: { $0.type == "mdia" }),
                let hdlr = boxes(mdia.body).first(where: { $0.type == "hdlr" }),
                String(decoding: data[(hdlr.body.lowerBound + 8)..<(hdlr.body.lowerBound + 12)], as: UTF8.self)
                    == handler
            else { continue }
            return children
        }
        return nil
    }

    /// The video media duration from `mdhd`, which counts every sample's duration, the last one included.
    func videoMediaSeconds() -> Double? {
        guard let mdia = track("vide")?.first(where: { $0.type == "mdia" }),
            let mdhd = boxes(mdia.body).first(where: { $0.type == "mdhd" })
        else { return nil }
        let at = mdhd.body.lowerBound
        // Version 1 widens the two dates and the duration to 64 bits.
        let (scale, duration) = data[at] == 1 ? (u32(at + 20), uint(at + 24, 8)) : (u32(at + 12), u32(at + 16))
        return Double(duration) / Double(scale)
    }
}
