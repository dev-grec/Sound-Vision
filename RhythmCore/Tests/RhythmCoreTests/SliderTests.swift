import Foundation
import Testing
@testable import RhythmCore

/// A slider note at 4000 ms: head straight ahead, 30° to the right over 1000 ms.
private func sliderNote(_ id: String = "s", atMs ms: Double = 4000, lat: Double = 0, lon: Double = 0,
                        direction: CardinalDirection = .right, lengthDeg: Double = 30, durationMs: Double = 1000) -> TapNote {
    let head = SurfacePoint(lat: lat, lon: lon)
    return TapNote(id: id, timeMs: ms, at: head,
                   slider: .cardinal(from: head, direction: direction, lengthDeg: lengthDeg, durationMs: durationMs))
}

/// Drag events following a note's slider ball from `fromFraction` to `toFraction`, offset north by `offLat`.
private func follow(_ note: TapNote, from: Double = 0, to: Double = 1, offLat: Double = 0, hz: Double = 60) -> [InputEvent] {
    guard let slider = note.slider else { return [] }
    var events: [InputEvent] = []
    var t = from * slider.durationMs
    while t <= to * slider.durationMs {
        let p = note.sliderBallPoint(atMs: note.timeMs + t)!
        events.append(.dragChanged(point: SurfacePoint(lat: p.lat + offLat, lon: p.lon), atMs: note.timeMs + t))
        t += 1000 / hz
    }
    return events
}

@Suite struct SliderModelTests {
    @Test func cardinalSliders() {
        let head = SurfacePoint(lat: 10, lon: -20)
        #expect(Slider.cardinal(from: head, direction: .up, lengthDeg: 25, durationMs: 500).path == [SurfacePoint(lat: 35, lon: -20)])
        #expect(Slider.cardinal(from: head, direction: .left, lengthDeg: 25, durationMs: 500).path == [SurfacePoint(lat: 10, lon: -45)])
        #expect(Slider.cardinal(from: head, direction: .down, lengthDeg: 5, durationMs: 500).path == [SurfacePoint(lat: 5, lon: -20)])
        #expect(Slider.cardinal(from: head, direction: .right, lengthDeg: 5, durationMs: 500).path == [SurfacePoint(lat: 10, lon: -15)])
    }

    @Test func ballTravelsThePathOverTheDuration() {
        let note = sliderNote()
        #expect(note.endMs == 5000)
        #expect(approxEqual(note.sliderBallPoint(atMs: 3000)!.lon, 0))      // waits at the head before the hit time
        #expect(approxEqual(note.sliderBallPoint(atMs: 4500)!.lon, 15))     // halfway
        #expect(approxEqual(note.sliderBallPoint(atMs: 6000)!.lon, 30))     // stays at the end
        #expect(TapNote(id: "t", timeMs: 1, at: SurfacePoint(lat: 0, lon: 0)).sliderBallPoint(atMs: 1) == nil)
    }

    @Test func sliderRoundTripsAndPlainNotesOmitIt() throws {
        let map = Fixtures.map(notes: [sliderNote(), Fixtures.note("plain", atMs: 8000)])
        let data = try BeatmapLoader.encode(map)
        #expect(try BeatmapLoader.decode(data) == map)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.components(separatedBy: "\"slider\"").count == 2) // only the slider note has the key
    }

}

@Suite struct SliderValidatorTests {
    let tuning = Tuning()

    func codes(_ notes: [TapNote]) -> Set<String> {
        Set(BeatmapValidator.validate(Fixtures.map(notes: notes), tuning: tuning).issues.map(\.code))
    }

    @Test func cleanSlider() {
        let report = BeatmapValidator.validate(Fixtures.map(notes: [sliderNote()]), tuning: tuning)
        #expect(report.issues.isEmpty, "\(report.issues)")
    }

    @Test func sliderRules() {
        #expect(codes([sliderNote(lon: 20, lengthDeg: 40)]).contains("slider.outsideZone"))          // ends 60° right
        #expect(codes([sliderNote(lengthDeg: 40, durationMs: 500)]).contains("slider.tooFast"))      // 80°/s
        #expect(codes([TapNote(id: "z", timeMs: 4000, at: .init(lat: 0, lon: 0), slider: .init(durationMs: 0, path: [.init(lat: 0, lon: 10)]))]).contains("slider.duration"))
        #expect(codes([TapNote(id: "e", timeMs: 4000, at: .init(lat: 0, lon: 0), slider: .init(durationMs: 500, path: []))]).contains("slider.path"))
        #expect(codes([sliderNote(atMs: 59_500)]).contains("slider.afterEnd"))
    }

