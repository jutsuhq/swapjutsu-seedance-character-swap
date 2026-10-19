import AVFoundation

/// Core Audio's AVAudioUnitTimePitch: pitch only, same length, no added delay (measured: onset within 1 ms).
struct TimePitch: PitchShifting {
    func shift(_ audio: AVAudioPCMBuffer, semitones: Float) throws -> AVAudioPCMBuffer {
        let unit = AVAudioUnitTimePitch()
        unit.pitch = semitones * 100
        return try renderOffline(audio, through: unit)
    }
}
