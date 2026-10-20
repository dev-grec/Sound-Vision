import Foundation

/// The state of one play-through of a beatmap: which notes are judged, and the score.
///
/// Pure value type: the app drives it once per frame with `advance(nowMs:inputs:)`, where `nowMs`
/// is the master clock (audio position). Nothing in here reads a clock or counts frames.
///
/// Notes: plain tap notes, and tap notes with a slider (pinch the head on the beat, hold, drag along
/// the path following the ball). Strokes are loaded and validated but not yet played.
public struct GameSession: Sendable {
    public enum NoteState: Sendable, Equatable {
        case pending
        /// A slider whose head was hit and that is being followed. `deltaMs` is the head's timing error.
        case holding(head: Judgment, deltaMs: Double, atMs: Double)
        /// Final. `deltaMs` is the (head) pinch's signed timing error (positive = late); `atMs` the raw
        /// time it was judged (the pinch, or for a slider its release or end).
        case hit(Judgment, deltaMs: Double, atMs: Double)
        /// `atMs` is the raw clock time of the miss. `deltaMs` is the timing error of the pinch that
        /// ended the note too early or too late, or nil if the note timed out unhit or its slider broke.
        case missed(atMs: Double, deltaMs: Double?)

        /// Finished: hit or missed (a held slider is not finished yet).
        public var isJudged: Bool {
            switch self {
            case .pending, .holding: false
            case .hit, .missed: true
            }
        }

        public var judgment: Judgment? {
            switch self {
            case .pending, .holding: nil
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
        /// A note was finished by a pinch or timed out. `deltaMs` is the pinch's timing error
        /// (positive = late), or nil for a note that timed out. A Miss with a delta is an off-beat
        /// pinch: negative = Early, positive = Late.
        case judged(noteID: String, judgment: Judgment, deltaMs: Double?, combo: Int)
        /// A slider's head was hit on time; the player now follows the ball. Not scored yet.
        case sliderStarted(noteID: String, head: Judgment, deltaMs: Double)
        /// A slider finished (released or reached its end). `judgment` is final; Miss means it broke.
        case sliderEnded(noteID: String, judgment: Judgment, followScore: Double, combo: Int)
        case ignored(targetID: String?, reason: IgnoredReason)
    }

    public let beatmap: Beatmap
    public let tuning: Tuning
    public let playfield: Playfield
    /// Tap notes (with or without sliders) sorted by time.
    public let notes: [TapNote]
    /// Each note's pop-up and approach ring timing (same order as `notes`). Before `appearMs` a note
    /// is not shown and can't be targeted.
    public let approaches: [NoteApproach]
    public private(set) var states: [NoteState]
    public private(set) var score = ScoreKeeper()
    /// Clock time after which the session is over (once every note is judged).
    public let endMs: Double

    /// Follow scorers of sliders being held, by note index.
    private var followers: [Int: PathFollowScorer] = [:]
    /// The slider the current drag is following, if any.
    public private(set) var activeSliderIndex: Int?

    private let indexByID: [String: Int]
    /// Every note before this index is finished; used to keep auto-miss scanning cheap.
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
        let lastNoteMs = sorted.map { $0.endMs + tuning.goodWindowMs + tuning.inputOffsetMs }.max() ?? 0
        let duration = songDurationMs ?? beatmap.definedDurationMs ?? lastNoteMs
        self.endMs = max(duration, lastNoteMs)
    }

    // MARK: Driving

    /// One frame: handle the inputs that arrived (in time order), then declare misses for notes whose
    /// window has closed and finish sliders that reached their end. Inputs go first so a pinch stamped
    /// inside its window still counts even if the frame that delivers it lands just after the window closes.
    public mutating func advance(nowMs: Double, inputs: [InputEvent]) -> [Event] {
        var events: [Event] = []
        for input in inputs.sorted(by: { $0.atMs < $1.atMs }) {
            events += handle(input)
        }
        events += finishSlidersPastTheirEnd(nowMs: nowMs)
        events += declareMisses(nowMs: nowMs)
        return events
    }

