import RealityKit
import RhythmCore
import simd
import UIKit

// Conversions between RhythmCore's Double math and RealityKit's Float transforms.

extension SIMD3 where Scalar == Float {
    init(_ d: SIMD3<Double>) {
        self.init(Float(d.x), Float(d.y), Float(d.z))
    }
}

extension simd_quatf {
    init(_ q: simd_quatd) {
        self.init(vector: SIMD4<Float>(Float(q.vector.x), Float(q.vector.y), Float(q.vector.z), Float(q.vector.w)))
    }
}

extension SurfacePoint {
    var unitVectorF: SIMD3<Float> { SIMD3<Float>(unitVector) }
}

/// Rotation that turns +Y onto `normal` (used to lay flat discs on the surface).
func orientationFacing(normal: SIMD3<Float>) -> simd_quatf {
    let up = SIMD3<Float>(0, 1, 0)
    let n = simd_normalize(normal)
    if simd_dot(up, n) < -0.9999 { return simd_quatf(angle: .pi, axis: [1, 0, 0]) }
    return simd_quatf(from: up, to: n)
}

extension RGBColor {
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
}
