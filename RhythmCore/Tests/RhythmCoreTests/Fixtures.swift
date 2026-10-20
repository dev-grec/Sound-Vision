import Foundation
@testable import RhythmCore

/// Shared builders for tests.
enum Fixtures {
    /// 120 BPM, rotating 6°/beat about +Y (12°/s): the front of the object at time t is longitude
    /// -0.012 * t degrees. `frontLon(atMs:)` gives the longitude that faces the player at t.
    static let bpm = 120.0
    static let degreesPerBeat = 6.0

    static func frontLon(atMs ms: Double, offsetMs: Double = 0) -> Double {
        let beat = (ms - offsetMs) / (60_000 / bpm)
        var lon = -(beat * degreesPerBeat).truncatingRemainder(dividingBy: 360)
        if lon <= -180 { lon += 360 }
        if lon > 180 { lon -= 360 }
        return lon
    }

    /// The point on the rotating surface that faces the player at time `ms` (shifted by `lat`).
    static func frontPoint(atMs ms: Double, lat: Double = 0) -> SurfacePoint {
        SurfacePoint(lat: lat, lon: frontLon(atMs: ms))
    }

    /// A tap note at a fixed spot in the player's view (default: straight ahead).
    static func note(_ id: String, atMs ms: Double, lat: Double = 0, lon: Double = 0) -> TapNote {
        TapNote(id: id, timeMs: ms, at: SurfacePoint(lat: lat, lon: lon))
    }

    static func map(
        notes: [TapNote] = [],
        strokes: [Stroke] = [],
        rotation: [RotationSegment] = [RotationSegment(startBeat: 0, axis: [0, 1, 0], degreesPerBeat: degreesPerBeat)],
        bars: Int = 30
    ) -> Beatmap {
        Beatmap(
            meta: .init(title: "Fixture"),
            audio: .generatedClick(.init(beatsPerBar: 4, bars: bars)),
            timing: .init(bpm: bpm, offsetMs: 0),
            object: .init(shape: .sphere, radiusM: 0.35),
            rotation: rotation,
            notes: notes,
            strokes: strokes
        )
    }

    /// The repo's Maps directory, found relative to this source file.
    static var mapsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RhythmCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // RhythmCore
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Maps")
    }
}

func approxEqual(_ a: Double, _ b: Double, tolerance: Double = 1e-6) -> Bool {
    abs(a - b) <= tolerance
}
