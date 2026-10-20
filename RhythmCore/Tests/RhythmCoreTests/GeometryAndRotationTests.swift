import Foundation
import simd
import Testing
@testable import RhythmCore

@Suite struct SurfacePointTests {
    @Test func conventions() {
        let front = SurfacePoint(lat: 0, lon: 0).unitVector
        let right = SurfacePoint(lat: 0, lon: 90).unitVector
        let top = SurfacePoint(lat: 90, lon: 0).unitVector
        #expect(simd_distance(front, [0, 0, 1]) < 1e-12)
        #expect(simd_distance(right, [1, 0, 0]) < 1e-12)
        #expect(simd_distance(top, [0, 1, 0]) < 1e-12)
    }

    @Test(arguments: [(10.0, -48.0), (-35, 170), (0, 180), (60, -120), (-89, 5)])
    func directionRoundTrip(lat: Double, lon: Double) throws {
        let p = SurfacePoint(lat: lat, lon: lon)
        let back = try #require(SurfacePoint(direction: p.unitVector * 3.7))
        #expect(back.angularDistanceDeg(to: p) < 1e-9)
    }

    @Test func zeroVectorHasNoSurfacePoint() {
        #expect(SurfacePoint(direction: .zero) == nil)
    }

    @Test func angularDistance() {
        #expect(approxEqual(SurfacePoint(lat: 0, lon: 0).angularDistanceDeg(to: SurfacePoint(lat: 0, lon: 90)), 90))
        #expect(approxEqual(SurfacePoint(lat: 0, lon: 0).angularDistanceDeg(to: SurfacePoint(lat: 0, lon: 180)), 180))
        #expect(approxEqual(SurfacePoint(lat: 10, lon: 20).angularDistanceDeg(to: SurfacePoint(lat: 10, lon: 20)), 0))
    }

    @Test func slerpMidpointIsOnGreatCircle() throws {
        let a = SurfacePoint(lat: 0, lon: 0).unitVector
        let b = SurfacePoint(lat: 0, lon: 90).unitVector
        let mid = try #require(SurfacePoint(direction: slerpUnit(a, b, 0.5)))
        #expect(approxEqual(mid.lat, 0) && approxEqual(mid.lon, 45))
        #expect(approxEqual(simd_length(slerpUnit(a, b, 0.3)), 1))
    }

    @Test func sphereShapeProjects() throws {
        let shape = SphereShape(radiusM: 0.35)
        let p = SurfacePoint(lat: 20, lon: -30)
        #expect(approxEqual(simd_length(shape.position(of: p)), 0.35))
        let projected = try #require(shape.project(localPosition: shape.position(of: p) * 1.2))
        #expect(projected.angularDistanceDeg(to: p) < 1e-9)
    }
}

@Suite struct RotationScheduleTests {
    let grid = BeatGrid(bpm: 120, offsetMs: 0)

    @Test func beatGridConverts() {
        let g = BeatGrid(bpm: 120, offsetMs: 250)
        #expect(g.msPerBeat == 500)
        #expect(g.beat(atMs: 1250) == 2)
        #expect(g.ms(atBeat: 4) == 2250)
    }

    @Test func identityAtBeatZero() {
        let s = RotationSchedule(segments: [.init(startBeat: 0, axis: [0, 1, 0], degreesPerBeat: 6)], grid: grid)
        let q = s.orientation(atMs: 0)
        #expect(approxEqual(q.angle, 0))
    }

    @Test func constantRotationBringsNoteToFront() {
        // 6°/beat about +Y, beat 8 (4000 ms) = 48°: the point at lon -48 faces the player.
        let s = RotationSchedule(segments: [.init(startBeat: 0, axis: [0, 1, 0], degreesPerBeat: 6)], grid: grid)
        let n = s.orientation(atMs: 4000).act(SurfacePoint(lat: 0, lon: -48).unitVector)
        #expect(simd_distance(n, Playfield.front) < 1e-9)
    }

