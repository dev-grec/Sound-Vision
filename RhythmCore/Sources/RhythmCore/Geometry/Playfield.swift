import Foundation
import simd

/// The object's shape plus its rotation over time, seen from the player.
///
/// Frames:
/// - **object-local**: the object's own coordinates, which rotate with it. Beatmap positions live here.
/// - **placement frame**: non-rotating, centered on the object. +X right, +Y up, +Z toward the player.
///   The app parents the rotating object entity to a placement entity with exactly this frame.
///
/// The player is assumed to stand along +Z of the placement frame. The front direction is fixed
/// when the object is placed (see docs/DECISIONS.md, "Front direction").
public struct Playfield: Sendable {
    /// Direction from the object's center toward the player, in the placement frame.
    public static let front = SIMD3<Double>(0, 0, 1)

    public let shape: any SurfaceShape
    public let schedule: RotationSchedule

    public init(shape: any SurfaceShape, schedule: RotationSchedule) {
        self.shape = shape
        self.schedule = schedule
    }

    public init(beatmap: Beatmap) {
        self.init(shape: beatmap.object.surfaceShape, schedule: RotationSchedule(beatmap: beatmap))
    }

    public func orientation(atMs ms: Double) -> simd_quatd {
        schedule.orientation(atMs: ms)
    }

    /// Surface normal of `point` in the placement frame at time `ms`.
    public func worldNormal(of point: SurfacePoint, atMs ms: Double) -> SIMD3<Double> {
        orientation(atMs: ms).act(shape.normal(at: point))
    }

    /// Position of `point` in the placement frame at time `ms`, in meters.
    public func worldPosition(of point: SurfacePoint, atMs ms: Double) -> SIMD3<Double> {
        orientation(atMs: ms).act(shape.position(of: point))
    }

    /// Angle in degrees between the point's surface normal and the direction to the player.
    /// 0 means dead center of the hittable zone; 180 means directly behind.
    public func angleFromFrontDeg(of point: SurfacePoint, atMs ms: Double) -> Double {
        angleBetweenDeg(worldNormal(of: point, atMs: ms), Self.front)
    }

    /// True while the point is inside the front-facing hittable zone.
    public func isInHitZone(_ point: SurfacePoint, atMs ms: Double, tuning: Tuning) -> Bool {
        angleFromFrontDeg(of: point, atMs: ms) <= tuning.hitZoneHalfAngleDeg
    }

    /// True while the point should be an input target (slightly wider than the hit zone).
    public func isTargetable(_ point: SurfacePoint, atMs ms: Double, tuning: Tuning) -> Bool {
        angleFromFrontDeg(of: point, atMs: ms) <= tuning.targetableHalfAngleDeg
    }

    /// True while the point faces away from the player (seen through the glass).
    public func isFarSide(_ point: SurfacePoint, atMs ms: Double) -> Bool {
        simd_dot(worldNormal(of: point, atMs: ms), Self.front) < 0
    }

    /// The latest time at or before `ms` when `point` was at least `angleDeg` from front, searching back
    /// at most `lookbackMs`. Returns `ms - lookbackMs` if the point stayed closer than that throughout
    /// (for example, a point near the rotation axis).
    ///
    /// Used for a note's final approach: every note comes past the front once per revolution, so a
    /// note must only appear (and be targetable) on the pass that ends at its own time.
    public func lastTimeBefore(_ ms: Double, point: SurfacePoint, atLeastDeg angleDeg: Double,
                               lookbackMs: Double = 60_000, stepMs: Double = 50) -> Double {
        if angleFromFrontDeg(of: point, atMs: ms) >= angleDeg { return ms }
        var later = ms
        var t = ms - stepMs
        while t >= ms - lookbackMs {
            if angleFromFrontDeg(of: point, atMs: t) >= angleDeg {
                // Crossing is in (t, later]: bisect to sub-millisecond precision.
                var lo = t, hi = later
                while hi - lo > 0.5 {
                    let mid = (lo + hi) / 2
                    if angleFromFrontDeg(of: point, atMs: mid) >= angleDeg { lo = mid } else { hi = mid }
                }
                return lo
            }
            later = t
            t -= stepMs
        }
        return ms - lookbackMs
    }

    /// When a target due at `hitMs` becomes visible (fading in, usually on the far side) and when it
    /// becomes targetable, on its final approach.
    public func approach(of point: SurfacePoint, hitMs: Double, tuning: Tuning) -> Approach {
        Approach(
            appearMs: lastTimeBefore(hitMs, point: point, atLeastDeg: tuning.noteAppearAngleDeg),
            targetableFromMs: lastTimeBefore(hitMs, point: point, atLeastDeg: tuning.targetableHalfAngleDeg)
        )
    }

    public struct Approach: Sendable, Equatable {
        /// Before this the target is hidden: it hasn't started the pass that ends at its hit time.
        public var appearMs: Double
        /// From this the target may be an input target (within the targetable angle on its final pass).
        public var targetableFromMs: Double
    }

    /// Projects an object-local position (for example a drag location already converted into the
    /// rotating object's space) onto the surface.
    public func surfacePoint(fromObjectLocal p: SIMD3<Double>) -> SurfacePoint? {
        shape.project(localPosition: p)
    }

    /// Projects a placement-frame position onto the surface, undoing the rotation at time `ms`.
    public func surfacePoint(fromPlacement p: SIMD3<Double>, atMs ms: Double) -> SurfacePoint? {
        shape.project(localPosition: orientation(atMs: ms).inverse.act(p))
    }
}
