import Foundation

public enum BeatmapError: Error, Equatable, CustomStringConvertible {
    case missingFormatVersion
    case unsupportedFormatVersion(Int)
    case malformed(String)

    public var description: String {
        switch self {
        case .missingFormatVersion:
            return "beatmap has no \"formatVersion\""
        case .unsupportedFormatVersion(let v):
            return "beatmap formatVersion \(v) is not supported (this build reads \(Beatmap.currentFormatVersion))"
        case .malformed(let detail):
            return "beatmap is malformed: \(detail)"
        }
    }
}

public enum BeatmapLoader {
    /// Decodes a beatmap, checking the format version before anything else so that a newer
    /// map produces a clear "unsupported version" error instead of a confusing decoding error.
    /// Decoding does not validate gameplay rules; run `BeatmapValidator` for that.
    public static func decode(_ data: Data) throws -> Beatmap {
        struct VersionProbe: Decodable { var formatVersion: Int? }
        let probe: VersionProbe
        do {
            probe = try JSONDecoder().decode(VersionProbe.self, from: data)
        } catch {
            throw BeatmapError.malformed(describe(error))
        }
        guard let version = probe.formatVersion else { throw BeatmapError.missingFormatVersion }
        guard version == Beatmap.currentFormatVersion else { throw BeatmapError.unsupportedFormatVersion(version) }
        do {
            return try JSONDecoder().decode(Beatmap.self, from: data)
        } catch {
            throw BeatmapError.malformed(describe(error))
        }
    }

    public static func load(contentsOf url: URL) throws -> Beatmap {
        try decode(try Data(contentsOf: url))
    }

    public static func encode(_ beatmap: Beatmap) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(beatmap)
    }

    private static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return String(describing: error) }
        func path(_ codingPath: [any CodingKey]) -> String {
            codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        }
        switch error {
        case .keyNotFound(let key, let ctx):
            return "missing \"\(key.stringValue)\" at \(path(ctx.codingPath).isEmpty ? "top level" : path(ctx.codingPath))"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return "\(path(ctx.codingPath)): \(ctx.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }
}