    @Test func overlappingSlidersAndNotesDuringSliders() {
        let a = sliderNote("a", atMs: 4000, lat: 20, lon: -30, durationMs: 2000)
        let b = sliderNote("b", atMs: 5000, lat: -25, lon: -30, durationMs: 1000)
        let c = codes([a, b])
        #expect(c.contains("slider.overlap"))
        #expect(c.contains("note.duringSlider"))
    }

    @Test func crowdingChecksTheWholePath() {
        // The slider ends 30° to the right; a note popping up near its end while it's on screen is crowded,
        // even though it's 30° from the head.
        let slider = sliderNote(durationMs: 1000)
        let near = Fixtures.note("near", atMs: 6000, lat: 5, lon: 30) // pops up at 4500, slider on screen until 5170
        #expect(BeatmapValidator.validate(Fixtures.map(notes: [slider, near]), tuning: tuning).errors.contains { $0.code == "targets.crowded" })
    }
}

@Suite struct RandomSliderTests {
    let tuning = Tuning()

    func testMap() throws -> Beatmap {
        try BeatmapLoader.load(contentsOf: Fixtures.mapsDirectory.appendingPathComponent("test-metronome/beatmap.json"))
    }

    @Test func sameSeedSameSliders() throws {
        let map = try testMap()
        let a = RandomSliders.add(to: map, tuning: tuning, seed: 42)
        let b = RandomSliders.add(to: map, tuning: tuning, seed: 42)
        #expect(a.beatmap == b.beatmap)
        #expect(!a.added.isEmpty)
    }

    @Test(arguments: [1, 2, 3, 7, 42, 1234, 99_999] as [UInt64])
    func generatedMapsAreCleanCardinalAndPlayable(seed: UInt64) throws {
        let map = try testMap()
        let result = RandomSliders.add(to: map, tuning: tuning, seed: seed)
        let report = BeatmapValidator.validate(result.beatmap, tuning: tuning)
        #expect(report.issues.isEmpty, "seed \(seed): \(report.issues)")
        for note in result.beatmap.notes {
            guard let slider = note.slider, let end = slider.path.first else { continue }
            #expect(slider.path.count == 1)
            let horizontal = end.lat == note.at.lat, vertical = end.lon == note.at.lon
            #expect(horizontal != vertical, "\(note.id) is not cardinal")
            #expect(tuning.randomSliderBeats.contains(slider.durationMs / 500))
        }
        // And autoplay still plays every note perfectly.
        var session = GameSession(beatmap: result.beatmap, tuning: tuning)
        var input = ScriptedInputSource.autoplay(for: result.beatmap, tuning: tuning)
        var now = 0.0
        while !session.isFinished(nowMs: now) {
            now += 11.1
            _ = session.advance(nowMs: now, inputs: input.pollEvents(nowMs: now))
        }
        #expect(session.score.count(.perfect) == map.notes.count)
    }

    @Test func differentSeedsDiffer() throws {
        let map = try testMap()
        #expect(RandomSliders.add(to: map, tuning: tuning, seed: 1).beatmap != RandomSliders.add(to: map, tuning: tuning, seed: 2).beatmap)
    }

    @Test func zeroChanceAddsNothingAndExistingSlidersAreKept() throws {
        var t = Tuning()
        t.randomSliderChance = 0
        let map = try testMap()
        #expect(RandomSliders.add(to: map, tuning: t, seed: 5).added.isEmpty)
        var withSlider = map
        withSlider.notes[0].slider = .cardinal(from: withSlider.notes[0].at, direction: .down, lengthDeg: 10, durationMs: 500)
        t.randomSliderChance = 1
        let result = RandomSliders.add(to: withSlider, tuning: t, seed: 5)
        #expect(result.beatmap.notes[0].slider == withSlider.notes[0].slider)
        #expect(!result.added.contains(withSlider.notes[0].id))
    }
}

