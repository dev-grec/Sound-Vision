import Observation
import os
import RealityKit
import RhythmCore
import SwiftUI
import UIKit

private let log = Logger(subsystem: "com.devgrec.SoundVision", category: "game")

/// Runs one play-through in the immersive space: the bridge between RhythmCore and RealityKit.
///
/// Each frame: read the master clock (audio position) → set the object's rotation from the
/// RhythmCore playfield → drain input sources → advance the GameSession → update visuals.
/// All game logic lives in RhythmCore; this class only reads it and moves entities.
@Observable
final class GameSceneController {
    /// What the floating HUD shows. Updated on judgments, not every frame.
    struct HUD: Equatable {
        var title = ""
        var score = 0
        var combo = 0
        var accuracy = 1.0
        var judged = 0
        var total = 0
        var autoplay = false
        var message = "Get ready…"
        var finished = false
    }

    private(set) var hud = HUD()

    @ObservationIgnored private var model: AppModel?
    @ObservationIgnored private var session: GameSession?
    @ObservationIgnored private let clock = AudioEngineClock()
    @ObservationIgnored private lazy var gestures = GestureInputSource(clock: clock)
    @ObservationIgnored private var autoplay: ScriptedInputSource?
    @ObservationIgnored private var rig: PlacementRig?
    @ObservationIgnored private var glass: GlassObject?
    @ObservationIgnored private var noteEntities: [ModelEntity] = []
    @ObservationIgnored private var approachRings: [Entity?] = []
    @ObservationIgnored private let popups = JudgmentPopups()
    /// Slider visuals by note index (only notes with a slider).
    @ObservationIgnored private var sliderVisuals: [Int: SliderVisuals] = [:]
    @ObservationIgnored private let dragCursor = DragCursor()
    @ObservationIgnored private var lastDragPoint: SurfacePoint?
    @ObservationIgnored private var updateSubscription: EventSubscription?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var stopped = false

    /// Seconds between the space opening and the music starting.
    private let startDelay: Duration = .seconds(1.5)

    /// Builds the scene for the selected map and adds it to `content`. Returns an error message
    /// to show if the map can't be played.
    func load(model: AppModel, into content: inout RealityViewContent, hud hudEntity: Entity?) -> String? {
        self.model = model
        guard let entry = model.selectedMap else { return "No beatmap found in the app bundle." }
        guard entry.report.isPlayable else { return "The beatmap has errors; see the launcher." }
        var map = entry.beatmap
        let tuning = model.tuning
        if model.randomSliders {
            // Development: random cardinal sliders, a new layout each play (or a fixed -sliderSeed).
            let seed = model.sliderSeed ?? UInt64.random(in: 0...UInt64(UInt32.max))
            let result = RandomSliders.add(to: map, tuning: tuning, seed: seed)
            map = result.beatmap
            let details = result.beatmap.notes.compactMap { note -> String? in
                guard let slider = note.slider, let end = slider.path.last else { return nil }
                let dir = end.lat > note.at.lat ? "up" : end.lat < note.at.lat ? "down" : end.lon > note.at.lon ? "right" : "left"
                return "\(note.id)@\(Int(note.timeMs)) \(dir) \(Int(note.at.angularDistanceDeg(to: end)))° \(Int(slider.durationMs))ms"
            }
            log.info("random sliders: seed \(seed), \(details.count) sliders: \(details.joined(separator: "; "), privacy: .public)")
        }

        do {
            try clock.load(map, folder: entry.folder)
        } catch {
            return "Audio: \(error)"
        }
        let session = GameSession(beatmap: map, tuning: tuning, songDurationMs: clock.durationMs)
        self.session = session
        if model.autoplay {
            autoplay = .autoplay(for: map, tuning: tuning, jitterMs: -model.autoplayEarlyMs)
        }

        let rig = PlacementRig()
        let radius = Float(map.object.radiusM)
        let glass = GlassObject(radius: radius, variant: model.glassVariant)
        rig.placement.addChild(glass.root)
        rig.placement.addChild(popups.root)

        // Tap notes are fixed in the player's view (DECISIONS D18): they hang from the non-rotating
        // glass root, not the rotating surfaceRoot, and their positions never change.
        noteEntities = session.notes.map { note in
            let e = NoteVisuals.makeNote(note, radius: radius, tuning: tuning)
            e.isEnabled = false // hidden until it pops up
            glass.root.addChild(e)
            glass.setSide(of: e, farSide: false)
            return e
        }
        approachRings = noteEntities.map { NoteVisuals.approachRing(of: $0) }
        for (i, note) in session.notes.enumerated() where note.slider != nil {
            let visuals = SliderVisuals(note: note, radius: radius, tuning: tuning)
            glass.root.addChild(visuals.root)
            sliderVisuals[i] = visuals
        }
        glass.root.addChild(dragCursor.entity)

        if let hudEntity {
            hudEntity.position = [0, radius + 0.16, 0]
            rig.placement.addChild(hudEntity)
        }

        content.add(rig.anchor)
        self.rig = rig
        self.glass = glass
        hud = HUD(title: map.meta.title, total: session.notes.count, autoplay: model.autoplay,
                  message: "Pinch each note when its ring closes. Sliders: hold and follow the ball.")

        updateSubscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            self?.frame()
        }
        frame() // place everything at t = 0 before the first render

