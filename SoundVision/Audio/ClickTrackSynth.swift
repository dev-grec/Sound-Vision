import AVFoundation
import RhythmCore

/// Synthesizes a metronome click track at runtime, so the test map needs no audio file
/// (the project never commits audio the owner hasn't supplied).
enum ClickTrackSynth {
    /// A mono buffer: a click on every beat from `timing.offsetMs`, beat 1 of each bar accented,
    /// followed by `tailMs` of silence.
    static func makeBuffer(click: AudioSource.ClickTrack, timing: Beatmap.Timing,
                           sampleRate: Double = 48_000, tailMs: Double = 1_500) -> AVAudioPCMBuffer? {
        let beats = click.bars * click.beatsPerBar
        let msPerBeat = 60_000 / timing.bpm
        let totalMs = timing.offsetMs + Double(beats) * msPerBeat + tailMs
        let frameCount = AVAudioFrameCount((totalMs / 1000 * sampleRate).rounded(.up))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frameCount
        samples.update(repeating: 0, count: Int(frameCount))

        let clickLength = Int(0.045 * sampleRate)
        for beat in 0..<beats {
            let accent = beat % click.beatsPerBar == 0
            let frequency = accent ? 1_600.0 : 1_050.0
            let amplitude: Float = accent ? 0.8 : 0.5
            let start = Int(((timing.offsetMs + Double(beat) * msPerBeat) / 1000 * sampleRate).rounded())
            for i in 0..<clickLength where start + i < Int(frameCount) {
                let t = Double(i) / sampleRate
                let attack = min(t / 0.001, 1)        // 1 ms attack avoids a pop
                let decay = exp(-t / 0.009)
                samples[start + i] = amplitude * Float(attack * decay * sin(2 * .pi * frequency * t))
            }
        }
        return buffer
    }
}
