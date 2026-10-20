import Foundation

/// The state of one play-through of a beatmap: which notes are judged, and the score.
///
/// Pure value type: the app drives it once per frame with `advance(nowMs:inputs:)`, where `nowMs`
/// is the master clock (audio position). Nothing in here reads a clock or counts frames.
///
/// Notes: plain tap notes, and tap notes with a slider (pinch the head on the beat, then drag the knob
/// along the track and reach the end at the slider's target time, DECISIONS D20). Strokes are loaded and
/// validated but not yet played.
public struct GameSession: Sendable {
    public enum NoteState: Sendable, Equatable {
        case pending
        /// A slider whose head was hit and whose knob is being dragged. `deltaMs` is the head's timing error.
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
        /// A slider's head was hit on time; the player now drags the knob. Not scored yet.
        case sliderStarted(noteID: String, head: Judgment, deltaMs: Double)
        /// A slider finished. `judgment` is final: the worse of the head and the finish. `finishDeltaMs`
        /// is when the knob reached the end relative to the target time (negative = early), or nil if it
        /// never got there (released early or ran out of time).
        case sliderEnded(noteID: String, judgment: Judgment, finishDeltaMs: Double?, combo: Int)
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

    /// Sliders being dragged, by note index.
    private var sliders: [Int: SliderProgress] = [:]
    /// The slider the current drag is moving, if any.
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
        let lastNoteMs = sorted.map {
            $0.endMs + max(tuning.goodWindowMs, tuning.sliderEndGoodWindowMs) + tuning.inputOffsetMs + tuning.inputDeliveryGraceMs
        }.max() ?? 0
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
            return press(targetID: targetID, atMs: atMs)
        case .dragBegan(let targetID, let point, let atMs):
            let events = press(targetID: targetID, atMs: atMs)
            return events + (point.map { sample($0, atMs: atMs) } ?? [])
        case .dragChanged(let point, let atMs):
            return point.map { sample($0, atMs: atMs) } ?? []
        case .dragEnded(let point, let atMs):
            var events = point.map { sample($0, atMs: atMs) } ?? []
            // Let go before the knob reached the end: the slider breaks.
            if let i = activeSliderIndex { events.append(finishSlider(i, atMs: atMs)) }
            return events
        }
    }

    /// A pinch on a note: judges a plain note or a slider's head. Hitting a slider head while another
    /// slider is still held ends the held one first (both events are returned).
    private mutating func press(targetID: String?, atMs: Double) -> [Event] {
        guard let id = targetID, let index = indexByID[id] else {
            return [.ignored(targetID: targetID, reason: .unknownTarget)]
        }
        guard states[index] == .pending else {
            return [.ignored(targetID: id, reason: .alreadyJudged)]
        }
        let note = notes[index]
        let judgedMs = atMs - tuning.inputOffsetMs
        guard approaches[index].hasAppeared(atMs: judgedMs) else {
            return [.ignored(targetID: id, reason: .notYetVisible)]
        }
        guard playfield.isInPlayArea(view: note.at, tuning: tuning) else {
            return [.ignored(targetID: id, reason: .outsideHitZone)]
        }
        // A pinch on a visible note always ends it (owner's rule, DECISIONS D9): inside the Good
        // window it's judged on timing; outside it's a Miss that the app shows as Early or Late.
        let delta = TapJudge.delta(inputMs: atMs, targetMs: note.timeMs, tuning: tuning)
        let judgment = TapJudge.judgment(forDeltaMs: delta, tuning: tuning) ?? .miss
        if judgment != .miss, note.slider != nil {
            // Slider head hit: the knob now follows the drag. Scored when the slider finishes.
            var events: [Event] = []
            if let previous = activeSliderIndex, previous != index { events.append(finishSlider(previous, atMs: atMs)) }
            states[index] = .holding(head: judgment, deltaMs: delta, atMs: atMs)
            sliders[index] = SliderProgress(note: note)
            activeSliderIndex = index
            return events + [.sliderStarted(noteID: id, head: judgment, deltaMs: delta)]
        }
        states[index] = judgment == .miss
            ? .missed(atMs: atMs, deltaMs: delta)
            : .hit(judgment, deltaMs: delta, atMs: atMs)
        score.record(judgment, tuning: tuning)
        advanceFirstPending()
        return [.judged(noteID: id, judgment: judgment, deltaMs: delta, combo: score.combo)]
    }

    /// A drag sample moves the active slider's knob; reaching the end finishes the slider.
    private mutating func sample(_ point: SurfacePoint, atMs: Double) -> [Event] {
        guard let i = activeSliderIndex, var progress = sliders[i] else { return [] }
        let finished = progress.add(point, atMs: atMs, tuning: tuning)
        sliders[i] = progress
        return finished ? [finishSlider(i, atMs: atMs)] : []
    }

    /// The final judgment of a slider: the worse of its head and its finish. A finish outside the Good
    /// window (or no finish at all) is a Miss.
    public static func sliderJudgment(head: Judgment, finishDeltaMs: Double?, tuning: Tuning) -> Judgment {
        guard let d = finishDeltaMs, let finish = SliderProgress.finishJudgment(deltaMs: d, tuning: tuning) else { return .miss }
        return max(head, finish) // Judgment orders best first, so max is the worse one
    }

    private mutating func finishSlider(_ index: Int, atMs: Double) -> Event {
        guard case .holding(let head, let delta, _) = states[index] else {
            return .ignored(targetID: notes[index].id, reason: .alreadyJudged)
        }
        let finishDelta = sliders[index]?.finishedAtMs.map { ($0 - tuning.inputOffsetMs) - notes[index].endMs }
        let judgment = Self.sliderJudgment(head: head, finishDeltaMs: finishDelta, tuning: tuning)
        states[index] = judgment == .miss
            ? .missed(atMs: atMs, deltaMs: nil)
            : .hit(judgment, deltaMs: delta, atMs: atMs)
        sliders[index] = nil
        if activeSliderIndex == index { activeSliderIndex = nil }
        score.record(judgment, tuning: tuning)
        advanceFirstPending()
        return .sliderEnded(noteID: notes[index].id, judgment: judgment, finishDeltaMs: finishDelta, combo: score.combo)
    }

    /// A held slider whose knob hasn't reached the end by the close of its finish window is a Miss.
    /// Like auto-misses, this waits `inputDeliveryGraceMs` for drag samples still on their way (D22).
    private mutating func finishSlidersPastTheirEnd(nowMs: Double) -> [Event] {
        let judgedNow = nowMs - tuning.inputOffsetMs - tuning.inputDeliveryGraceMs
        return sliders.keys.sorted()
            .filter { judgedNow > notes[$0].endMs + tuning.sliderEndGoodWindowMs }
            .map { finishSlider($0, atMs: nowMs) }
    }

    /// An unhit note becomes a Miss once its Good window has closed and `inputDeliveryGraceMs` more has
    /// passed: inputs are stamped with when the pinch happened (D22), so one can arrive after its window
    /// closed and still belong inside it.
    private mutating func declareMisses(nowMs: Double) -> [Event] {
        let judgedNow = nowMs - tuning.inputOffsetMs - tuning.inputDeliveryGraceMs
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

    /// The knob state of a held slider (for drawing the knob), nil if the slider isn't held.
    public func sliderProgress(ofNote index: Int) -> SliderProgress? {
        sliders[index]
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
