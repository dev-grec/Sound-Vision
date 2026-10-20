# Sound Vision: orientation for Claude Code sessions

**Read `docs/STATUS.md` before starting any work.** Update it at the end of every session.

Several Claude Code instances work on this project in separate sessions that cannot see each other. The repo and its docs are the only shared memory, so keeping them accurate is part of every task.

## What this is

A rhythm game for Apple Vision Pro, played on the surface of a transparent glass object (a sphere for now) that floats in a mixed-reality immersive space and rotates slowly in time with the music.

- **Tap notes** pop up at fixed spots in the player's view, around the front of the object (the play area); they don't move. A shrinking **approach ring** around each note closes exactly on the beat; the player looks at the note and pinches when the ring closes. A pinch outside the timing window ends the note as a Miss ("Early"/"Late"). Direction and flow come from **sequences of notes** (e.g. dots left to right), not from moving notes. (Owner's design, 2026-10-19: DECISIONS D17, D18, D9.)
- **Sliders:** some notes carry a slider: pinch the head on the beat, then drag the knob (it follows your drag) along the track and reach the end at the slider's target time. A timer beside it counts down to 0.00 = Perfect; arriving early is Early, late or never is a Miss. For now the app adds random up/down/left/right sliders each play (development); the owner will design each level's sliders later. (DECISIONS D19, D20.)
- **Stroke notes** (M1): look at the start point, pinch on time, hold, and drag along a guided path, following a moving guide. A completed stroke fills with its final color. Strokes live on the object's rotating surface.
- **The picture** (M2): all of a song's strokes together form a hidden artwork. At song end the object stops and shows it, vivid where the player did well.

## Hard rules

- **No eye tracking and no hand tracking.** Use only the system's look-and-pinch: entities with `CollisionComponent` + `InputTargetComponent` + `HoverEffectComponent`, receiving `SpatialTapGesture` / `DragGesture` targeted to entities. No ARKit hand tracking.
- **Apps can't see gaze.** They only learn which entity was targeted when the pinch happens. Never design a mechanic that depends on gaze before a pinch.
- **Eye targeting is imprecise.** Notes must be large, spaced apart, and slow-moving. Never put two notes close together at the same moment (the beatmap validator enforces this).
- **Pinch has latency.** Hit windows are generous and configurable, and there is a user input offset.
- **The audio playback position is the master clock.** Rotation, note timing and judging all derive from it, never from frame counts or accumulated deltas.
- **Stroke drags** are converted into the object's local space (which accounts for its rotation) and projected onto the surface before being compared with the guide.
- **All game-feel numbers live in `RhythmCore/Sources/RhythmCore/Tuning.swift`.** Don't scatter constants.
- **Never commit audio the project owner hasn't supplied.** The test map uses a click track synthesized at runtime.
- **Never claim something works on the Vision Pro unless the owner has confirmed it.** Anything verified only in the simulator goes in `docs/DEVICE_TEST_CHECKLIST.md`.
- If the SDK makes a request impractical, tell the owner and propose an alternative. Don't silently work around it.
- Big architecture changes require updating `docs/ARCHITECTURE.md` and `docs/DECISIONS.md`, and telling the owner. Read DECISIONS before undoing anything that looks odd.

## Where things live

| Path | What |
|---|---|
| `RhythmCore/` | Pure Swift package (Foundation + simd only, no RealityKit/SwiftUI): beatmap model and validator, geometry, clock, rotation, play area, note approach, judging, scoring, stroke follow, reveal state, input protocol. All game logic goes here. |
| `RhythmCore/Sources/RhythmCore/Tuning.swift` | The single tunable settings file |
| `SoundVision/` | visionOS app (SwiftUI + RealityKit). A synchronized folder: new files are picked up automatically, no pbxproj edits needed. |
| `SoundVision.xcodeproj` | Hand-maintained project (see DECISIONS) |
| `Maps/` | Beatmaps, one folder per song (`beatmap.json` + its audio). Bundled into the app as a folder reference. |
| `Config/` | App Info.plist |
| `scripts/` | `test.sh`, `build.sh`, `run-sim.sh` |
| `docs/` | ARCHITECTURE, BEATMAP_FORMAT, STATUS, DEVICE_TEST_CHECKLIST, DECISIONS |

## Build and test

Requires Xcode 26.6 or later with the visionOS 26.5 SDK. The app targets visionOS 26.0.

```sh
scripts/test.sh        # swift test for RhythmCore (runs on the Mac, fast)
scripts/build.sh       # xcodebuild for the "Apple Vision Pro" simulator
scripts/run-sim.sh     # build, boot the simulator, install, launch
```

Run both the tests and the build before every commit, and fix build errors before calling a task done. Use small commits with clear messages.

In the simulator, a click is a pinch and a click-drag is a drag. The launcher has an **Autoplay** toggle that feeds scripted input through the same `InputSource` protocol, so the full loop can be checked without clicking.

## Milestones

M0: scaffold, docs, beatmap format, core engine, glass prototype, tap notes. M1: stroke notes and color reveal. M2: end-of-song artwork, results, menus, song select, settings and calibration. M3: beatmap editor, other shapes, polish, the owner's designs and music. Current state is in `docs/STATUS.md`.
