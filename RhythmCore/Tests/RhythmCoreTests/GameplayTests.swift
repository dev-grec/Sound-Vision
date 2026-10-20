import Foundation
import Testing
@testable import RhythmCore

@Suite struct TapJudgeTests {
    let tuning = Tuning()

    @Test(arguments: [
        (0.0, Judgment.perfect), (60, .perfect), (-60, .perfect),
        (60.01, .great), (-110, .great),
        (110.01, .good), (170, .good), (-170, .good),
    ])
    func tiers(delta: Double, expected: Judgment) {
        #expect(TapJudge.judgment(forDeltaMs: delta, tuning: tuning) == expected)
    }

    @Test func outsideGoodWindowIsIgnoredNotMissed() {
        #expect(TapJudge.judgment(forDeltaMs: 170.01, tuning: tuning) == nil)
        #expect(TapJudge.judgment(forDeltaMs: -400, tuning: tuning) == nil)
    }

    @Test func inputOffsetIsSubtracted() {
        var t = Tuning()
        t.inputOffsetMs = 80 // pinches register 80 ms late
        #expect(TapJudge.delta(inputMs: 1080, targetMs: 1000, tuning: t) == 0)
        #expect(TapJudge.delta(inputMs: 1000, targetMs: 1000, tuning: t) == -80)
    }

    @Test func windowsAreConfigurable() {
        var t = Tuning()
        t.perfectWindowMs = 20
        #expect(TapJudge.judgment(forDeltaMs: 30, tuning: t) == .great)
    }
}

@Suite struct ScoreKeeperTests {
    let tuning = Tuning()

    @Test func comboAndMaxCombo() {
        var s = ScoreKeeper()
        for j in [Judgment.perfect, .great, .good, .miss, .perfect, .perfect] { s.record(j, tuning: tuning) }
        #expect(s.combo == 2)
        #expect(s.maxCombo == 3)
        #expect(s.count(.perfect) == 3 && s.count(.miss) == 1)
        #expect(s.judgedCount == 6)
    }

    @Test func scoreAndAccuracy() {
        var s = ScoreKeeper()
        #expect(s.accuracy == 1)
        s.record(.perfect, tuning: tuning)
        s.record(.great, tuning: tuning)
        s.record(.good, tuning: tuning)
        s.record(.miss, tuning: tuning)
        #expect(s.score == 300 + 200 + 100)
        #expect(approxEqual(s.accuracy, (1.0 + 0.7 + 0.4 + 0) / 4))
    }
}

@Suite struct GameSessionTests {
    let tuning = Tuning()

    func makeSession(_ notes: [TapNote], tuning: Tuning? = nil) -> GameSession {
        GameSession(beatmap: Fixtures.map(notes: notes), tuning: tuning ?? self.tuning)
    }

    @Test func notesAreSortedByTime() {
        let s = makeSession([Fixtures.note("b", atMs: 6000), Fixtures.note("a", atMs: 4000)])
        #expect(s.notes.map(\.id) == ["a", "b"])
    }

    @Test func onTimeTapIsPerfect() {
        var s = makeSession([Fixtures.note("n1", atMs: 4000)])
        let events = s.advance(nowMs: 4010, inputs: [.tap(targetID: "n1", atMs: 4005)])
        #expect(events == [.judged(noteID: "n1", judgment: .perfect, deltaMs: 5, combo: 1)])
        #expect(s.state(ofNote: "n1") == .hit(.perfect, deltaMs: 5, atMs: 4005))
    }

    @Test func lateTapIsGreat() {
        var s = makeSession([Fixtures.note("n1", atMs: 4000)])
        let events = s.advance(nowMs: 4100, inputs: [.tap(targetID: "n1", atMs: 4090)])
        #expect(events.first == .judged(noteID: "n1", judgment: .great, deltaMs: 90, combo: 1))
    }

    @Test func earlyTapEndsTheNoteAsAMiss() {
        // Owner's rule: a pinch on a visible note always ends it. Too early = Miss (shown as "Early").
        var s = makeSession([Fixtures.note("a", atMs: 4000), Fixtures.note("b", atMs: 6000, lon: 30)])
        _ = s.advance(nowMs: 3000, inputs: [.tap(targetID: "a", atMs: 3000)]) // a is 1 s early; still counts... as a miss
        #expect(s.state(ofNote: "a") == .missed(atMs: 3000, deltaMs: -1000))
        #expect(s.score.count(.miss) == 1)
        let tooSoon = s.advance(nowMs: 4300, inputs: [.tap(targetID: "b", atMs: 4300)]) // 1.7 s early: b not popped up
        #expect(tooSoon == [.ignored(targetID: "b", reason: .notYetVisible)])
        let early = s.advance(nowMs: 5700, inputs: [.tap(targetID: "b", atMs: 5700)])
        #expect(early == [.judged(noteID: "b", judgment: .miss, deltaMs: -300, combo: 0)])
        #expect(s.allNotesJudged)
    }

