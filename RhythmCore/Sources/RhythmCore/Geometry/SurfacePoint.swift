import Foundation
import simd

/// A position on the object's surface, in the object's own (rotating) coordinates.
///
/// Format v1 uses latitude/longitude in degrees, which is natural for a sphere. Other shapes (M3)
/// may add other coordinate kinds, which is why the JSON form is an object (`{"lat":..,"lon":..}`)
/// rather than a bare pair.
///
/// Convention (object-local frame, before rotation): +Y is up, +Z faces the player at rest.
/// lat 0, lon 0 is the point facing the player. Latitude is positive upward (-90...90).
/// Longitude is positive toward +X (the player's right at rest).
public struct SurfacePoint: Codable, Sendable, Equatable, Hashable {
    public var lat: Double
    public var lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    /// Unit direction from the object's center to this point, in object-local coordinates.
    public var unitVector: SIMD3<Double> {
        let la = lat * .pi / 180
        let lo = lon * .pi / 180
        return SIMD3(cos(la) * sin(lo), sin(la), cos(la) * cos(lo))
    }

    /// The surface point in the direction of `v` (projection onto the unit sphere).
    /// Returns nil for a zero-length vector. Longitude comes back in (-180, 180].
    public init?(direction v: SIMD3<Double>) {
        let len = simd_length(v)
        guard len > 1e-12, len.isFinite else { return nil }
        let u = v / len
        lat = asin(min(max(u.y, -1), 1)) * 180 / .pi
        // At the poles longitude is undefined; atan2(0, 0) returns 0, which is fine.
        lon = atan2(u.x, u.z) * 180 / .pi
    }

    /// Great-circle angle between two surface points, in degrees.
    public func angularDistanceDeg(to other: SurfacePoint) -> Double {
        angleBetweenDeg(unitVector, other.unitVector)
    }

    public var isFinite: Bool { lat.isFinite && lon.isFinite }
}

/// Angle between two vectors in degrees, numerically stable for small and near-180 angles.
public func angleBetweenDeg(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    let crossLen = simd_length(simd_cross(a, b))
    let dot = simd_dot(a, b)
    return atan2(crossLen, dot) * 180 / .pi
}

/// Spherical linear interpolation between two unit vectors (constant angular speed).
/// Falls back to a normalized lerp when the vectors are nearly identical.
public func slerpUnit(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
    let angle = angleBetweenDeg(a, b) * .pi / 180
    if angle < 1e-9 { return a }
    if abs(angle - .pi) < 1e-9 {
        // Antipodal points: the great circle is ambiguous. Pick one through a perpendicular axis.
        // Beatmap validation rejects stroke segments this long, so this is only a safety net.
        let perp = simd_normalize(simd_cross(a, abs(a.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)))
        let q = simd_quatd(angle: angle * t, axis: perp)
        return q.act(a)
    }
    let s = sin(angle)
    return (sin((1 - t) * angle) / s) * a + (sin(t * angle) / s) * b
}
