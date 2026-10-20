import RealityKit
import RhythmCore
import UIKit

/// The visuals of one slider (a tap note with a path), in view coordinates on the non-rotating glass root:
/// a translucent track along the path, a marker at its end, the knob that follows the player's drag once
/// the head is hit, and a timer above the slider that counts down to the target finish time
/// (0.00 = Perfect; DECISIONS D20).
@MainActor
final class SliderVisuals {
    let root = Entity()
    private let track: ModelEntity?
    private let endMarker: ModelEntity?
    private let knob: ModelEntity
    private let timer = TimerLabel()
    private let radius: Float
    private let lift: Float

    private static let trackMaterial: UnlitMaterial = {
        var m = UnlitMaterial(color: UIColor(red: 0.35, green: 0.95, blue: 1, alpha: 1))
        m.blending = .transparent(opacity: .init(floatLiteral: 0.3))
        m.faceCulling = .none
        return m
    }()
    private static let onTrackMaterial = UnlitMaterial(color: UIColor(red: 0.35, green: 0.95, blue: 1, alpha: 1))
    private static let lostMaterial = UnlitMaterial(color: UIColor(red: 1, green: 0.5, blue: 0.3, alpha: 1))
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
        endMarker = (try? MeshBuilders.annulus(radius: noteRadius * 0.9, thickness: 0.003))
            .map { ModelEntity(mesh: $0, materials: [Self.ringMaterial]) }
        knob = ModelEntity(mesh: .generateCylinder(height: 0.004, radius: noteRadius * 0.8), materials: [Self.onTrackMaterial])

        if let track { root.addChild(track) }
        if let endMarker, let end = path.points.last {
            place(endMarker, at: end, extraLift: 0.001)
            root.addChild(endMarker)
        }
        knob.isEnabled = false
        root.addChild(knob)

        // Timer: above the slider's highest point, centered on it, a little toward the player.
        let positions = samples.map { SIMD3<Float>($0.unitVectorF * radius) }
        let top = positions.map(\.y).max() ?? 0
        let midX = ((positions.map(\.x).min() ?? 0) + (positions.map(\.x).max() ?? 0)) / 2
        let midZ = positions.map(\.z).max() ?? radius
        timer.root.position = [midX, top + 0.05, midZ + 0.07]
        root.addChild(timer.root)
        root.isEnabled = false
    }

    /// Puts a flat entity on the sphere at a view point, facing outward.
    private func place(_ entity: Entity, at point: SurfacePoint, extraLift: Float = 0) {
        let n = point.unitVectorF
        entity.position = n * (radius + lift + extraLift)
        entity.orientation = orientationFacing(normal: n)
    }

    /// The outcome shown on the timer after the slider finishes.
    struct Result {
        var judgment: Judgment
        /// Finish time relative to the target (negative = early), nil if it never reached the end.
        var finishDeltaMs: Double?
    }

    /// Updates the slider for the note's state at clock time `nowMs`.
    /// - Parameters:
    ///   - popIn: 0...1 pop-up progress of the note (the slider fades in with it).
    ///   - judgedNow: clock time minus the input offset.
    func update(note: TapNote, state: GameSession.NoteState, popIn: Float, judgedNow: Double, nowMs: Double,
                progress: SliderProgress?, result: Result?, tuning: Tuning) {
        let remainingMs = note.endMs - judgedNow
        switch state {
        case .pending:
            root.isEnabled = popIn > 0
            NoteVisuals.setOpacity(root, popIn)
            knob.isEnabled = false
            // Before the pinch: the slider's time budget.
            timer.set(Self.seconds(note.slider?.durationMs ?? 0), color: .white)
        case .holding:
            root.isEnabled = true
            NoteVisuals.setOpacity(root, 1)
            knob.isEnabled = true
            if let progress {
                place(knob, at: progress.knobPoint, extraLift: 0.002)
                knob.model?.materials = [progress.onTrack ? Self.onTrackMaterial : Self.lostMaterial]
            }
            // Counting down to the target finish; 0.00 is Perfect, green inside the Perfect window.
            let perfectNow = abs(remainingMs) <= tuning.sliderEndPerfectWindowMs
            timer.set(Self.seconds(remainingMs), color: perfectNow ? TimerLabel.green : .white)
        case .hit(_, _, let atMs), .missed(let atMs, _):
            // Show how early/late the finish was, then fade out.
            let shown = nowMs - atMs
            let t = Float(min(max((shown - tuning.sliderResultDisplayMs) / 300, 0), 1))
            root.isEnabled = t < 1
            NoteVisuals.setOpacity(root, 1 - t)
            knob.isEnabled = false
            if let result {
                let text = result.finishDeltaMs.map { Self.seconds($0, signed: true) } ?? "miss"
                timer.set(text, color: TimerLabel.color(for: result.judgment))
            }
        }
    }

    /// "1.25", "-0.08", or signed "+0.05".
    static func seconds(_ ms: Double, signed: Bool = false) -> String {
        let s = String(format: "%.2f", ms / 1000)
        return signed && ms >= 0 ? "+" + s : (s == "-0.00" ? "0.00" : s)
    }
}

