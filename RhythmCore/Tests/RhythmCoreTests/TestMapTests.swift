import Foundation
import Testing
@testable import RhythmCore

/// Checks the maps shipped in the repo's Maps/ folder, so a broken hand edit fails the tests.
@Suite struct ShippedMapTests {
    func load(_ name: String) throws -> Beatmap {
        try BeatmapLoader.load(contentsOf: Fixtures.mapsDirectory.appendingPathComponent(name).appendingPathComponent("beatmap.json"))
    }

    @Test func everyShippedMapValidatesClean() throws {
        let dirs = try FileManager.default.contentsOfDirectory(at: Fixtures.mapsDirectory, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("beatmap.json").path) }
        #expect(!dirs.isEmpty)
        for dir in dirs {
            let map = try load(dir.lastPathComponent)
            let report = BeatmapValidator.validate(map)
            #expect(report.issues.isEmpty, "\(dir.lastPathComponent): \(report.issues)")
        }
    }

    @Test func testMetronomeShape() throws {
        let map = try load("test-metronome")
        #expect(map.audio == .generatedClick(.init(beatsPerBar: 4, bars: 30)))
        #expect(map.definedDurationMs == 60_000)
        #expect(map.notes.count >= 20)
        #expect(map.strokes.count == 2)
    }

    @Test func testMetronomeAutoplaysPerfectly() throws {
        let map = try load("test-metronome")
        let tuning = Tuning()
        var session = GameSession(beatmap: map, tuning: tuning)
        var input = ScriptedInputSource.autoplay(for: map, tuning: tuning)
        var now = -500.0
        while !session.isFinished(nowMs: now) {
            now += 1000.0 / 90
            _ = session.advance(nowMs: now, inputs: input.pollEvents(nowMs: now))
        }
        #expect(session.score.count(.perfect) == map.notes.count)
        #expect(session.score.maxCombo == map.notes.count)
        #expect(now >= 60_000)
    }

    @Test func testMetronomeWithoutInputMissesEverything() throws {
        let map = try load("test-metronome")
        var session = GameSession(beatmap: map, tuning: Tuning())
        _ = session.advance(nowMs: 61_000, inputs: [])
        #expect(session.score.count(.miss) == map.notes.count)
        #expect(session.isFinished(nowMs: 61_000))
    }
}
