import Foundation
import Observation
import RhythmCore

/// App-wide state shared by the launcher window and the immersive space.
@Observable
final class AppModel {
    static let immersiveSpaceID = "PlaySpace"

    enum Mode: String {
        case game
        case glassLab
    }

    enum SpaceState {
        case closed, opening, open
    }

    var mode: Mode = .game
    var spaceState: SpaceState = .closed

    /// Game-feel settings. The launcher edits `inputOffsetMs`; everything else uses the defaults in
    /// RhythmCore's Tuning.swift. (Persisting overrides is M2.)
    var tuning = Tuning()
    /// Feed scripted perfect input through the InputSource protocol (debug; works without clicking).
    var autoplay = false
    /// Debug: makes every autoplay pinch this many ms early, to exercise Early/Late.
    /// Launch argument only: -autoplayEarlyMs 400 (negative values can't be passed as launch arguments).
    var autoplayEarlyMs: Double = 0
    var glassVariant: GlassVariant = .defaultForGameplay

    let library = MapLibrary.loadBundled()
    var selectedMap: MapLibrary.Entry? { library.entries.first }

    /// Live status line shown in the launcher while playing.
    var liveStatus: String = ""
    var lastResult: GameResult?

    init() {
        // Launch arguments for automated simulator runs, e.g.
        //   simctl launch <device> com.devgrec.SoundVision -autostart game -autoplay YES -glassVariant C
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "autoplay") { autoplay = true }
        autoplayEarlyMs = defaults.double(forKey: "autoplayEarlyMs")
        if let v = defaults.string(forKey: "glassVariant"), let variant = GlassVariant(rawValue: v) {
            glassVariant = variant
        }
        if defaults.object(forKey: "inputOffsetMs") != nil {
            tuning.inputOffsetMs = defaults.double(forKey: "inputOffsetMs")
        }
    }

    /// Mode requested by the `-autostart` launch argument, if any.
    var autostartMode: Mode? {
        UserDefaults.standard.string(forKey: "autostart").flatMap(Mode.init(rawValue:))
    }
}

/// End-of-song summary (the full results screen is M2).
struct GameResult: Equatable {
    var title: String
    var score: Int
    var accuracy: Double
    var maxCombo: Int
    var counts: [Judgment: Int]
    var totalNotes: Int
}
