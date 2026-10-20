import Foundation
import Testing
@testable import RhythmCore

@Suite struct StrokePathTests {
    @Test func interpolatesAlongEquator() {
        let path = StrokePath(points: [SurfacePoint(lat: 0, lon: 0), SurfacePoint(lat: 0, lon: 90)])
        #expect(approxEqual(path.totalAngleDeg, 90))
        let mid = path.point(atFraction: 0.5)
        #expect(approxEqual(mid.lat, 0) && approxEqual(mid.lon, 45))
        #expect(path.point(atFraction: -1) == SurfacePoint(lat: 0, lon: 0))
        #expect(approxEqual(path.point(atFraction: 2).lon, 90))
    }

    @Test func multiSegmentIsArcLengthParameterized() {
        // 30° east, then 60° north along the 30° meridian: total 90°. One third of the way is the corner.
        let path = StrokePath(points: [
            SurfacePoint(lat: 0, lon: 0), SurfacePoint(lat: 0, lon: 30), SurfacePoint(lat: 60, lon: 30),
        ])
        #expect(approxEqual(path.totalAngleDeg, 90))
        let corner = path.point(atFraction: 1.0 / 3)
        #expect(corner.angularDistanceDeg(to: SurfacePoint(lat: 0, lon: 30)) < 1e-6)
        let twoThirds = path.point(atFraction: 2.0 / 3)
        #expect(approxEqual(twoThirds.lat, 30, tolerance: 1e-6) && approxEqual(twoThirds.lon, 30, tolerance: 1e-6))
        #expect(approxEqual(path.longestSegmentDeg, 60))
    }

    @Test func sampledIncludesEnds() {
        let path = StrokePath(points: [SurfacePoint(lat: 0, lon: 0), SurfacePoint(lat: 0, lon: 40)])
        let samples = path.sampled(count: 5)
        #expect(samples.count == 5)
        #expect(approxEqual(samples[2].lon, 20))
        #expect(approxEqual(samples[4].lon, 40))
    }
}

@Suite struct PathFollowScorerTests {
    let tuning = Tuning()
    let stroke = Stroke(id: "s1", startMs: 10_000, durationMs: 2000,
                        path: [SurfacePoint(lat: 0, lon: 0), SurfacePoint(lat: 0, lon: 60)],
                        color: RGBColor(red: 1, green: 0, blue: 0))

    /// Drag samples at 90 Hz over [fromMs, toMs], placed at the guide position shifted north by `offsetLat`.
    func follow(_ scorer: inout PathFollowScorer, fromMs: Double, toMs: Double, offsetLat: Double = 0) {
        var t = fromMs
        while t <= toMs {
            let g = scorer.guidePoint(atMs: t)
            scorer.addSample(point: SurfacePoint(lat: g.lat + offsetLat, lon: g.lon), atMs: t)
            t += 11.1
        }
    }

    @Test func guideMovesAtConstantSpeed() {
        let scorer = PathFollowScorer(stroke: stroke, tuning: tuning)
        #expect(approxEqual(scorer.guidePoint(atMs: 9_000).lon, 0))   // before start: at start point
        #expect(approxEqual(scorer.guidePoint(atMs: 11_000).lon, 30))  // halfway
        #expect(approxEqual(scorer.guidePoint(atMs: 13_000).lon, 60))  // after end: at end point
    }

    @Test func perfectFollowScoresOne() {
        var scorer = PathFollowScorer(stroke: stroke, tuning: tuning)
        follow(&scorer, fromMs: 10_000, toMs: 12_000)
        #expect(approxEqual(scorer.followScore, 1))
    }

    @Test func withinToleranceStillScoresOne() {
        var scorer = PathFollowScorer(stroke: stroke, tuning: tuning)
        follow(&scorer, fromMs: 10_000, toMs: 12_000, offsetLat: 5) // tolerance is 6°
        #expect(approxEqual(scorer.followScore, 1))
    }