        startTask = Task { [weak self, startDelay] in
            try? await Task.sleep(for: startDelay)
            guard let self, !self.stopped else { return }
            do {
                try self.clock.start()
                log.info("started \(map.meta.title, privacy: .public): \(session.notes.count) notes, autoplay \(model.autoplay)")
            } catch {
                self.hud.message = "Audio failed to start: \(error.localizedDescription)"
            }
        }
        return nil
    }

    private func spawnPopup(_ kind: JudgmentPopups.Kind, forNote id: String, session: GameSession, now: Double) {
        guard let note = session.notes.first(where: { $0.id == id }) else { return }
        let pos = session.playfield.viewPosition(of: note.at)
        // Toward the player (not along the surface normal), so text near the edge stays in front of the glass.
        popups.spawn(kind, at: SIMD3<Float>(pos + Playfield.front * 0.08), nowMs: now)
    }

    func applyVariant(_ variant: GlassVariant) {
        glass?.apply(variant)
    }

    /// A pinch on an entity (from SpatialTapGesture.targetedToAnyEntity).
    func handleTap(on entity: Entity) {
        guard !stopped else { return }
        gestures.tap(on: entity)
    }

    /// A DragGesture update (pinch-and-hold): the press, then movement.
    func handleDrag(_ value: EntityTargetValue<DragGesture.Value>) {
        guard !stopped, let rig else { return }
        let point = surfacePoint(of: value, in: rig.placement)
        lastDragPoint = point
        gestures.drag(on: value.entity, point: point)
    }

    func handleDragEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        guard !stopped, let rig else { return }
        lastDragPoint = nil
        gestures.dragEnded(point: surfacePoint(of: value, in: rig.placement))
    }

    /// The drag location projected onto the sphere, in view coordinates: convert it into the placement
    /// frame (centered on the object, non-rotating) and take its direction from the center.
    private func surfacePoint(of value: EntityTargetValue<DragGesture.Value>, in placement: Entity) -> SurfacePoint? {
        let p = value.convert(value.location3D, from: .local, to: placement)
        return SurfacePoint(direction: SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)))
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        startTask?.cancel()
        updateSubscription?.cancel()
        updateSubscription = nil
        clock.stop()
    }

    // MARK: Frame

    private func frame() {
        guard var session, let glass, let model else { return }
        let now = clock.nowMs
        let tuning = session.tuning

        glass.surfaceRoot.orientation = simd_quatf(session.playfield.orientation(atMs: now))

        var inputs = gestures.pollEvents(nowMs: now)
        if var auto = autoplay {
            inputs += auto.pollEvents(nowMs: now)
            autoplay = auto
        }
        let events = stopped ? [] : session.advance(nowMs: now, inputs: inputs)
        self.session = session

        for event in events {
            switch event {
            case .judged(let id, let judgment, let delta, let combo):
                // A Miss from a pinch (it has a delta) was off-beat: show Early or Late instead of Miss.
                let kind: JudgmentPopups.Kind = switch (judgment, delta) {
                case (.miss, .some(let d)): d < 0 ? .early : .late
                default: .judgment(judgment)
                }
                spawnPopup(kind, forNote: id, session: session, now: now)
                if let delta {
                    log.info("hit \(id, privacy: .public): \(judgment.rawValue, privacy: .public), delta \(Int(delta)) ms, combo \(combo)")
                } else {
                    log.debug("miss \(id, privacy: .public)")
                }
            case .sliderStarted(let id, let head, let delta):
                spawnPopup(.judgment(head), forNote: id, session: session, now: now)
                log.info("slider \(id, privacy: .public) head \(head.rawValue, privacy: .public), delta \(Int(delta)) ms")
            case .sliderEnded(let id, let judgment, let followScore, let combo):
                if let note = session.notes.first(where: { $0.id == id }), let end = note.sliderBallPoint(atMs: note.endMs) {
                    let pos = session.playfield.viewPosition(of: end)
                    popups.spawn(.judgment(judgment), at: SIMD3<Float>(pos + Playfield.front * 0.08), nowMs: now)
                }
                log.info("slider \(id, privacy: .public) ended: \(judgment.rawValue, privacy: .public), follow \(Int(followScore * 100))%, combo \(combo)")
            case .ignored(let target, let reason):
                log.info("pinch on \(target ?? "nothing", privacy: .public) ignored: \(String(describing: reason), privacy: .public)")
            }
        }
        if !events.isEmpty { refreshHUD(session) }

        updateNotes(session, now: now, tuning: tuning)
        updateSliders(session, now: now, tuning: tuning)
        dragCursor.show(at: lastDragPoint, radius: glass.radius)
        popups.update(nowMs: now, durationMs: tuning.judgmentPopupMs)

        if !hud.finished, session.isFinished(nowMs: now) {
            finish(session, model: model)
        }
    }

    private func updateNotes(_ session: GameSession, now: Double, tuning: Tuning) {
        for (i, entity) in noteEntities.enumerated() {
            switch session.states[i] {
            case .pending:
                // A note exists only from its pop-up; then its ring shrinks and closes at the hit time.
                guard session.hasAppeared(i, atMs: now) else {
                    NoteVisuals.setTargetable(entity, false)
                    if entity.isEnabled { entity.isEnabled = false }
                    continue
                }
                if !entity.isEnabled { entity.isEnabled = true }
                let judgedNow = now - tuning.inputOffsetMs
                let approach = session.approaches[i]
                let pop = Float(min(max((judgedNow - approach.appearMs) / tuning.noteFadeInMs, 0), 1))
                NoteVisuals.setTargetable(entity, true)
                NoteVisuals.setLook(entity, .hittable)
                NoteVisuals.setOpacity(entity, pop)
                entity.scale = SIMD3(repeating: 0.6 + 0.4 * pop)
                if let ring = approachRings[i] {
                    if !ring.isEnabled { ring.isEnabled = true }
                    let s = Float(approach.ringScale(atMs: judgedNow, tuning: tuning))
                    ring.scale = [s, 1, s]
                    NoteVisuals.setOpacity(ring, 0.35 + 0.65 * Float(approach.progress(atMs: judgedNow)))
                }
            case .holding:
                // The slider ball takes over from the head.
                approachRings[i]?.isEnabled = false
                NoteVisuals.setTargetable(entity, false)
                NoteVisuals.setOpacity(entity, 0)
            case .hit(_, _, let atMs):
                approachRings[i]?.isEnabled = false
                NoteVisuals.setTargetable(entity, false)
                NoteVisuals.setLook(entity, .hit)
                let t = Float(min(max((now - atMs) / 250, 0), 1))
                entity.scale = SIMD3(repeating: 1 + 0.6 * t)
                NoteVisuals.setOpacity(entity, 1 - t)
            case .missed(let atMs, _):
                approachRings[i]?.isEnabled = false
                NoteVisuals.setTargetable(entity, false)
                NoteVisuals.setLook(entity, .missed)
                let t = Float(min(max((now - atMs) / 500, 0), 1))
                NoteVisuals.setOpacity(entity, 0.8 * (1 - t))
            }
        }
    }

    private func updateSliders(_ session: GameSession, now: Double, tuning: Tuning) {
        let judgedNow = now - tuning.inputOffsetMs
        for (i, visuals) in sliderVisuals {
            let approach = session.approaches[i]
            let popIn = approach.hasAppeared(atMs: judgedNow)
                ? Float(min(max((judgedNow - approach.appearMs) / tuning.noteFadeInMs, 0), 1)) : 0
            visuals.update(note: session.notes[i], state: session.states[i], popIn: popIn, judgedNow: judgedNow,
                           nowMs: now, lastCredit: session.lastFollowCredit(ofNote: i))
        }
    }

    private func refreshHUD(_ session: GameSession) {
        hud.score = session.score.score
        hud.combo = session.score.combo
        hud.accuracy = session.score.accuracy
        hud.judged = session.score.judgedCount
        model?.liveStatus = "\(hud.judged)/\(hud.total) judged · combo \(hud.combo) · score \(hud.score)"
    }

    private func finish(_ session: GameSession, model: AppModel) {
        hud.finished = true
        hud.message = "Song complete"
        clock.stop() // rotation freezes where the song ended
        let result = GameResult(title: session.beatmap.meta.title, score: session.score.score,
                                accuracy: session.score.accuracy, maxCombo: session.score.maxCombo,
                                counts: session.score.counts, totalNotes: session.notes.count)
        model.lastResult = result
        model.liveStatus = "Finished. Results are below."
        log.info("finished: score \(result.score) accuracy \(result.accuracy) maxCombo \(result.maxCombo)/\(result.totalNotes) perfect \(result.counts[.perfect, default: 0]) miss \(result.counts[.miss, default: 0])")
    }
}