    @Test func comboBreaksOnEarlyTap() {
        var s = makeSession([Fixtures.note("a", atMs: 4000), Fixtures.note("b", atMs: 6000, lon: 30)])
        _ = s.advance(nowMs: 4000, inputs: [.tap(targetID: "a", atMs: 4000)])
        #expect(s.score.combo == 1)
        _ = s.advance(nowMs: 5600, inputs: [.tap(targetID: "b", atMs: 5600)])
        #expect(s.score.combo == 0)
    }

    @Test func tapOutsideHitZoneIsIgnored() {
        // A note placed outside the play area (the validator rejects such maps) is never hittable.
        let misplaced = TapNote(id: "n1", timeMs: 4000, at: SurfacePoint(lat: 0, lon: 90))
        var s = makeSession([misplaced])
        let events = s.advance(nowMs: 4000, inputs: [.tap(targetID: "n1", atMs: 4000)])
        #expect(events == [.ignored(targetID: "n1", reason: .outsideHitZone)])
    }

    @Test func unknownAndMissingTargetsAreIgnored() {
        var s = makeSession([Fixtures.note("n1", atMs: 4000)])
        let events = s.advance(nowMs: 4000, inputs: [.tap(targetID: "nope", atMs: 4000), .tap(targetID: nil, atMs: 4000)])
        #expect(events == [
            .ignored(targetID: "nope", reason: .unknownTarget),
            .ignored(targetID: nil, reason: .unknownTarget),
        ])
    }

    @Test func unhitNoteBecomesMissAfterWindow() {
        var s = makeSession([Fixtures.note("n1", atMs: 4000), Fixtures.note("n2", atMs: 6000)])
        #expect(s.advance(nowMs: 4170, inputs: []).isEmpty) // window still open (exactly at its edge)
        let events = s.advance(nowMs: 4171, inputs: [])
        #expect(events == [.judged(noteID: "n1", judgment: .miss, deltaMs: nil, combo: 0)])
        #expect(s.state(ofNote: "n1") == .missed(atMs: 4171, deltaMs: nil))
        #expect(s.state(ofNote: "n2") == .pending)
        // A late tap after the miss is ignored.
        let late = s.advance(nowMs: 4200, inputs: [.tap(targetID: "n1", atMs: 4200)])
        #expect(late == [.ignored(targetID: "n1", reason: .alreadyJudged)])
    }

    @Test func inputsBeforeWindowClosesCountEvenIfDeliveredLate() {
        var s = makeSession([Fixtures.note("n1", atMs: 4000)])
        // The tap arrived at 4160 but the frame that delivers it runs at 4190, after the window closed.
        let events = s.advance(nowMs: 4190, inputs: [.tap(targetID: "n1", atMs: 4160)])
        #expect(events == [.judged(noteID: "n1", judgment: .good, deltaMs: 160, combo: 1)])
    }

    @Test func missBreaksCombo() {
        var s = makeSession([Fixtures.note("a", atMs: 4000), Fixtures.note("b", atMs: 6000), Fixtures.note("c", atMs: 8000)])
        _ = s.advance(nowMs: 4000, inputs: [.tap(targetID: "a", atMs: 4000)])
        _ = s.advance(nowMs: 7000, inputs: []) // b missed
        let events = s.advance(nowMs: 8000, inputs: [.tap(targetID: "c", atMs: 8000)])
        #expect(events == [.judged(noteID: "c", judgment: .perfect, deltaMs: 0, combo: 1)])
        #expect(s.score.maxCombo == 1)
        #expect(s.score.count(.miss) == 1)
    }

    @Test func inputOffsetShiftsJudgingAndMisses() {
        var t = Tuning()
        t.inputOffsetMs = 100
        var s = makeSession([Fixtures.note("n1", atMs: 4000)], tuning: t)
        // With +100 ms offset the window closes at 4000 + 170 + 100 on the raw clock.
        #expect(s.advance(nowMs: 4250, inputs: []).isEmpty)
        let events = s.advance(nowMs: 4260, inputs: [.tap(targetID: "n1", atMs: 4100)])
        #expect(events == [.judged(noteID: "n1", judgment: .perfect, deltaMs: 0, combo: 1)])
    }

    @Test func dragsAreNotPlayedYet() {
        var s = makeSession([Fixtures.note("n1", atMs: 4000)])
        let events = s.handle(.dragBegan(targetID: "s1", point: nil, atMs: 4000))
        #expect(events == [.ignored(targetID: "s1", reason: .unsupportedInput)])
    }

    @Test func finishesAfterLastNoteAndSongEnd() {
        let map = Fixtures.map(notes: [Fixtures.note("n1", atMs: 4000)], bars: 4) // song is 8000 ms
        var s = GameSession(beatmap: map, tuning: tuning)
        #expect(s.endMs == 8000)
        _ = s.advance(nowMs: 4000, inputs: [.tap(targetID: "n1", atMs: 4000)])
        #expect(s.allNotesJudged)
        #expect(!s.isFinished(nowMs: 7999))
        #expect(s.isFinished(nowMs: 8000))
        #expect(s.progress == 1)
    }

    @Test func autoplayHitsEverythingPerfectly() {
        var t = Tuning()
        t.inputOffsetMs = 40
        let notes = (0..<10).map { Fixtures.note("n\($0)", atMs: 4000 + Double($0) * 1500, lat: $0.isMultiple(of: 2) ? 12 : -12) }
        let map = Fixtures.map(notes: notes)
        var session = GameSession(beatmap: map, tuning: t)
        var input = ScriptedInputSource.autoplay(for: map, tuning: t)
        // Drive at an uneven ~90 fps frame rate; results must not depend on frame timing.
        var now = 0.0
        while !session.isFinished(nowMs: now) {
            now += 11.1
            _ = session.advance(nowMs: now, inputs: input.pollEvents(nowMs: now))
        }
        #expect(session.score.count(.perfect) == 10)
        #expect(session.score.maxCombo == 10)
        #expect(input.isEmpty)
    }

    @Test func jitteredAutoplayGivesGreats() {
        let notes = [Fixtures.note("a", atMs: 4000), Fixtures.note("b", atMs: 6000)]
        let map = Fixtures.map(notes: notes)
        var session = GameSession(beatmap: map, tuning: tuning)
        var input = ScriptedInputSource.autoplay(for: map, tuning: tuning, jitterMs: 90)
        _ = session.advance(nowMs: 10_000, inputs: input.pollEvents(nowMs: 10_000))
        #expect(session.score.count(.great) == 2)
    }
}

