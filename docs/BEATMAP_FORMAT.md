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
    { "id": "n01", "timeMs": 4000, "at": { "lat": 15, "lon": -35 } },
    { "id": "n02", "timeMs": 6000, "at": { "lat": -15, "lon": 35 },
      "slider": { "durationMs": 1000, "path": [ { "lat": -15, "lon": 5 } ] } }
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
- Positions are `{ "lat": degrees, "lon": degrees }`: latitude from -90 to 90, positive upward; longitude positive toward +X (the player's right); any longitude wraps. They are objects rather than `[lat, lon]` pairs so later shapes can add other coordinate kinds without breaking v1.
- **Two frames, on purpose:**
  - **Tap note `at` is in the player's view** (the placement frame, fixed): `lat 0, lon 0` is straight toward the player. Tap notes do not ride the rotation (DECISIONS D18).
  - **Stroke `path` points are on the object's rotating surface** (the object's own frame): `lat 0, lon 0` faces the player before any rotation. Strokes turn with the object, because together they form the picture wrapped around it.

## Rotation schedule

Each segment is `{ "startBeat", "axis": [x, y, z], "degreesPerBeat" }`, and applies until the next segment starts.

- `axis` is in the placement frame and does not need to be normalized. Rotation follows the right-hand rule: with axis `[0,1,0]` and a positive rate, the front of the object moves toward the player's right.
- The first segment must start at beat 0. Before beat 0 (lead-in), the first segment extends backward.
- Orientation is computed analytically from song time: completed segments in full, then the current one partially. Each segment's rotation is applied on top of the orientation reached so far.
- Speed limit: `|degreesPerBeat| × bpm / 60` must not exceed `Tuning.maxDegreesPerSecond` (20°/s by default).

## Tap notes

`{ "id", "timeMs", "at": {lat, lon} }`. Each id must be unique across notes and strokes.

`at` is where the note sits **in the player's view**, on the front of the object, and it stays there: `{ "lat": 15, "lon": -35 }` is 35° to the left and 15° up. No rotation math is needed.

**Rules:**
- A note pops up `Tuning.approachMs` (1500 ms) before `timeMs`, and its approach ring closes on it at `timeMs`.
- It must be inside the **play area**: within `Tuning.hitZoneHalfAngleDeg` (45°) of straight ahead.
- Notes on screen at the same time (pop-up to Good-window close) must be at least `Tuning.minNoteSeparationDeg` (25°) apart. Keep a little margin: 25° steps along a latitude other than 0 come out slightly under 25°.

**Leading the eye:** motion comes from sequences of notes, not from notes moving. To draw the player's eye to the right, place several notes in a row going left to right, one per beat. The test map has examples: left to right, right to left, two diagonals, and a circle of eight.

> One beat at 120 BPM is 500 ms. A four-dot stream: `{lat 0, lon -39}`, `{0, -13}`, `{0, 13}`, `{0, 39}` at 16000, 16500, 17000, 17500 ms. With a 1.5 s approach, all four are on screen together, so each pair must be ≥25° apart; 26° steps leave margin.

## Sliders

A tap note can carry a `slider`: `{ "durationMs", "path": [view points] }`. The player pinches the note (the head) on the beat as usual, then drags the slider's knob along the track and must reach the end at the **target time**, `timeMs + durationMs`. The knob follows the player's drag (DECISIONS D20). A timer beside the slider (DECISIONS D21) shows the time budget, counts down after the pinch, and reads 0.00 at the target.

- `path` lists the points after the head, in view coordinates like `at`. A straight slider has one point, its end. More points make a bent path (great-circle arcs between them). Curves may come later.
- Scoring: the head is judged like a tap; a head Miss (Early/Late) ends the slider. The knob follows the drag while it's within `Tuning.sliderGrabRadiusDeg` (15°) of the track, and never moves backward. The slider finishes when the knob is within `sliderEndToleranceDeg` (1.5°) of the end. The finish time is judged against the target with slider windows (Perfect ±100 ms, Great ±180, Good ±260). Finishing earlier is "Early" (a Miss). Not finishing by the end of the Good window, or letting go before the end, is a Miss. The slider's judgment is the worse of the head and the finish, and it counts once in the score.
- Rules: every path point inside the play area; required pace (track length / duration) ≤ `Tuning.maxSliderSpeedDegPerSec` (75°/s); sliders may not overlap each other or strokes in time; a note during a slider is a warning. For crowding, a slider occupies its whole path until it ends.
- **For now the test map has no sliders written in.** The app adds random cardinal sliders each play (launcher toggle "Random sliders", on by default; `RhythmCore/RandomSliders.swift`): up/down/left/right, 20–45°, 1–2 beats, only where a note has room before the next one and the map stays valid. The owner will design each level's sliders to fit its song later, written into the map with this format.

## Strokes

`{ "id", "startMs", "durationMs", "path": [surface points], "color": "#RRGGBB" }`

- `path` has at least two points. The guide moves along the great-circle arcs between consecutive points at constant angular speed, from `startMs` to `startMs + durationMs`.
- Keep each segment under 170°, since near-antipodal arcs are ambiguous.
- The start point pops up like a tap note and must be in the play area from its pop-up until `startMs`. The guide should stay in the play area for the whole stroke, otherwise you get a warning. To keep a stroke on the front, let the path drift against the rotation (for a +Y rotation, decrease longitude by the rotation over the stroke's duration).
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
- a note leaving the play area while on screen (pop-up to window close)
- a stroke with fewer than two points, a non-positive duration, a segment of 170° or more, or a start outside the play area
- overlapping strokes
- a slider with a non-positive duration, an empty path, a point outside the play area, a required pace faster than 75°/s, ending after the song, or overlapping another slider or a stroke
- **crowded targets**: two targets (notes or stroke starts) on screen at the same time (pop-up to Good window close) and less than `Tuning.minNoteSeparationDeg` (25°) apart on the surface. With a 1.5 s approach, notes 1 s apart overlap and must be spread out; notes 2 s apart don't overlap. The object is rigid, so their separation never changes as it turns.

**Warnings** (the map loads):

- a stroke guide leaving the play area
- a tap note during a stroke or a slider

## Versioning

Bump `formatVersion` for any change that an old reader would misread. Purely additive optional fields can stay at v1 if old builds can safely ignore them. When v2 arrives, keep a v1 reader or a migration, and document both here.
