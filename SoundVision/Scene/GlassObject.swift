import CoreGraphics
import RealityKit
import UIKit

/// Glass rendering variants, compared in the Glass Lab. Findings are in docs/DECISIONS.md.
enum GlassVariant: String, CaseIterable, Identifiable {
    /// A: one transparent PBR sphere, both faces drawn, no sorting help. The baseline.
    case naive = "A"
    /// B: back-face shell and front-face shell in one ModelSortGroup; surface items are drawn
    /// between the shells while on the far side and after the front shell while on the near side.
    case twoShell = "B"
    /// C: B plus a baked fresnel rim (opacity rises toward the silhouette), using billboarded
    /// shells with a gradient texture instead of a custom shader.
    case fresnel = "C"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .naive: "A: naive single sphere"
        case .twoShell: "B: two shells + sort order"
        case .fresnel: "C: B + baked fresnel rim"
        }
    }

    /// What gameplay uses unless overridden in the launcher.
    static let defaultForGameplay: GlassVariant = .fresnel

    var usesSortOrder: Bool { self != .naive }
}

/// The glass object: non-rotating shells plus a rotating `surfaceRoot` that carries notes and strokes.
///
/// A sphere looks the same however it's turned, so the shells don't rotate (which lets variant C
/// keep its rim facing the viewer); only the surface content does.
///
/// Draw order with sorting (variants B and C), lowest first, in one ModelSortGroup:
///   0 far-side items → 1 back shell → 2 front shell → 3 near-side items
/// Each frame the scene tells this object which side every surface item is on (`setSide`).
final class GlassObject {
    enum Layer: Int32 {
        case farItems = 0, backShell = 1, frontShell = 2, nearItems = 3
    }

    let root = Entity()
    /// Rotating container for surface content. Set its orientation from the RhythmCore playfield.
    let surfaceRoot = Entity()
    let radius: Float
    private(set) var variant: GlassVariant
    private let shellRoot = Entity()
    private let sortGroup = ModelSortGroup(depthPass: nil)

    init(radius: Float, variant: GlassVariant) {
        self.radius = radius
        self.variant = variant
        root.name = "GlassObject"
        surfaceRoot.name = "SurfaceRoot"
        root.addChild(shellRoot)
        root.addChild(surfaceRoot)
        buildShells()
    }

    func apply(_ newVariant: GlassVariant) {
        guard newVariant != variant else { return }
        variant = newVariant
        buildShells()
    }

    /// Assigns a surface item (an entity with a ModelComponent) to the far or near layer.
    /// Cheap to call every frame; it only writes the component when something changes.
    func setSide(of entity: Entity, farSide: Bool) {
        guard variant.usesSortOrder else {
            if entity.components.has(ModelSortGroupComponent.self) {
                entity.components.remove(ModelSortGroupComponent.self)
            }
            return
        }
        let order = (farSide ? Layer.farItems : Layer.nearItems).rawValue
        if entity.components[ModelSortGroupComponent.self]?.order != order {
            entity.components.set(ModelSortGroupComponent(group: sortGroup, order: order))
        }
    }

    /// Opacity multiplier for a surface item on the far side, seen through the glass.
    func farSideOpacity(base: Float) -> Float {
        variant == .naive ? 1 : base
    }

    // MARK: Shells

    private func buildShells() {
        shellRoot.children.removeAll()
        shellRoot.components.remove(BillboardComponent.self)
        switch variant {
        case .naive:
            var m = Self.glassMaterial(opacity: 0.18)
            m.faceCulling = .none
            shellRoot.addChild(ModelEntity(mesh: .generateSphere(radius: radius), materials: [m]))

        case .twoShell:
            var back = Self.glassMaterial(opacity: 0.10)
            back.faceCulling = .front // draw only the inside of the far hemisphere
            var front = Self.glassMaterial(opacity: 0.18)
            front.faceCulling = .back
            addShell(mesh: .generateSphere(radius: radius), material: back, layer: .backShell)
            addShell(mesh: .generateSphere(radius: radius), material: front, layer: .frontShell)

        case .fresnel:
            // Billboarding keeps the mesh's +Z (the gradient's center) toward the viewer.
            shellRoot.components.set(BillboardComponent())
            guard let mesh = try? MeshBuilders.zPolarSphere(radius: radius),
                  let ramp = Self.fresnelRamp else {
                // Fall back to B rather than show nothing.
                variant = .twoShell
                buildShells()
                return
            }
            var back = Self.glassMaterial(opacity: 1)
            back.blending = .transparent(opacity: .init(scale: 0.6, texture: ramp))
            back.faceCulling = .front
            var front = Self.glassMaterial(opacity: 1)
            front.blending = .transparent(opacity: .init(scale: 1, texture: ramp))
            front.faceCulling = .back
            addShell(mesh: mesh, material: back, layer: .backShell)
            addShell(mesh: mesh, material: front, layer: .frontShell)
        }
    }

    private func addShell(mesh: MeshResource, material: PhysicallyBasedMaterial, layer: Layer) {
        let shell = ModelEntity(mesh: mesh, materials: [material])
        shell.components.set(ModelSortGroupComponent(group: sortGroup, order: layer.rawValue))
        shellRoot.addChild(shell)
    }

    static func glassMaterial(opacity: Float) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: 0.92, green: 0.97, blue: 1.0, alpha: 1))
        m.metallic = 0.0
        m.roughness = 0.04
        m.specular = 1.0
        m.clearcoat = 1.0
        m.clearcoatRoughness = 0.02
        m.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return m
    }

    /// 1×256 grayscale opacity ramp along v (polar angle from the viewer):
    /// nearly clear facing the viewer, rising toward the silhouette, symmetric for the back half.
    private static let fresnelRamp: PhysicallyBasedMaterial.Texture? = {
        let n = 256
        var pixels = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            let polar = Double(i) / Double(n - 1) * .pi
            let facing = abs(cos(polar))              // 1 facing the viewer (or directly away), 0 edge-on
            let fresnel = pow(1 - facing, 3)
            let opacity = 0.05 + 0.6 * fresnel
            pixels[i] = UInt8((min(max(opacity, 0), 1) * 255).rounded())
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: 1, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 1,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let resource = try? TextureResource(image: image, withName: "fresnelRamp", options: .init(semantic: .raw))
        else { return nil }
        return PhysicallyBasedMaterial.Texture(resource)
    }()
}
