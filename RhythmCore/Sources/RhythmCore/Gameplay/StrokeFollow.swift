import Foundation
import simd

/// A stroke's guided path on the surface: great-circle arcs between consecutive points, traversed
/// at constant angular speed (arc-length parameterized).
public struct StrokePath: Sendable, Equatable {
    public let points: [SurfacePoint]
    private let units: [SIMD3<Double>]
    /// Cumulative arc length (degrees) at each point; `cumulative[0] == 0`.
    private let cumulative: [Double]

    public init(points: [SurfacePoint]) {
        self.points = points
        self.units = points.map(\.unitVector)
        var acc: [Double] = [0]
        for i in units.indices.dropFirst() {
            acc.append(acc[i - 1] + angleBetweenDeg(units[i - 1], units[i]))
        }
        self.cumulative = acc
    }

    /// Total arc length of the path in degrees.
    public var totalAngleDeg: Double { cumulative.last ?? 0 }

    /// Point at fraction `f` (0...1, clamped) of the path's total arc length.
    public func point(atFraction f: Double) -> SurfacePoint {
        guard units.count > 1, totalAngleDeg > 0 else { return points.first ?? SurfacePoint(lat: 0, lon: 0) }
        let target = min(max(f, 0), 1) * totalAngleDeg
        // Segment containing `target`.
        var i = 1
        while i < cumulative.count - 1, cumulative[i] < target { i += 1 }
        let segLen = cumulative[i] - cumulative[i - 1]
        let t = segLen > 0 ? (target - cumulative[i - 1]) / segLen : 0
        return SurfacePoint(direction: slerpUnit(units[i - 1], units[i], t)) ?? points[i - 1]
    }

    /// Evenly spaced samples along the path (for rendering ribbons), including both ends.
    public func sampled(count: Int) -> [SurfacePoint] {
        guard count > 1 else { return [point(atFraction: 0)] }
        return (0..<count).map { point(atFraction: Double($0) / Double(count - 1)) }
    }

    /// The point on the path closest to `point`: its fraction of the total arc length (0...1) and its
    /// angular distance from `point` in degrees. A point beyond either end projects onto that end.
    public func closest(to point: SurfacePoint) -> (fraction: Double, distanceDeg: Double) {
        let p = point.unitVector
        guard units.count > 1, totalAngleDeg > 0 else { return (0, angleBetweenDeg(p, units.first ?? p)) }
        var best = (fraction: 0.0, distanceDeg: Double.infinity)
        for i in 1..<units.count {
            let a = units[i - 1], b = units[i]
            let segLen = cumulative[i] - cumulative[i - 1]
            // Closest point on the great-circle arc a→b: project onto the arc's plane, then clamp to the arc.
            var along: Double
            let n = simd_cross(a, b)
            if simd_length(n) > 1e-12 {
                let onPlane = p - simd_dot(p, simd_normalize(n)) * simd_normalize(n)
                if simd_length(onPlane) > 1e-12 {
                    let q = simd_normalize(onPlane)
                    let fromA = angleBetweenDeg(a, q), toB = angleBetweenDeg(q, b)
                    along = abs(fromA + toB - segLen) < 1e-6 ? fromA : (fromA < toB ? 0 : segLen)
                } else {
                    along = 0
                }
            } else {
                along = 0
            }
            let t = segLen > 0 ? along / segLen : 0
            let c = slerpUnit(a, b, t)
            let d = angleBetweenDeg(p, c)
            if d < best.distanceDeg {
                best = ((cumulative[i - 1] + along) / totalAngleDeg, d)
            }
        }
        return best
    }

    /// Longest single segment in degrees (the validator limits this; near-180 arcs are ambiguous).
    public var longestSegmentDeg: Double {
        zip(cumulative, cumulative.dropFirst()).map { $1 - $0 }.max() ?? 0
    }
}

/// Scores how closely a drag follows a moving guide along a path (a stroke's guide).
///
/// The guide's duration is split into `buckets` equal time buckets. Each drag sample earns credit by its
/// angular distance from where the guide was at that moment: full credit within `toleranceDeg`, falling
/// linearly to zero at `falloffDeg`. A bucket scores the mean credit of its samples; an empty bucket
/// scores zero. The follow score is the mean over buckets, so it doesn't depend on the drag event rate,
/// and letting go early costs exactly the missing part.
///
/// Samples must be in the same coordinates as the path (object-local for strokes, view for sliders).
/// Times are raw clock times; the input offset is removed here.
public struct PathFollowScorer: Sendable {
    public let path: StrokePath
    public let startMs: Double
    public let durationMs: Double
    public let toleranceDeg: Double
    public let falloffDeg: Double
    public let inputOffsetMs: Double
    private var bucketSums: [Double]
    private var bucketCounts: [Int]
    /// Credit of the most recent sample (for live feedback), nil before any sample.
    public private(set) var lastCredit: Double?

