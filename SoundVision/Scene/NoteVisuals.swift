import RealityKit
import RhythmCore
import UIKit

/// Builds tap-note entities and updates their look from session state.
///
/// A note is a flat disc lying on the glass, fixed in the player's view (a child of the non-rotating
/// glass root, DECISIONS D18): a colored fill with a white rim. It carries a GameTargetComponent with
/// its note ID, plus collision, input target and hover effect so the system's look-and-pinch can target
/// it. Its child "approachRing" (a white band with a thin dark outline, so it reads on bright rooms and on
/// the glass rim) shrinks onto the note's rim and closes there at the hit time. Notes are hidden and
/// untargetable until they pop up. Looks: DECISIONS D21.
@MainActor
enum NoteVisuals {
    enum Look {
        case approaching, hittable, hit, missed
    }

    static let fillColor = UIColor(red: 0.2, green: 0.85, blue: 1.0, alpha: 1)
    private static let approachingMaterial = UnlitMaterial(color: UIColor(white: 0.95, alpha: 1))
    private static let hittableMaterial = UnlitMaterial(color: fillColor)
    private static let hitMaterial = UnlitMaterial(color: UIColor(red: 1.0, green: 0.84, blue: 0.3, alpha: 1))
    private static let missedMaterial = UnlitMaterial(color: UIColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1))
    static let rimMaterial: UnlitMaterial = {
        var m = UnlitMaterial(color: .white)
        m.faceCulling = .none
        return m
    }()
    static let outlineMaterial: UnlitMaterial = {
        var m = UnlitMaterial(color: UIColor(red: 0.04, green: 0.08, blue: 0.12, alpha: 1))
        m.blending = .transparent(opacity: .init(floatLiteral: 0.55))
        m.faceCulling = .none
        return m
    }()

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

        // White rim on the disc's edge: the approach ring closes exactly onto it.
        if let rim = makeRim(radius: discRadius) {
            entity.addChild(rim)
        }
        if let ring = makeApproachRing(radius: discRadius, thickness: Float(tuning.approachRingThicknessM)) {
            ring.isEnabled = false
            entity.addChild(ring)
        }
        return entity
    }

    /// A white band on the edge of a disc of `radius`, just above its top face (the disc is 3 mm tall).
    static func makeRim(radius: Float, height: Float = 0.003) -> ModelEntity? {
        guard let mesh = try? MeshBuilders.annulus(radius: radius, thickness: radius * 0.16) else { return nil }
        let rim = ModelEntity(mesh: mesh, materials: [rimMaterial])
        rim.name = "rim"
        rim.position = [0, height / 2 + 0.0004, 0]
        return rim
    }

    /// The approach ring: a white band with a dark outline 1 mm wider on each side, under it. Its outer
    /// edge at scale 1 is the note's edge. Scale it in X and Z.
    private static func makeApproachRing(radius: Float, thickness: Float) -> Entity? {
        guard let bandMesh = try? MeshBuilders.annulus(radius: radius, thickness: thickness),
              let outlineMesh = try? MeshBuilders.annulus(radius: radius + 0.001, thickness: thickness + 0.002)
        else { return nil }
        let ring = Entity()
        ring.name = approachRingName
        // Just above the disc and its rim, so it doesn't z-fight when it closes. The outline sits a little
        // lower so it sorts behind the band.
        let outline = ModelEntity(mesh: outlineMesh, materials: [outlineMaterial])
        outline.position = [0, 0.0022, 0]
        let band = ModelEntity(mesh: bandMesh, materials: [rimMaterial])
        band.position = [0, 0.0028, 0]
        ring.addChild(outline)
        ring.addChild(band)
        return ring
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

    // MARK: Animation (all driven by master-clock progress, never by frame time)

    /// A popped-up note waiting for its pinch. `pop` is the 0...1 pop-up progress, `ringScale` the
    /// approach ring's size (1 = closed on the rim) and `ringProgress` 0...1 toward the hit time.
    static func showApproach(_ entity: ModelEntity, ring: Entity?, pop: Float, ringScale: Float,
                             ringProgress: Float, tuning: Tuning) {
        setLook(entity, .hittable)
        setOpacity(entity, pop)
        // Grows in with a slight overshoot, so the pop-up catches the eye.
        entity.scale = SIMD3(repeating: 0.6 + 0.4 * easeOutBack(pop))
        if let ring {
            if !ring.isEnabled { ring.isEnabled = true }
            ring.scale = [ringScale, 1, ringScale]
            let start = Float(tuning.approachRingStartOpacity)
            setOpacity(ring, start + (1 - start) * ringProgress)
        }
    }

    /// A hit note: gold flash that grows and fades; `t` is 0...1 over `noteHitFlashMs`.
    static func showHit(_ entity: ModelEntity, t: Float) {
        setLook(entity, .hit)
        let e = 1 - (1 - t) * (1 - t) // ease out
        entity.scale = SIMD3(repeating: 1 + 0.6 * e)
        setOpacity(entity, 1 - t)
    }

    /// A missed note: red, shrinking a little and fading; `t` is 0...1 over `noteMissFadeMs`.
    static func showMiss(_ entity: ModelEntity, t: Float) {
        setLook(entity, .missed)
        entity.scale = SIMD3(repeating: 1 - 0.15 * t)
        setOpacity(entity, 0.8 * (1 - t))
    }

    /// 0 → 0, 1 → 1, overshooting about 10% on the way.
    private static func easeOutBack(_ t: Float) -> Float {
        let c: Float = 1.7
        let u = t - 1
        return 1 + (c + 1) * u * u * u + c * u * u
    }
}