@Suite struct ScriptedInputTests {
    @Test func releasesEventsInTimeOrderOnce() {
        var src = ScriptedInputSource(events: [
            .tap(targetID: "b", atMs: 200), .tap(targetID: "a", atMs: 100), .tap(targetID: "c", atMs: 300),
        ])
        #expect(src.pollEvents(nowMs: 50).isEmpty)
        #expect(src.pollEvents(nowMs: 200) == [.tap(targetID: "a", atMs: 100), .tap(targetID: "b", atMs: 200)])
        #expect(src.pollEvents(nowMs: 250).isEmpty)
        #expect(src.pollEvents(nowMs: 1000) == [.tap(targetID: "c", atMs: 300)])
        #expect(src.isEmpty)
    }
}

/// Notes exist only from their pop-up (hidden and untargetable before). DECISIONS D16.
@Suite struct PopUpTests {
    @Test func noteIsHiddenUntilItPopsUp() {
        let session = GameSession(beatmap: Fixtures.map(notes: [Fixtures.note("n", atMs: 40_000)]), tuning: Tuning())
        #expect(!session.hasAppeared(0, atMs: 10_000))
        #expect(!session.hasAppeared(0, atMs: 38_499))
        #expect(session.hasAppeared(0, atMs: 38_500))
    }

    @Test func appearanceRespectsInputOffset() {
        var t = Tuning()
        t.inputOffsetMs = 100
        let session = GameSession(beatmap: Fixtures.map(notes: [Fixtures.note("n", atMs: 10_000)]), tuning: t)
        #expect(!session.hasAppeared(0, atMs: 8_599))
        #expect(session.hasAppeared(0, atMs: 8_600))
    }
}
