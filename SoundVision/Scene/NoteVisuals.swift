import RealityKit
import RhythmCore
import UIKit

/// Builds tap-note entities and updates their look from session state.
///
/// A note is a flat disc lying on the surface, a child of the glass object's rotating `surfaceRoot`.
/// It carries a GameTargetComponent with its note ID, plus collision, input target and hover effect so
/// the system's look-and-pinch can target it. Its child "approachRing" shrinks onto it and closes at
/// the hit time. Notes are hidden and untargetable until they pop up.
@MainActor
enum NoteVisuals {
    enum Look {
        case approaching, hittable, hit, missed
    }

    private static let approachingMaterial = UnlitMaterial(color: UIColor(white: 0.95, alpha: 1))
    private static let hittableMaterial = UnlitMaterial(color: UIColor(red: 0.35, green: 0.95, blue: 1.0, alpha: 1))
    private static let hitMaterial = UnlitMaterial(color: UIColor(red: 1.0, green: 0.84, blue: 0.3, alpha: 1))
    private static let missedMaterial = UnlitMaterial(color: UIColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1))

    static func makeNote(_ note: TapNote, radius: Float, tuning: Tuning) -> ModelEntity {
        let discRadius = Float(tuning.noteDiameterM / 2)
        let entity = ModelEntity(mesh: .generateCylinder(height: 0.003, radius: discRadius), materials: [approachingMaterial])
        entity.name = "note:\(note.id)"
        let n = note.at.unitVectorF
        entity.position = n * (radius + Float(tuning.noteSurfaceLiftM))
        entity.orientation = orientationFacing(normal: n)
        entity.components.set(GameTargetComponent(targetID: note.id))
        entity.components.set(CollisionComponent(shapes: [.generateSphere(radius: discRadius * Float(tuning.noteHitRadiusScale))]))
        var input = InputTargetComponent()
        input.isEnabled = false
        entity.components.set(input)
        entity.components.set(HoverEffectComponent())
        entity.components.set(OpacityComponent(opacity: 1))

        if let mesh = try? MeshBuilders.annulus(radius: discRadius, thickness: 0.003) {
            var m = UnlitMaterial(color: .white)
            m.faceCulling = .none
            let ring = ModelEntity(mesh: mesh, materials: [m])
            ring.name = approachRingName
            ring.position = [0, 0.002, 0] // just above the disc, so it doesn't z-fight when it closes
            ring.isEnabled = false
            entity.addChild(ring)
        }
        return entity
    }

    static let approachRingName = "approachRing"

    static func approachRing(of note: Entity) -> Entity? {
        note.children.first { $0.name == approachRingName }
    }

    static func setLook(_ entity: ModelEntity, _ look: Look) {
        let material: UnlitMaterial = switch look {
        case .approaching: approachingMaterial
        case .hittable: hittableMaterial
        case .hit: hitMaterial
        case .missed: missedMaterial
        }
        entity.model?.materials = [material]
    }

    static func setTargetable(_ entity: Entity, _ targetable: Bool) {
        if entity.components[InputTargetComponent.self]?.isEnabled != targetable {
            entity.components[InputTargetComponent.self]?.isEnabled = targetable
        }
    }

    static func setOpacity(_ entity: Entity, _ opacity: Float) {
        if entity.components[OpacityComponent.self]?.opacity != opacity {
            entity.components.set(OpacityComponent(opacity: opacity))
        }
    }
}

/// Floating feedback text that rises and fades, timed by the master clock: the judgment of a hit, or
/// "Early"/"Late" for a pinch on a note outside its timing window (ignored, no penalty, but the player
/// must see that the pinch registered).
@MainActor
final class JudgmentPopups {
    enum Kind: Hashable {
        case judgment(Judgment)
        case early, late

        static let all: [Kind] = Judgment.allCases.map { .judgment($0) } + [.early, .late]
    }

    let root = Entity()
    private var templates: [Kind: Entity] = [:]
    private var live: [(entity: Entity, spawnMs: Double, start: SIMD3<Float>)] = []

    init() {
        root.name = "JudgmentPopups"
        for kind in Kind.all {
            templates[kind] = Self.makeTemplate(kind)
        }
    }

    func spawn(_ kind: Kind, at position: SIMD3<Float>, nowMs: Double) {
        guard let entity = templates[kind]?.clone(recursive: true) else { return }
        entity.position = position
        root.addChild(entity)
        live.append((entity, nowMs, position))
    }

    func update(nowMs: Double, durationMs: Double) {
        live.removeAll { item in
            let t = Float((nowMs - item.spawnMs) / durationMs)
            if t >= 1 {
                item.entity.removeFromParent()
                return true
            }
            item.entity.position = item.start + [0, 0.04 * t, 0]
            item.entity.components.set(OpacityComponent(opacity: 1 - t * t))
            return false
        }
    }

    private static func makeTemplate(_ kind: Kind) -> Entity {
        let (label, color, size): (String, UIColor, CGFloat) = switch kind {
        case .judgment(.perfect): ("Perfect", UIColor(red: 0.45, green: 1, blue: 1, alpha: 1), 0.032)
        case .judgment(.great): ("Great", UIColor(red: 0.5, green: 1, blue: 0.55, alpha: 1), 0.032)
        case .judgment(.good): ("Good", UIColor(red: 1, green: 0.85, blue: 0.4, alpha: 1), 0.032)
        case .judgment(.miss): ("Miss", UIColor(red: 1, green: 0.35, blue: 0.35, alpha: 1), 0.032)
        case .early: ("Early", UIColor(white: 0.9, alpha: 1), 0.022)
        case .late: ("Late", UIColor(white: 0.9, alpha: 1), 0.022)
        }
        let mesh = MeshResource.generateText(label, extrusionDepth: 0.002,
                                             font: .systemFont(ofSize: size, weight: .heavy))
        let text = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
        text.position = -mesh.bounds.center // center the text on its parent
        let holder = Entity()
        holder.addChild(text)
        holder.components.set(BillboardComponent())
        return holder
    }
}