/// Floating feedback text that rises and fades, timed by the master clock: the judgment of a hit, or
/// "Early"/"Late" for a pinch outside the timing window (it ends the note as a Miss, DECISIONS D9).
/// Each label has a soft dark shadow behind it, so it stays readable over bright rooms and the glass rim.
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
    /// Draws every shadow before every label, so a shadow never covers its own text.
    private static let sortGroup = ModelSortGroup(depthPass: nil)

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
            // Pops in slightly large, settles within the first 15%, rises with an ease-out, fades late.
            let settle = min(t / 0.15, 1)
            item.entity.scale = SIMD3(repeating: 1.25 - 0.25 * settle)
            item.entity.position = item.start + [0, 0.04 * (1 - (1 - t) * (1 - t)), 0]
            item.entity.components.set(OpacityComponent(opacity: 1 - t * t * t))
            return false
        }
    }

    static func color(for kind: Kind) -> UIColor {
        switch kind {
        case .judgment(let j): TimerLabel.color(for: j)
        case .early, .late: UIColor(red: 1, green: 0.55, blue: 0.3, alpha: 1)
        }
    }

    private static func makeTemplate(_ kind: Kind) -> Entity {
        let (label, size): (String, CGFloat) = switch kind {
        case .judgment(.perfect): ("Perfect", 0.032)
        case .judgment(.great): ("Great", 0.032)
        case .judgment(.good): ("Good", 0.032)
        case .judgment(.miss): ("Miss", 0.032)
        case .early: ("Early", 0.028)
        case .late: ("Late", 0.028)
        }
        let mesh = MeshResource.generateText(label, extrusionDepth: 0.002,
                                             font: .systemFont(ofSize: size, weight: .heavy))
        let holder = Entity()
        let text = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color(for: kind))])
        text.position = -mesh.bounds.center // center the text on its parent
        text.components.set(ModelSortGroupComponent(group: sortGroup, order: 1))
        // Drop shadow: the same glyphs, dark and translucent, a little down-right and behind.
        var shadowMaterial = UnlitMaterial(color: UIColor(red: 0.03, green: 0.05, blue: 0.08, alpha: 1))
        shadowMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.6))
        let shadow = ModelEntity(mesh: mesh, materials: [shadowMaterial])
        shadow.position = text.position + [0.0014, -0.0016, -0.003]
        shadow.components.set(ModelSortGroupComponent(group: sortGroup, order: 0))
        holder.addChild(shadow)
        holder.addChild(text)
        holder.components.set(BillboardComponent())
        return holder
    }
}
