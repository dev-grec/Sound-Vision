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
│ StrokePath · StrokeFollowScorer · RevealState · InputEvent/InputSource             │
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
| `Playfield` | `Geometry/Playfield.swift` | Shape + rotation as seen from the player: world normal and position at time t, angle from front, play-area checks (`isInHitZone`, `maxAngleFromFrontDeg`), far side, projecting placement-frame or object-local points to the surface |
| `PlaybackClock`, `ManualClock`, `BeatGrid` | `Timing/Clock.swift` | Clock protocol (the app's audio clock implements it); ms ↔ beats |
| `RotationSchedule` | `Rotation/RotationSchedule.swift` | Orientation as a pure function of time, computed analytically per segment |
| `Judgment`, `TapJudge` | `Gameplay/Judgment.swift` | Timing tiers; the input offset is applied here |
| `ScoreKeeper` | `Gameplay/ScoreKeeper.swift` | Score, combo, max combo, accuracy, counts |
| `GameSession` | `Gameplay/GameSession.swift` | One play-through: `advance(nowMs:inputs:)` handles inputs, then auto-misses. Returns `Event`s (judged or ignored-with-reason). Per-note `approaches` and `hasAppeared` (D16, D17). Tap notes only in M0. |
| `NoteApproach` | `Gameplay/NoteApproach.swift` | Pop-up time and approach-ring progress and scale for a target (D17) |
| `StrokePath`, `StrokeFollowScorer`, `RevealState` | `Gameplay/StrokeFollow.swift` | M1 logic, already tested: guide position, bucketed follow score, reveal level and animation |
| `InputEvent`, `InputSource`, `ScriptedInputSource` | `Input/InputEvent.swift` | Device-independent input; scripted source for tests and autoplay |

### Frames and conventions

- **Object-local frame**: rotates with the object. Beatmap surface points live here.
- **Placement frame**: non-rotating, centered on the object. +X right, +Y up, +Z toward the player. `Playfield.front = +Z`.
- `orientation(atMs:)` maps object-local to placement. The app sets `surfaceRoot.orientation` to it every frame.
- All times are master-clock ms (audio position). Inputs carry raw clock time; only `TapJudge`/`StrokeFollowScorer`/`GameSession` subtract `Tuning.inputOffsetMs`.

## SoundVision app (`SoundVision/`)

A synchronized folder: files added here join the target with no pbxproj edit.

| Piece | Responsibility |
|---|---|
| `SoundVisionApp`, `AppModel` | Scenes (WindowGroup + mixed ImmersiveSpace), shared state (mode, tuning, autoplay, glass variant, last result), launch-argument hooks for automated runs |
| `Launcher/LauncherView`, `MapLibrary` | 2D window: play, Glass Lab, autoplay toggle, input-offset slider, glass variant picker, validation messages, last result. Loads `Maps/` from the bundle. |
| `Audio/AudioEngineClock` | **Master clock.** AVAudioEngine + AVAudioPlayerNode; `nowMs` from the render position (see its doc comment). Loads click or file audio. |
| `Audio/ClickTrackSynth` | Runtime metronome synthesis for `generatedClick` maps |
| `Input/GestureInputSource` | Buffers entity-targeted gestures as `InputEvent`s stamped with the clock. `GameTargetComponent` tags an entity with its note or stroke ID. |
| `Scene/GameSceneController` | Per-frame bridge: clock → rotation → inputs → `GameSession` → note visuals, popups, HUD. No game rules live here. |
| `Scene/GameView` | RealityView + HUD attachment + `SpatialTapGesture().targetedToAnyEntity()` |
| `Scene/GlassObject` | Glass variants A/B/C, the shells, the rotating `surfaceRoot`, sort layers (`setSide`) |
| `Scene/NoteVisuals` | Note entities (disc + collision + input target + hover) and looks; `JudgmentPopups` |
| `Scene/PlacementRig` | Head anchor (`.once`) → placement entity 1.1 m ahead, slightly low |
| `Scene/MeshBuilders`, `SceneMath` | Procedural meshes (fresnel-UV sphere, surface ribbons, approach-ring annulus); Double↔Float conversions |
| `GlassLab/GlassLabView` | Rendering prototype scene (debug; spins on host time) |

### Per-frame flow (GameSceneController.frame)

1. `now = clock.nowMs` (audio position).
2. `surfaceRoot.orientation = playfield.orientation(atMs: now)`.
3. Drain `GestureInputSource` and `ScriptedInputSource` (autoplay) → `session.advance(nowMs: now, inputs:)`.
4. For each judged event, spawn a popup and refresh the HUD.
5. For each note: hidden until it pops up, then popped in. Its approach ring is scaled from `NoteApproach.ringScale`. Its state sets the input target, look, opacity and sort layer.
6. When `session.isFinished(nowMs:)`, record the result, stop audio, and freeze the rotation.

### Input path

The system does look-and-pinch hit testing. `SpatialTapGesture` targeted to an entity with Collision + InputTarget runs `GestureInputSource.tap(on:)`, which records `.tap(targetID, atMs: clock.nowMs)`. The next frame, `GameSession` checks the zone and the timing window. Gaze is never read. Stroke drags (M1) will add `DragGesture().targetedToAnyEntity()`, which converts the location into the rotating `surfaceRoot` space (`value.convert(_:from:to:)`) and projects it with `Playfield.surfacePoint(fromObjectLocal:)`.

## Build system

`SoundVision.xcodeproj` is hand-written (see DECISIONS). It contains one app target, the `SoundVision/` synchronized folder, `Maps/` as a folder reference (copied with its structure), `Config/Info.plist`, and RhythmCore as a local package. The scheme is shared under `xcshareddata`.
