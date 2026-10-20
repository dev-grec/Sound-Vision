import AVFoundation
import RhythmCore

/// The master clock: the song's audio playback position, read from the audio engine.
///
/// `nowMs` comes from the player node's render position (`playerTime(forNodeTime: lastRenderTime)`),
/// which advances in render-buffer steps (about 10 ms). Between buffers it is interpolated with the
/// render timestamp's host time, capped at `maxInterpolationSeconds`, then the session's output
/// latency is subtracted so the value approximates what is audible now. It is never built from
/// frame counts or accumulated frame deltas, and it never goes backward.
///
/// Whatever error remains (pinch latency, display latency) is absorbed by the user's input offset.
/// Audio/visual sync is on the device checklist.
final class AudioEngineClock: @MainActor PlaybackClock {
    enum ClockError: Error, CustomStringConvertible {
        case cannotSynthesizeClick
        case audioFileMissing(String)

        var description: String {
            switch self {
            case .cannotSynthesizeClick: "could not synthesize the click track"
            case .audioFileMissing(let name): "audio file \"\(name)\" is not in the map folder"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isRunning = false
    private var lastMs: Double = 0
    private let maxInterpolationSeconds = 0.03

    /// Length of the loaded audio in ms.
    private(set) var durationMs: Double = 0

    init() {
        engine.attach(player)
    }

    /// Loads the beatmap's audio: a synthesized click track or a file next to the beatmap.
    func load(_ beatmap: Beatmap, folder: URL) throws {
        switch beatmap.audio {
        case .generatedClick(let click):
            guard let buffer = ClickTrackSynth.makeBuffer(click: click, timing: beatmap.timing) else {
                throw ClockError.cannotSynthesizeClick
            }
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            player.scheduleBuffer(buffer, at: nil)
            durationMs = Double(buffer.frameLength) / buffer.format.sampleRate * 1000
        case .file(let name):
            // Untested until the owner supplies real audio (see docs/STATUS.md).
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ClockError.audioFileMissing(name) }
            let file = try AVAudioFile(forReading: url)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            player.scheduleFile(file, at: nil)
            durationMs = Double(file.length) / file.processingFormat.sampleRate * 1000
        }
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        try engine.start()
        player.play()
        isRunning = true
    }

    /// Stops playback. `nowMs` freezes at its last value.
    func stop() {
        _ = nowMs
        isRunning = false
        player.stop()
        engine.stop()
    }

    var nowMs: Double {
        guard isRunning,
              let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return lastMs }
        var seconds = Double(playerTime.sampleTime) / playerTime.sampleRate
        if nodeTime.isHostTimeValid {
            let elapsed = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: nodeTime.hostTime)
            seconds += min(max(elapsed, 0), maxInterpolationSeconds)
        }
        seconds -= AVAudioSession.sharedInstance().outputLatency
        lastMs = max(lastMs, seconds * 1000)
        return lastMs
    }
}

/// Wall-clock time since creation. DEBUG SCENES ONLY (the Glass Lab spins its sphere with it).
/// Gameplay must use AudioEngineClock.
final class HostTimeClock: @MainActor PlaybackClock {
    private let start = CACurrentMediaTime()
    var nowMs: Double { (CACurrentMediaTime() - start) * 1000 }
}
