import Foundation

/// A target's on-screen life: it pops up `Tuning.approachMs` before its hit time, its approach ring
/// shrinks onto it, and the ring closes exactly at the hit time.
///
/// All times are judged clock times (raw clock minus the input offset), so the ring closes when a
/// perfectly timed pinch should land.
public struct NoteApproach: Sendable, Equatable {
    public var appearMs: Double
    public var hitMs: Double

    public init(hitMs: Double, tuning: Tuning) {
        self.hitMs = hitMs
        self.appearMs = hitMs - tuning.approachMs
    }

    /// Whether the target has popped up by (judged) time `ms`.
    public func hasAppeared(atMs ms: Double) -> Bool {
        ms >= appearMs
    }

    /// 0 at pop-up, 1 at the hit time, clamped. The ring's scale goes from the start scale to 1.
    public func progress(atMs ms: Double) -> Double {
        guard hitMs > appearMs else { return 1 }
        return min(max((ms - appearMs) / (hitMs - appearMs), 0), 1)
    }

    /// Approach ring scale (multiple of the note radius) at (judged) time `ms`.
    public func ringScale(atMs ms: Double, tuning: Tuning) -> Double {
        tuning.approachRingStartScale + (1 - tuning.approachRingStartScale) * progress(atMs: ms)
    }
}
