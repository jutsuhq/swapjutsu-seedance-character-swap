import AVFoundation

/// Copies `video` to `output` (frames untouched) with the soundtrack of `audioSource` trimmed to the video and
/// encoded as AAC, stereo at 48 kHz whatever the source was.
///
/// `length` stretches the video evenly to that duration first, and the sound is trimmed to it instead. Seedance
/// hands back a 5 s edit as 113 frames at 24 fps (4.71 s) holding all 5 s of motion, so the original sound only
/// lines up with the lips once the frames are spread back over 5 s.
///
/// The audio goes through AVAssetWriter rather than a passthrough export: passthrough of an AAC track from another
/// file kept the wrong share of the encoder's priming in the edit list, so the voice played ~48 ms late, enough for
/// Seedance to read the lips out of sync.
public func muxAudio(video: URL, audioSource: URL, output: URL, length target: CMTime? = nil) async throws {
    let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audioSource)
    let own = try await videoAsset.load(.duration)
    let length = target ?? own
    // Half a frame either way is the encoder's rounding, not a different length.
    let scale = target.map { abs($0.seconds - own.seconds) > 0.02 ? $0.seconds / own.seconds : 1 } ?? 1
    guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
        throw PrepError.writeFailed("mux: no video")
    }
    try? FileManager.default.removeItem(at: output)
    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    var lanes: [MuxLane] = []

    let videoReader = try AVAssetReader(asset: videoAsset)
    let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
    videoReader.add(videoOutput)
    let formats = try await videoTrack.load(.formatDescriptions)
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
    videoInput.transform = try await videoTrack.load(.preferredTransform)
    writer.add(videoInput)
    lanes.append(MuxLane(reader: videoReader, output: videoOutput, input: videoInput, scale: scale))

    if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first {
        let lane = try audioLane(audioTrack, of: audioAsset, length: length)
        writer.add(lane.input)
        lanes.append(lane)
    }

    guard writer.startWriting() else { throw PrepError.writeFailed("mux: \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)
    do {
        for lane in lanes where !lane.reader.startReading() {
            throw PrepError.readFailed("mux: \(String(describing: lane.reader.error))")
        }
        try await copy(lanes, into: writer)
    } catch {
        for lane in lanes { lane.reader.cancelReading() }
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: output)
        throw error
    }
    writer.endSession(atSourceTime: length)
    await writer.finishWriting()
    guard writer.status == .completed else { throw PrepError.writeFailed("mux: \(String(describing: writer.error))") }
}

/// The audio of `asset` up to `length`, decoded and re-encoded as AAC, stereo at 48 kHz.
private func audioLane(_ audioTrack: AVAssetTrack, of audioAsset: AVAsset, length: CMTime) throws -> MuxLane {
    let audioReader = try AVAssetReader(asset: audioAsset)
    audioReader.timeRange = CMTimeRange(start: .zero, duration: length)
    // One fixed format: the source's own rate and channel count aren't always encodable at our bit rate (an
    // HE-AAC v2 track reports its 22 kHz mono base layer), and 5.1 has to be folded down anyway.
    var stereo = AudioChannelLayout()
    stereo.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
    let layout = Data(bytes: &stereo, count: MemoryLayout<AudioChannelLayout>.size)
    let pcm: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        AVChannelLayoutKey: layout,
    ]
    let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcm)
    audioReader.add(audioOutput)
    let audioInput = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: layout, AVEncoderBitRateKey: 192_000,
        ])
    return MuxLane(reader: audioReader, output: audioOutput, input: audioInput)
}

/// One track copied from a reader output into a writer input.
private final class MuxLane {
    let reader: AVAssetReader
    let samples: SampleQueue
    let input: AVAssetWriterInput
    /// Every timestamp and duration is multiplied by this.
    let scale: Double
    /// The first frame's time, which the stretch moves to zero. A track with B-frames reads out starting at its
    /// reorder delay; scaled in place, that delay grew and the picture started ~90 ms after the sound.
    private var origin: CMTime?

    init(reader: AVAssetReader, output: AVAssetReaderOutput, input: AVAssetWriterInput, scale: Double = 1) {
        self.reader = reader
        samples = SampleQueue(output)
        self.input = input
        self.scale = scale
    }

    func retimed(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        guard scale != 1 else { return sample }
        let infos = try sample.sampleTimingInfos()
        let origin = origin ?? infos.first?.presentationTimeStamp ?? .zero
        self.origin = origin
        func moved(_ time: CMTime) -> CMTime {
            time.isValid ? CMTimeMultiplyByFloat64(time - origin, multiplier: scale) : time
        }
        var timing = infos.map {
            CMSampleTimingInfo(
                duration: $0.duration.isValid ? CMTimeMultiplyByFloat64($0.duration, multiplier: scale) : $0.duration,
                presentationTimeStamp: moved($0.presentationTimeStamp), decodeTimeStamp: moved($0.decodeTimeStamp))
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: timing.count, sampleTimingArray: &timing,
            sampleBufferOut: &copy)
        guard status == noErr, let copy else { throw PrepError.writeFailed("mux: retime \(status)") }
        return copy
    }
}

/// Feeds every lane in turn from one loop: the writer interleaves the tracks and holds one back while it waits for
/// the other, so each lane gets whatever its input takes right now. No callbacks, so a failed writer or a
/// cancelled task ends the loop instead of leaving a continuation unresumed.
private func copy(_ lanes: [MuxLane], into writer: AVAssetWriter) async throws {
    var open = Array(lanes.indices)
    var lastProgress = Date()
    while !open.isEmpty {
        try Task.checkCancellation()
        if writer.status == .failed { throw PrepError.writeFailed("mux: \(String(describing: writer.error))") }
        var moved = false
        for k in open {
            let lane = lanes[k]
            while lane.input.isReadyForMoreMediaData {
                guard let sample = await lane.samples.next() else {
                    if lane.reader.status == .failed {
                        throw PrepError.readFailed("mux: \(String(describing: lane.reader.error))")
                    }
                    lane.input.markAsFinished()
                    open.removeAll { $0 == k }
                    break
                }
                guard lane.input.append(try lane.retimed(sample)) else {
                    throw PrepError.writeFailed("mux: \(String(describing: writer.error))")
                }
                moved = true
            }
        }
        if moved {
            lastProgress = Date()
        } else if !open.isEmpty {
            guard Date().timeIntervalSince(lastProgress) < 20 else { throw PrepError.writeFailed("mux stalled") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