@Suite struct DragTrackerTests {
    @Test func unknownAnchorOffsetCancelsOut() throws {
        // The object really sits 1.5 m up and 1 m ahead (hidden from the app). The player pinches a note
        // at view (15, -35) and drags 30° worth of arc to the right.
        let shape = SphereShape(radiusM: 0.3)
        let hidden = SIMD3<Double>(0.2, 1.5, -1.0)
        let head = SurfacePoint(lat: 15, lon: -35)
        let target = SurfacePoint(lat: 15, lon: -5)
        let tracker = DragTracker(startScene: hidden + shape.position(of: head), startPlacement: shape.position(of: head))
        let p = try #require(tracker.viewPoint(forScene: hidden + shape.position(of: target), shape: shape))
        #expect(p.angularDistanceDeg(to: target) < 1e-9)
        // The start maps back to the head itself.
        #expect(try #require(tracker.viewPoint(forScene: tracker.startScene, shape: shape)).angularDistanceDeg(to: head) < 1e-9)
    }

    @Test func handOffTheSurfaceStillProjects() throws {
        // Hand 10 cm closer to the player than the surface: still maps to the same direction-ish point.
        let shape = SphereShape(radiusM: 0.3)
        let head = SurfacePoint(lat: 0, lon: 0)
        let tracker = DragTracker(startScene: [0, 0, 0], startPlacement: shape.position(of: head))
        let p = try #require(tracker.viewPoint(forScene: [0.1, 0, 0.1], shape: shape))
        #expect(p.lon > 10 && p.lon < 25 && abs(p.lat) < 1e-9)
    }
}

@Suite struct ClosestPointTests {
    @Test func projectsOntoStraightPath() {
        let path = StrokePath(points: [SurfacePoint(lat: 0, lon: 0), SurfacePoint(lat: 0, lon: 40)])
        let mid = path.closest(to: SurfacePoint(lat: 5, lon: 10))
        #expect(approxEqual(mid.fraction, 0.25, tolerance: 0.01))
        #expect(approxEqual(mid.distanceDeg, 5, tolerance: 0.05))
        #expect(path.closest(to: SurfacePoint(lat: 0, lon: 60)).fraction == 1)  // beyond the end → the end
        #expect(path.closest(to: SurfacePoint(lat: 0, lon: -20)).fraction == 0) // before the start → the start
    }

    @Test func projectsOntoBentPath() {
        let path = StrokePath(points: [SurfacePoint(lat: 0, lon: 0), SurfacePoint(lat: 0, lon: 20), SurfacePoint(lat: 20, lon: 20)])
        let c = path.closest(to: SurfacePoint(lat: 10, lon: 22))
        #expect(approxEqual(c.fraction, 0.75, tolerance: 0.01))
    }
}

@Suite struct SliderProgressTests {
    let tuning = Tuning()

    @Test func knobFollowsTheDragAndNeverGoesBack() {
        var p = SliderProgress(note: sliderNote())              // right 30° from (0,0)
        p.add(SurfacePoint(lat: 3, lon: 15), atMs: 4500, tuning: tuning)
        #expect(approxEqual(p.progress, 0.5, tolerance: 0.01) && p.onTrack)
        p.add(SurfacePoint(lat: 0, lon: 6), atMs: 4600, tuning: tuning)  // dragging back doesn't rewind
        #expect(approxEqual(p.progress, 0.5, tolerance: 0.01))
        p.add(SurfacePoint(lat: 30, lon: 25), atMs: 4700, tuning: tuning) // far off the track: lost, knob stays
        #expect(!p.onTrack && approxEqual(p.progress, 0.5, tolerance: 0.01))
    }

    @Test func finishesWithinTheEndTolerance() {
        var p = SliderProgress(note: sliderNote())
        let notYet = p.add(SurfacePoint(lat: 0, lon: 28), atMs: 4900, tuning: tuning)
        let done = p.add(SurfacePoint(lat: 0, lon: 28.6), atMs: 4950, tuning: tuning)
        #expect(!notYet && done)
        #expect(p.finishedAtMs == 4950 && p.progress == 1)
    }

    @Test(arguments: [(0.0, Judgment.perfect), (100, .perfect), (-100, .perfect), (150, .great), (-250, .good)])
    func finishWindows(delta: Double, expected: Judgment) {
        #expect(SliderProgress.finishJudgment(deltaMs: delta, tuning: tuning) == expected)
    }

    @Test func outsideTheWindowIsNoJudgment() {
        #expect(SliderProgress.finishJudgment(deltaMs: -261, tuning: tuning) == nil)
    }