    @Test func positiveYRotationMovesFrontToPlayersRight() {
        let s = RotationSchedule(segments: [.init(startBeat: 0, axis: [0, 1, 0], degreesPerBeat: 6)], grid: grid)
        let n = s.orientation(atMs: 500).act(SurfacePoint(lat: 0, lon: 0).unitVector)
        #expect(n.x > 0)
    }

    @Test func continuousAcrossSegmentBoundaries() {
        let s = RotationSchedule(segments: [
            .init(startBeat: 0, axis: [0, 1, 0], degreesPerBeat: 6),
            .init(startBeat: 16, axis: [1, 0, 0], degreesPerBeat: 3),
            .init(startBeat: 32, axis: [0, 1, 0], degreesPerBeat: -4),
        ], grid: grid)
        let p = SurfacePoint(lat: 25, lon: 40).unitVector
        for boundaryBeat in [16.0, 32.0] {
            let before = s.orientation(atBeat: boundaryBeat - 1e-6).act(p)
            let at = s.orientation(atBeat: boundaryBeat).act(p)
            let after = s.orientation(atBeat: boundaryBeat + 1e-6).act(p)
            #expect(simd_distance(before, at) < 1e-6)
            #expect(simd_distance(at, after) < 1e-6)
        }
    }

    @Test func composesSegmentsInOrder() {
        // 16 beats * 6° = 96° about Y, then 10 beats * 3° = 30° about X (placement frame).
        let s = RotationSchedule(segments: [
            .init(startBeat: 0, axis: [0, 1, 0], degreesPerBeat: 6),
            .init(startBeat: 16, axis: [1, 0, 0], degreesPerBeat: 3),
        ], grid: grid)
        let expected = simd_quatd(angle: 30 * .pi / 180, axis: [1, 0, 0]) * simd_quatd(angle: 96 * .pi / 180, axis: [0, 1, 0])
        let p = SurfacePoint(lat: 5, lon: 5).unitVector
        #expect(simd_distance(s.orientation(atBeat: 26).act(p), expected.act(p)) < 1e-9)
    }

    @Test func segmentsNeedNotBeSortedInInput() {
        let a = RotationSchedule(segments: [
            .init(startBeat: 16, axis: [1, 0, 0], degreesPerBeat: 3),
            .init(startBeat: 0, axis: [0, 1, 0], degreesPerBeat: 6),
        ], grid: grid)
        let b = RotationSchedule(segments: [
            .init(startBeat: 0, axis: [0, 1, 0], degreesPerBeat: 6),
            .init(startBeat: 16, axis: [1, 0, 0], degreesPerBeat: 3),
        ], grid: grid)
        let p = SurfacePoint(lat: 5, lon: 5).unitVector
        #expect(simd_distance(a.orientation(atBeat: 20).act(p), b.orientation(atBeat: 20).act(p)) < 1e-12)
    }

    @Test func leadInExtendsFirstSegmentBackward() {
        let s = RotationSchedule(segments: [.init(startBeat: 0, axis: [0, 1, 0], degreesPerBeat: 6)], grid: grid)
        let n = s.orientation(atBeat: -2).act(SurfacePoint(lat: 0, lon: 12).unitVector)
        #expect(simd_distance(n, Playfield.front) < 1e-9)
    }

    @Test func sameTimeGivesSameOrientation() {
        let s = RotationSchedule(segments: [
            .init(startBeat: 0, axis: [0, 1, 0], degreesPerBeat: 6),
            .init(startBeat: 8, axis: [0.3, 1, 0], degreesPerBeat: 5),
        ], grid: grid)
        let q1 = s.orientation(atMs: 12_345.6)
        _ = s.orientation(atMs: 99_999)
        let q2 = s.orientation(atMs: 12_345.6)
        #expect(q1 == q2)
    }

    @Test func reportsSpeedPerSegment() {
        let s = RotationSchedule(segments: [
            .init(startBeat: 0, axis: [0, 1, 0], degreesPerBeat: 6),
            .init(startBeat: 8, axis: [0, 1, 0], degreesPerBeat: -12),
        ], grid: grid)
        #expect(s.degreesPerSecondBySegment == [12, 24])
    }

