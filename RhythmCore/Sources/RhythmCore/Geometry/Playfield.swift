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

    /// True while the point is inside the front-facing play area.
    public func isInHitZone(_ point: SurfacePoint, atMs ms: Double, tuning: Tuning) -> Bool {
        angleFromFrontDeg(of: point, atMs: ms) <= tuning.hitZoneHalfAngleDeg
    }

    /// The largest angle from front that `point` reaches over [fromMs, toMs], sampled every `stepMs`
    /// (and at both ends). Used to check a target stays in the play area while it's on screen.
    public func maxAngleFromFrontDeg(of point: SurfacePoint, fromMs: Double, toMs: Double, stepMs: Double = 50) -> Double {
        var worst = angleFromFrontDeg(of: point, atMs: toMs)
        var t = fromMs
        while t < toMs {
            worst = max(worst, angleFromFrontDeg(of: point, atMs: t))
            t += stepMs
        }
        return worst
    }

    /// True while the point faces away from the player (seen through the glass).
    public func isFarSide(_ point: SurfacePoint, atMs ms: Double) -> Bool {
        simd_dot(worldNormal(of: point, atMs: ms), Self.front) < 0
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
