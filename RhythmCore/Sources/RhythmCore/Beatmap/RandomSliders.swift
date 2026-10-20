import Foundation

/// Development helper: attaches random cardinal sliders to a map's tap notes.
///
/// Until levels are designed by hand (the owner will design each level's sliders to fit its song),
/// this gives sliders to play with. For each note without a slider, with probability
/// `Tuning.randomSliderChance`, it tries a duration from `randomSliderBeats` that ends at least
/// `randomSliderGapBeats` before the next note, a random length in `randomSliderLengthDeg` (capped by the
/// slider speed limit), and the four cardinal directions in random order. A candidate is kept only if the
/// map still validates with no new issues (play area, speed, crowding, overlaps). Deterministic for a seed.
public enum RandomSliders {
    public struct Result: Sendable {
        public var beatmap: Beatmap
        /// IDs of the notes that got a slider.
        public var added: [String]
    }

    public static func add(to map: Beatmap, tuning: Tuning, seed: UInt64) -> Result {
        var rng = SeededRandom(seed: seed)
        var result = map
        let order = map.notes.indices.sorted { map.notes[$0].timeMs < map.notes[$1].timeMs }
        let msPerBeat = 60_000 / map.timing.bpm
        let baseline = BeatmapValidator.validate(map, tuning: tuning).issues.count
        var added: [String] = []

        for (k, i) in order.enumerated() {
            let note = result.notes[i]
            guard note.slider == nil, Double.random(in: 0..<1, using: &rng) < tuning.randomSliderChance else { continue }
            // Room until the next note (or stroke, or the end of the song).
            var nextMs = k + 1 < order.count ? result.notes[order[k + 1]].timeMs : (map.definedDurationMs ?? .infinity)
            if let stroke = map.strokes.map(\.startMs).filter({ $0 > note.timeMs }).min() { nextMs = min(nextMs, stroke) }
            let roomMs = nextMs - note.timeMs - tuning.randomSliderGapBeats * msPerBeat
            let beats = tuning.randomSliderBeats.filter { $0 * msPerBeat <= roomMs }
            guard let b = beats.randomElement(using: &rng) else { continue }
            let durationMs = b * msPerBeat
            let maxLength = tuning.maxSliderSpeedDegPerSec * durationMs / 1000
            let range = tuning.randomSliderLengthDeg
            let length = min(Double.random(in: range, using: &rng), maxLength)
            guard length >= range.lowerBound * 0.5 else { continue }

            for direction in CardinalDirection.allCases.shuffled(using: &rng) {
                var trial = result
                trial.notes[i].slider = .cardinal(from: note.at, direction: direction, lengthDeg: length, durationMs: durationMs)
                if BeatmapValidator.validate(trial, tuning: tuning).issues.count == baseline {
                    result = trial
                    added.append(note.id)
                    break
                }
            }
        }
        return Result(beatmap: result, added: added)
    }
}

/// SplitMix64: a small, fast, seedable generator, so random layouts can be reproduced from their seed.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
