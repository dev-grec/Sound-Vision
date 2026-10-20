import Foundation

/// The state of one play-through of a beatmap: which notes are judged, and the score.
///
/// Pure value type: the app drives it once per frame with `advance(nowMs:inputs:)`, where `nowMs`
/// is the master clock (audio position). Nothing in here reads a clock or counts frames.
///
/// M0 scope: tap notes. Strokes are loaded and validated but not yet played (M1).
public struct GameSession: Sendable {
    public enum NoteState: Sendable, Equatable {
        case pending
        /// `deltaMs` is the signed timing error (positive = late); `atMs` the raw input time.
        case hit(Judgment, deltaMs: Double, atMs: Double)
        /// `atMs` is the raw clock time of the miss. `deltaMs` is the timing error of the pinch that
        /// ended the note too early or too late, or nil if the note timed out unhit.
        case missed(atMs: Double, deltaMs: Double?)

        public var isJudged: Bool { self != .pending }

        public var judgment: Judgment? {
            switch self {
            case .pending: nil
            case .hit(let j, _, _): j
            case .missed: .miss
            }
        }
    }

    public enum IgnoredReason: Sendable, Equatable {
        case unknownTarget
        case alreadyJudged
        case outsideHitZone
        /// The note hasn't popped up yet (it's hidden, so this shouldn't come from real gestures).
        case notYetVisible
        case unsupportedInput
    }

    public enum Event: Sendable, Equatable {
        /// `deltaMs` is the pinch's timing error (positive = late), or nil for a note that timed out.
        /// A Miss with a delta is an off-beat pinch: negative = Early, positive = Late.
        case judged(noteID: String, judgment: Judgment, deltaMs: Double?, combo: Int)
        case ignored(targetID: String?, reason: IgnoredReason)
    }

    public let beatmap: Beatmap
    public let tuning: Tuning
    public let playfield: Playfield
    /// Tap notes sorted by time.
    public let notes: [TapNote]
    /// Each note's pop-up and approach ring timing (same order as `notes`). Before `appearMs` a note
    /// is not shown and can't be targeted.
    public let approaches: [NoteApproach]
    public private(set) var states: [NoteState]
    public private(set) var score = ScoreKeeper()
    /// Clock time after which the session is over (once every note is judged).
    public let endMs: Double

    private let indexByID: [String: Int]
    /// Every note before this index is judged; used to keep auto-miss scanning cheap.
    private var firstPendingIndex = 0

    /// - Parameter songDurationMs: the audio's length if known (file audio); otherwise the map's
    ///   own defined duration is used, then the last note.
    public init(beatmap: Beatmap, tuning: Tuning, songDurationMs: Double? = nil) {
        self.beatmap = beatmap
        self.tuning = tuning
        self.playfield = Playfield(beatmap: beatmap)
        let sorted = beatmap.notes.sorted { $0.timeMs < $1.timeMs }
        self.notes = sorted
        self.approaches = sorted.map { NoteApproach(hitMs: $0.timeMs, tuning: tuning) }
        self.states = Array(repeating: .pending, count: sorted.count)
        self.indexByID = Dictionary(sorted.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let lastNoteMs = sorted.last.map { $0.timeMs + tuning.goodWindowMs + tuning.inputOffsetMs } ?? 0
        let duration = songDurationMs ?? beatmap.definedDurationMs ?? lastNoteMs
        self.endMs = max(duration, lastNoteMs)
    }

    // MARK: Driving

    /// One frame: handle the inputs that arrived (in time order), then declare misses for notes whose
    /// window has closed. Inputs go first so a pinch stamped inside its window still counts even if
    /// the frame that delivers it lands just after the window closes.
    public mutating func advance(nowMs: Double, inputs: [InputEvent]) -> [Event] {
        var events: [Event] = []
        for input in inputs.sorted(by: { $0.atMs < $1.atMs }) {
            events += handle(input)
        }
        events += declareMisses(nowMs: nowMs)
        return events
    }

    public mutating func handle(_ input: InputEvent) -> [Event] {
        switch input {
        case .tap(let targetID, let atMs):
            return [handleTap(targetID: targetID, atMs: atMs)]
        case .dragBegan(let targetID, _, _):
            // Strokes are M1. Report it so the debug overlay can show it.
            return [.ignored(targetID: targetID, reason: .unsupportedInput)]
        case .dragChanged, .dragEnded:
            return []
        }
    }

    private mutating func handleTap(targetID: String?, atMs: Double) -> Event {
        guard let id = targetID, let index = indexByID[id] else {
            return .ignored(targetID: targetID, reason: .unknownTarget)
        }
        guard states[index] == .pending else {
            return .ignored(targetID: id, reason: .alreadyJudged)
        }
        let note = notes[index]
        let judgedMs = atMs - tuning.inputOffsetMs
        guard approaches[index].hasAppeared(atMs: judgedMs) else {
            return .ignored(targetID: id, reason: .notYetVisible)
        }
        guard playfield.isInPlayArea(view: note.at, tuning: tuning) else {
            return .ignored(targetID: id, reason: .outsideHitZone)
        }
        // A pinch on a visible note always ends it (owner's rule, DECISIONS D9): inside the Good
        // window it's judged on timing; outside it's a Miss that the app shows as Early or Late.
        let delta = TapJudge.delta(inputMs: atMs, targetMs: note.timeMs, tuning: tuning)
        let judgment = TapJudge.judgment(forDeltaMs: delta, tuning: tuning) ?? .miss
        states[index] = judgment == .miss
            ? .missed(atMs: atMs, deltaMs: delta)
            : .hit(judgment, deltaMs: delta, atMs: atMs)
        score.record(judgment, tuning: tuning)
        advanceFirstPending()
        return .judged(noteID: id, judgment: judgment, deltaMs: delta, combo: score.combo)
    }

    private mutating func declareMisses(nowMs: Double) -> [Event] {
        let judgedNow = nowMs - tuning.inputOffsetMs
        var events: [Event] = []
        var i = firstPendingIndex
        while i < notes.count, notes[i].timeMs + tuning.goodWindowMs < judgedNow {
            if states[i] == .pending {
                states[i] = .missed(atMs: nowMs, deltaMs: nil)
                score.record(.miss, tuning: tuning)
                events.append(.judged(noteID: notes[i].id, judgment: .miss, deltaMs: nil, combo: score.combo))
            }
            i += 1
        }
        advanceFirstPending()
        return events
    }

    private mutating func advanceFirstPending() {
        while firstPendingIndex < states.count, states[firstPendingIndex].isJudged {
            firstPendingIndex += 1
        }
    }

    // MARK: Queries

    public func state(ofNote id: String) -> NoteState? {
        indexByID[id].map { states[$0] }
    }

    /// Whether note `index` has popped up by raw clock time `ms`. The app hides notes until then.
    /// (The object keeps turning, so a note's surface spot also passes the front on earlier laps;
    /// it only exists from its pop-up.)
    public func hasAppeared(_ index: Int, atMs ms: Double) -> Bool {
        approaches[index].hasAppeared(atMs: ms - tuning.inputOffsetMs)
    }

    public var allNotesJudged: Bool { firstPendingIndex >= notes.count }

    public func isFinished(nowMs: Double) -> Bool {
        allNotesJudged && nowMs >= endMs
    }

    /// Fraction of notes judged, 0...1.
    public var progress: Double {
        notes.isEmpty ? 1 : Double(states.filter(\.isJudged).count) / Double(notes.count)
    }
}
