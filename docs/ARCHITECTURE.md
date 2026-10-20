# Architecture

Two modules: a pure-Swift engine that holds all game logic, and a visionOS app that renders it and feeds it input.

```
┌──────────────────────────── SoundVision (visionOS app) ────────────────────────────┐
│ Launcher window (SwiftUI)        Immersive space (RealityKit, mixed)               │
│  LauncherView ── AppModel ──▶    ImmersiveRootView ─▶ GameView / GlassLabView       │
│                                       │                                            │
│  AudioEngineClock ──nowMs──▶ GameSceneController ◀── GestureInputSource ◀ gestures │
│  (AVAudioEngine)                 │  per frame:           ScriptedInputSource (autoplay)
│                                  │  orientation, inputs → session → visuals        │
│                                  ▼                                                 │
│          GlassObject (shells + rotating surfaceRoot), NoteVisuals, JudgmentPopups  │
└──────────────────────────────────┬─────────────────────────────────────────────────┘
                                   │ value types only
┌──────────────────────────── RhythmCore (Swift package) ────────────────────────────┐
│ Beatmap (+Loader, Validator) · Tuning · SurfacePoint/SurfaceShape/Playfield         │
│ BeatGrid · RotationSchedule · TapJudge · ScoreKeeper · GameSession                 │
│ StrokePath · PathFollowScorer · RevealState · InputEvent/InputSource · RandomSliders│
└────────────────────────────────────────────────────────────────────────────────────┘
```

## RhythmCore (`RhythmCore/`)

Imports Foundation and simd only. No RealityKit, SwiftUI or AVFoundation. It is tested with `swift test` on the Mac. Everything is a value type except `ManualClock`.