/// Short text that can change every frame. Each character slot holds one pre-built entity per
/// possible character, and `set` only toggles which one is visible. (Swapping a mesh on an entity made
/// that character vanish for a frame or two, so a digit changing every frame never showed; seen in the
/// simulator.) Monospaced and billboarded.
@MainActor
final class TimerLabel {
    static let green = UIColor(red: 0.4, green: 1, blue: 0.5, alpha: 1)
    static let charset = Array("0123456789.-+mis")

    let root = Entity()
    /// slots[i][c] = the entity showing character c at position i.
    private var slots: [[Character: ModelEntity]] = []
    private var visible: [ModelEntity?] = []
    private static var meshCache: [Character: MeshResource] = [:]
    private static let font = UIFont.monospacedSystemFont(ofSize: 0.026, weight: .bold)
    private let advance: Float = 0.026 * 0.62
    private var text = ""
    private var color = UIColor.white
    private var material = UnlitMaterial(color: .white)

    init(capacity: Int = 5) {
        root.name = "SliderTimer"
        root.components.set(BillboardComponent())
        for _ in 0..<capacity {
            var slot: [Character: ModelEntity] = [:]
            for c in Self.charset {
                let e = ModelEntity(mesh: Self.mesh(for: c), materials: [material])
                e.isEnabled = false
                root.addChild(e)
                slot[c] = e
            }
            slots.append(slot)
            visible.append(nil)
        }
    }

    func set(_ newText: String, color newColor: UIColor) {
        guard newText != text || newColor != color else { return }
        if newColor != color {
            material = UnlitMaterial(color: newColor)
            for slot in slots { for e in slot.values { e.model?.materials = [material] } }
        }
        let chars = Array(newText.prefix(slots.count))
        let width = Float(chars.count) * advance
        for i in slots.indices {
            let wanted = i < chars.count ? slots[i][chars[i]] : nil
            if visible[i] !== wanted {
                visible[i]?.isEnabled = false
                wanted?.isEnabled = true
                visible[i] = wanted
            }
            wanted?.position = [Float(i) * advance - width / 2, -0.009, 0]
        }
        text = newText
        color = newColor
    }

    private static func mesh(for c: Character) -> MeshResource {
        if let m = meshCache[c] { return m }
        let m = MeshResource.generateText(String(c), extrusionDepth: 0.001, font: font)
        meshCache[c] = m
        return m
    }

    static func color(for judgment: Judgment) -> UIColor {
        switch judgment {
        case .perfect: UIColor(red: 0.45, green: 1, blue: 1, alpha: 1)
        case .great: UIColor(red: 0.5, green: 1, blue: 0.55, alpha: 1)
        case .good: UIColor(red: 1, green: 0.85, blue: 0.4, alpha: 1)
        case .miss: UIColor(red: 1, green: 0.4, blue: 0.35, alpha: 1)
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
