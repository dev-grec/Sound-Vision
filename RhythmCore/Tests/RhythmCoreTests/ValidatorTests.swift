import Foundation
import Testing
@testable import RhythmCore

@Suite struct ValidatorTests {
    let tuning = Tuning()

    func codes(_ map: Beatmap) -> Set<String> {
        Set(BeatmapValidator.validate(map, tuning: tuning).issues.map(\.code))
    }

    @Test func wellFormedMapIsClean() {
        let map = Fixtures.map(notes: [
            Fixtures.note("a", atMs: 4000, lat: 10),
            Fixtures.note("b", atMs: 5500, lat: -12, lon: 20), // on screen with a: 30° apart
            Fixtures.note("c", atMs: 8000),
        ])
        let report = BeatmapValidator.validate(map, tuning: tuning)
        #expect(report.issues.isEmpty, "\(report.issues)")
        #expect(report.isPlayable)
    }

    @Test func badTempoStopsEarly() {
        var map = Fixtures.map()
        map.timing.bpm = 0
        let report = BeatmapValidator.validate(map, tuning: tuning)
        #expect(report.issues.map(\.code) == ["timing.bpm"])
        #expect(!report.isPlayable)
    }

    @Test func rotationRules() {
        #expect(codes(Fixtures.map(rotation: [])).contains("rotation.empty"))
        #expect(codes(Fixtures.map(rotation: [.init(startBeat: 4, axis: [0, 1, 0], degreesPerBeat: 6)])).contains("rotation.start"))
        #expect(codes(Fixtures.map(rotation: [.init(startBeat: 0, axis: [0, 0, 0], degreesPerBeat: 6)])).contains("rotation.axis"))
        #expect(codes(Fixtures.map(rotation: [.init(startBeat: 0, axis: [0, 1], degreesPerBeat: 6)])).contains("rotation.axis"))
        // 11°/beat at 120 BPM = 22°/s, over the 20°/s limit.
        #expect(codes(Fixtures.map(rotation: [.init(startBeat: 0, axis: [0, 1, 0], degreesPerBeat: 11)])).contains("rotation.tooFast"))
        #expect(codes(Fixtures.map(rotation: [
            .init(startBeat: 0, axis: [0, 1, 0], degreesPerBeat: 6),
            .init(startBeat: 0, axis: [1, 0, 0], degreesPerBeat: 6),
        ])).contains("rotation.duplicate"))
    }

    @Test func duplicateAndEmptyIDs() {
        let map = Fixtures.map(notes: [Fixtures.note("a", atMs: 4000), Fixtures.note("a", atMs: 8000), Fixtures.note("", atMs: 12000)])
        #expect(codes(map).isSuperset(of: ["id.duplicate", "id.empty"]))
    }

    @Test func noteOutsideZoneIsError() {
        let misplaced = Fixtures.note("n", atMs: 4000, lon: 48) // 48° off front
        let report = BeatmapValidator.validate(Fixtures.map(notes: [misplaced]), tuning: tuning)
        #expect(report.errors.map(\.code) == ["note.outsideZone"])
        #expect(report.errors.first?.itemID == "n")
    }

    @Test func notesMayPopUpAnywhereInThePlayArea() {
        // Off center, up and to the right at hit time: fine.
        let note = Fixtures.note("n", atMs: 4000, lat: 25, lon: 20)
        let report = BeatmapValidator.validate(Fixtures.map(notes: [note]), tuning: tuning)
        #expect(report.issues.isEmpty, "\(report.issues)")
    }

    @Test func notesAreViewFixedSoRotationDoesNotMatter() {
        // 40° right is inside the 45° area at any time, however much the object has turned.
        let report = BeatmapValidator.validate(Fixtures.map(notes: [Fixtures.note("n", atMs: 17_000, lon: 40)]), tuning: tuning)
        #expect(report.issues.isEmpty, "\(report.issues)")
    }

    @Test func leftToRightStreamIsValid() {
        // The owner's example: dots going left to right to lead the eye, one per beat, 26° apart.
        let notes = [-39.0, -13.0, 13.0, 39.0].enumerated().map { i, lon in
            Fixtures.note("s\(i)", atMs: 8000 + Double(i) * 500, lon: lon)
        }
        let report = BeatmapValidator.validate(Fixtures.map(notes: notes), tuning: tuning)
        #expect(report.issues.isEmpty, "\(report.issues)")
    }

    @Test func noteTimingRules() {
        let map = Fixtures.map(notes: [
            TapNote(id: "neg", timeMs: -10, at: SurfacePoint(lat: 0, lon: Fixtures.frontLon(atMs: -10))),
            Fixtures.note("late", atMs: 70_000), // song is 30 bars = 60 s
            TapNote(id: "nan", timeMs: .nan, at: SurfacePoint(lat: 0, lon: 0)),
            TapNote(id: "lat", timeMs: 20_000, at: SurfacePoint(lat: 95, lon: 0)),
        ])
        #expect(codes(map).isSuperset(of: ["note.negativeTime", "note.afterEnd", "note.nonFinite", "note.latitude"]))
    }

    @Test func crowdedTargetsAreErrors() {
        // Two notes 0.5 s apart at nearly the same spot on the surface.
        let a = Fixtures.note("a", atMs: 4000)
        let b = TapNote(id: "b", timeMs: 4500, at: SurfacePoint(lat: 8, lon: a.at.lon + 3))
        let report = BeatmapValidator.validate(Fixtures.map(notes: [a, b]), tuning: tuning)
        #expect(report.errors.contains { $0.code == "targets.crowded" && $0.itemID == "b" })
    }

    @Test func crowdingUsesOnScreenOverlap() {
        // 1 s apart and 12° apart: b pops up (1.5 s before) while a is still on screen.
        let a = Fixtures.note("a", atMs: 4000)
        let b = Fixtures.note("b", atMs: 5000)
        let report = BeatmapValidator.validate(Fixtures.map(notes: [a, b]), tuning: tuning)
        #expect(report.errors.contains { $0.code == "targets.crowded" && $0.itemID == "b" })
        // 2 s apart: a is gone (window closed at 4170) before b pops up (4500).
        let c = Fixtures.note("c", atMs: 6000)
        #expect(!BeatmapValidator.validate(Fixtures.map(notes: [a, c]), tuning: tuning).has("targets.crowded"))
    }

    @Test func sameSpotFarApartInTimeIsFine() {
        // 30 s apart is a full turn later (12°/s * 30 s = 360°): same surface spot, no crowding.
        let report = BeatmapValidator.validate(Fixtures.map(notes: [Fixtures.note("a", atMs: 4000), Fixtures.note("b", atMs: 34_000)]), tuning: tuning)
        #expect(!report.has("targets.crowded"))
    }

    func stroke(_ id: String, startMs: Double, durationMs: Double = 2000, spanDeg: Double = 20) -> Stroke {
        // Starts at zone center and climbs `spanDeg` north while drifting west at the rotation speed
        // (12°/s), so the guide stays on the front meridian and only its latitude changes.
        let start = SurfacePoint(lat: 0, lon: Fixtures.frontLon(atMs: startMs))
        let drift = 12 * durationMs / 1000
        return Stroke(id: id, startMs: startMs, durationMs: durationMs,
                      path: [start, SurfacePoint(lat: spanDeg, lon: start.lon - drift)],
                      color: RGBColor(red: 0.2, green: 0.6, blue: 1))
    }

    @Test func validStrokeIsClean() {
        let report = BeatmapValidator.validate(Fixtures.map(strokes: [stroke("s", startMs: 10_000)]), tuning: tuning)
        #expect(report.issues.isEmpty, "\(report.issues)")
    }

    @Test func strokeRules() {
        var short = stroke("short", startMs: 10_000)
        short.path = [short.path[0]]
        var zero = stroke("zero", startMs: 20_000)
        zero.durationMs = 0
        var offZone = stroke("off", startMs: 30_000)
        offZone.path[0] = SurfacePoint(lat: 0, lon: offZone.path[0].lon + 90)
        var antipodal = stroke("anti", startMs: 40_000)
        antipodal.path = [antipodal.path[0], SurfacePoint(lat: 0, lon: antipodal.path[0].lon + 175)]
        let c = codes(Fixtures.map(strokes: [short, zero, offZone, antipodal]))
        #expect(c.isSuperset(of: ["stroke.path", "stroke.duration", "stroke.startOutsideZone", "stroke.segmentTooLong"]))
    }

    @Test func strokeLeavingZoneIsWarning() {
        // A 70° climb over 2 s leaves the 30° zone.
        let report = BeatmapValidator.validate(Fixtures.map(strokes: [stroke("s", startMs: 10_000, spanDeg: 70)]), tuning: tuning)
        #expect(report.isPlayable)
        #expect(report.has("stroke.leavesZone"))
    }

    @Test func overlappingStrokesAndNotesDuringStrokes() {
        let s1 = stroke("s1", startMs: 10_000, durationMs: 3000)
        let s2 = stroke("s2", startMs: 12_000, durationMs: 2000)
        let busy = Fixtures.note("busy", atMs: 11_000, lat: -25)
        let report = BeatmapValidator.validate(Fixtures.map(notes: [busy], strokes: [s1, s2]), tuning: tuning)
        #expect(report.errors.contains { $0.code == "stroke.overlap" && $0.itemID == "s2" })
        #expect(report.warnings.contains { $0.code == "note.duringStroke" && $0.itemID == "busy" })
    }

    @Test func emptyAudioFileName() {
        var map = Fixtures.map()
        map.audio = .file("  ")
        #expect(codes(map).contains("audio.file"))
    }
}
