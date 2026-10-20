import Foundation
import simd

/// Maps a drag to points on the object in view coordinates, using only hand movement since the pinch.
///
/// Why relative: the object is placed under a head anchor whose transform visionOS hides from apps, so
/// converting a gesture's absolute location into the object's frame comes out offset (the first slider
/// build saw every drag land near the top of the sphere). Two things are reliable: the target that was
/// pinched (its position in the placement frame is known) and how far the hand has moved in scene space.
/// So: point = pinched target's position + (current scene location − scene location at the pinch),
/// projected onto the object. This assumes the placement frame's axes match the scene's, which holds
/// because both are set from the player's facing direction when the space opens (DECISIONS D19).
public struct DragTracker: Sendable, Equatable {
    /// Scene-space location of the pinch.
    public let startScene: SIMD3<Double>
    /// Placement-frame position of what was pinched.
    public let startPlacement: SIMD3<Double>

    public init(startScene: SIMD3<Double>, startPlacement: SIMD3<Double>) {
        self.startScene = startScene
        self.startPlacement = startPlacement
    }

    /// Placement-frame position for a scene-space drag location.
    public func placementPosition(forScene scene: SIMD3<Double>) -> SIMD3<Double> {
        startPlacement + (scene - startScene)
    }

    /// The point on the object (view coordinates) for a scene-space drag location.
    public func viewPoint(forScene scene: SIMD3<Double>, shape: any SurfaceShape) -> SurfacePoint? {
        shape.project(localPosition: placementPosition(forScene: scene))
    }
}
