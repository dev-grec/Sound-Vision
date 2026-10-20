import Foundation

/// A song's beatmap, format version 1. The JSON format is documented in docs/BEATMAP_FORMAT.md;
/// keep that file in sync with any change here.
public struct Beatmap: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var meta: Meta
    public var audio: AudioSource
    public var timing: Timing
    public var object: ObjectSpec
    /// Rotation schedule. The first segment must start at beat 0.
    public var rotation: [RotationSegment]
    public var notes: [TapNote]
    public var strokes: [Stroke]

    public init(
        formatVersion: Int = Beatmap.currentFormatVersion,
        meta: Meta,
        audio: AudioSource,
        timing: Timing,
        object: ObjectSpec,
        rotation: [RotationSegment],
        notes: [TapNote],
        strokes: [Stroke] = []
    ) {
        self.formatVersion = formatVersion
        self.meta = meta
        self.audio = audio
        self.timing = timing
        self.object = object
        self.rotation = rotation
        self.notes = notes
        self.strokes = strokes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        meta = try c.decode(Meta.self, forKey: .meta)
        audio = try c.decode(AudioSource.self, forKey: .audio)
        timing = try c.decode(Timing.self, forKey: .timing)
        object = try c.decode(ObjectSpec.self, forKey: .object)
        rotation = try c.decode([RotationSegment].self, forKey: .rotation)
        notes = try c.decodeIfPresent([TapNote].self, forKey: .notes) ?? []
        strokes = try c.decodeIfPresent([Stroke].self, forKey: .strokes) ?? []
    }

    public struct Meta: Codable, Sendable, Equatable {
        public var title: String
        public var artist: String?
        public var mapper: String?

        public init(title: String, artist: String? = nil, mapper: String? = nil) {
            self.title = title
            self.artist = artist
            self.mapper = mapper
        }
    }

    public struct Timing: Codable, Sendable, Equatable {
        /// Beats per minute. Constant for the whole song in format v1.
        public var bpm: Double
        /// Time of beat 0, in ms from the start of the audio.
        public var offsetMs: Double

        public init(bpm: Double, offsetMs: Double = 0) {
            self.bpm = bpm
            self.offsetMs = offsetMs
        }
    }

    public struct ObjectSpec: Codable, Sendable, Equatable {
        public var shape: ShapeKind
        /// Radius in meters (for a sphere).
        public var radiusM: Double

        public init(shape: ShapeKind = .sphere, radiusM: Double) {
            self.shape = shape
            self.radiusM = radiusM
        }
    }

    public enum ShapeKind: String, Codable, Sendable, Equatable {
        case sphere
    }

    /// The song's duration in ms if the map defines it without reading the audio file
    /// (true for generated click tracks). Nil for file audio; the app reads the file's length.
    public var definedDurationMs: Double? {
        switch audio {
        case .generatedClick(let click):
            return timing.offsetMs + Double(click.bars * click.beatsPerBar) * 60_000 / timing.bpm
        case .file:
            return nil
        }
    }
}

/// Where the song's audio comes from.
public enum AudioSource: Codable, Sendable, Equatable {
    /// An audio file next to the beatmap, by file name. Only the project owner supplies these.
    case file(String)
    /// A metronome click synthesized at runtime from the map's BPM, so no audio file is needed.
    case generatedClick(ClickTrack)

    public struct ClickTrack: Codable, Sendable, Equatable {
        public var beatsPerBar: Int
        public var bars: Int

        public init(beatsPerBar: Int = 4, bars: Int) {
            self.beatsPerBar = beatsPerBar
            self.bars = bars
        }
    }

    private enum CodingKeys: String, CodingKey {
        case file, generatedClick
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let keys = Set(c.allKeys)
        guard keys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath,
                debugDescription: "audio must have exactly one of \"file\" or \"generatedClick\""))
        }
        if keys.contains(.file) {
            self = .file(try c.decode(String.self, forKey: .file))
        } else {
            self = .generatedClick(try c.decode(ClickTrack.self, forKey: .generatedClick))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .file(let name): try c.encode(name, forKey: .file)
        case .generatedClick(let click): try c.encode(click, forKey: .generatedClick)
        }
    }
}

/// One segment of the rotation schedule. Applies from `startBeat` until the next segment starts.
public struct RotationSegment: Codable, Sendable, Equatable {
    public var startBeat: Double
    /// Rotation axis in the player-facing frame: +X to the player's right, +Y up, +Z toward the player.
    /// Need not be normalized; must be non-zero.
    public var axis: [Double]
    /// Degrees per beat around `axis`, right-hand rule. With axis [0,1,0] and a positive value,
    /// the front of the object moves toward the player's right.
    public var degreesPerBeat: Double

