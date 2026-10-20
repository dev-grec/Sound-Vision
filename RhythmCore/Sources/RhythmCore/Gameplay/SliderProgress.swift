import Foundation

/// A held slider: the knob follows the player's drag along the track, and the slider is finished when
/// the knob reaches the end. The finish is judged against the slider's target time (owner's design,
/// DECISIONS D20): the time to take is fixed by the map, and a timer counts it down.
public struct SliderProgress: Sendable, Equatable {
    public let path: StrokePath
    /// Target finish time (judged clock): the note's hit time + the slider's duration.
    public let targetMs: Double
    /// How far along the track the knob is, 0...1. It never moves backward.
    public private(set) var progress: Double = 0
    /// Whether the latest drag sample was close enough to the track to move the knob.
    public private(set) var onTrack = true
    /// Raw clock time when the knob reached the end, nil until then.
    public private(set) var finishedAtMs: Double?

    public init(note: TapNote) {
        path = note.sliderPath ?? StrokePath(points: [note.at])
        targetMs = note.endMs
    }

    /// Feeds a drag sample (view coordinates). Returns true if this sample finished the slider.
    @discardableResult
    public mutating func add(_ point: SurfacePoint, atMs rawMs: Double, tuning: Tuning) -> Bool {
        guard finishedAtMs == nil, point.isFinite else { return false }
        let (fraction, distance) = path.closest(to: point)
        onTrack = distance <= tuning.sliderGrabRadiusDeg
        guard onTrack else { return false }
        progress = max(progress, fraction)
        let remainingDeg = (1 - progress) * path.totalAngleDeg
        if remainingDeg <= tuning.sliderEndToleranceDeg {
            progress = 1
            finishedAtMs = rawMs
            return true
        }
        return false
    }

    /// Where the knob is, in view coordinates.
    public var knobPoint: SurfacePoint { path.point(atFraction: progress) }

    /// The finish judgment for a signed finish-time error (positive = late), or nil outside the Good window.
    public static func finishJudgment(deltaMs: Double, tuning: Tuning) -> Judgment? {
        let d = abs(deltaMs)
        if d <= tuning.sliderEndPerfectWindowMs { return .perfect }
        if d <= tuning.sliderEndGreatWindowMs { return .great }
        if d <= tuning.sliderEndGoodWindowMs { return .good }
        return nil
    }
}
