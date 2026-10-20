import Foundation

/// Carries an input event's own timestamp onto the master clock (DECISIONS D22).
///
/// A gesture callback runs some time after the pinch it reports (gesture recognition, main-thread
/// scheduling). When the system gives the event's time, the app measures how old the event is when the
/// callback runs (`eventAgeMs`, both readings from the same wall clock) and the event is stamped at
/// `arrivalMs - eventAgeMs`: where the audio clock stood when the pinch happened. Without a usable age
/// the event is stamped on arrival, as before. The input offset is still applied only when judging.
public struct InputTimestamp: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        /// Stamped at the event's own time.
        case eventTime
        /// No event time was available (or the feature is off): stamped when the callback ran.
        case arrival
        /// The event time was older than `Tuning.maxInputEventAgeMs`, so it was not trusted.
        case arrivalEventTooOld
        /// The event time was later than the callback by more than `futureToleranceMs`, so it was not trusted.
        case arrivalEventInFuture
    }

    /// Master-clock time to stamp on the event.
    public let atMs: Double
    /// How far `atMs` is before the arrival time (0 when stamped on arrival).
    public let backdatedMs: Double
    public let source: Source

    /// An event time this far after the callback is treated as rounding and clamped to the arrival time.
    public static let futureToleranceMs = 5.0

    /// - Parameters:
    ///   - arrivalMs: the master clock when the callback ran.
    ///   - eventAgeMs: how long before the callback the event happened, or nil if unknown.
    public static func stamp(arrivalMs: Double, eventAgeMs: Double?, tuning: Tuning) -> InputTimestamp {
        guard tuning.useInputEventTimestamps, let age = eventAgeMs, age.isFinite else {
            return InputTimestamp(atMs: arrivalMs, backdatedMs: 0, source: .arrival)
        }
        if age < -futureToleranceMs {
            return InputTimestamp(atMs: arrivalMs, backdatedMs: 0, source: .arrivalEventInFuture)
        }
        if age > tuning.maxInputEventAgeMs {
            return InputTimestamp(atMs: arrivalMs, backdatedMs: 0, source: .arrivalEventTooOld)
        }
        let backdated = max(age, 0)
        return InputTimestamp(atMs: arrivalMs - backdated, backdatedMs: backdated, source: .eventTime)
    }
}
