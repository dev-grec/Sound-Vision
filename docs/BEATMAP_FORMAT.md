# Beatmap format (version 1)

A beatmap is a JSON file, `Maps/<song-folder>/beatmap.json`. Any audio file sits next to it in the same folder. The Swift model is `RhythmCore/Sources/RhythmCore/Beatmap/Beatmap.swift`, and the rules are enforced by `BeatmapValidator.swift`. **Keep this document, the model and the validator in sync.**

Maps are hand-written JSON until the editor exists (M3). Run `scripts/test.sh` after editing a shipped map. A test validates every map in `Maps/` and fails on any error or warning.

## Example

```json
{
  "formatVersion": 1,
  "meta": { "title": "Test Metronome", "artist": "Generated click track", "mapper": "M0 test map" },
  "audio": { "generatedClick": { "beatsPerBar": 4, "bars": 30 } },
  "timing": { "bpm": 120, "offsetMs": 0 },
  "object": { "shape": "sphere", "radiusM": 0.3 },
  "rotation": [
    { "startBeat": 0,  "axis": [0, 1, 0], "degreesPerBeat": 6 },
    { "startBeat": 64, "axis": [0, 1, 0], "degreesPerBeat": 4 }
  ],
  "notes": [
    { "id": "n01", "timeMs": 4000, "at": { "lat": 0, "lon": -48 } }
  ],
  "strokes": [
    { "id": "s1", "startMs": 42000, "durationMs": 2000,
      "path": [ { "lat": 10, "lon": -104 }, { "lat": 0, "lon": -112 }, { "lat": -10, "lon": -120 } ],
      "color": "#FF6A3D" }
  ]
}
```

## Fields

| Field | Type | Required | Meaning |
|---|---|---|---|
| `formatVersion` | int | yes | Must be `1`. Checked first. A newer version gives a clear "unsupported version" error. |
| `meta.title` | string | yes | Song title |
| `meta.artist`, `meta.mapper` | string | no | Credits |
| `audio` | object | yes | Exactly one of the two forms below |
| `audio.file` | string | | An audio file name in the same folder. Only the project owner supplies audio. |
| `audio.generatedClick` | `{beatsPerBar, bars}` | | A metronome synthesized at runtime from `timing`, with beat 1 of each bar accented. No file needed. Song length = `offsetMs + bars × beatsPerBar` beats. |
| `timing.bpm` | number | yes | Constant tempo for the whole song (v1 has no tempo changes) |
| `timing.offsetMs` | number | yes | Time of beat 0, in ms from the start of the audio |
| `object.shape` | string | yes | `"sphere"` (the only shape in v1) |
| `object.radiusM` | number | yes | Radius in meters. About 0.3 is comfortable at 1.1 m. |
| `rotation` | array | yes | The rotation schedule (below). At least one segment. |
| `notes` | array | no | Tap notes (below). Default `[]`. |
| `strokes` | array | no | Stroke notes (below). Default `[]`. Parsed and validated now, playable from M1. |

All times are **milliseconds from the start of the audio**, except rotation, which is in **beats**. Rotation is tied to the music's meter; notes are placed at exact moments.

## Coordinates

- **Placement frame** (non-rotating, centered on the object): +X is the player's right, +Y is up, +Z points toward the player. The player stands along +Z.
- **Surface points** are `{ "lat": degrees, "lon": degrees }` in the object's own (rotating) frame. `lat 0, lon 0` faces the player before any rotation. Latitude runs from -90 to 90, positive upward. Longitude is positive toward +X. Any longitude value is accepted; it wraps.
- Surface points are objects rather than `[lat, lon]` pairs so that later shapes can add other coordinate kinds without breaking v1.

## Rotation schedule

Each segment is `{ "startBeat", "axis": [x, y, z], "degreesPerBeat" }`, and applies until the next segment starts.

- `axis` is in the placement frame and does not need to be normalized. Rotation follows the right-hand rule: with axis `[0,1,0]` and a positive rate, the front of the object moves toward the player's right.
- The first segment must start at beat 0. Before beat 0 (lead-in), the first segment extends backward.
- Orientation is computed analytically from song time: completed segments in full, then the current one partially. Each segment's rotation is applied on top of the orientation reached so far.
- Speed limit: `|degreesPerBeat| × bpm / 60` must not exceed `Tuning.maxDegreesPerSecond` (20°/s by default).

## Tap notes

`{ "id", "timeMs", "at": {lat, lon} }`. Each id must be unique across notes and strokes.

**Placement rule:** a note must face the player at its own hit time. The surface point is given in the object's frame, so you have to undo the rotation. For a schedule that only rotates about +Y, the longitude facing the player at time t is **lon = −θ(t)**, where θ(t) is the total rotation in degrees so far.

> Test map: 120 BPM (500 ms per beat), 6°/beat until beat 64, then 4°/beat.
> A note at 4000 ms is beat 8, so θ = 48° and lon = -48.
> A note at 34000 ms is beat 68, so θ = 384 + 4×4 = 400°, which is 40° after wrapping, so lon = -40.

**Laps:** the object keeps turning, so every surface point passes the front once per revolution (30 s at 12°/s). A note is shown and targetable only on its *final approach*: it fades in when, counting back from its hit time, it was last `Tuning.noteAppearAngleDeg` (150°) from front. On earlier laps it's hidden. You can reuse a surface spot for a later note, as long as the two notes aren't targetable at the same time.

Keep latitude modest (about ±15°). The angle from zone center at hit time must be within `Tuning.noteComfortAngleDeg` (20°) to avoid a warning, and within `Tuning.hitZoneHalfAngleDeg` (30°) to be hittable at all.

## Strokes

`{ "id", "startMs", "durationMs", "path": [surface points], "color": "#RRGGBB" }`

- `path` has at least two points. The guide moves along the great-circle arcs between consecutive points at constant angular speed, from `startMs` to `startMs + durationMs`.
- Keep each segment under 170°, since near-antipodal arcs are ambiguous.
- The start point must be in the hit zone at `startMs`. The guide should stay in the zone for the whole stroke, otherwise you get a warning. To keep a stroke on the front, let the path drift against the rotation (for a +Y rotation, decrease longitude by the rotation over the stroke's duration).
- `color` is the hue the stroke fills with when completed well.

## Validator rules

**Errors** (the map won't load):

- bpm not positive
- radius not positive
- empty audio file name, or non-positive click bars/beats
- rotation missing, not starting at beat 0, with duplicate start beats, a bad axis, or too fast
- duplicate or empty ids
- non-finite numbers, negative times, latitude outside ±90
- a note or stroke after the end of a generated click track
- a note outside the hit zone at its time
- a stroke with fewer than two points, a non-positive duration, a segment of 170° or more, or a start outside the zone
- overlapping strokes
- **crowded targets**: two targets (notes or stroke starts) that are targetable at the same time and less than `Tuning.minNoteSeparationDeg` (25°) apart on the surface. A target is targetable from its final approach within `targetableHalfAngleDeg` (40°) until its Good window closes. At 12°/s that's about 3.5 s, so same-latitude notes 2 s apart (24°) are too close. The object is rigid, so their separation never changes as it turns.

**Warnings** (the map loads):

- a note more than 20° from zone center at its time
- a stroke guide leaving the zone
- a tap note during a stroke

## Versioning

Bump `formatVersion` for any change that an old reader would misread. Purely additive optional fields can stay at v1 if old builds can safely ignore them. When v2 arrives, keep a v1 reader or a migration, and document both here.