    public init(startBeat: Double, axis: [Double], degreesPerBeat: Double) {
        self.startBeat = startBeat
        self.axis = axis
        self.degreesPerBeat = degreesPerBeat
    }
}

/// A tap note: it pops up, its approach ring closes on the beat, and the player looks at it and pinches.
public struct TapNote: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Hit time in ms from the start of the audio.
    public var timeMs: Double
    /// Position in the PLAYER'S VIEW, on the front of the object: lat 0, lon 0 is straight toward the
    /// player, +lon is to the player's right, +lat is up. Fixed: tap notes do not ride the rotation
    /// (owner's design, DECISIONS D18). Strokes, by contrast, are drawn on the rotating surface.
    public var at: SurfacePoint
    /// Optional slider: after pinching this note on the beat, hold and drag along `slider.path`.
    public var slider: Slider?

    public init(id: String, timeMs: Double, at: SurfacePoint, slider: Slider? = nil) {
        self.id = id
        self.timeMs = timeMs
        self.at = at
        self.slider = slider
    }

    /// When the note is finished: its hit time, or the end of its slider.
    public var endMs: Double { timeMs + (slider?.durationMs ?? 0) }

    /// The slider's full path in view coordinates, starting at the head (`at`). Nil for a plain note.
    public var sliderPath: StrokePath? {
        slider.map { StrokePath(points: [at] + $0.path) }
    }

    /// Where the slider ball is at (judged) time `ms`: at the head until the hit time, then moving
    /// along the path at constant speed, at the end afterward. Nil for a plain note.
    public func sliderBallPoint(atMs ms: Double) -> SurfacePoint? {
        guard let slider, let path = sliderPath else { return nil }
        let f = slider.durationMs > 0 ? (ms - timeMs) / slider.durationMs : 1
        return path.point(atFraction: f)
    }
}

/// A slider attached to a tap note. The ball leaves the note's position at its hit time and travels
/// the path (great-circle arcs, view coordinates) at constant speed over `durationMs`.
public struct Slider: Codable, Sendable, Equatable {
    public var durationMs: Double
    /// Points after the head, in view coordinates. A straight slider has one point: its end.
    public var path: [SurfacePoint]

    public init(durationMs: Double, path: [SurfacePoint]) {
        self.durationMs = durationMs
        self.path = path
    }

    /// A straight slider from `head` in a cardinal direction of the player's view.
    public static func cardinal(from head: SurfacePoint, direction: CardinalDirection,
                                lengthDeg: Double, durationMs: Double) -> Slider {
        let d = direction.delta
        return Slider(durationMs: durationMs,
                      path: [SurfacePoint(lat: head.lat + d.lat * lengthDeg, lon: head.lon + d.lon * lengthDeg)])
    }
}

/// Up, down, left or right in the player's view.
public enum CardinalDirection: String, Codable, Sendable, CaseIterable {
    case up, down, left, right

    /// Unit step in (lat, lon) degrees.
    public var delta: (lat: Double, lon: Double) {
        switch self {
        case .up: (1, 0)
        case .down: (-1, 0)
        case .left: (0, -1)
        case .right: (0, 1)
        }
    }
}

/// A stroke note: pinch at the start on time, then drag along `path` for `durationMs`.
public struct Stroke: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var startMs: Double
    public var durationMs: Double
    /// At least two points. The guide moves along the path at constant angular speed.
    public var path: [SurfacePoint]
    /// Final hue once completed, as "#RRGGBB".
    public var color: RGBColor

    public init(id: String, startMs: Double, durationMs: Double, path: [SurfacePoint], color: RGBColor) {
        self.id = id
        self.startMs = startMs
        self.durationMs = durationMs
        self.path = path
        self.color = color
    }

    public var endMs: Double { startMs + durationMs }
}

/// An sRGB color, written in JSON as "#RRGGBB".
public struct RGBColor: Codable, Sendable, Equatable, CustomStringConvertible {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init?(hex: String) {
        var s = Substring(hex)
        guard s.first == "#" else { return nil }
        s = s.dropFirst()
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    public var hex: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    public var description: String { hex }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let color = RGBColor(hex: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "color must be \"#RRGGBB\", got \"\(s)\"")
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}
