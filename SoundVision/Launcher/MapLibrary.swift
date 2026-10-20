import Foundation
import RhythmCore

/// The beatmaps bundled with the app (the repo's Maps/ folder, copied as a folder reference).
struct MapLibrary {
    struct Entry: Identifiable {
        var id: String { folder.lastPathComponent }
        var folder: URL
        var beatmap: Beatmap
        var report: BeatmapValidator.Report
    }

    var entries: [Entry] = []
    /// Maps that failed to load at all, with the reason.
    var failures: [(name: String, message: String)] = []

    static func loadBundled() -> MapLibrary {
        var library = MapLibrary()
        guard let root = Bundle.main.url(forResource: "Maps", withExtension: nil),
              let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else {
            library.failures.append((name: "Maps", message: "the Maps folder is missing from the app bundle"))
            return library
        }
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let file = folder.appendingPathComponent("beatmap.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                let map = try BeatmapLoader.load(contentsOf: file)
                library.entries.append(Entry(folder: folder, beatmap: map, report: BeatmapValidator.validate(map)))
            } catch {
                library.failures.append((name: folder.lastPathComponent, message: String(describing: error)))
            }
        }
        return library
    }
}
