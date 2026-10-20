import RealityKit
import RhythmCore

/// Tags an entity as a gameplay target, so a gesture on it can be mapped to a note or stroke ID.
struct GameTargetComponent: Component {
    var targetID: String
}

/// Turns RealityKit entity-targeted gestures into RhythmCore `InputEvent`s.
///
/// Gesture callbacks carry no audio timestamp, so each event is stamped with the master clock when
/// the callback runs. The calibrated input offset is applied later, by the session.
/// The game loop drains the buffer once per frame through the `InputSource` protocol, exactly like
/// the scripted autoplay source.
final class GestureInputSource: @MainActor InputSource {
    private var pending: [InputEvent] = []
    private let clock: any PlaybackClock

    init(clock: any PlaybackClock) {
        self.clock = clock
    }

    /// A pinch (SpatialTapGesture) on `entity` or one of its descendants.
    func tap(on entity: Entity) {
        pending.append(.tap(targetID: Self.targetID(of: entity), atMs: clock.nowMs))
    }

    func pollEvents(nowMs: Double) -> [InputEvent] {
        defer { pending.removeAll() }
        return pending
    }

    /// The target ID on `entity` or its nearest tagged ancestor.
    static func targetID(of entity: Entity) -> String? {
        var e: Entity? = entity
        while let current = e {
            if let tag = current.components[GameTargetComponent.self] { return tag.targetID }
            e = current.parent
        }
        return nil
    }
}
