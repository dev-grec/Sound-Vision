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

    @Test func sliderJudgmentTable() {
        let t = Tuning()
        #expect(GameSession.sliderJudgment(head: .perfect, followScore: 0.9, tuning: t) == .perfect)
        #expect(GameSession.sliderJudgment(head: .perfect, followScore: 0.6, tuning: t) == .great)
        #expect(GameSession.sliderJudgment(head: .great, followScore: 0.6, tuning: t) == .good)
        #expect(GameSession.sliderJudgment(head: .good, followScore: 0.6, tuning: t) == .good)
        #expect(GameSession.sliderJudgment(head: .perfect, followScore: 0.49, tuning: t) == .miss)
    }
}

@Suite struct SliderSessionTests {
    let tuning = Tuning()

    func session(_ notes: [TapNote]) -> GameSession {
        GameSession(beatmap: Fixtures.map(notes: notes), tuning: tuning)
    }

    @Test func perfectHeadAndFollowKeepsPerfect() {
        let note = sliderNote()
        var s = session([note])
        let start = s.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "s", point: note.at, atMs: 4000)])
        #expect(start == [.sliderStarted(noteID: "s", head: .perfect, deltaMs: 0)])
        #expect(s.state(ofNote: "s") == .holding(head: .perfect, deltaMs: 0, atMs: 4000))
        #expect(s.activeSliderIndex == 0)
        #expect(s.score.judgedCount == 0) // not scored until it finishes
        _ = s.advance(nowMs: 5000, inputs: follow(note))
        let end = s.advance(nowMs: 5010, inputs: [.dragEnded(point: note.sliderBallPoint(atMs: 5000), atMs: 5010)])
        #expect(end == [.sliderEnded(noteID: "s", judgment: .perfect, followScore: 1, combo: 1)])
        #expect(s.score.score == tuning.scorePerfect)
        #expect(s.allNotesJudged)
    }

    @Test func sloppyFollowDropsATier() {
        // 14° off the ball: credit 1 - (14 - 8) / 12 = 0.5 → Perfect head drops to Great.
        let note = sliderNote()
        var s = session([note])
        _ = s.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "s", point: note.at, atMs: 4000)])
        _ = s.advance(nowMs: 5000, inputs: follow(note, offLat: 14))
        let end = s.advance(nowMs: 5010, inputs: [.dragEnded(point: nil, atMs: 5010)])
        guard case .sliderEnded(_, let judgment, let score, _) = end.first else { Issue.record("no sliderEnded"); return }
        #expect(approxEqual(score, 0.5, tolerance: 0.02))
        #expect(judgment == .great)
    }

    @Test func lettingGoEarlyBreaksTheSlider() {
        let note = sliderNote()
        var s = session([note])
        _ = s.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "s", point: note.at, atMs: 4000)])
        _ = s.advance(nowMs: 4350, inputs: follow(note, to: 0.35))
        let end = s.advance(nowMs: 4360, inputs: [.dragEnded(point: nil, atMs: 4360)])
        guard case .sliderEnded(_, let judgment, let score, let combo) = end.first else { Issue.record("no sliderEnded"); return }
        #expect(score < 0.5)
        #expect(judgment == .miss && combo == 0)
        #expect(s.state(ofNote: "s") == .missed(atMs: 4360, deltaMs: nil))
    }

    @Test func earlyHeadEndsTheSliderAsEarly() {
        var s = session([sliderNote()])
        let events = s.advance(nowMs: 3600, inputs: [.dragBegan(targetID: "s", point: nil, atMs: 3600)])
        #expect(events == [.judged(noteID: "s", judgment: .miss, deltaMs: -400, combo: 0)])
        #expect(s.activeSliderIndex == nil)
    }

    @Test func heldPastTheEndFinishesOnItsOwn() {
        let note = sliderNote()
        var s = session([note])
        _ = s.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "s", point: note.at, atMs: 4000)])
        _ = s.advance(nowMs: 5000, inputs: follow(note))
        #expect(s.advance(nowMs: 5000, inputs: []).isEmpty) // exactly at the end: still held
        let events = s.advance(nowMs: 5020, inputs: [])
        #expect(events == [.sliderEnded(noteID: "s", judgment: .perfect, followScore: 1, combo: 1)])
        // The late release finds nothing to end.
        #expect(s.advance(nowMs: 5100, inputs: [.dragEnded(point: nil, atMs: 5100)]).isEmpty)
    }

    @Test func tapWithoutDraggingBreaksTheSlider() {
        // A SpatialTap (no drag) hits the head, but the ball is never followed.
        var s = session([sliderNote()])
        #expect(s.advance(nowMs: 4000, inputs: [.tap(targetID: "s", atMs: 4000)]).first == .sliderStarted(noteID: "s", head: .perfect, deltaMs: 0))
        let events = s.advance(nowMs: 5100, inputs: [])
        guard case .sliderEnded(_, .miss, _, _) = events.first else { Issue.record("expected a broken slider, got \(events)"); return }
    }

    @Test func secondGestureForTheSamePinchIsIgnored() {
        // DragGesture reports the press, SpatialTapGesture the release: only the first counts.
        let note = sliderNote()
        var s = session([note])
        _ = s.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "s", point: note.at, atMs: 4000)])
        let events = s.advance(nowMs: 4080, inputs: [.tap(targetID: "s", atMs: 4080)])
        #expect(events == [.ignored(targetID: "s", reason: .alreadyJudged)])
        // Same for a plain note pinched by drag first.
        var p = session([Fixtures.note("n", atMs: 4000)])
        _ = p.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "n", point: nil, atMs: 4000)])
        #expect(p.advance(nowMs: 4080, inputs: [.tap(targetID: "n", atMs: 4080)]) == [.ignored(targetID: "n", reason: .alreadyJudged)])
        #expect(p.score.count(.perfect) == 1)
    }

    @Test func liveFollowCredit() {
        let note = sliderNote()
        var s = session([note])
        _ = s.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "s", point: note.at, atMs: 4000)])
        _ = s.advance(nowMs: 4500, inputs: [.dragChanged(point: SurfacePoint(lat: 30, lon: 15), atMs: 4500)])
        #expect(s.lastFollowCredit(ofNote: 0) == 0)
        _ = s.advance(nowMs: 4600, inputs: [.dragChanged(point: note.sliderBallPoint(atMs: 4600), atMs: 4600)])
        #expect(s.lastFollowCredit(ofNote: 0) == 1)
    }

    @Test func autoplayPlaysSlidersPerfectly() {
        let notes = [Fixtures.note("a", atMs: 4000, lon: -30), sliderNote("b", atMs: 6000, lat: 10, lon: -20),
                     sliderNote("c", atMs: 9000, lat: -10, lon: 20, direction: .up, lengthDeg: 25, durationMs: 1500),
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
        #expect(s.score.maxCombo == 4)
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

@Suite struct SliderReleaseTests {
    let tuning = Tuning()

    @Test func releasingOnTheEndMarkerJustEarlyKeepsPerfect() {
        // Owner's report: Perfect head, followed all the way, let go at the end bubble → must be Perfect.
        let note = sliderNote(durationMs: 500)
        var s = GameSession(beatmap: Fixtures.map(notes: [note]), tuning: tuning)
        _ = s.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "s", point: note.at, atMs: 4000)])
        _ = s.advance(nowMs: 4380, inputs: follow(note, to: 0.76))           // follows until 120 ms before the end
        let end = s.advance(nowMs: 4380, inputs: [.dragEnded(point: note.sliderBallPoint(atMs: 4380), atMs: 4380)])
        #expect(end == [.sliderEnded(noteID: "s", judgment: .perfect, followScore: 1, combo: 1)])
    }

    @Test func releasingWellBeforeTheEndIsNotGraced() {
        let note = sliderNote(durationMs: 1000)
        var s = GameSession(beatmap: Fixtures.map(notes: [note]), tuning: tuning)
        _ = s.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "s", point: note.at, atMs: 4000)])
        _ = s.advance(nowMs: 4600, inputs: follow(note, to: 0.6))
        let end = s.advance(nowMs: 4600, inputs: [.dragEnded(point: nil, atMs: 4600)])
        guard case .sliderEnded(_, let judgment, let score, _) = end.first else { Issue.record("no sliderEnded"); return }
        #expect(approxEqual(score, 0.6, tolerance: 0.051))
        #expect(judgment == .great)
    }

    @Test func graceUsesTheLatestAccuracy() {
        // Drifting at the end (credit 0) gets no free credit.
        let note = sliderNote(durationMs: 500)
        var s = GameSession(beatmap: Fixtures.map(notes: [note]), tuning: tuning)
        _ = s.advance(nowMs: 4000, inputs: [.dragBegan(targetID: "s", point: note.at, atMs: 4000)])
        _ = s.advance(nowMs: 4380, inputs: follow(note, to: 0.76) + [.dragChanged(point: SurfacePoint(lat: 40, lon: 0), atMs: 4380)])
        let end = s.advance(nowMs: 4385, inputs: [.dragEnded(point: nil, atMs: 4385)])
        guard case .sliderEnded(_, _, let score, _) = end.first else { Issue.record("no sliderEnded"); return }
        #expect(score < 0.8)
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
