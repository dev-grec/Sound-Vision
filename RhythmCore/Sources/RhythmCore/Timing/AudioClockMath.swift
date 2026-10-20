import Foundation

/// The arithmetic behind the app's audio master clock (`AudioEngineClock`), kept here so it is tested.
///
/// The audio engine reports, for the buffer it rendered last, the song position of that buffer's first
/// sample and the host time at which that sample reaches the output. Render timestamps are for the
/// buffer about to play, so that host time is usually slightly in the future when the clock is read.
/// The song position at host time `now` is therefore `renderSeconds + (now - renderHostSeconds)`, which
/// is negative interpolation while the buffer is still queued. Clamping that to zero (as the first build
/// did) made the clock run up to one buffer ahead and then stall, a staircase instead of a line.
/// Interpolation is capped both ways so a stalled or bogus timestamp can't run away. Output latency
/// (output to speaker) is then subtracted so the result approximates what is audible now.
public enum AudioClockMath {
    /// Audible song position in seconds.
    /// - Parameters:
    ///   - renderSeconds: player position of the first sample of the last rendered buffer.
    ///   - renderHostSeconds: host time (seconds) at which that sample reaches the output, or nil if invalid.
    ///   - nowHostSeconds: host time now, same timebase.
    ///   - outputLatencySeconds: the session's output latency.
    ///   - maxInterpolationSeconds: interpolation cap, in either direction.
    public static func audibleSeconds(renderSeconds: Double, renderHostSeconds: Double?, nowHostSeconds: Double,
                                      outputLatencySeconds: Double, maxInterpolationSeconds: Double) -> Double {
        var seconds = renderSeconds
        if let host = renderHostSeconds {
            seconds += min(max(nowHostSeconds - host, -maxInterpolationSeconds), maxInterpolationSeconds)
        }
        return seconds - outputLatencySeconds
    }
}

/// Keeps a clock reading from going backward, and counts how often it had to (a health check: with
/// correct interpolation, backward steps should be rare and tiny).
///
/// Right after the audio starts, the interpolated position is briefly negative (the first buffers are
/// still queued; about 30 ms in the simulator). Those readings are held at `startMs` but not counted:
/// they are the pre-roll, not the clock stepping back.
public struct MonotonicReading: Sendable, Equatable {
    public private(set) var lastMs: Double
    /// Readings that came out earlier than the previous one and were held (pre-roll excluded).
    public private(set) var backwardCount = 0
    /// The largest backward step that was held, in ms.
    public private(set) var maxBackwardMs = 0.0
    public private(set) var readCount = 0
    /// Whether a reading has passed `startMs` yet.
    private var started = false

    public init(startMs: Double = 0) {
        lastMs = startMs
    }

    /// Accepts a raw reading and returns the monotonic value.
    public mutating func accept(_ rawMs: Double) -> Double {
        readCount += 1
        if rawMs < lastMs {
            if started {
                backwardCount += 1
                maxBackwardMs = max(maxBackwardMs, lastMs - rawMs)
            }
        } else {
            if rawMs > lastMs { started = true }
            lastMs = rawMs
        }
        return lastMs
    }
}
