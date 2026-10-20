import AVFoundation

/// A short tick played the moment a pinch hits a note (DECISIONS D21): sound is the quickest feedback
/// the game can give, ahead of the next rendered frame. Synthesized at runtime (the project never
/// commits audio the owner hasn't supplied).
///
/// It is its own player node on the clock's engine, mixed in beside the song. The master clock reads
/// the song player's position only, so the tick never moves it.
final class HitSoundPlayer {
    private let node = AVAudioPlayerNode()
    private let buffer: AVAudioPCMBuffer?

    init(engine: AVAudioEngine) {
        buffer = Self.makeTick()
        engine.attach(node)
        if let buffer {
            engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
        }
    }

    /// Call after the engine starts. An idle playing node renders silence until a tick is scheduled.
    func start() {
        node.play()
    }

    func stop() {
        node.stop()
    }

    /// Plays the tick now (at the next render cycle), cutting off one still ringing. `volume` 0 is silent.
    func play(volume: Double) {
        guard volume > 0, let buffer, node.isPlaying else { return }
        node.volume = Float(min(volume, 1))
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    /// A 30 ms tick, higher and shorter than the metronome click (1050/1600 Hz, 45 ms) so the two
    /// don't blur together.
    private static func makeTick(sampleRate: Double = 48_000) -> AVAudioPCMBuffer? {
        let length = Int(0.03 * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)),
              let samples = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(length)
        for i in 0..<length {
            let t = Double(i) / sampleRate
            let attack = min(t / 0.0005, 1) // 0.5 ms attack avoids a pop
            let decay = exp(-t / 0.006)
            let tone = 0.7 * sin(2 * .pi * 2_800 * t) + 0.3 * sin(2 * .pi * 4_100 * t)
            samples[i] = Float(0.9 * attack * decay * tone)
        }
        return buffer
    }
}
