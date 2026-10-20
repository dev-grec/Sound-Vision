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
    @ObservationIgnored private let popups = JudgmentPopups()
    @ObservationIgnored private var zoneRing: ModelEntity?
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
        let map = entry.beatmap
        let tuning = model.tuning

        do {
            try clock.load(map, folder: entry.folder)
        } catch {
            return "Audio: \(error)"
        }
        let session = GameSession(beatmap: map, tuning: tuning, songDurationMs: clock.durationMs)
        self.session = session
        if model.autoplay {
            autoplay = .autoplay(for: map, tuning: tuning)
        }

        let rig = PlacementRig()
        let radius = Float(map.object.radiusM)
        let glass = GlassObject(radius: radius, variant: model.glassVariant)
        rig.placement.addChild(glass.root)
        rig.placement.addChild(popups.root)

        // Outline of the hittable zone, fixed toward the player.
        if let mesh = try? MeshBuilders.surfaceRibbon(directions: MeshBuilders.zoneCircle(angleDeg: tuning.hitZoneHalfAngleDeg),
                                                       radius: radius, lift: 0.001, width: 0.003, closed: true) {
            var m = UnlitMaterial(color: .white)
            m.blending = .transparent(opacity: .init(floatLiteral: 0.3))
            m.faceCulling = .none
            let ring = ModelEntity(mesh: mesh, materials: [m])
            glass.root.addChild(ring)
            zoneRing = ring
        }

        noteEntities = session.notes.map { note in
            let e = NoteVisuals.makeNote(note, radius: radius, tuning: tuning)
            glass.surfaceRoot.addChild(e)
            return e
        }

        if let hudEntity {
            hudEntity.position = [0, radius + 0.16, 0]
            rig.placement.addChild(hudEntity)
        }

        content.add(rig.anchor)
        self.rig = rig
        self.glass = glass
        hud = HUD(title: map.meta.title, total: session.notes.count,
                  message: model.autoplay ? "Autoplay" : "Look at a glowing note and pinch on the beat")

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

    func applyVariant(_ variant: GlassVariant) {
        glass?.apply(variant)
    }

    /// A pinch on an entity (from SpatialTapGesture.targetedToAnyEntity).
    func handleTap(on entity: Entity) {
        guard !stopped else { return }
        gestures.tap(on: entity)
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
                if let i = session.notes.firstIndex(where: { $0.id == id }) {
                    let pos = session.playfield.worldPosition(of: session.notes[i].at, atMs: now)
                    let normal = session.playfield.worldNormal(of: session.notes[i].at, atMs: now)
                    popups.spawn(judgment, at: SIMD3<Float>(pos + normal * 0.07), nowMs: now)
                }
                log.debug("\(id, privacy: .public) \(judgment.rawValue, privacy: .public) delta \(delta ?? .nan) combo \(combo)")
            case .ignored(let target, let reason):
                log.debug("ignored tap on \(target ?? "nothing", privacy: .public): \(String(describing: reason), privacy: .public)")
            }
        }
        if !events.isEmpty { refreshHUD(session) }

        updateNotes(session, glass: glass, now: now, tuning: tuning)
        if let zoneRing { glass.setSide(of: zoneRing, farSide: false) }
        popups.update(nowMs: now, durationMs: tuning.judgmentPopupMs)

        if !hud.finished, session.isFinished(nowMs: now) {
            finish(session, model: model)
        }
    }

    private func updateNotes(_ session: GameSession, glass: GlassObject, now: Double, tuning: Tuning) {
        let farOpacity = glass.farSideOpacity(base: Float(tuning.farSideOpacity))
        for (i, entity) in noteEntities.enumerated() {
            let note = session.notes[i]
            let far = session.playfield.isFarSide(note.at, atMs: now)
            glass.setSide(of: entity, farSide: far)
            switch session.states[i] {
            case .pending:
                let angle = session.playfield.angleFromFrontDeg(of: note.at, atMs: now)
                NoteVisuals.setTargetable(entity, angle <= tuning.targetableHalfAngleDeg)
                NoteVisuals.setLook(entity, angle <= tuning.hitZoneHalfAngleDeg ? .hittable : .approaching)
                NoteVisuals.setOpacity(entity, far ? farOpacity : 1)
                entity.scale = .one
            case .hit(_, _, let atMs):
                NoteVisuals.setTargetable(entity, false)
                NoteVisuals.setLook(entity, .hit)
                let t = Float(min(max((now - atMs) / 250, 0), 1))
                entity.scale = SIMD3(repeating: 1 + 0.6 * t)
                NoteVisuals.setOpacity(entity, 1 - t)
            case .missed(let atMs):
                NoteVisuals.setTargetable(entity, false)
                NoteVisuals.setLook(entity, .missed)
                let t = Float(min(max((now - atMs) / 500, 0), 1))
                NoteVisuals.setOpacity(entity, 0.8 * (1 - t))
            }
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
