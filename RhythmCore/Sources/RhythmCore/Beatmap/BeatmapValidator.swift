import Foundation

/// Checks a decoded beatmap against the format's rules and the game's playability rules
/// (eye targeting needs slow, well-spaced targets). Errors make a map unplayable; warnings are
/// shown to the mapper but the map still loads.
public enum BeatmapValidator {
    public struct Issue: Sendable, Equatable, CustomStringConvertible {
        public enum Severity: String, Sendable { case error, warning }
        public var severity: Severity
        /// Stable identifier for the rule, for tests and tooling.
        public var code: String
        public var message: String
        /// The note, stroke or rotation segment concerned, if any.
        public var itemID: String?

        public var description: String {
            "\(severity.rawValue): [\(code)]\(itemID.map { " \($0):" } ?? "") \(message)"
        }
    }

    public struct Report: Sendable, Equatable {
        public var issues: [Issue]
        public var errors: [Issue] { issues.filter { $0.severity == .error } }
        public var warnings: [Issue] { issues.filter { $0.severity == .warning } }
        public var isPlayable: Bool { errors.isEmpty }
        public func has(_ code: String) -> Bool { issues.contains { $0.code == code } }
    }

    public static func validate(_ map: Beatmap, tuning: Tuning = .default) -> Report {
        var issues: [Issue] = []
        func error(_ code: String, _ message: String, _ id: String? = nil) {
            issues.append(Issue(severity: .error, code: code, message: message, itemID: id))
        }
        func warning(_ code: String, _ message: String, _ id: String? = nil) {
            issues.append(Issue(severity: .warning, code: code, message: message, itemID: id))
        }
        func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

        // Timing and object
        if !(map.timing.bpm > 0) || !map.timing.bpm.isFinite {
            error("timing.bpm", "bpm must be a positive number")
            return Report(issues: issues) // everything below depends on a valid tempo
        }
        if !map.timing.offsetMs.isFinite { error("timing.offset", "offsetMs must be a finite number") }
        if !(map.object.radiusM > 0) || !map.object.radiusM.isFinite {
            error("object.radius", "radiusM must be a positive number")
        }

        // Audio
        switch map.audio {
        case .file(let name):
            if name.trimmingCharacters(in: .whitespaces).isEmpty { error("audio.file", "audio file name is empty") }
        case .generatedClick(let click):
            if click.bars <= 0 || click.beatsPerBar <= 0 {
                error("audio.click", "generatedClick needs positive bars and beatsPerBar")
            }
        }

        // Rotation schedule
        if map.rotation.isEmpty {
            error("rotation.empty", "rotation needs at least one segment")
        } else {
            let sorted = map.rotation.sorted { $0.startBeat < $1.startBeat }
            if sorted[0].startBeat != 0 { error("rotation.start", "the first rotation segment must start at beat 0") }
            for (a, b) in zip(sorted, sorted.dropFirst()) where a.startBeat == b.startBeat {
                error("rotation.duplicate", "two rotation segments start at beat \(fmt(a.startBeat))")
            }
            let schedule = RotationSchedule(segments: map.rotation, grid: BeatGrid(map.timing))
            for (seg, dps) in zip(sorted, schedule.degreesPerSecondBySegment) {
                let id = "beat \(fmt(seg.startBeat))"
                let axisOK = seg.axis.count == 3 && seg.axis.allSatisfy(\.isFinite) && seg.axis.contains { $0 != 0 }
                if !axisOK { error("rotation.axis", "axis must be three finite numbers, not all zero", id) }
                if !seg.degreesPerBeat.isFinite { error("rotation.rate", "degreesPerBeat must be finite", id) }
                if dps > tuning.maxDegreesPerSecond {
                    error("rotation.tooFast",
                          "rotates \(fmt(dps))°/s; the limit is \(fmt(tuning.maxDegreesPerSecond))°/s", id)
                }
            }
        }

        // IDs
        var seen = Set<String>()
        for id in map.notes.map(\.id) + map.strokes.map(\.id) {
            if id.isEmpty { error("id.empty", "every note and stroke needs a non-empty id") }
            else if !seen.insert(id).inserted { error("id.duplicate", "id is used more than once", id) }
        }

        let playfield = Playfield(beatmap: map)
        let durationMs = map.definedDurationMs

        // Tap notes
        for note in map.notes {
            guard note.timeMs.isFinite, note.at.isFinite else {
                error("note.nonFinite", "time and position must be finite numbers", note.id)
                continue
            }
            if note.timeMs < 0 { error("note.negativeTime", "timeMs is negative", note.id) }
            if let d = durationMs, note.timeMs > d { error("note.afterEnd", "timeMs is after the song ends (\(fmt(d)) ms)", note.id) }
            if abs(note.at.lat) > 90 { error("note.latitude", "lat must be between -90 and 90", note.id) }
            // On screen from pop-up until its window closes; it must stay in the play area throughout.
            let worst = playfield.maxAngleFromFrontDeg(of: note.at, fromMs: note.timeMs - tuning.approachMs,
                                                       toMs: note.timeMs + tuning.goodWindowMs)
            if worst > tuning.hitZoneHalfAngleDeg {
                error("note.outsideZone",
                      "reaches \(fmt(worst))° from front while on screen; the play area is ±\(fmt(tuning.hitZoneHalfAngleDeg))°",
                      note.id)
            }
        }

        // Strokes
        for stroke in map.strokes {
            guard stroke.startMs.isFinite, stroke.durationMs.isFinite, stroke.path.allSatisfy(\.isFinite) else {
                error("stroke.nonFinite", "times and path must be finite numbers", stroke.id)
                continue
            }
            if stroke.path.count < 2 { error("stroke.path", "path needs at least two points", stroke.id); continue }
            if stroke.path.contains(where: { abs($0.lat) > 90 }) { error("stroke.latitude", "lat must be between -90 and 90", stroke.id) }
            if !(stroke.durationMs > 0) { error("stroke.duration", "durationMs must be positive", stroke.id); continue }
            if stroke.startMs < 0 { error("stroke.negativeTime", "startMs is negative", stroke.id) }
            if let d = durationMs, stroke.endMs > d { error("stroke.afterEnd", "ends after the song ends (\(fmt(d)) ms)", stroke.id) }
            let path = StrokePath(points: stroke.path)
            if path.longestSegmentDeg >= 170 {
                error("stroke.segmentTooLong", "a path segment spans \(fmt(path.longestSegmentDeg))°; keep segments under 170° so the arc is unambiguous", stroke.id)
            }
            let startAngle = playfield.maxAngleFromFrontDeg(of: stroke.path[0], fromMs: stroke.startMs - tuning.approachMs,
                                                            toMs: stroke.startMs)
            if startAngle > tuning.hitZoneHalfAngleDeg {
                error("stroke.startOutsideZone", "start point reaches \(fmt(startAngle))° from front between its pop-up and startMs", stroke.id)
            }
            // The guide should stay in the play area for the whole stroke.
            let scorer = StrokeFollowScorer(stroke: stroke, tuning: tuning)
            let worst = (0...20).map { i -> Double in
                let t = stroke.startMs + stroke.durationMs * Double(i) / 20
                return playfield.angleFromFrontDeg(of: scorer.guidePoint(atMs: t), atMs: t)
            }.max() ?? 0
            if worst > tuning.hitZoneHalfAngleDeg {
                warning("stroke.leavesZone", "the guide reaches \(fmt(worst))° from front during the stroke", stroke.id)
            }
        }

        // Strokes may not overlap each other (one drag at a time); tap notes during a stroke are discouraged.
        let strokes = map.strokes.filter { $0.startMs.isFinite && $0.durationMs > 0 }.sorted { $0.startMs < $1.startMs }
        for (a, b) in zip(strokes, strokes.dropFirst()) where b.startMs < a.endMs {
            error("stroke.overlap", "overlaps stroke \(a.id) in time", b.id)
        }
        for note in map.notes where note.timeMs.isFinite {
            if let s = strokes.first(where: { note.timeMs > $0.startMs && note.timeMs < $0.endMs }) {
                warning("note.duringStroke", "falls during stroke \(s.id); the player is busy dragging", note.id)
            }
        }

        // Crowding: targets on screen at the same time (pop-up to window close) must be far apart on the
        // surface. The object is rigid, so the angle between two surface points never changes as it
        // rotates; comparing surface positions is enough.
        struct Target { var id: String; var fromMs: Double; var toMs: Double; var at: SurfacePoint }
        func target(_ id: String, _ ms: Double, _ at: SurfacePoint) -> Target {
            Target(id: id, fromMs: ms - tuning.approachMs, toMs: ms + tuning.goodWindowMs, at: at)
        }
        let targets = (map.notes.filter { $0.timeMs.isFinite && $0.at.isFinite }.map { target($0.id, $0.timeMs, $0.at) }
            + map.strokes.filter { $0.startMs.isFinite && ($0.path.first?.isFinite ?? false) }.map { target($0.id, $0.startMs, $0.path[0]) })
            .sorted { $0.fromMs < $1.fromMs }
        for i in targets.indices {
            var j = i + 1
            while j < targets.count, targets[j].fromMs <= targets[i].toMs {
                let sep = targets[i].at.angularDistanceDeg(to: targets[j].at)
                if sep < tuning.minNoteSeparationDeg {
                    let later = targets[i].toMs > targets[j].toMs ? targets[i] : targets[j]
                    let earlier = later.id == targets[i].id ? targets[j] : targets[i]
                    error("targets.crowded",
                          "is only \(fmt(sep))° from \(earlier.id) while both are on screen; needs ≥\(fmt(tuning.minNoteSeparationDeg))°",
                          later.id)
                }
                j += 1
            }
        }

        return Report(issues: issues)
    }
}
