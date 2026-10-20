import Foundation
import Testing
@testable import RhythmCore

@Suite struct BeatmapDecodingTests {
    let minimal = """
    {
      "formatVersion": 1,
      "meta": { "title": "Mini" },
      "audio": { "generatedClick": { "beatsPerBar": 4, "bars": 8 } },
      "timing": { "bpm": 120, "offsetMs": 0 },
      "object": { "shape": "sphere", "radiusM": 0.35 },
      "rotation": [ { "startBeat": 0, "axis": [0, 1, 0], "degreesPerBeat": 6 } ],
      "notes": [ { "id": "n1", "timeMs": 4000, "at": { "lat": 10, "lon": -48 } } ],
      "strokes": [ { "id": "s1", "startMs": 8000, "durationMs": 2000,
                     "path": [ { "lat": 0, "lon": -96 }, { "lat": 10, "lon": -80 } ], "color": "#FF6A3D" } ]
    }
    """

    @Test func decodesMinimalMap() throws {
        let map = try BeatmapLoader.decode(Data(minimal.utf8))
        #expect(map.meta.title == "Mini")
        #expect(map.audio == .generatedClick(.init(beatsPerBar: 4, bars: 8)))
        #expect(map.timing.bpm == 120)
        #expect(map.notes == [TapNote(id: "n1", timeMs: 4000, at: SurfacePoint(lat: 10, lon: -48))])
        #expect(map.strokes.first?.color == RGBColor(red: 1, green: 0x6A / 255.0, blue: 0x3D / 255.0))
        #expect(map.definedDurationMs == 16_000) // 8 bars * 4 beats * 500 ms
    }

    @Test func notesAndStrokesAreOptional() throws {
        let json = """
        { "formatVersion": 1, "meta": { "title": "Empty" }, "audio": { "file": "song.m4a" },
          "timing": { "bpm": 90, "offsetMs": 120 }, "object": { "shape": "sphere", "radiusM": 0.3 },
          "rotation": [ { "startBeat": 0, "axis": [0, 1, 0], "degreesPerBeat": 4 } ] }
        """
        let map = try BeatmapLoader.decode(Data(json.utf8))
        #expect(map.notes.isEmpty)
        #expect(map.strokes.isEmpty)
        #expect(map.audio == .file("song.m4a"))
        #expect(map.definedDurationMs == nil)
    }

    @Test func roundTripsThroughEncoder() throws {
        let map = try BeatmapLoader.decode(Data(minimal.utf8))
        let again = try BeatmapLoader.decode(try BeatmapLoader.encode(map))
        #expect(again == map)
    }

    @Test func rejectsMissingVersion() {
        #expect(throws: BeatmapError.missingFormatVersion) {
            try BeatmapLoader.decode(Data(#"{ "meta": { "title": "x" } }"#.utf8))
        }
    }

    @Test func rejectsNewerVersionClearly() {
        let json = minimal.replacingOccurrences(of: "\"formatVersion\": 1", with: "\"formatVersion\": 2")
        #expect(throws: BeatmapError.unsupportedFormatVersion(2)) {
            try BeatmapLoader.decode(Data(json.utf8))
        }
    }

    @Test func rejectsInvalidJSON() {
        #expect(throws: BeatmapError.self) { try BeatmapLoader.decode(Data("{ not json".utf8)) }
    }

    @Test func rejectsMissingRequiredField() {
        let json = minimal.replacingOccurrences(of: "\"timing\": { \"bpm\": 120, \"offsetMs\": 0 },", with: "")
        do {
            _ = try BeatmapLoader.decode(Data(json.utf8))
            Issue.record("expected an error")
        } catch let BeatmapError.malformed(detail) {
            #expect(detail.contains("timing"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func rejectsBadColor() {
        let json = minimal.replacingOccurrences(of: "#FF6A3D", with: "orange")
        #expect(throws: BeatmapError.self) { try BeatmapLoader.decode(Data(json.utf8)) }
    }

    @Test func rejectsAmbiguousAudio() {
        let json = minimal.replacingOccurrences(
            of: #""audio": { "generatedClick": { "beatsPerBar": 4, "bars": 8 } }"#,
            with: #""audio": { "file": "a.m4a", "generatedClick": { "beatsPerBar": 4, "bars": 8 } }"#)
        #expect(throws: BeatmapError.self) { try BeatmapLoader.decode(Data(json.utf8)) }
    }

    @Test func rejectsUnknownShape() {
        let json = minimal.replacingOccurrences(of: "\"sphere\"", with: "\"torus\"")
        #expect(throws: BeatmapError.self) { try BeatmapLoader.decode(Data(json.utf8)) }
    }

    @Test func colorHexRoundTrip() {
        #expect(RGBColor(hex: "#00ff80")?.hex == "#00FF80")
        #expect(RGBColor(hex: "00FF80") == nil)
        #expect(RGBColor(hex: "#12345") == nil)
    }
}
