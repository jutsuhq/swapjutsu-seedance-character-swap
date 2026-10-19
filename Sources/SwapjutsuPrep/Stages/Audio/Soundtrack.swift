import AVFoundation

/// The soundtrack for `@Video1`, as the reference Genjutsu workflow prepares it: the music bed stripped, the vocals
/// pitched up (default +3 semitones) at the same duration, so Seedance follows the performance and lip sync without
/// reproducing the original voice. The finished video gets the original soundtrack back.
struct Soundtrack {
    let voice: (any VoiceIsolating)?
    let pitch: any PitchShifting

    /// Writes the first `seconds` of `source`'s audio to `output` (.m4a): vocals only when there is an isolator,
    /// pitched by `semitones`. Returns false when there is no audio. Only that range is exported and decoded, so a
    /// long source costs no more memory than the clip prep actually uses.
    func prepare(_ source: URL, seconds: Double, semitones: Float, output: URL, work: URL) async throws -> Bool {
        let asset = AVURLAsset(url: source)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { return false }
        let extracted = work.appendingPathComponent("source-audio.m4a")
        try? FileManager.default.removeItem(at: extracted)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw PrepError.writeFailed("audio: no export session")
        }
        export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 48_000))
        try await export.export(to: extracted, as: .m4a)
        try Task.checkCancellation()

        let input = try AVAudioFile(forReading: extracted)
        guard
            let mix = AVAudioPCMBuffer(
                pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length))
        else { throw PrepError.writeFailed("audio: no read buffer") }
        try input.read(into: mix)

        var sound = mix
        if let voice { sound = try voice.isolate(sound) }
        if semitones != 0 { sound = try pitch.shift(sound, semitones: semitones) }

        try? FileManager.default.removeItem(at: output)
        let format = sound.format
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 192_000,
        ]
        let file = try AVAudioFile(
            forWriting: output, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved
        )
        try file.write(from: sound)
        return true
    }
}