| Piece | File | Responsibility |
|---|---|---|
| `Tuning` | `Tuning.swift` | **The only place for game-feel numbers**: hit windows, offset, zone angles, note size and spacing, rotation limit, far-side opacity, follow tolerance, reveal thresholds and timing, scoring. |
| `Beatmap`, `AudioSource`, `RotationSegment`, `TapNote`, `Stroke`, `RGBColor` | `Beatmap/Beatmap.swift` | Format v1 model (docs/BEATMAP_FORMAT.md) |
| `BeatmapLoader` | `Beatmap/BeatmapLoader.swift` | Version check first, then decode, with readable errors |
| `BeatmapValidator` | `Beatmap/BeatmapValidator.swift` | Format and playability rules (zone placement, crowding, speed, strokes). Errors and warnings with stable codes. |
| `SurfacePoint`, `SurfaceShape`, `SphereShape` | `Geometry/` | Lat/lon ↔ vectors, projection onto the surface, great-circle math. Shapes sit behind a protocol for M3. |
| `Playfield` | `Geometry/Playfield.swift` | Shape + rotation as seen from the player: world normal and position at time t, angle from front, view-fixed positions for tap notes (`viewPosition`, `isInPlayArea`, `viewPoint(ofSurface:)`), surface checks for strokes (`isInHitZone`, `maxAngleFromFrontDeg`), far side, projecting placement-frame or object-local points to the surface |
| `PlaybackClock`, `ManualClock`, `BeatGrid` | `Timing/Clock.swift` | Clock protocol (the app's audio clock implements it); ms ↔ beats |
| `AudioClockMath`, `MonotonicReading` | `Timing/AudioClockMath.swift` | The audio clock's interpolation (render position + host time, both directions, capped, minus output latency) and its never-backward guard with health counters (DECISIONS D2, D21) |
| `RotationSchedule` | `Rotation/RotationSchedule.swift` | Orientation as a pure function of time, computed analytically per segment |
| `Judgment`, `TapJudge` | `Gameplay/Judgment.swift` | Timing tiers; the input offset is applied here |
| `ScoreKeeper` | `Gameplay/ScoreKeeper.swift` | Score, combo, max combo, accuracy, counts |
| `GameSession` | `Gameplay/GameSession.swift` | One play-through: `advance(nowMs:inputs:)` handles inputs, then auto-misses. Returns `Event`s (judged or ignored-with-reason). Per-note `approaches` and `hasAppeared` (D16, D17). Tap notes only in M0. |
| `NoteApproach` | `Gameplay/NoteApproach.swift` | Pop-up time and approach-ring progress and scale for a target (D17) |
| `StrokePath`, `PathFollowScorer`, `RevealState` | `Gameplay/StrokeFollow.swift` | Path interpolation; bucketed follow scoring for slider balls and stroke guides (separate tolerances); stroke reveal level and animation |
| `SliderProgress` | `Gameplay/SliderProgress.swift` | A held slider's knob (projected drag, never backward), finish detection, finish-time windows (D20) |
| `DragTracker` | `Input/DragTracker.swift` | Maps a drag to view points from hand movement since the pinch (D19) |
| `InputTimestamp` | `Input/InputTimestamp.swift` | Stamps an input at its event time on the master clock (arrival minus event age, with sanity limits), D21 |
| `Slider`, `CardinalDirection` | `Beatmap/Beatmap.swift` | A tap note's optional slider (duration + view-space path); `TapNote.sliderBallPoint` |
| `RandomSliders`, `SeededRandom` | `Beatmap/RandomSliders.swift` | Development: seeded random cardinal sliders that keep the map valid (DECISIONS D19) |
| `InputEvent`, `InputSource`, `ScriptedInputSource` | `Input/InputEvent.swift` | Device-independent input; scripted source for tests and autoplay |

### Frames and conventions

- **Object-local frame**: rotates with the object. Stroke paths live here.
- **Placement frame**: non-rotating, centered on the object. +X right, +Y up, +Z toward the player. `Playfield.front = +Z`. Tap note positions live here (view-fixed).
- `orientation(atMs:)` maps object-local to placement. The app sets `surfaceRoot.orientation` to it every frame.
- All times are master-clock ms (audio position). Inputs carry raw clock time; only `TapJudge`/`PathFollowScorer`/`GameSession` subtract `Tuning.inputOffsetMs`.

## SoundVision app (`SoundVision/`)

A synchronized folder: files added here join the target with no pbxproj edit.

| Piece | Responsibility |
|---|---|
| `SoundVisionApp`, `AppModel` | Scenes (WindowGroup + mixed ImmersiveSpace), shared state (mode, tuning, autoplay, glass variant, last result), launch-argument hooks for automated runs |
| `Launcher/LauncherView`, `MapLibrary` | 2D window: play, Glass Lab, autoplay toggle, input-offset slider, glass variant picker, validation messages, last result. Loads `Maps/` from the bundle. |
| `Audio/AudioEngineClock` | **Master clock.** AVAudioEngine + AVAudioPlayerNode; `nowMs` from the render position (see its doc comment). Loads click or file audio. Asks for a 5 ms IO buffer; caches output latency. |
| `Audio/HitSoundPlayer` | The immediate hit tick (synthesized), a second player node on the clock's engine (D21) |
| `Audio/ClickTrackSynth` | Runtime metronome synthesis for `generatedClick` maps |
| `Input/GestureInputSource` | Buffers entity-targeted gestures as `InputEvent`s stamped with the clock (drag events at their event time, D21). `GameTargetComponent` tags an entity with its note or stroke ID. |
| `Scene/GameSceneController` | Per-frame bridge: clock → rotation → inputs → `GameSession` → note visuals, popups, HUD. No game rules live here. |
| `Scene/GameView` | RealityView + HUD attachment + `SpatialTapGesture().targetedToAnyEntity()` |
| `Scene/GlassObject` | Glass variants A/B/C, the shells, the rotating `surfaceRoot`, sort layers (`setSide`) |
| `Scene/SliderVisuals` | Slider track, end marker, knob (follows the drag; orange when lost), countdown `TimerLabel`; `DragCursor` shows where a drag projects |
| `Scene/NoteVisuals` | Note entities (disc + collision + input target + hover) and looks; `JudgmentPopups` |
| `Scene/PlacementRig` | Head anchor (`.once`) → placement entity 1.1 m ahead, slightly low |
| `Scene/MeshBuilders`, `SceneMath` | Procedural meshes (fresnel-UV sphere, surface ribbons, approach-ring annulus); Double↔Float conversions |
| `GlassLab/GlassLabView` | Rendering prototype scene (debug; spins on host time) |

### Per-frame flow (GameSceneController.frame)

`frame()` runs on every `SceneEvents.Update`, and also straight from each gesture callback when `Tuning.processInputOnArrival` is on (D21). Each run reads the clock afresh, so extra runs between frames change nothing but timing of feedback.

1. `now = clock.nowMs` (audio position).
2. `surfaceRoot.orientation = playfield.orientation(atMs: now)`.
3. Drain `GestureInputSource` and `ScriptedInputSource` (autoplay) → `session.advance(nowMs: now, inputs:)`.
4. For each judged event, spawn a popup, play the hit tick for hits, and refresh the HUD.
5. For each note (view-fixed children of the non-rotating `GlassObject.root`, DECISIONS D18): hidden until it pops up, then popped in. Its approach ring is scaled from `NoteApproach.ringScale`. Its state sets the input target, look and opacity.
6. When `session.isFinished(nowMs:)`, record the result, stop audio, and freeze the rotation.

### Input path

The system does look-and-pinch hit testing; gaze is never read. Two gestures run together on the RealityView:
- `SpatialTapGesture().targetedToAnyEntity()` → `GestureInputSource.tap(on:)` → `.tap(targetID, atMs)` on release.
- `DragGesture(minimumDistance: 0).targetedToAnyEntity()` → `GestureInputSource.drag(on:point:)`/`dragEnded` → `.dragBegan` (press), `.dragChanged`, `.dragEnded`. `GameSceneController` converts the drag location into the placement entity and projects it onto the sphere as a view-space `SurfacePoint`.

The first of the two to reach `GameSession` judges a note, and the second is ignored as already judged. Drag samples move the held slider's knob (`SliderProgress`).

Timing (DECISIONS D9, D21): drag events carry `DragGesture.Value.time`; `GestureInputSource` reads the audio clock and `Date()` together and stamps the event at the clock minus the event's age (`InputTimestamp`). Taps have no event time and are stamped on arrival. The callback then runs `frame()` immediately, which judges the event and plays the hit tick, rather than waiting for the next frame. Auto-misses wait `inputDeliveryGraceMs` so a backdated pinch that arrives after its window closed still counts.

## Build system

`SoundVision.xcodeproj` is hand-written (see DECISIONS). It contains one app target, the `SoundVision/` synchronized folder, `Maps/` as a folder reference (copied with its structure), `Config/Info.plist`, and RhythmCore as a local package. The scheme is shared under `xcshareddata`.