    @Test func zeroAxisMeansNoRotation() {
        let s = RotationSchedule(segments: [.init(startBeat: 0, axis: [0, 0, 0], degreesPerBeat: 6)], grid: grid)
        #expect(approxEqual(s.orientation(atBeat: 50).angle, 0))
    }
}

@Suite struct PlayfieldTests {
    let field = Playfield(beatmap: Fixtures.map())
    let tuning = Tuning()

    @Test func noteIsCenteredAtItsTime() {
        let note = Fixtures.note("n", atMs: 4000)
        #expect(field.angleFromFrontDeg(of: note.at, atMs: 4000) < 1e-6)
        #expect(field.isInHitZone(note.at, atMs: 4000, tuning: tuning))
    }

    @Test func zoneEntryAndExitFollowRotationSpeed() {
        // 12°/s with a 30° half-angle zone: the note is in the zone from 2.5 s before to 2.5 s after.
        let note = Fixtures.note("n", atMs: 10_000)
        #expect(field.isInHitZone(note.at, atMs: 7_600, tuning: tuning))
        #expect(!field.isInHitZone(note.at, atMs: 7_400, tuning: tuning))
        #expect(field.isInHitZone(note.at, atMs: 12_400, tuning: tuning))
        #expect(!field.isInHitZone(note.at, atMs: 12_600, tuning: tuning))
        // Targetable (40°) a little earlier.
        #expect(field.isTargetable(note.at, atMs: 7_000, tuning: tuning))
    }

    @Test func latitudeAddsToAngleFromFront() {
        let note = Fixtures.note("n", atMs: 4000, lat: 15)
        #expect(approxEqual(field.angleFromFrontDeg(of: note.at, atMs: 4000), 15, tolerance: 1e-6))
    }

    @Test func farSideIsBehind() {
        let note = Fixtures.note("n", atMs: 20_000) // faces front at 20 s, so faces away at 5 s (180° earlier)
        #expect(field.isFarSide(note.at, atMs: 5_000))
        #expect(!field.isFarSide(note.at, atMs: 20_000))
    }

    @Test func projectionFromPlacementUndoesRotation() throws {
        let p = SurfacePoint(lat: 12, lon: 33)
        for t in [0.0, 3_210, 17_777] {
            let world = field.worldPosition(of: p, atMs: t)
            let back = try #require(field.surfacePoint(fromPlacement: world * 1.1, atMs: t))
            #expect(back.angularDistanceDeg(to: p) < 1e-9)
        }
    }
}

@Suite struct ApproachTests {
    let field = Playfield(beatmap: Fixtures.map())
    let tuning = Tuning()

    @Test func approachTimesFollowRotationSpeed() {
        // 12°/s: a note centered at 20 s was 150° from front 12.5 s earlier and 40° from front 3.33 s earlier.
        let note = Fixtures.note("n", atMs: 20_000)
        let a = field.approach(of: note.at, hitMs: 20_000, tuning: tuning)
        #expect(approxEqual(a.appearMs, 7_500, tolerance: 1))
        #expect(approxEqual(a.targetableFromMs, 20_000 - 40_000.0 / 12, tolerance: 1))
    }

    @Test func alreadyFarAwayReturnsSameTime() {
        let behind = SurfacePoint(lat: 0, lon: Fixtures.frontLon(atMs: 0) + 180)
        #expect(field.lastTimeBefore(0, point: behind, atLeastDeg: 150) == 0)
    }

    @Test func pointThatNeverLeavesIsCappedByLookback() {
        // The north pole sits on the rotation axis: always 90° from front, never 150°.
        let pole = SurfacePoint(lat: 90, lon: 0)
        #expect(field.lastTimeBefore(50_000, point: pole, atLeastDeg: 150, lookbackMs: 10_000) == 40_000)
    }
}
