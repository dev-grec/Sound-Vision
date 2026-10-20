import RealityKit
import RhythmCore
import UIKit

/// The visuals of one slider (a tap note with a path), in view coordinates on the non-rotating glass root:
/// a translucent track along the path, a marker at its end, and the ball that travels the path once the
/// head is hit, with a follow ring showing how close the player has to stay.
@MainActor
final class SliderVisuals {
    let root = Entity()
    private let track: ModelEntity?
    private let endMarker: ModelEntity?
    private let ball: ModelEntity
    private let followRing: ModelEntity?
    private let radius: Float
    private let lift: Float

    private static let trackMaterial: UnlitMaterial = {
        var m = UnlitMaterial(color: UIColor(red: 0.35, green: 0.95, blue: 1, alpha: 1))
        m.blending = .transparent(opacity: .init(floatLiteral: 0.3))
        m.faceCulling = .none
        return m
    }()
    private static let followingMaterial = UnlitMaterial(color: UIColor(red: 0.35, green: 0.95, blue: 1, alpha: 1))
    private static let driftingMaterial = UnlitMaterial(color: UIColor(red: 1, green: 0.5, blue: 0.3, alpha: 1))
    private static let ringMaterial: UnlitMaterial = {
        var m = UnlitMaterial(color: .white)
        m.faceCulling = .none
        return m
    }()

    init(note: TapNote, radius: Float, tuning: Tuning) {
        self.radius = radius
        self.lift = Float(tuning.noteSurfaceLiftM)
        root.name = "slider:\(note.id)"
        let noteRadius = Float(tuning.noteDiameterM / 2)
        let path = note.sliderPath!

        let samples = path.sampled(count: max(8, Int(path.totalAngleDeg)))
        track = (try? MeshBuilders.surfaceRibbon(directions: samples.map(\.unitVectorF), radius: radius,
                                                 lift: lift * 0.5, width: noteRadius * 1.4))
            .map { ModelEntity(mesh: $0, materials: [Self.trackMaterial]) }
        endMarker = (try? MeshBuilders.annulus(radius: noteRadius * 0.7, thickness: 0.003))
            .map { ModelEntity(mesh: $0, materials: [Self.ringMaterial]) }
        ball = ModelEntity(mesh: .generateCylinder(height: 0.004, radius: noteRadius * 0.8), materials: [Self.followingMaterial])
        // The follow ring's radius is the full-credit tolerance, as an arc on the sphere.
        let toleranceRadius = radius * Float(tuning.sliderFollowToleranceDeg * .pi / 180)
        followRing = (try? MeshBuilders.annulus(radius: toleranceRadius, thickness: 0.002))
            .map { ModelEntity(mesh: $0, materials: [Self.ringMaterial]) }

        if let track { root.addChild(track) }
        if let endMarker, let end = path.points.last {
            place(endMarker, at: end, extraLift: 0.001)
            root.addChild(endMarker)
        }
        ball.isEnabled = false
        root.addChild(ball)
        if let followRing {
            followRing.isEnabled = false
            ball.addChild(followRing)
            followRing.position = [0, 0.003, 0]
        }
        root.isEnabled = false
    }

    /// Puts a flat entity on the sphere at a view point, facing outward.
    private func place(_ entity: Entity, at point: SurfacePoint, extraLift: Float = 0) {
        let n = point.unitVectorF
        entity.position = n * (radius + lift + extraLift)
        entity.orientation = orientationFacing(normal: n)
    }

    /// Updates the slider for the note's state at clock time `now`.
    /// - Parameters:
    ///   - popIn: 0...1 pop-up progress of the note (the track fades in with it).
    ///   - judgedNow: clock time minus the input offset (ball position is in judged time).
    func update(note: TapNote, state: GameSession.NoteState, popIn: Float, judgedNow: Double, nowMs: Double,
                lastCredit: Double?) {
        switch state {
        case .pending:
            root.isEnabled = popIn > 0
            NoteVisuals.setOpacity(root, popIn)
            ball.isEnabled = false
        case .holding:
            root.isEnabled = true
            NoteVisuals.setOpacity(root, 1)
            ball.isEnabled = true
            followRing?.isEnabled = true
            if let p = note.sliderBallPoint(atMs: judgedNow) { place(ball, at: p, extraLift: 0.002) }
            let following = (lastCredit ?? 1) >= 0.5
            ball.model?.materials = [following ? Self.followingMaterial : Self.driftingMaterial]
        case .hit(_, _, let atMs), .missed(let atMs, _):
            // Fade out over 300 ms after it finishes.
            let t = Float(min(max((nowMs - atMs) / 300, 0), 1))
            root.isEnabled = t < 1
            NoteVisuals.setOpacity(root, 1 - t)
            followRing?.isEnabled = false
        }
    }
}

/// A small dot where the player's drag currently projects onto the sphere (shown only while dragging).
@MainActor
final class DragCursor {
    let entity: ModelEntity

    init() {
        entity = ModelEntity(mesh: .generateSphere(radius: 0.006), materials: [UnlitMaterial(color: .white)])
        entity.name = "DragCursor"
        entity.isEnabled = false
    }

    func show(at point: SurfacePoint?, radius: Float) {
        guard let point else {
            entity.isEnabled = false
            return
        }
        entity.isEnabled = true
        entity.position = point.unitVectorF * (radius + 0.012)
    }
}
