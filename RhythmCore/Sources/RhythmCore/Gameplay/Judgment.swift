import Foundation

public enum Judgment: String, Codable, Sendable, CaseIterable, Comparable {
    case perfect, great, good, miss

    /// Rank order, best first, so `.perfect < .miss`.
    private var rank: Int {
        switch self {
        case .perfect: 0
        case .great: 1
        case .good: 2
        case .miss: 3
        }
    }

    public static func < (lhs: Judgment, rhs: Judgment) -> Bool { lhs.rank < rhs.rank }

    public var displayName: String {
        switch self {
        case .perfect: "Perfect"
        case .great: "Great"
        case .good: "Good"
        case .miss: "Miss"
        }
    }

    public var breaksCombo: Bool { self == .miss }
}

/// Timing judgment for a single pinch.
public enum TapJudge {
    /// Signed timing error: positive means late. `inputMs` is the raw clock time stamped on the input;
    /// the calibrated input offset is removed here and nowhere else.
    public static func delta(inputMs: Double, targetMs: Double, tuning: Tuning) -> Double {
        (inputMs - tuning.inputOffsetMs) - targetMs
    }

    /// The judgment for a timing error, or nil if it is outside the Good window
    /// (such a pinch is ignored, not counted as a miss).
    public static func judgment(forDeltaMs delta: Double, tuning: Tuning) -> Judgment? {
        let d = abs(delta)
        if d <= tuning.perfectWindowMs { return .perfect }
        if d <= tuning.greatWindowMs { return .great }
        if d <= tuning.goodWindowMs { return .good }
        return nil
    }
}
