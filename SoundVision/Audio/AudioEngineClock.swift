import AVFoundation
import os
import RhythmCore

private let log = Logger(subsystem: "com.devgrec.SoundVision", category: "audio")

/// The master clock: the song's audio playback position, read from the audio engine.
///
/// `nowMs` comes from the player node's render position (`playerTime(forNodeTime: lastRenderTime)`),
/// which advances in render-buffer steps (about 5 to 10 ms). Between buffers it is interpolated with the
/// render timestamp's host time (in either direction, capped at `maxInterpolationSeconds`; the math and
/// its reasoning are in RhythmCore's `AudioClockMath`), then the session's output latency is subtracted
/// so the value approximates what is audible now. It is never built from frame counts or accumulated
/// frame deltas, and it never goes backward (`MonotonicReading`, which also counts held steps).
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
    private var reading = MonotonicReading()
    private let maxInterpolationSeconds = 0.03
    /// Asked of the session before it starts; a smaller IO buffer means finer render steps and a
    /// quicker hit sound. The system may grant something else (logged at start).
    private let preferredIOBufferSeconds = 0.005
    /// `AVAudioSession.outputLatency`, cached: it only changes with the route.
    private var outputLatencySeconds: Double = 0
    private var routeObserver: (any NSObjectProtocol)?

    /// The immediate hit tick, mixed beside the song on the same engine (DECISIONS D22).
    private(set) lazy var hitSound = HitSoundPlayer(engine: engine)

    /// Length of the loaded audio in ms.
    private(set) var durationMs: Double = 0

    init() {
        engine.attach(player)
        _ = hitSound
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
        do {
            try session.setPreferredIOBufferDuration(preferredIOBufferSeconds)
        } catch {
            log.error("preferred IO buffer duration refused: \(error.localizedDescription, privacy: .public)")
        }
        try session.setActive(true)
        outputLatencySeconds = session.outputLatency
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.outputLatencySeconds = AVAudioSession.sharedInstance().outputLatency
                log.info("audio route changed: output latency \(self.outputLatencySeconds * 1000, format: .fixed(precision: 1)) ms")
            }
        }
        try engine.start()
        player.play()
        hitSound.start()
        isRunning = true
        log.info("audio started: sample rate \(session.sampleRate, format: .fixed(precision: 0)) Hz, IO buffer \(session.ioBufferDuration * 1000, format: .fixed(precision: 1)) ms (asked \(self.preferredIOBufferSeconds * 1000, format: .fixed(precision: 1))), output latency \(self.outputLatencySeconds * 1000, format: .fixed(precision: 1)) ms")
    }

    /// Stops playback. `nowMs` freezes at its last value.
    func stop() {
        _ = nowMs
        guard isRunning else { return }
        isRunning = false
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        hitSound.stop()
        player.stop()
        engine.stop()
        log.info("clock stats: \(self.reading.readCount) reads, \(self.reading.backwardCount) held backward steps (max \(self.reading.maxBackwardMs, format: .fixed(precision: 2)) ms), stopped at \(Int(self.reading.lastMs)) ms")
    }

    var nowMs: Double {
        guard isRunning,
              let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return reading.lastMs }
        let seconds = AudioClockMath.audibleSeconds(
            renderSeconds: Double(playerTime.sampleTime) / playerTime.sampleRate,
            renderHostSeconds: nodeTime.isHostTimeValid ? AVAudioTime.seconds(forHostTime: nodeTime.hostTime) : nil,
            nowHostSeconds: AVAudioTime.seconds(forHostTime: mach_absolute_time()),
            outputLatencySeconds: outputLatencySeconds,
            maxInterpolationSeconds: maxInterpolationSeconds)
        return reading.accept(seconds * 1000)
    }
}

/// Wall-clock time since creation. DEBUG SCENES ONLY (the Glass Lab spins its sphere with it).
/// Gameplay must use AudioEngineClock.
final class HostTimeClock: @MainActor PlaybackClock {
    private let start = CACurrentMediaTime()
    var nowMs: Double { (CACurrentMediaTime() - start) * 1000 }
}
