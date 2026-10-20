import RealityKit
import simd

/// Procedural meshes. Triangles are counter-clockwise when seen from the side the normals point to.
enum MeshBuilders {

    /// A UV sphere whose poles are on ±Z, with v = (polar angle from +Z) / π and u = azimuth / 2π.
    ///
    /// With the sphere's +Z facing the viewer (a BillboardComponent does that), v measures how
    /// edge-on each point is to the viewer, so a 1-D gradient texture along v gives a fresnel-like
    /// rim. That's how Glass variant C fakes fresnel without a custom shader (see docs/DECISIONS.md).
    static func zPolarSphere(radius: Float, segments: Int = 72, rings: Int = 48) throws -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        for i in 0...rings {
            let v = Float(i) / Float(rings)
            let polar = v * .pi
            for j in 0...segments {
                let u = Float(j) / Float(segments)
                let az = u * 2 * .pi
                let n = SIMD3<Float>(sin(polar) * cos(az), sin(polar) * sin(az), cos(polar))
                positions.append(n * radius)
                normals.append(n)
                uvs.append([u, v])
            }
        }
        var indices: [UInt32] = []
        let stride = UInt32(segments + 1)
        for i in 0..<UInt32(rings) {
            for j in 0..<UInt32(segments) {
                let a = i * stride + j          // inner ring, azimuth j
                let b = a + 1                   // inner ring, azimuth j+1
                let c = a + stride              // outer ring, azimuth j
                let d = c + 1                   // outer ring, azimuth j+1
                // Seen from outside near +Z: outward is increasing ring, CCW is increasing azimuth.
                indices += [a, c, d, a, d, b]
            }
        }
        var desc = MeshDescriptor(name: "zPolarSphere")
        desc.positions = MeshBuffers.Positions(positions)
        desc.normals = MeshBuffers.Normals(normals)
        desc.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        desc.primitives = .triangles(indices)
        return try MeshResource.generate(from: [desc])
    }

    /// A flat ribbon lying on a sphere's surface along `directions` (unit vectors from the center),
    /// lifted `lift` meters above a sphere of `radius`. `closed` joins the last point to the first.
    /// Render it with `faceCulling = .none`: far-side ribbons are seen from behind, through the glass.
    static func surfaceRibbon(directions: [SIMD3<Float>], radius: Float, lift: Float, width: Float, closed: Bool = false) throws -> MeshResource {
        let pts = closed ? directions + [directions[0]] : directions
        precondition(pts.count >= 2, "a ribbon needs at least two points")
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        for k in pts.indices {
            let n = simd_normalize(pts[k])
            let prev = pts[max(k - 1, 0)]
            let next = pts[min(k + 1, pts.count - 1)]
            var t = next - prev
            if closed && (k == 0 || k == pts.count - 1) { t = pts[1] - pts[pts.count - 2] }
            // Tangent projected onto the surface; side vector points to the left of travel, seen from outside.
            t = simd_normalize(t - simd_dot(t, n) * n)
            let side = simd_normalize(simd_cross(n, t))
            let center = n * (radius + lift)
            positions.append(center - side * width / 2) // right edge
            positions.append(center + side * width / 2) // left edge
            normals += [n, n]
            let u = Float(k) / Float(pts.count - 1)
            uvs += [[u, 0], [u, 1]]
        }
        var indices: [UInt32] = []
        for k in 0..<UInt32(pts.count - 1) {
            let r0 = 2 * k, l0 = 2 * k + 1, r1 = 2 * k + 2, l1 = 2 * k + 3
            indices += [r0, r1, l1, r0, l1, l0]
        }
        var desc = MeshDescriptor(name: "surfaceRibbon")
        desc.positions = MeshBuffers.Positions(positions)
        desc.normals = MeshBuffers.Normals(normals)
        desc.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        desc.primitives = .triangles(indices)
        return try MeshResource.generate(from: [desc])
    }

    /// A flat ring in the XZ plane (normal +Y), outer radius `radius`, `thickness` wide. Lies flat on
    /// the surface like a note disc. Used for approach rings (render with `faceCulling = .none`).
    static func annulus(radius: Float, thickness: Float, segments: Int = 64) throws -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        let inner = max(radius - thickness, 0)
        for k in 0...segments {
            let a = Float(k) / Float(segments) * 2 * .pi
            let dir = SIMD3<Float>(cos(a), 0, sin(a))
            positions += [dir * radius, dir * inner]
            normals += [[0, 1, 0], [0, 1, 0]]
        }
        var indices: [UInt32] = []
        for k in 0..<UInt32(segments) {
            let o0 = 2 * k, i0 = 2 * k + 1, o1 = 2 * k + 2, i1 = 2 * k + 3
            indices += [o0, i0, o1, o1, i0, i1]
        }
        var desc = MeshDescriptor(name: "annulus")
        desc.positions = MeshBuffers.Positions(positions)
        desc.normals = MeshBuffers.Normals(normals)
        desc.primitives = .triangles(indices)
        return try MeshResource.generate(from: [desc])
    }
}
