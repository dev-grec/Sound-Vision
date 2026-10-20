// THE single tunable settings file for game feel.
//
// Every number that changes how the game feels belongs here, not scattered through the code.
// Defaults are first guesses from the simulator. Anything marked [device] still needs tuning on
// a real Vision Pro (see docs/DEVICE_TEST_CHECKLIST.md).
//
// Tuning is Codable so settings and calibration (M2) can persist overrides on top of these defaults.

public struct Tuning: Codable, Sendable, Equatable {

    // MARK: Timing windows (half-widths, ms)

    /// |delta| at or under this is Perfect. [device]
    public var perfectWindowMs: Double = 60
    /// |delta| at or under this is Great. [device]
    public var greatWindowMs: Double = 110
    /// |delta| at or under this is Good. Past it, a tap is ignored and an unhit note becomes a Miss. [device]
    public var goodWindowMs: Double = 170

    // MARK: Calibration

    /// Input latency compensation, subtracted from every input timestamp before judging.
    /// Positive means "my pinches register late". User-adjustable in the launcher. [device]
    public var inputOffsetMs: Double = 0
    /// Range of the user-facing offset slider.
    public var inputOffsetRangeMs: ClosedRange<Double> = -250...250

    // MARK: Hittable zone

    /// A note is hittable while the angle between its surface normal and the front direction
    /// (toward the player) is at most this. [device]
    public var hitZoneHalfAngleDeg: Double = 30
    /// Notes become input targets (hover highlight, pinchable) inside this angle, slightly wider than
    /// the hit zone so the highlight appears as they arrive. Taps outside the hit zone are still ignored.
    public var targetableHalfAngleDeg: Double = 40
    /// Validator: a note should sit within this angle of zone center at its own time.
    /// Outside it (but inside the hit zone) is a warning. Outside the hit zone is an error.
    public var noteComfortAngleDeg: Double = 20

    // MARK: Note approach

    /// Every point on the object passes the front once per revolution, so a note is shown only on its
    /// final approach: it appears when it was last this far from front before its hit time.
    /// Over 90° means it first shows on the far side, faintly through the glass. [device]
    public var noteAppearAngleDeg: Double = 150
    /// Fade-in time when a note appears, in ms.
    public var noteFadeInMs: Double = 400

    // MARK: Note size and spacing

    /// Visual diameter of a tap note disc, in meters. [device]
    public var noteDiameterM: Double = 0.07
    /// Collision radius as a multiple of the visual radius; bigger is easier to target. [device]
    public var noteHitRadiusScale: Double = 1.3
    /// Height of notes above the glass surface, in meters, to avoid z-fighting.
    public var noteSurfaceLiftM: Double = 0.004
    /// Validator: two targets (notes or stroke starts) that are targetable at the same time
    /// (overlapping final approaches) must be at least this far apart on the surface. [device]
    public var minNoteSeparationDeg: Double = 25

    // MARK: Rotation

    /// Validator: the object may never rotate faster than this. Eye targeting needs slow targets. [device]
    public var maxDegreesPerSecond: Double = 20

    // MARK: Far-side visibility

    /// Opacity of notes and strokes on the far side of the object, seen through the glass. [device]
    public var farSideOpacity: Double = 0.35

    // MARK: Strokes (M1 uses these; the scoring logic is already tested)

    /// Drag samples within this angle of the guide earn full credit. [device]
    public var followToleranceDeg: Double = 6
    /// Credit falls linearly to zero at this angle from the guide. [device]
    public var followFalloffDeg: Double = 18
    /// A stroke's duration is split into this many time buckets; an empty bucket scores zero,
    /// so letting go early or skipping part of the path costs credit.
    public var strokeScoreBuckets: Int = 20
    /// Follow score at or above which a stroke reveals in full color.
    public var revealFullThreshold: Double = 0.8
    /// Follow score at or above which a stroke reveals faintly. Below it the stroke stays uncolored.
    public var revealFaintThreshold: Double = 0.4
    /// Duration of the color-fill animation when a stroke completes, in ms. [device]
    public var revealAnimationMs: Double = 600

    // MARK: Scoring

    public var scorePerfect: Int = 300
    public var scoreGreat: Int = 200
    public var scoreGood: Int = 100
    /// Accuracy weight per judgment (Miss is 0).
    public var accuracyPerfect: Double = 1.0
    public var accuracyGreat: Double = 0.7
    public var accuracyGood: Double = 0.4

    // MARK: Feedback

    /// How long a judgment popup stays visible, in ms.
    public var judgmentPopupMs: Double = 700

    public init() {}

    public static let `default` = Tuning()
}
