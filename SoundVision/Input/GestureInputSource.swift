import Foundation
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
/// Each event is stamped with the master clock (DECISIONS D9, D21). Drag events (the pinch press,
/// movement, release) carry the system's event time (`DragGesture.Value.time`), so they are stamped
/// with where the audio clock stood when the event happened: the clock now minus the event's age
/// (`InputTimestamp`). `SpatialTapGesture` gives no time, so a tap is stamped on arrival. The
/// calibrated input offset is applied later, by the session.
/// The game loop drains the buffer through the `InputSource` protocol, exactly like the scripted
/// autoplay source; with `Tuning.processInputOnArrival` the controller drains it right away.
final class GestureInputSource: @MainActor InputSource {
    private var pending: [InputEvent] = []
    private let clock: any PlaybackClock
    /// Set from the session's tuning when a map loads.
    var tuning = Tuning()
    private var stats = Stats()

    init(clock: any PlaybackClock) {
        self.clock = clock
    }

    /// A pinch (SpatialTapGesture, on release) on `entity` or one of its descendants.
    func tap(on entity: Entity) {
        let stamp = self.stamp(eventTime: nil)
        let event = InputEvent.tap(targetID: Self.targetID(of: entity), atMs: stamp.atMs)
        log.info("pinch gesture on \(entity.name, privacy: .public) at \(Int(stamp.atMs)) ms (release, stamped on arrival)")
        pending.append(event)
    }

    /// Whether a drag (pinch-and-hold) is in progress.
    private(set) var isDragging = false

    /// A DragGesture update. The first call of a drag is the pinch press on `entity`; later calls are
    /// movement. `point` is the drag location already projected onto the sphere in view coordinates.
    /// `eventTime` is the gesture value's `time`, when the system says the event happened.
    func drag(on entity: Entity, point: SurfacePoint?, eventTime: Date?) {
        let stamp = self.stamp(eventTime: eventTime)
        if !isDragging {
            isDragging = true
            stats.recordPress(stamp)
            let event = InputEvent.dragBegan(targetID: Self.targetID(of: entity), point: point, atMs: stamp.atMs)
            log.info("drag began on \(entity.name, privacy: .public) at \(Int(stamp.atMs)) ms (\(Self.describe(stamp), privacy: .public)), point \(point.map { "\(Int($0.lat)),\(Int($0.lon))" } ?? "none", privacy: .public)")
            pending.append(event)
        } else {
            pending.append(.dragChanged(point: point, atMs: stamp.atMs))
        }
    }

    /// The DragGesture ended (pinch released).
    func dragEnded(point: SurfacePoint?, eventTime: Date?) {
        guard isDragging else { return }
        isDragging = false
        let stamp = self.stamp(eventTime: eventTime)
        log.info("drag ended at \(Int(stamp.atMs)) ms (\(Self.describe(stamp), privacy: .public)), point \(point.map { "\(Int($0.lat)),\(Int($0.lon))" } ?? "none", privacy: .public)")
        pending.append(.dragEnded(point: point, atMs: stamp.atMs))
    }

    func pollEvents(nowMs: Double) -> [InputEvent] {
        defer { pending.removeAll() }
        return pending
    }

    /// Logs how far press callbacks lagged their events since the last call (DEVICE_TEST_CHECKLIST, latency).
    func logStats() {
        defer { stats = Stats() }
        guard stats.presses > 0 else { return }
        log.info("input stats: \(self.stats.presses) presses, \(self.stats.eventTimed) stamped at event time, backdated mean \(self.stats.meanBackdatedMs, format: .fixed(precision: 1)) ms, max \(self.stats.maxBackdatedMs, format: .fixed(precision: 1)) ms, fallbacks \(self.stats.fallbacks.description, privacy: .public)")
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

    // MARK: Stamping

    /// Reads the audio clock and the event's age back to back, so both describe the same moment.
    private func stamp(eventTime: Date?) -> InputTimestamp {
        let arrivalMs = clock.nowMs
        let ageMs = eventTime.map { Date().timeIntervalSince($0) * 1000 }
        return InputTimestamp.stamp(arrivalMs: arrivalMs, eventAgeMs: ageMs, tuning: tuning)
    }

    private static func describe(_ stamp: InputTimestamp) -> String {
        switch stamp.source {
        case .eventTime: "event time, \(String(format: "%.1f", stamp.backdatedMs)) ms before callback"
        case .arrival: "stamped on arrival"
        case .arrivalEventTooOld: "event time too old, stamped on arrival"
        case .arrivalEventInFuture: "event time in the future, stamped on arrival"
        }
    }

    private struct Stats {
        var presses = 0
        var eventTimed = 0
        var totalBackdatedMs = 0.0
        var maxBackdatedMs = 0.0
        var fallbacks: [String: Int] = [:]

        var meanBackdatedMs: Double { eventTimed > 0 ? totalBackdatedMs / Double(eventTimed) : 0 }

        mutating func recordPress(_ stamp: InputTimestamp) {
            presses += 1
            if stamp.source == .eventTime {
                eventTimed += 1
                totalBackdatedMs += stamp.backdatedMs
                maxBackdatedMs = max(maxBackdatedMs, stamp.backdatedMs)
            } else {
                fallbacks[stamp.source.rawValue, default: 0] += 1
            }
        }
    }
}
