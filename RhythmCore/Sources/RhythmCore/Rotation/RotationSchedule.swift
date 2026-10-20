import Foundation
import simd

/// The object's orientation as a pure function of song time.
///
/// Orientation at any time is computed analytically: the full rotation of every completed segment,
/// then the partial rotation of the current one. Nothing is accumulated frame to frame, so the same
/// song time always gives exactly the same orientation.
///
/// Axes are in the player-facing placement frame (+X right, +Y up, +Z toward the player), so each
/// segment's rotation is applied on top of (pre-multiplied onto) the orientation reached so far.
/// Before the first segment starts (lead-in, negative beats), the first segment is extended backward
/// so the object is already turning when the song starts.
public struct RotationSchedule: Sendable {
    struct Resolved: Sendable {
        var startBeat: Double
        var axis: SIMD3<Double>          // unit length
        var radiansPerBeat: Double
        var startOrientation: simd_quatd // orientation at startBeat
    }

    let grid: BeatGrid
    let segments: [Resolved]

    /// Segments are sorted by start beat. A segment with a zero or non-finite axis or rate is treated
    /// as "no rotation" for its span (the validator reports it as an error).
    public init(segments input: [RotationSegment], grid: BeatGrid) {
        self.grid = grid
        let sorted = input.sorted { $0.startBeat < $1.startBeat }
        var resolved: [Resolved] = []
        var orientation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        for (i, seg) in sorted.enumerated() {
            let raw = seg.axis.count == 3 ? SIMD3(seg.axis[0], seg.axis[1], seg.axis[2]) : .zero
            let len = simd_length(raw)
            let usable = len > 1e-9 && len.isFinite && seg.degreesPerBeat.isFinite
            let axis = usable ? raw / len : SIMD3<Double>(0, 1, 0)
            let rate = usable ? seg.degreesPerBeat * .pi / 180 : 0
            if i > 0, let prev = resolved.last {
                let span = seg.startBeat - prev.startBeat
                orientation = simd_quatd(angle: prev.radiansPerBeat * span, axis: prev.axis) * prev.startOrientation
            }
            resolved.append(Resolved(startBeat: seg.startBeat, axis: axis, radiansPerBeat: rate,
                                     startOrientation: simd_normalize(orientation)))
        }
        self.segments = resolved
    }

    public init(beatmap: Beatmap) {
        self.init(segments: beatmap.rotation, grid: BeatGrid(beatmap.timing))
    }

    public func orientation(atMs ms: Double) -> simd_quatd {
        orientation(atBeat: grid.beat(atMs: ms))
    }

    public func orientation(atBeat beat: Double) -> simd_quatd {
        guard let first = segments.first else { return simd_quatd(ix: 0, iy: 0, iz: 0, r: 1) }
        // Last segment whose start is at or before `beat`; the first segment covers the lead-in.
        var seg = first
        for s in segments.dropFirst() {
            if s.startBeat <= beat { seg = s } else { break }
        }
        let partial = simd_quatd(angle: seg.radiansPerBeat * (beat - seg.startBeat), axis: seg.axis)
        return simd_normalize(partial * seg.startOrientation)
    }

    /// Angular speed of each segment in degrees per second, for validation.
    public var degreesPerSecondBySegment: [Double] {
        segments.map { abs($0.radiansPerBeat) * 180 / .pi * grid.bpm / 60 }
    }
}
