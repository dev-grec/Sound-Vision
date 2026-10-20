import Foundation
import simd

/// The geometry of the glass object, in object-local coordinates (meters).
///
/// Gameplay code only talks to this protocol, so later shapes (M3) can slot in.
/// A shape maps surface points to positions and normals, and projects arbitrary local points
/// (such as a drag location) back onto its surface.
public protocol SurfaceShape: Sendable {
    /// Position of a surface point, object-local, in meters.
    func position(of point: SurfacePoint) -> SIMD3<Double>
    /// Outward unit normal at a surface point, object-local.
    func normal(at point: SurfacePoint) -> SIMD3<Double>
    /// The surface point nearest to an arbitrary object-local position, or nil if undefined
    /// (for a sphere, the center itself).
    func project(localPosition: SIMD3<Double>) -> SurfacePoint?
}

public struct SphereShape: SurfaceShape, Equatable {
    public var radiusM: Double

    public init(radiusM: Double) {
        self.radiusM = radiusM
    }

    public func position(of point: SurfacePoint) -> SIMD3<Double> {
        point.unitVector * radiusM
    }

    public func normal(at point: SurfacePoint) -> SIMD3<Double> {
        point.unitVector
    }

    public func project(localPosition: SIMD3<Double>) -> SurfacePoint? {
        SurfacePoint(direction: localPosition)
    }
}

public extension Beatmap.ObjectSpec {
    /// The concrete shape for this spec.
    var surfaceShape: any SurfaceShape {
        switch shape {
        case .sphere: SphereShape(radiusM: radiusM)
        }
    }
}
