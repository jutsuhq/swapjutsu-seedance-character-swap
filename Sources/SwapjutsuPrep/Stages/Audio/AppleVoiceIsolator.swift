import AVFoundation
import Accelerate

/// Apple's voice isolation unit (AUSoundIsolation, the one behind Voice Isolation in calls): no model to download,
/// ~40× real time. Built for speech; singing over a loud music bed is where htdemucs (the reference's choice) would
/// do better, behind the same protocol.
struct AppleVoiceIsolator: VoiceIsolating {
    private static let description = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)

    /// Nil where the unit is missing (it ships with macOS 13 and later).
    init?() {
        guard AudioComponentFindNext(nil, [Self.description]) != nil else { return nil }
    }

    func isolate(_ audio: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let unit = AVAudioUnitEffect(audioComponentDescription: Self.description)
        unit.auAudioUnit.parameterTree?.parameter(
            withAddress: AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent))?
            .value = 100
        return Self.aligned(try renderOffline(audio, through: unit), to: audio)
    }

    /// `processed` shifted back by the delay it has against `original`. The unit delays its output by ~76 ms while
    /// reporting zero latency, enough to throw lip sync off; the delay is measured on the clip itself, as the lag of
    /// the best match between the two within `maxLag` seconds.
    static func aligned(
        _ processed: AVAudioPCMBuffer, to original: AVAudioPCMBuffer, maxLag: Double = 0.25
    )
        -> AVAudioPCMBuffer
    {
        let lag = delay(of: processed, against: original, maxLag: maxLag)
        guard lag > 0, let channels = processed.floatChannelData else { return processed }
        let length = Int(processed.frameLength)
        for c in 0..<Int(processed.format.channelCount) {
            let samples = channels[c]
            samples.update(from: samples + lag, count: length - lag)
            (samples + length - lag).update(repeating: 0, count: lag)
        }
        return processed
    }

    /// Frames by which `processed` lags `original`, from the cross-correlation of their first channels.
    static func delay(of processed: AVAudioPCMBuffer, against original: AVAudioPCMBuffer, maxLag: Double) -> Int {
        guard let out = processed.floatChannelData?[0], let input = original.floatChannelData?[0] else { return 0 }
        // A 4 kHz low-pass of each keeps the search cheap; speech energy lines up well at that rate.
        let step = max(1, Int(processed.format.sampleRate / 4000))
        let decimate = { (samples: UnsafeMutablePointer<Float>, count: Int) -> [Float] in
            stride(from: 0, to: count - step, by: step).map { i in
                var sum: Float = 0
                vDSP_sve(samples + i, 1, &sum, vDSP_Length(step))
                return sum
            }
        }
        let count = Int(min(processed.frameLength, original.frameLength))
        let a = decimate(out, count), b = decimate(input, count)
        let lags = min(Int(maxLag * processed.format.sampleRate) / step, a.count / 2)
        guard lags > 0 else { return 0 }
        let window = a.count - lags
        var scores = [Float](repeating: 0, count: lags + 1)
        for lag in 0...lags {
            scores[lag] = vDSP.dot(a[lag..<(lag + window)], b[0..<window])
        }
        let best = scores.indices.max { scores[$0] < scores[$1] } ?? 0
        return best * step
    }
}
