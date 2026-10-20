import Foundation

/// Score, combo, accuracy and per-judgment counts.
public struct ScoreKeeper: Sendable, Equatable, Codable {
    public private(set) var score: Int = 0
    public private(set) var combo: Int = 0
    public private(set) var maxCombo: Int = 0
    public private(set) var counts: [Judgment: Int] = [:]
    private var accuracySum: Double = 0

    public init() {}

    public mutating func record(_ judgment: Judgment, tuning: Tuning) {
        counts[judgment, default: 0] += 1
        switch judgment {
        case .perfect:
            score += tuning.scorePerfect
            accuracySum += tuning.accuracyPerfect
        case .great:
            score += tuning.scoreGreat
            accuracySum += tuning.accuracyGreat
        case .good:
            score += tuning.scoreGood
            accuracySum += tuning.accuracyGood
        case .miss:
            break
        }
        if judgment.breaksCombo {
            combo = 0
        } else {
            combo += 1
            maxCombo = max(maxCombo, combo)
        }
    }

    public func count(_ judgment: Judgment) -> Int { counts[judgment, default: 0] }

    public var judgedCount: Int { counts.values.reduce(0, +) }

    /// Accuracy over the notes judged so far, 0...1. 1.0 before anything is judged.
    public var accuracy: Double {
        judgedCount == 0 ? 1 : accuracySum / Double(judgedCount)
    }
}