    @Test func finalJudgmentIsTheWorseOfHeadAndFinish() {
        #expect(GameSession.sliderJudgment(head: .perfect, finishDeltaMs: 20, tuning: tuning) == .perfect)
        #expect(GameSession.sliderJudgment(head: .great, finishDeltaMs: 20, tuning: tuning) == .great)
        #expect(GameSession.sliderJudgment(head: .perfect, finishDeltaMs: -200, tuning: tuning) == .good)
        #expect(GameSession.sliderJudgment(head: .perfect, finishDeltaMs: -400, tuning: tuning) == .miss)
        #expect(GameSession.sliderJudgment(head: .perfect, finishDeltaMs: nil, tuning: tuning) == .miss)
    }
}

@Suite struct SliderSessionTests {
    let tuning = Tuning()

    func session(_ notes: [TapNote]) -> GameSession {
        GameSession(beatmap: Fixtures.map(notes: notes), tuning: tuning)
    }

    /// Drag samples along the track at the slider's own pace, scaled: pace 2 = twice as fast.
    func drag(_ note: TapNote, pace: Double = 1, until fraction: Double = 1) -> [InputEvent] {
        let slider = note.slider!
        let path = note.sliderPath!
        var events: [InputEvent] = []
        var f = 0.0
        while f <= fraction + 1e-9 {
            events.append(.dragChanged(point: path.point(atFraction: f), atMs: note.timeMs + f * slider.durationMs / pace))
            f += 0.02
        }
        return events
    }

