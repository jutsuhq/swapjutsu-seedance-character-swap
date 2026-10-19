import AVFoundation

/// `audio` rendered offline through `effect`, as long as the input. Stops on cancellation, and fails instead of
/// spinning when the engine stops producing frames.
func renderOffline(_ audio: AVAudioPCMBuffer, through effect: AVAudioNode) throws -> AVAudioPCMBuffer {
    let format = audio.format, length = audio.frameLength
    let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    engine.attach(player)
    engine.attach(effect)
    engine.connect(player, to: effect, format: format)
    engine.connect(effect, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    try engine.start()
    defer {
        player.stop()
        engine.stop()
    }
    player.scheduleBuffer(audio)
    player.play()

    guard let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: length),
        let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)
    else { throw PrepError.writeFailed("audio: no render buffer") }
    var idle = 0
    while output.frameLength < length {
        try Task.checkCancellation()
        let frames = min(chunk.frameCapacity, length - output.frameLength)
        switch try engine.renderOffline(frames, to: chunk) {
        case .success:
            append(chunk, to: output)
            idle = 0
        case .error: throw PrepError.writeFailed("audio: render failed")
        default:
            // .insufficientDataFromInputNode / .cannotDoInCurrentContext: retry a few times, then give up.
            idle += 1
            if idle > 100 { throw PrepError.writeFailed("audio: the render stalled") }
        }
    }
    return output
}

private func append(_ chunk: AVAudioPCMBuffer, to buffer: AVAudioPCMBuffer) {
    guard let from = chunk.floatChannelData, let to = buffer.floatChannelData else { return }
    let start = Int(buffer.frameLength), frames = Int(chunk.frameLength)
    for c in 0..<Int(buffer.format.channelCount) { (to[c] + start).update(from: from[c], count: frames) }
    buffer.frameLength += chunk.frameLength
}
