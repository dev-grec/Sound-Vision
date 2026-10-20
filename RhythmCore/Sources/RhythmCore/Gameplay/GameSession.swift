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
        /// `atMs` is the clock time when the miss was declared.
        case missed(atMs: Double)

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
        case outsideTimingWindow(deltaMs: Double)
        case unsupportedInput
    }

    public enum Event: Sendable, Equatable {
        case judged(noteID: String, judgment: Judgment, deltaMs: Double?, combo: Int)
        case ignored(targetID: String?, reason: IgnoredReason)
    }

    public let beatmap: Beatmap
    public let tuning: Tuning
    public let playfield: Playfield
    /// Tap notes sorted by time.
    public let notes: [TapNote]
    /// Each note's final approach (same order as `notes`): when it appears and when it may be targeted.
    /// Before `appearMs` a note is on an earlier revolution and must not be shown.
    public let approaches: [Playfield.Approach]
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
        let playfield = Playfield(beatmap: beatmap)
        self.playfield = playfield
        let sorted = beatmap.notes.sorted { $0.timeMs < $1.timeMs }
        self.notes = sorted
        self.approaches = sorted.map { playfield.approach(of: $0.at, hitMs: $0.timeMs, tuning: tuning) }
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
        guard playfield.isInHitZone(note.at, atMs: judgedMs, tuning: tuning) else {
            return .ignored(targetID: id, reason: .outsideHitZone)
        }
        let delta = TapJudge.delta(inputMs: atMs, targetMs: note.timeMs, tuning: tuning)
        guard let judgment = TapJudge.judgment(forDeltaMs: delta, tuning: tuning) else {
            return .ignored(targetID: id, reason: .outsideTimingWindow(deltaMs: delta))
        }
        states[index] = .hit(judgment, deltaMs: delta, atMs: atMs)
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
                states[i] = .missed(atMs: nowMs)
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

    /// Whether note `index` is on its final approach (or later) at clock time `ms`. The app hides notes
    /// until then; a note passing the front on an earlier revolution is not playable.
    public func isOnFinalApproach(_ index: Int, atMs ms: Double) -> Bool {
        ms - tuning.inputOffsetMs >= approaches[index].appearMs
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