    public init(path: StrokePath, startMs: Double, durationMs: Double, toleranceDeg: Double, falloffDeg: Double,
                buckets: Int, inputOffsetMs: Double) {
        self.path = path
        self.startMs = startMs
        self.durationMs = durationMs
        self.toleranceDeg = toleranceDeg
        self.falloffDeg = falloffDeg
        self.inputOffsetMs = inputOffsetMs
        let n = max(buckets, 1)
        bucketSums = Array(repeating: 0, count: n)
        bucketCounts = Array(repeating: 0, count: n)
    }

    /// A stroke's guide, with the stroke tolerances.
    public init(stroke: Stroke, tuning: Tuning) {
        self.init(path: StrokePath(points: stroke.path), startMs: stroke.startMs, durationMs: stroke.durationMs,
                  toleranceDeg: tuning.followToleranceDeg, falloffDeg: tuning.followFalloffDeg,
                  buckets: tuning.strokeScoreBuckets, inputOffsetMs: tuning.inputOffsetMs)
    }

    public var endMs: Double { startMs + durationMs }

    /// Where the guide is at (judged) time `ms`: the start point before, the end point after.
    public func guidePoint(atMs ms: Double) -> SurfacePoint {
        path.point(atFraction: progress(atMs: ms))
    }

    /// Fraction of the duration elapsed at (judged) time `ms`, clamped to 0...1.
    public func progress(atMs ms: Double) -> Double {
        guard durationMs > 0 else { return 1 }
        return min(max((ms - startMs) / durationMs, 0), 1)
    }

    /// Credit for one sample at a given angular error.
    public static func credit(errorDeg: Double, toleranceDeg: Double, falloffDeg: Double) -> Double {
        if errorDeg <= toleranceDeg { return 1 }
        if errorDeg >= falloffDeg { return 0 }
        return 1 - (errorDeg - toleranceDeg) / (falloffDeg - toleranceDeg)
    }

    /// Adds one drag sample. Samples outside the time span are ignored.
    /// Returns the sample's credit (or nil if ignored), for live feedback.
    @discardableResult
    public mutating func addSample(point: SurfacePoint, atMs rawMs: Double) -> Double? {
        let ms = rawMs - inputOffsetMs
        guard ms >= startMs, ms <= endMs, point.isFinite else { return nil }
        let error = point.angularDistanceDeg(to: guidePoint(atMs: ms))
        let c = Self.credit(errorDeg: error, toleranceDeg: toleranceDeg, falloffDeg: falloffDeg)
        let n = bucketSums.count
        let bucket = min(Int(progress(atMs: ms) * Double(n)), n - 1)
        bucketSums[bucket] += c
        bucketCounts[bucket] += 1
        lastCredit = c
        return c
    }

    /// Follow score, 0...1.
    public var followScore: Double {
        let perBucket = zip(bucketSums, bucketCounts).map { $1 > 0 ? $0 / Double($1) : 0 }
        return perBucket.reduce(0, +) / Double(perBucket.count)
    }
}

/// How much a stroke's color shows once it's done.
public enum RevealLevel: String, Sendable, Codable, Equatable, Comparable {
    /// Missed or badly followed: stays clear glass.
    case uncolored
    /// Followed roughly: shows a faint tint.
    case faint
    /// Followed well: lights up in full color.
    case full

    private var rank: Int {
        switch self {
        case .uncolored: 0
        case .faint: 1
        case .full: 2
        }
    }

    public static func < (lhs: RevealLevel, rhs: RevealLevel) -> Bool { lhs.rank < rhs.rank }
}

/// The color-reveal state of a stroke.
public struct RevealState: Sendable, Equatable {
    public var level: RevealLevel
    /// Color strength the stroke settles at, 0...1 (0 = clear glass).
    public var targetIntensity: Double
    /// Clock time when the stroke completed and the fill animation started.
    public var completedAtMs: Double

    /// - Parameter startJudgment: the timing judgment of the stroke's opening pinch; a missed start
    ///   means the stroke was never played and stays uncolored.
    public init(followScore: Double, startJudgment: Judgment, completedAtMs: Double, tuning: Tuning) {
        self.completedAtMs = completedAtMs
        let score = min(max(followScore, 0), 1)
        if startJudgment == .miss || score < tuning.revealFaintThreshold {
            level = .uncolored
            targetIntensity = 0
        } else if score < tuning.revealFullThreshold {
            level = .faint
            // Scale faint strokes between 0.25 and 0.6 so better following still reads as better.
            let t = (score - tuning.revealFaintThreshold) / (tuning.revealFullThreshold - tuning.revealFaintThreshold)
            targetIntensity = 0.25 + 0.35 * t
        } else {
            level = .full
            targetIntensity = 1
        }
    }

    /// Color strength at clock time `ms`, animating from 0 up to `targetIntensity` over
    /// `tuning.revealAnimationMs` (ease-out).
    public func intensity(atMs ms: Double, tuning: Tuning) -> Double {
        guard tuning.revealAnimationMs > 0 else { return targetIntensity }
        let t = min(max((ms - completedAtMs) / tuning.revealAnimationMs, 0), 1)
        let eased = 1 - (1 - t) * (1 - t)
        return targetIntensity * eased
    }
}
