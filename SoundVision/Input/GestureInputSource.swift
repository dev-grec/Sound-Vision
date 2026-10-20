import os
import RealityKit
import RhythmCore

private let log = Logger(subsystem: "com.devgrec.SoundVision", category: "input")

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
        let event = InputEvent.tap(targetID: Self.targetID(of: entity), atMs: clock.nowMs)
        log.info("pinch gesture on \(entity.name, privacy: .public) at \(Int(event.atMs)) ms")
        pending.append(event)
    }

    /// Whether a drag (pinch-and-hold) is in progress.
    private(set) var isDragging = false

    /// A DragGesture update. The first call of a drag is the pinch press on `entity`; later calls are
    /// movement. `point` is the drag location already projected onto the sphere in view coordinates.
    func drag(on entity: Entity, point: SurfacePoint?) {
        let now = clock.nowMs
        if !isDragging {
            isDragging = true
            let event = InputEvent.dragBegan(targetID: Self.targetID(of: entity), point: point, atMs: now)
            log.info("drag began on \(entity.name, privacy: .public) at \(Int(now)) ms, point \(point.map { "\(Int($0.lat)),\(Int($0.lon))" } ?? "none", privacy: .public)")
            pending.append(event)
        } else {
            pending.append(.dragChanged(point: point, atMs: now))
        }
    }

    /// The DragGesture ended (pinch released).
    func dragEnded(point: SurfacePoint?) {
        guard isDragging else { return }
        isDragging = false
        let now = clock.nowMs
        log.info("drag ended at \(Int(now)) ms, point \(point.map { "\(Int($0.lat)),\(Int($0.lon))" } ?? "none", privacy: .public)")
        pending.append(.dragEnded(point: point, atMs: now))
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