    /// Input semantics. A pinch arrives as `.tap` (SpatialTapGesture, on release) and/or `.dragBegan`
    /// (DragGesture, on press); whichever comes first judges the note and the other is ignored as
    /// already judged. Drag points are in view coordinates (placement frame).
    public mutating func handle(_ input: InputEvent) -> [Event] {
        switch input {
        case .tap(let targetID, let atMs):
            return [press(targetID: targetID, atMs: atMs)]
        case .dragBegan(let targetID, let point, let atMs):
            let event = press(targetID: targetID, atMs: atMs)
            if let point { sample(point, atMs: atMs) }
            return [event]
        case .dragChanged(let point, let atMs):
            if let point { sample(point, atMs: atMs) }
            return []
        case .dragEnded(let point, let atMs):
            if let point { sample(point, atMs: atMs) }
            guard let i = activeSliderIndex else { return [] }
            return [finishSlider(i, atMs: atMs)]
        }
    }

    /// A pinch on a note: judges a plain note or a slider's head.
    private mutating func press(targetID: String?, atMs: Double) -> Event {
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
        if judgment != .miss, let follower = PathFollowScorer(sliderOf: note, tuning: tuning) {
            // Slider head hit: start following. Scored when the slider finishes.
            if let previous = activeSliderIndex, previous != index { _ = finishSlider(previous, atMs: atMs) }
            states[index] = .holding(head: judgment, deltaMs: delta, atMs: atMs)
            followers[index] = follower
            activeSliderIndex = index
            return .sliderStarted(noteID: id, head: judgment, deltaMs: delta)
        }
        states[index] = judgment == .miss
            ? .missed(atMs: atMs, deltaMs: delta)
            : .hit(judgment, deltaMs: delta, atMs: atMs)
        score.record(judgment, tuning: tuning)
        advanceFirstPending()
        return .judged(noteID: id, judgment: judgment, deltaMs: delta, combo: score.combo)
    }

    private mutating func sample(_ point: SurfacePoint, atMs: Double) {
        guard let i = activeSliderIndex else { return }
        followers[i]?.addSample(point: point, atMs: atMs)
    }

    /// The final judgment of a slider from its head judgment and follow score.
    public static func sliderJudgment(head: Judgment, followScore: Double, tuning: Tuning) -> Judgment {
        if followScore >= tuning.sliderKeepJudgmentScore { return head }
        if followScore >= tuning.sliderBreakScore {
            switch head {
            case .perfect: return .great
            case .great, .good: return .good
            case .miss: return .miss
            }
        }
        return .miss
    }

    private mutating func finishSlider(_ index: Int, atMs: Double) -> Event {
        guard case .holding(let head, let delta, _) = states[index] else {
            return .ignored(targetID: notes[index].id, reason: .alreadyJudged)
        }
        let followScore = followers[index]?.followScore ?? 0
        let judgment = Self.sliderJudgment(head: head, followScore: followScore, tuning: tuning)
        states[index] = judgment == .miss
            ? .missed(atMs: atMs, deltaMs: nil)
            : .hit(judgment, deltaMs: delta, atMs: atMs)
        followers[index] = nil
        if activeSliderIndex == index { activeSliderIndex = nil }
        score.record(judgment, tuning: tuning)
        advanceFirstPending()
        return .sliderEnded(noteID: notes[index].id, judgment: judgment, followScore: followScore, combo: score.combo)
    }

    /// A held slider whose end has passed finishes on its own (the player may still be holding).
    private mutating func finishSlidersPastTheirEnd(nowMs: Double) -> [Event] {
        let judgedNow = nowMs - tuning.inputOffsetMs
        return followers.keys.sorted()
            .filter { judgedNow > notes[$0].endMs }
            .map { finishSlider($0, atMs: nowMs) }
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
    public func hasAppeared(_ index: Int, atMs ms: Double) -> Bool {
        approaches[index].hasAppeared(atMs: ms - tuning.inputOffsetMs)
    }

    /// The credit of the latest drag sample on a held slider (for live "following / not following"
    /// feedback), nil if the slider isn't held or has no samples yet.
    public func lastFollowCredit(ofNote index: Int) -> Double? {
        followers[index]?.lastCredit
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
