import Foundation

/// Player input, independent of where it came from (RealityKit gestures, autoplay, tests).
///
/// Every event carries `atMs`, the raw master-clock time when the input arrived. The calibrated input
/// offset is NOT applied here; the session applies it when judging.
public enum InputEvent: Sendable, Equatable {
    /// A pinch while targeting an entity. `targetID` is the note or stroke ID of the targeted entity,
    /// or nil if the pinch targeted nothing the game knows about.
    case tap(targetID: String?, atMs: Double)
    /// A drag began on a target (M1: stroke start). `point` is the drag location on the surface,
    /// in the object's own rotating coordinates.
    case dragBegan(targetID: String?, point: SurfacePoint?, atMs: Double)
    case dragChanged(point: SurfacePoint?, atMs: Double)
    case dragEnded(point: SurfacePoint?, atMs: Double)

    public var atMs: Double {
        switch self {
        case .tap(_, let t), .dragBegan(_, _, let t), .dragChanged(_, let t), .dragEnded(_, let t): t
        }
    }
}

/// Something that produces input events. The game loop polls every source once per frame.
///
/// - The app's gesture source buffers events from RealityKit gesture callbacks (stamped with the
///   audio clock when they arrive) and hands them over here.
/// - `ScriptedInputSource` replays a fixed list, for tests and the Autoplay debug mode.
public protocol InputSource {
    /// Returns, and removes, every pending event with `atMs <= nowMs`, in time order.
    mutating func pollEvents(nowMs: Double) -> [InputEvent]
}

/// Replays a fixed list of events as the clock reaches each one.
public struct ScriptedInputSource: InputSource, Sendable {
    private var pending: [InputEvent]

    public init(events: [InputEvent]) {
        pending = events.sorted { $0.atMs < $1.atMs }
    }

    public mutating func pollEvents(nowMs: Double) -> [InputEvent] {
        let due = pending.prefix { $0.atMs <= nowMs }
        pending.removeFirst(due.count)
        return Array(due)
    }

    public var isEmpty: Bool { pending.isEmpty }

    /// Perfect play: one tap on every note exactly on time (accounting for the input offset so the
    /// judged delta is zero). `jitterMs` optionally shifts every tap, to exercise other judgments.
    public static func autoplay(for beatmap: Beatmap, tuning: Tuning, jitterMs: Double = 0) -> ScriptedInputSource {
        let taps = beatmap.notes.map {
            InputEvent.tap(targetID: $0.id, atMs: $0.timeMs + tuning.inputOffsetMs + jitterMs)
        }
        return ScriptedInputSource(events: taps)
    }
}
