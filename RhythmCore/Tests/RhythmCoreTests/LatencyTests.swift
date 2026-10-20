import Foundation
import Testing
@testable import RhythmCore

@Suite struct InputTimestampTests {
    let tuning = Tuning()

    @Test func eventAgeBackdatesTheStamp() {
        let stamp = InputTimestamp.stamp(arrivalMs: 4040, eventAgeMs: 40, tuning: tuning)
        #expect(stamp == InputTimestamp(atMs: 4000, backdatedMs: 40, source: .eventTime))
    }

    @Test func noEventTimeStampsOnArrival() {
        #expect(InputTimestamp.stamp(arrivalMs: 4040, eventAgeMs: nil, tuning: tuning)
            == InputTimestamp(atMs: 4040, backdatedMs: 0, source: .arrival))
    }

    @Test func disabledStampsOnArrival() {
        var t = Tuning()
        t.useInputEventTimestamps = false
        #expect(InputTimestamp.stamp(arrivalMs: 4040, eventAgeMs: 40, tuning: t).source == .arrival)
        #expect(InputTimestamp.stamp(arrivalMs: 4040, eventAgeMs: 40, tuning: t).atMs == 4040)
    }

    @Test func tooOldIsNotTrusted() {
        let stamp = InputTimestamp.stamp(arrivalMs: 4040, eventAgeMs: tuning.maxInputEventAgeMs + 1, tuning: tuning)
        #expect(stamp == InputTimestamp(atMs: 4040, backdatedMs: 0, source: .arrivalEventTooOld))
        // Exactly at the limit is still trusted.
        #expect(InputTimestamp.stamp(arrivalMs: 4040, eventAgeMs: tuning.maxInputEventAgeMs, tuning: tuning).source == .eventTime)
    }

    @Test func slightlyInTheFutureIsClampedToArrival() {
        let stamp = InputTimestamp.stamp(arrivalMs: 4040, eventAgeMs: -2, tuning: tuning)
        #expect(stamp == InputTimestamp(atMs: 4040, backdatedMs: 0, source: .eventTime))
    }

    @Test func farInTheFutureIsNotTrusted() {
        let stamp = InputTimestamp.stamp(arrivalMs: 4040, eventAgeMs: -50, tuning: tuning)
        #expect(stamp == InputTimestamp(atMs: 4040, backdatedMs: 0, source: .arrivalEventInFuture))
    }

    @Test func nonFiniteAgeStampsOnArrival() {
        #expect(InputTimestamp.stamp(arrivalMs: 4040, eventAgeMs: .nan, tuning: tuning).source == .arrival)
    }

    @Test func offsetIsNotAppliedHere() {
        var t = Tuning()
        t.inputOffsetMs = 80
        #expect(InputTimestamp.stamp(arrivalMs: 4040, eventAgeMs: 40, tuning: t).atMs == 4000)
    }

    @Test func backdatedPressJudgesThePinchNotTheCallback() {
        // The pinch happened on the beat; its callback ran 45 ms later.
        var s = GameSession(beatmap: Fixtures.map(notes: [Fixtures.note("n1", atMs: 4000)]), tuning: tuning)
        let stamp = InputTimestamp.stamp(arrivalMs: 4045, eventAgeMs: 45, tuning: tuning)
        let events = s.advance(nowMs: 4045, inputs: [.dragBegan(targetID: "n1", point: nil, atMs: stamp.atMs)])
        #expect(events == [.judged(noteID: "n1", judgment: .perfect, deltaMs: 0, combo: 1)])
    }
}

@Suite struct AudioClockMathTests {
    func read(render: Double, host: Double?, now: Double, latency: Double = 0, cap: Double = 0.03) -> Double {
        AudioClockMath.audibleSeconds(renderSeconds: render, renderHostSeconds: host, nowHostSeconds: now,
                                      outputLatencySeconds: latency, maxInterpolationSeconds: cap)
    }

    @Test func interpolatesForwardFromTheRenderTimestamp() {
        #expect(approxEqual(read(render: 10, host: 100, now: 100.004), 10.004))
    }

    @Test func aRenderTimestampInTheFutureReadsEarlier() {
        // The buffer starting at 10 s reaches the output 5 ms from now, so now is 5 ms before it.
        #expect(approxEqual(read(render: 10, host: 100.005, now: 100), 9.995))
    }

    @Test func consecutiveBuffersGiveTheSameLine() {
        // Two 10 ms buffers on the same timeline read identically at the same host time: no staircase.
        let a = read(render: 10.00, host: 100.00, now: 100.007)
        let b = read(render: 10.01, host: 100.01, now: 100.007)
        #expect(approxEqual(a, b))
    }

    @Test func interpolationIsCappedBothWays() {
        #expect(approxEqual(read(render: 10, host: 100, now: 101), 10.03))
        #expect(approxEqual(read(render: 10, host: 101, now: 100), 9.97))
    }

    @Test func invalidHostTimeMeansNoInterpolation() {
        #expect(approxEqual(read(render: 10, host: nil, now: 123), 10))
    }

    @Test func outputLatencyIsSubtracted() {
        #expect(approxEqual(read(render: 10, host: 100, now: 100.01, latency: 0.02), 9.99))
    }
}

@Suite struct MonotonicReadingTests {
    @Test func neverGoesBackwardAndCountsHeldSteps() {
        var m = MonotonicReading()
        #expect(m.accept(10) == 10)
        #expect(m.accept(8) == 10)
        #expect(m.accept(9.5) == 10)
        #expect(m.accept(12) == 12)
        #expect(m.backwardCount == 2)
        #expect(m.maxBackwardMs == 2)
        #expect(m.readCount == 4)
    }
}
