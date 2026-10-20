import RealityKit
import RhythmCore
import SwiftUI
import UIKit

/// Rendering prototype: the glass sphere with notes and strokes on both hemispheres, rotating,
/// so transparency sorting can be compared across GlassVariant A/B/C (picked in the launcher).
/// Findings go in docs/DECISIONS.md. This is a debug scene: it spins on wall-clock time, not audio.
struct GlassLabView: View {
    @Environment(AppModel.self) private var model
    @State private var lab = GlassLabController()

    var body: some View {
        RealityView { content, attachments in
            lab.build(into: &content, variant: model.glassVariant, tuning: model.tuning,
                      label: attachments.entity(for: "label"))
        } update: { _, _ in
            lab.apply(model.glassVariant)
        } attachments: {
            Attachment(id: "label") {
                Text("Glass Lab · \(model.glassVariant.label)")
                    .font(.headline)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .glassBackgroundEffect()
            }
        }
        .onDisappear { lab.stop() }
    }
}

@MainActor
final class GlassLabController {
    private let clock = HostTimeClock()
    private var glass: GlassObject?
    private var items: [(entity: Entity, at: SurfacePoint)] = []
    private var playfield: Playfield?
    private var tuning = Tuning()
    private var subscription: EventSubscription?

    func build(into content: inout RealityViewContent, variant: GlassVariant, tuning: Tuning, label: Entity?) {
        self.tuning = tuning
        let radius: Float = 0.3
        let rig = PlacementRig()
        let glass = GlassObject(radius: radius, variant: variant)
        rig.placement.addChild(glass.root)
        // Same speed as the test map: 6°/beat at 120 BPM = 12°/s about +Y.
        playfield = Playfield(shape: SphereShape(radiusM: Double(radius)),
                              schedule: RotationSchedule(segments: [.init(startBeat: 0, axis: [0, 1, 0], degreesPerBeat: 6)],
                                                         grid: BeatGrid(bpm: 120, offsetMs: 0)))

        // Notes spread over the whole sphere, so some are always behind the glass.
        for lat in [-35.0, 0, 35] {
            for lonStep in 0..<6 {
                let at = SurfacePoint(lat: lat, lon: Double(lonStep) * 60 + (lat == 0 ? 30 : 0))
                let note = NoteVisuals.makeNote(TapNote(id: "lab", timeMs: 0, at: at), radius: radius, tuning: tuning)
                note.components.remove(InputTargetComponent.self)
                NoteVisuals.setLook(note, lat == 0 ? .hittable : .approaching)
                glass.surfaceRoot.addChild(note)
                items.append((note, at))
            }
        }

        // Two strokes: one revealed in full color, one still clear glass (the "uncolored" state).
        let strokeSpecs: [(path: [SurfacePoint], material: any RealityKit.Material)] = [
            ([SurfacePoint(lat: -25, lon: -40), SurfacePoint(lat: 0, lon: -10), SurfacePoint(lat: 25, lon: -40), SurfacePoint(lat: 40, lon: -90)],
             Self.revealedStrokeMaterial(RGBColor(hex: "#FF6A3D")!)),
            ([SurfacePoint(lat: 20, lon: 140), SurfacePoint(lat: -10, lon: 170), SurfacePoint(lat: -30, lon: 220)],
             Self.clearStrokeMaterial()),
        ]
        for spec in strokeSpecs {
            let path = StrokePath(points: spec.path)
            for (i, piece) in Self.split(path.sampled(count: 64), into: 8).enumerated() {
                guard let mesh = try? MeshBuilders.surfaceRibbon(directions: piece.map(\.unitVectorF), radius: radius,
                                                                 lift: 0.002, width: 0.018) else { continue }
                let e = ModelEntity(mesh: mesh, materials: [spec.material])
                e.name = "stroke-piece-\(i)"
                glass.surfaceRoot.addChild(e)
                // A piece's side is judged by its middle point.
                items.append((e, piece[piece.count / 2]))
            }
        }

        if let label {
            label.position = [0, radius + 0.14, 0]
            rig.placement.addChild(label)
        }
        content.add(rig.anchor)
        self.glass = glass
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in self?.frame() }
        frame()
    }

    func apply(_ variant: GlassVariant) {
        glass?.apply(variant)
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
    }

    private func frame() {
        guard let glass, let playfield else { return }
        let now = clock.nowMs
        glass.surfaceRoot.orientation = simd_quatf(playfield.orientation(atMs: now))
        let farOpacity = glass.farSideOpacity(base: Float(tuning.farSideOpacity))
        for item in items {
            let far = playfield.isFarSide(item.at, atMs: now)
            glass.setSide(of: item.entity, farSide: far)
            NoteVisuals.setOpacity(item.entity, far ? farOpacity : 1)
        }
    }

    /// Splits samples into `count` overlapping runs, so each ribbon piece can be sorted on its own
    /// as it crosses from the far side to the near side.
    private static func split(_ samples: [SurfacePoint], into count: Int) -> [[SurfacePoint]] {
        let step = max((samples.count - 1) / count, 1)
        return stride(from: 0, to: samples.count - 1, by: step).map { start in
            Array(samples[start...min(start + step, samples.count - 1)])
        }
    }

    static func revealedStrokeMaterial(_ color: RGBColor) -> UnlitMaterial {
        var m = UnlitMaterial(color: color.uiColor)
        m.faceCulling = .none
        return m
    }

    static func clearStrokeMaterial() -> PhysicallyBasedMaterial {
        var m = GlassObject.glassMaterial(opacity: 0.45)
        m.faceCulling = .none
        return m
    }
}
