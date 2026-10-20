import RealityKit
import RhythmCore
import UIKit

/// The visuals of one slider (a tap note with a path), in view coordinates on the non-rotating glass root:
/// a translucent track with white edges along the path, a ring at its end, the knob that follows the
/// player's drag once the head is hit, and a timer beside the slider that counts down to the target
/// finish time (0.00 = Perfect; DECISIONS D20, D21).
@MainActor
final class SliderVisuals {
    let root = Entity()
    private let knob: ModelEntity
    private let timer: TimerLabel
    private let radius: Float
    private let lift: Float

    private static let trackMaterial: UnlitMaterial = {
        var m = UnlitMaterial(color: NoteVisuals.fillColor)
        m.blending = .transparent(opacity: .init(floatLiteral: 0.25))
        m.faceCulling = .none
        return m
    }()
    private static let edgeMaterial: UnlitMaterial = {
        var m = UnlitMaterial(color: .white)
        m.blending = .transparent(opacity: .init(floatLiteral: 0.85))
        m.faceCulling = .none
        return m
    }()
    private static let onTrackMaterial = UnlitMaterial(color: NoteVisuals.fillColor)
    private static let lostMaterial = UnlitMaterial(color: UIColor(red: 1, green: 0.5, blue: 0.3, alpha: 1))