    @Test func ownersCase_perfectHeadFollowAllTheWayReleaseAtEnd_isPerfect() {
        let note = sliderNote()
        var s = session([note])
        let start = s.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "s", point: note.at, atMs: 4000)])
        #expect(start == [.sliderStarted(noteID: "s", head: .perfect, deltaMs: 0)])
        let events = s.advance(nowMs: 5000, inputs: drag(note))
        guard case .sliderEnded(_, .perfect, let finish?, 1)? = events.last else { Issue.record("\(events)"); return }
        #expect(abs(finish) <= tuning.sliderEndPerfectWindowMs)
        // Letting go afterward changes nothing.
        #expect(s.advance(nowMs: 5050, inputs: [.dragEnded(point: nil, atMs: 5050)]).isEmpty)
        #expect(s.score.count(.perfect) == 1)
    }

    @Test func finishingTooFastIsEarly() {
        let note = sliderNote(durationMs: 1000)
        var s = session([note])
        _ = s.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "s", point: note.at, atMs: 4000)])
        let events = s.advance(nowMs: 4500, inputs: drag(note, pace: 2.5)) // done in ~400 ms instead of 1000
        guard case .sliderEnded(_, .miss, let finish?, 0)? = events.last else { Issue.record("\(events)"); return }
        #expect(finish < -tuning.sliderEndGoodWindowMs)
    }

    @Test func slightlyFastIsGreat() {
        let note = sliderNote(durationMs: 1000)
        var s = session([note])
        _ = s.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "s", point: note.at, atMs: 4000)])
        let events = s.advance(nowMs: 5000, inputs: drag(note, pace: 1.17)) // ~150 ms early
        guard case .sliderEnded(_, .great, _, _)? = events.last else { Issue.record("\(events)"); return }
    }

    @Test func notFinishingInTimeIsAMiss() {
        let note = sliderNote()
        var s = session([note])
        _ = s.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "s", point: note.at, atMs: 4000)])
        _ = s.advance(nowMs: 5000, inputs: drag(note, pace: 0.5, until: 0.5)) // only halfway by 5000
        let closes = 5000 + tuning.sliderEndGoodWindowMs + tuning.inputDeliveryGraceMs
        #expect(s.advance(nowMs: closes, inputs: []).isEmpty)                // Good window plus delivery grace
        let events = s.advance(nowMs: closes + 1, inputs: [])
        #expect(events == [.sliderEnded(noteID: "s", judgment: .miss, finishDeltaMs: nil, combo: 0)])
    }

    @Test func lettingGoBeforeTheEndBreaksTheSlider() {
        let note = sliderNote()
        var s = session([note])
        _ = s.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "s", point: note.at, atMs: 4000)])
        _ = s.advance(nowMs: 4500, inputs: drag(note, until: 0.5))
        let events = s.advance(nowMs: 4510, inputs: [.dragEnded(point: nil, atMs: 4510)])
        #expect(events == [.sliderEnded(noteID: "s", judgment: .miss, finishDeltaMs: nil, combo: 0)])
    }

    @Test func greatHeadCapsTheSliderAtGreat() {
        let note = sliderNote()
        var s = session([note])
        _ = s.advance(nowMs: 4090, inputs: [.dragBegan(targetID: "s", point: note.at, atMs: 4090)]) // head 90 ms late
        let events = s.advance(nowMs: 5000, inputs: drag(note))
        guard case .sliderEnded(_, .great, _, _)? = events.last else { Issue.record("\(events)"); return }
    }

    @Test func earlyHeadEndsTheSliderAsEarly() {
        var s = session([sliderNote()])
        let events = s.advance(nowMs: 3600, inputs: [.dragBegan(targetID: "s", point: nil, atMs: 3600)])
        #expect(events == [.judged(noteID: "s", judgment: .miss, deltaMs: -400, combo: 0)])
        #expect(s.activeSliderIndex == nil)
    }

    @Test func hittingTheNextSliderWhileOneIsHeldReportsTheFirstOnesEnd() {
        // Slider b starts where a ends (a valid map). The player is still holding a, short of its end,
        // when b's head is pinched: a breaks, and its end must be reported (popup, timer result, log).
        let a = sliderNote("a", atMs: 4000, lat: 10, lon: -30)
        let b = sliderNote("b", atMs: 5000, lat: -10, lon: 10)
        var s = session([a, b])
        _ = s.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "a", point: a.at, atMs: 4000)])
        _ = s.advance(nowMs: 4500, inputs: drag(a, until: 0.5))
        let events = s.advance(nowMs: 4960, inputs: [.dragBegan(targetID: "b", point: b.at, atMs: 4960)])
        #expect(events == [
            .sliderEnded(noteID: "a", judgment: .miss, finishDeltaMs: nil, combo: 0),
            .sliderStarted(noteID: "b", head: .perfect, deltaMs: -40),
        ])
        #expect(s.state(ofNote: "a") == .missed(atMs: 4960, deltaMs: nil))
        #expect(s.activeSliderIndex == 1)
    }

    @Test func secondGestureForTheSamePinchIsIgnored() {
        let note = sliderNote()
        var s = session([note])
        _ = s.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "s", point: note.at, atMs: 4000)])
        #expect(s.advance(nowMs: 4080, inputs: [.tap(targetID: "s", atMs: 4080)]) == [.ignored(targetID: "s", reason: .alreadyJudged)])
        var p = session([Fixtures.note("n", atMs: 4000)])
        _ = p.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "n", point: nil, atMs: 4000)])
        #expect(p.advance(nowMs: 4080, inputs: [.tap(targetID: "n", atMs: 4080)]) == [.ignored(targetID: "n", reason: .alreadyJudged)])
        #expect(p.score.count(.perfect) == 1)
    }

    @Test func knobStateIsExposedForDrawing() {
        let note = sliderNote()
        var s = session([note])
        _ = s.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "s", point: note.at, atMs: 4000)])
        _ = s.advance(nowMs: 4500, inputs: [.dragChanged(point: SurfacePoint(lat: 0, lon: 15), atMs: 4500)])
        #expect(approxEqual(s.sliderProgress(ofNote: 0)!.knobPoint.lon, 15, tolerance: 0.01))
    }

    @Test func autoplayPlaysSlidersPerfectly() {
        let notes = [Fixtures.note("a", atMs: 4000, lon: -30), sliderNote("b", atMs: 6000, lat: 10, lon: -20),
                     sliderNote("c", atMs: 9000, lat: -10, lon: 20, direction: .up, lengthDeg: 25, durationMs: 750),
                     Fixtures.note("d", atMs: 12000)]
        let map = Fixtures.map(notes: notes)
        var s = GameSession(beatmap: map, tuning: tuning)
        var input = ScriptedInputSource.autoplay(for: map, tuning: tuning)
        var now = 0.0
        while !s.isFinished(nowMs: now) {
            now += 11.1
            _ = s.advance(nowMs: now, inputs: input.pollEvents(nowMs: now))
        }
        #expect(s.score.count(.perfect) == 4)
    }
}
