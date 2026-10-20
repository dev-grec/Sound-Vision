import RealityKit

/// Places the object once in front of the player when the space opens.
///
/// `AnchorEntity(.head, trackingMode: .once)` resolves to the head pose a single time, then stays fixed
/// in the room, so the player can lean or walk without the object following. `placement` is the
/// non-rotating frame RhythmCore calls the "placement frame": +Z points back toward where the head was,
/// which is the front direction for the hittable zone (docs/DECISIONS.md, "Front direction").
///
/// `physicsSimulation: .none` puts the anchored content in the scene's own simulation; with the default
/// (.isolated) anchored collision shapes can be invisible to entity-targeted gestures.
struct PlacementRig {
    let anchor: AnchorEntity
    let placement: Entity

    /// - Parameters:
    ///   - distance: meters in front of the head.
    ///   - drop: meters below eye level (slightly low is more comfortable to look at).
    init(distance: Float = 1.1, drop: Float = 0.12) {
        anchor = AnchorEntity(.head, trackingMode: .once, physicsSimulation: .none)
        anchor.name = "HeadAnchorOnce"
        placement = Entity()
        placement.name = "Placement"
        placement.position = [0, -drop, -distance]
        anchor.addChild(placement)
    }
}