    init(note: TapNote, radius: Float, tuning: Tuning) {
        self.radius = radius
        self.lift = Float(tuning.noteSurfaceLiftM)
        root.name = "slider:\(note.id)"
        let noteRadius = Float(tuning.noteDiameterM / 2)
        let path = note.sliderPath!

        // Track: a translucent band as wide as the end ring, with white edge lines. It runs from the head's
        // center to the end ring's center, so its square ends hide under the head and meet the end ring.
        let samples = path.sampled(count: max(8, Int(path.totalAngleDeg)))
        let directions = samples.map(\.unitVectorF)
        let halfWidth = noteRadius * 0.9
        let edge: Float = 0.003
        if let mesh = try? MeshBuilders.surfaceRibbon(directions: directions, radius: radius, lift: lift * 0.5,
                                                      width: halfWidth * 2) {
            root.addChild(ModelEntity(mesh: mesh, materials: [Self.trackMaterial]))
        }
        for side: Float in [-1, 1] {
            if let mesh = try? MeshBuilders.surfaceRibbon(directions: directions, radius: radius, lift: lift * 0.6,
                                                          width: edge, sideOffset: side * (halfWidth - edge / 2)) {
                root.addChild(ModelEntity(mesh: mesh, materials: [Self.edgeMaterial]))
            }
        }
        // The end ring is the target. A thin ring at the start, like the edges, closes the track's outline
        // once the head is gone (before that the head covers it).
        let endMarker = (try? MeshBuilders.annulus(radius: halfWidth, thickness: 0.005))
            .map { ModelEntity(mesh: $0, materials: [NoteVisuals.rimMaterial]) }
        let startCap = (try? MeshBuilders.annulus(radius: halfWidth, thickness: edge))
            .map { ModelEntity(mesh: $0, materials: [Self.edgeMaterial]) }

        // Knob: like a note, a filled disc with a white rim (the fill turns orange when the drag is lost).
        knob = ModelEntity(mesh: .generateCylinder(height: 0.004, radius: noteRadius * 0.8), materials: [Self.onTrackMaterial])
        if let rim = NoteVisuals.makeRim(radius: noteRadius * 0.8, height: 0.004) {
            knob.addChild(rim)
        }
        knob.scale = .zero // hidden until the head is hit; see TimerLabel on why not isEnabled
        root.addChild(knob)

        // Timer: beside the slider, clear of the track and of the judgment popups (which rise from the head
        // and the end). A horizontal slider gets it centered below; a vertical one to its outer side, away
        // from the middle of the play area where the other notes are. A little toward the player.
        timer = TimerLabel(fontSize: Float(tuning.sliderTimerFontSizeM))
        let positions = directions.map { $0 * radius }
        let minX = positions.map(\.x).min() ?? 0, maxX = positions.map(\.x).max() ?? 0
        let minY = positions.map(\.y).min() ?? 0, maxY = positions.map(\.y).max() ?? 0
        let frontZ = (positions.map(\.z).max() ?? radius) + 0.05
        let travel = (positions.last ?? .zero) - (positions.first ?? .zero)
        let gap = noteRadius + 0.012 // clear of the head disc and the end ring
        if abs(travel.x) >= abs(travel.y) {
            timer.root.position = [(minX + maxX) / 2, minY - gap - timer.size.y / 2, frontZ]
        } else {
            let midX = (minX + maxX) / 2
            let outward: Float = midX < -0.01 ? -1 : 1
            let x = outward < 0 ? minX - gap - timer.size.x / 2 : maxX + gap + timer.size.x / 2
            timer.root.position = [x, (minY + maxY) / 2, frontZ]
        }
        root.addChild(timer.root)
        if let endMarker, let end = path.points.last {
            place(endMarker, at: end, extraLift: 0.001)
            root.addChild(endMarker)
        }
        if let startCap {
            place(startCap, at: note.at, extraLift: 0.0005)
            root.addChild(startCap)
        }
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
            knob.scale = .zero
            // Before the pinch: the slider's time budget.
            timer.set(Self.seconds(note.slider?.durationMs ?? 0), color: .white)
        case .holding:
            root.isEnabled = true
            NoteVisuals.setOpacity(root, 1)
            knob.scale = .one
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
            knob.scale = .zero
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
/// simulator.) Hidden glyphs are scaled to zero rather than disabled: an entity enabled for the first
/// time didn't draw for a few frames in the simulator, so each digit blanked the first time it came up
/// (e.g. "0. 9" just after the head was hit). Scaled-out glyphs are already in the scene from the
/// slider's pop-up. Monospaced and billboarded, on a dark rounded plate so it reads over bright rooms
/// and the glass rim.
@MainActor
final class TimerLabel {
    static let green = UIColor(red: 0.4, green: 1, blue: 0.5, alpha: 1)
    static let charset = Array("0123456789.-+mis")

    let root = Entity()
    /// Width and height of the backing plate, in meters.
    let size: SIMD2<Float>
    /// slots[i][c] = the entity showing character c at position i.
    private var slots: [[Character: ModelEntity]] = []
    private var visible: [ModelEntity?] = []
    private static var meshCache: [String: MeshResource] = [:]
    private let fontSize: Float
    private let advance: Float
    private let baseline: Float
    private var text = ""
    private var color = UIColor.white
    private var material = UnlitMaterial(color: .white)

    init(capacity: Int = 5, fontSize: Float) {
        self.fontSize = fontSize
        advance = fontSize * 0.62
        size = [Float(capacity) * advance + fontSize * 0.7, fontSize * 1.35]
        // Centers digits vertically on the plate (text meshes start at the baseline).
        let digit = Self.mesh(for: "0", fontSize: fontSize).bounds
        baseline = -digit.center.y
        root.name = "SliderTimer"
        root.components.set(BillboardComponent())

        var plateMaterial = UnlitMaterial(color: UIColor(red: 0.03, green: 0.05, blue: 0.08, alpha: 1))
        plateMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.55))
        let plate = ModelEntity(mesh: .generatePlane(width: size.x, height: size.y, cornerRadius: size.y / 2),
                                materials: [plateMaterial])
        // 2 mm behind the opaque glyphs, so depth keeps it under them. (Don't put the glyphs in a
        // ModelSortGroup: in the simulator a glyph enabled that frame then didn't draw, so the digit that
        // changes every frame vanished during the countdown.)
        plate.position = [0, 0, -0.002]
        root.addChild(plate)

        for _ in 0..<capacity {
            var slot: [Character: ModelEntity] = [:]
            for c in Self.charset {
                let e = ModelEntity(mesh: Self.mesh(for: c, fontSize: fontSize), materials: [material])
                e.scale = .zero
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
                visible[i]?.scale = .zero
                wanted?.scale = .one
                visible[i] = wanted
            }
            wanted?.position = [Float(i) * advance - width / 2, baseline, 0]
        }
        text = newText
        color = newColor
    }

    private static func mesh(for c: Character, fontSize: Float) -> MeshResource {
        let key = "\(c)@\(fontSize)"
        if let m = meshCache[key] { return m }
        let font = UIFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .bold)
        let m = MeshResource.generateText(String(c), extrusionDepth: 0.001, font: font)
        meshCache[key] = m
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