    @Test func creditFallsOffLinearly() {
        #expect(PathFollowScorer.credit(errorDeg: 12, toleranceDeg: tuning.followToleranceDeg, falloffDeg: tuning.followFalloffDeg) == 0.5) // halfway from 6° to 18°
        #expect(PathFollowScorer.credit(errorDeg: 18, toleranceDeg: tuning.followToleranceDeg, falloffDeg: tuning.followFalloffDeg) == 0)
        var scorer = PathFollowScorer(stroke: stroke, tuning: tuning)
        follow(&scorer, fromMs: 10_000, toMs: 12_000, offsetLat: 12)
        #expect(approxEqual(scorer.followScore, 0.5, tolerance: 1e-6))
    }

    @Test func lettingGoHalfwayScoresAboutHalf() {
        var scorer = PathFollowScorer(stroke: stroke, tuning: tuning)
        follow(&scorer, fromMs: 10_000, toMs: 11_000)
        #expect(approxEqual(scorer.followScore, 0.5, tolerance: 0.051))
    }

    @Test func sampleRateDoesNotMatter() {
        var sparse = PathFollowScorer(stroke: stroke, tuning: tuning)
        var dense = PathFollowScorer(stroke: stroke, tuning: tuning)
        for i in 0..<20 { // one sample in the middle of each bucket
            let t = 10_000 + (Double(i) + 0.5) * 100
            sparse.addSample(point: sparse.guidePoint(atMs: t), atMs: t)
        }
        follow(&dense, fromMs: 10_000, toMs: 12_000)
        #expect(approxEqual(sparse.followScore, dense.followScore))
    }

    @Test func samplesOutsideStrokeAreIgnoredAndOffsetApplies() {
        var t = Tuning()
        t.inputOffsetMs = 50
        var scorer = PathFollowScorer(stroke: stroke, tuning: t)
        #expect(scorer.addSample(point: SurfacePoint(lat: 0, lon: 0), atMs: 10_020) == nil) // judged 9970: before start
        #expect(scorer.addSample(point: SurfacePoint(lat: 0, lon: 0), atMs: 10_050) == 1)
        #expect(scorer.addSample(point: SurfacePoint(lat: 0, lon: 60), atMs: 12_040) != nil) // judged 11990: inside
        #expect(scorer.addSample(point: SurfacePoint(lat: 0, lon: 60), atMs: 12_100) == nil) // judged 12050: after end
    }
}

@Suite struct RevealStateTests {
    let tuning = Tuning()

    @Test func levelsByFollowScore() {
        #expect(RevealState(followScore: 0.95, startJudgment: .perfect, completedAtMs: 0, tuning: tuning).level == .full)
        #expect(RevealState(followScore: 0.8, startJudgment: .good, completedAtMs: 0, tuning: tuning).level == .full)
        #expect(RevealState(followScore: 0.6, startJudgment: .perfect, completedAtMs: 0, tuning: tuning).level == .faint)
        #expect(RevealState(followScore: 0.39, startJudgment: .perfect, completedAtMs: 0, tuning: tuning).level == .uncolored)
    }

    @Test func missedStartStaysUncolored() {
        let r = RevealState(followScore: 1, startJudgment: .miss, completedAtMs: 0, tuning: tuning)
        #expect(r.level == .uncolored)
        #expect(r.targetIntensity == 0)
    }

    @Test func faintIntensityGrowsWithScore() {
        let low = RevealState(followScore: 0.45, startJudgment: .perfect, completedAtMs: 0, tuning: tuning)
        let high = RevealState(followScore: 0.75, startJudgment: .perfect, completedAtMs: 0, tuning: tuning)
        #expect(low.targetIntensity < high.targetIntensity)
        #expect(high.targetIntensity < 1)
    }

    @Test func intensityAnimatesFromCompletion() {
        let r = RevealState(followScore: 1, startJudgment: .perfect, completedAtMs: 5000, tuning: tuning)
        #expect(r.intensity(atMs: 4000, tuning: tuning) == 0)
        #expect(r.intensity(atMs: 5000, tuning: tuning) == 0)
        let mid = r.intensity(atMs: 5300, tuning: tuning)
        #expect(mid > 0.5 && mid < 1) // ease-out: past halfway at the time midpoint
        #expect(r.intensity(atMs: 5600, tuning: tuning) == 1)
        #expect(r.intensity(atMs: 9000, tuning: tuning) == 1)
    }
}
