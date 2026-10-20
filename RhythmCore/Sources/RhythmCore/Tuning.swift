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

    // MARK: Input latency (DECISIONS D21)

    /// Stamp drag events (the pinch press, movement, release) with the time the system says the event
    /// happened (`DragGesture.Value.time`), carried back onto the audio clock, instead of the time the
    /// callback ran. Removes the gesture delivery delay and its jitter from judging. [device]
    public var useInputEventTimestamps: Bool = true
    /// An event timestamp older than this when its callback runs is treated as unreliable, and the event
    /// is stamped on arrival instead. [device]
    public var maxInputEventAgeMs: Double = 150
    /// Auto-misses and slider timeouts wait this long after their window closes, so a pinch that happened
    /// inside the window still counts when its callback arrives a little after. [device]
    public var inputDeliveryGraceMs: Double = 50
    /// Run the game step (judge, update notes, play the hit sound) straight from the gesture callback
    /// instead of waiting for the next frame. Judging is unchanged: it only depends on the stamped time.
    public var processInputOnArrival: Bool = true

    // MARK: Play area

    /// The play area: the part of the object's front, within this angle of the direction toward the
    /// player, where notes pop up and can be hit. The validator requires every note to stay inside it
    /// for its whole visible window (pop-up to the end of its Good window). [device]
    public var hitZoneHalfAngleDeg: Double = 45

    // MARK: Note approach (pop-up + shrinking ring)

    /// A note pops up this long before its hit time. Its approach ring shrinks over the same span and
    /// closes onto the note exactly at the hit time: that's the timing cue. [device]
    public var approachMs: Double = 1500
    /// Approach ring size when the note pops up, as a multiple of the note's radius (1 = touching). [device]
    public var approachRingStartScale: Double = 3
    /// Pop-up animation time (fade and grow in), in ms.
    public var noteFadeInMs: Double = 200

    // MARK: Note size and spacing

    /// Visual diameter of a tap note disc, in meters. [device]
    public var noteDiameterM: Double = 0.07
    /// Collision radius as a multiple of the visual radius; bigger is easier to target. [device]
    public var noteHitRadiusScale: Double = 1.3
    /// Height of notes above the glass surface, in meters, to avoid z-fighting.
    public var noteSurfaceLiftM: Double = 0.004
    /// Validator: two targets (notes or stroke starts) on screen at the same time (overlapping
    /// pop-up-to-window-close spans) must be at least this far apart on the surface. [device]
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

    // MARK: Sliders (a tap note with a path: pinch the head on the beat, then drag the knob along the
    // track and reach the end at the slider's target time)

    /// The knob follows the player's drag while the drag is within this angle of the track; further away
    /// it stops (and shows as lost). [device]
    public var sliderGrabRadiusDeg: Double = 15
    /// The slider is finished when the knob is within this angle of the track's end. [device]
    public var sliderEndToleranceDeg: Double = 1.5
    /// Finish-time windows (half-widths, ms) around the target time (hit time + duration). More generous
    /// than tap windows: dragging to a point is less precise than pinching. Finishing earlier than the Good
    /// window is "Early" (a Miss); not finishing by its end is a Miss. [device]
    public var sliderEndPerfectWindowMs: Double = 100
    public var sliderEndGreatWindowMs: Double = 180
    public var sliderEndGoodWindowMs: Double = 260
    /// Validator: a slider's required pace (track length / duration) may not exceed this. [device]
    public var maxSliderSpeedDegPerSec: Double = 75
    /// How long the slider timer shows the final early/late time after the slider finishes, in ms.
    public var sliderResultDisplayMs: Double = 900

    // MARK: Random sliders (development only, until levels are designed)

    /// Chance that a note with room after it gets a random slider.
    public var randomSliderChance: Double = 0.5
    /// Random slider length range, in degrees of view.
    public var randomSliderLengthDeg: ClosedRange<Double> = 20...45
    /// Random slider durations to choose from, in beats (0.5–1 s at 120 BPM; owner asked for quicker sliders).
    public var randomSliderBeats: [Double] = [1, 1.5, 2]
    /// A random slider must end at least this many beats before the next note's hit time.
    public var randomSliderGapBeats: Double = 1

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
    /// Volume (0...1) of the short tick played the moment a pinch hits a note, synthesized at runtime.
    /// Sound is the fastest feedback channel; 0 turns it off. [device]
    public var hitSoundVolume: Double = 0.35

    public init() {}

    public static let `default` = Tuning()
}
