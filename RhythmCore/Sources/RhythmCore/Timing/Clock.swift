import Foundation

/// The master clock: the song's audio playback position, in ms from the start of the audio.
///
/// Everything time-based (rotation, note timing, judging, auto-misses) is a pure function of this
/// value. Never derive game time from frame counts or accumulated frame deltas.
/// The app's implementation reads the audio engine's render position (AudioEngineClock).
public protocol PlaybackClock: AnyObject {
    var nowMs: Double { get }
}

/// A clock you set by hand, for tests and previews.
public final class ManualClock: PlaybackClock {
    public var nowMs: Double

    public init(nowMs: Double = 0) {
        self.nowMs = nowMs
    }
}

/// Converts between ms and beats for a constant-tempo song.
public struct BeatGrid: Sendable, Equatable {
    public var bpm: Double
    public var offsetMs: Double

    public init(bpm: Double, offsetMs: Double) {
        self.bpm = bpm
        self.offsetMs = offsetMs
    }

    public init(_ timing: Beatmap.Timing) {
        self.init(bpm: timing.bpm, offsetMs: timing.offsetMs)
    }

    public var msPerBeat: Double { 60_000 / bpm }

    public func beat(atMs ms: Double) -> Double {
        (ms - offsetMs) / msPerBeat
    }

    public func ms(atBeat beat: Double) -> Double {
        offsetMs + beat * msPerBeat
    }
}
