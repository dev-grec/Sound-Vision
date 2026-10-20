# Decisions

Design choices and why. Read this before undoing something that looks odd. When you change one, update the entry rather than deleting it, and say why.

## Architecture

### D1. All game logic in RhythmCore, a pure Swift package (M0)
Beatmaps, clock math, rotation, the zone, judging, scoring, stroke follow and reveal state all live in `RhythmCore/`, which imports only Foundation and **simd**. It is tested with `swift test` on the Mac, with no simulator and no headset. simd is allowed because it is plain Apple math (not RealityKit) and makes the handoff to entity transforms trivial. The app contains no game rules: it reads the clock, moves entities and forwards input.

### D2. The audio playback position is the master clock (M0)
`AudioEngineClock.nowMs` reads `AVAudioPlayerNode.playerTime(forNodeTime: lastRenderTime)`. Between render buffers (about 10 ms) it interpolates using the render timestamp's host time, capped at 30 ms. It then subtracts `AVAudioSession.outputLatency`, and it never goes backward. Nothing uses frame counts or accumulated deltas. Rotation, judging and auto-misses are pure functions of this value in RhythmCore. The residual error (display latency, pinch latency) is absorbed by the user's input offset. Exact A/V sync is on the device checklist.

### D3. The click track is synthesized at runtime (M0)
The owner's rule is to never commit audio they haven't supplied, but the test map needs to be playable from day one. So beatmaps can say `"audio": {"generatedClick": {...}}`, and `ClickTrackSynth` builds the PCM buffer from the BPM, with no file involved. Real songs use `"audio": {"file": ...}`. That path is implemented but untested until real audio arrives.

### D4. Front direction fixed at placement, using a head anchor with `.once` (M0)
Apps can't follow the head without ARKit. `PlacementRig` uses `AnchorEntity(.head, trackingMode: .once, physicsSimulation: .none)`: the object appears 1.1 m in front of where the head was when the space opened (12 cm below eye level) and then stays put in the room. The hittable zone faces that original head position (`Playfield.front = +Z` of the placement frame). If the player moves sideways mid-song, the zone doesn't follow. That is acceptable for a seated or standing game.
- `physicsSimulation: .none` because anchored content in the default `.isolated` simulation may not be hit-testable by entity-targeted gestures.
- If the head was tilted at launch, the placement frame inherits the tilt. That's on the device checklist.
- **Not done:** ARKit `WorldTrackingProvider` device pose. It is not hand or eye tracking, but it adds an ARKit session and could track the zone continuously. It needs the owner's approval first. It may be needed in M2, when the player walks around the finished artwork (see D10).

### D5. Hand-written Xcode project with synchronized folders (M0)
No xcodegen or tuist was installed, and adding tools to the owner's Mac wasn't necessary. `SoundVision.xcodeproj/project.pbxproj` is small and hand-maintained:
- `SoundVision/` is a `PBXFileSystemSynchronizedRootGroup`, so new Swift files join the target automatically. **Don't add per-file entries.**
- `Maps/` is a folder reference, so it is copied with its folder structure and every map keeps its own `beatmap.json`.
- RhythmCore is an `XCLocalSwiftPackageReference`.
- `Config/Info.plist` lives outside the synchronized folder, so it isn't also copied as a resource.

### D6. Swift 6 with MainActor default isolation in the app (M0)
The app target uses `SWIFT_VERSION = 6.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency. App classes that implement RhythmCore protocols use isolated conformances (`final class AudioEngineClock: @MainActor PlaybackClock`). RhythmCore's types are `Sendable` value types.

### D7. Don't name a type `GameController` (M0)
It clashes with Apple's GameController framework, which RealityKit pulls in. The scene bridge is `GameSceneController`.

## Input and judging

### D8. System look-and-pinch only (owner's rule)
Notes are entities with `CollisionComponent` + `InputTargetComponent` + `HoverEffectComponent` and a `GameTargetComponent(targetID:)`. `SpatialTapGesture().targetedToAnyEntity()` delivers pinches. No ARKit hand tracking, no eye tracking, and nothing reads gaze before a pinch.
- **The glass shells have no collision or input target**, so they can't swallow pinches aimed at notes.
- A note's input target is enabled only while it's on screen (pop-up to judgment). Hidden notes are disabled entities, so nothing on the far side can be pinched.
- A pinch must target the note entity itself. There is no "nearest note" assist. If device testing shows misses from imprecise targeting, try a bigger `noteHitRadiusScale` before adding an assist.

### D9. Pinches are timestamped on arrival, and the offset is applied only in RhythmCore (M0)
Gesture callbacks carry no audio timestamp, so `GestureInputSource` stamps each event with `clock.nowMs` when the callback runs. `Tuning.inputOffsetMs` is subtracted only in `TapJudge.delta`, `GameSession` (pop-up gating, auto-miss, slider end) and `PathFollowScorer`. Never apply it in the app as well.
- Each frame, inputs are processed **before** auto-misses, so a pinch stamped inside its window still counts if the frame that delivers it lands just after the window closed.
- **A pinch on a visible note always ends it** (owner's request, 2026-10-19). Inside the Good window it's judged Perfect/Great/Good. Outside it, the note becomes a Miss (combo breaks) and the app shows "Early" or "Late" (`NoteState.missed(atMs:deltaMs:)` keeps the delta). Before pop-up a note is hidden and can't be pinched. History: the first build ignored off-window pinches silently, which looked like broken input; the next build showed Early/Late but left the note up, and the owner wanted the note to end.

## Rendering

### D10. Glass rendering: variant C (two sorted shells + baked fresnel) is the gameplay default (M0)
**Problem:** overlapping transparent meshes in RealityKit can sort wrongly. The glass, notes behind it and notes in front of it all overlap.

**Constraints found in the visionOS 26.5 SDK:**
- `CustomMaterial` (Metal surface shaders) is `@available(visionOS, unavailable)`.
- RealityKit has no refraction or screen-space transmission for app content. "Glass" here means transparency, specular highlights and clearcoat.
- A custom fresnel would need a Reality Composer Pro ShaderGraph. No MaterialX node definitions ship on disk to check node IDs against, so a hand-written `.usda` graph would be guesswork. Building one in the Reality Composer Pro GUI is an M3 polish option.

**What the Glass Lab compared** (simulator screenshots, 2026-10-19; switch variants live in the launcher):
- **A, naive** (one transparent PBR sphere, `faceCulling = .none`, no sort help). It looks glassy, and the system lighting gives a nice rim highlight on its own. But far-side notes render as solid as near ones, so you can't tell front from back, which matters because the approach is coming around from behind. **Rejected.**
- **B, two shells + sort order.** A back-face shell (`faceCulling = .front`, opacity 0.10) and a front-face shell (`.back`, 0.18) in one `ModelSortGroup`. Each frame every surface item is put in layer 0 (far: drawn before the back shell) or layer 3 (near: drawn after the front shell), decided by the sign of its normal against the front direction. Far items are also dimmed to `Tuning.farSideOpacity` (0.35) with `OpacityComponent`. Depth reads correctly: far notes and strokes look like they're behind the glass, and near ones sit on it. No sorting artifacts were seen in the screenshots.
- **C, B + baked fresnel.** The same shells, built as a UV sphere with poles on ±Z and a `BillboardComponent` that keeps +Z toward the viewer. A 1×256 grayscale opacity ramp along v (polar angle from the viewer: 0.05 facing the viewer, rising to 0.65 at the silhouette) is used as the transparent-blending opacity texture. The center is a little clearer than B, so notes and strokes behind the front glass keep more color, and the rim stays bright. **The difference from B is subtle in the simulator.**

**Chosen:** C for gameplay (`GlassVariant.defaultForGameplay`). B is the fallback if C's texture fails to build. The shells don't rotate (a sphere looks the same however it's turned), which is what lets C keep its rim on the viewer. Only `surfaceRoot` rotates.

**Known limits:**
- Sorting uses the fixed front direction, not the live head position. That is fine while the player stands in front. When the player walks around the artwork in M2, far and near need the real viewpoint (see D4).
- A note crossing the silhouette switches layer in one frame. It hasn't been seen to pop in the simulator, but it's on the device checklist.
- Everything above is simulator-only. **Check the glass look on the headset.**

### D11. Notes and strokes are lifted off the surface (M0)
Notes sit `Tuning.noteSurfaceLiftM` (4 mm) above the sphere, and stroke ribbons 2 mm above, to avoid z-fighting with the shells. Ribbons use `faceCulling = .none` because far-side ribbons are seen from behind through the glass. Long ribbons are split into pieces, so each piece is sorted on its own side as it crosses over.

## Beatmaps and scoring

### D12. Beatmap units and shapes (M0)
Times are ms from the start of the audio, because notes are exact moments. Rotation is in beats, because it follows the meter. Surface points are JSON objects (`{"lat","lon"}`), not pairs, so other shapes can add coordinate kinds without breaking v1. The crowding rule compares surface positions directly: the object is rigid, so the angle between two points on it never changes as it rotates. Two targets are compared when their targetable intervals overlap (D16), not within a fixed time window. The first version used a fixed 2 s window, which missed same-latitude notes 2 s apart that are both targetable at once.

### D13. Follow score is bucketed by time (M0; strokes and sliders)
The stroke's duration is split into `Tuning.strokeScoreBuckets` buckets. Each bucket takes its samples' mean credit, and an empty bucket scores 0. This makes the score independent of the drag event rate, and letting go early costs exactly the unplayed fraction.

### D14. Tuning is one Codable struct with defaults (M0)
Every game-feel number is in `RhythmCore/Sources/RhythmCore/Tuning.swift`. The synthesized `Decodable` requires every key, so M2's persisted settings need a decoder that falls back to the defaults for missing keys.

### D16. Notes exist only from their pop-up (M0, found in the simulator)
The object rotates continuously, so every surface point passes the front once per revolution. The first build drew every pending note all the time, and the simulator showed notes due 40 s later glowing as hittable next to the current ones, overlapping them. Now each note has a `NoteApproach` (`GameSession.approaches`): it is hidden and disabled (no input) until `appearMs`, then pops up. Regression test: `LappingTests`. (An interim fix showed notes from their "final approach" on the far side; D17 replaced that.)

### D17. Approach ring is the timing cue; notes pop up around the play area (owner's design change, 2026-10-19)
The original brief made the rotation the approach: a note became hittable as it rotated into a front zone, and its beat was when it reached center. On trying it, the owner clarified the intended design: notes **pop up around the player's view**, and **an outer ring tells you exactly when to click**. So:
- A note pops up `Tuning.approachMs` (1500 ms) before its time. An approach ring (`NoteVisuals` child "approachRing", `NoteApproach.ringScale`) shrinks from `approachRingStartScale` (3×) to the note's edge and closes at the hit time.
- Notes are placed anywhere in the **play area** (`hitZoneHalfAngleDeg`, now 45°) and must stay in it while on screen (validator). The center hit-zone outline is gone, along with the "comfort angle" warning and the targetable angle.
- The object still rotates slowly in time with the music. (At first notes rode on it; D18 changed that.)
- Crowding compares targets on screen at the same time (pop-up to window close).
- Notes no longer show faintly on the far side before they arrive (the brief had them visible through the glass as they came around). A faint preview of upcoming notes could come back as an option if the owner wants it.

### D18. Tap notes are fixed in the player's view; flow comes from note sequences (owner's design, 2026-10-19)
After trying D17, the owner said: "I don't want the buttons to be moving really, rather there to be more buttons that follow movement. For example, if I want to draw my user's eyes to the right, we should have multiple dots going from left to right." So:
- A tap note's `at` is a position in the player's view (placement frame), not on the rotating surface. Note entities are children of the non-rotating `GlassObject.root`; they never move while on screen.
- Movement and direction are expressed by placing **sequences** of notes (streams) along a path, one per beat. The test map demonstrates left-to-right, right-to-left, diagonal and circular streams.
- The object still rotates in time with the music, and **strokes stay on the rotating surface** (they make up the picture). That's why the format has two frames (BEATMAP_FORMAT, "Coordinates").
- Validation is simpler: a note is in the play area or not; crowding compares view positions of targets on screen together. A stroke's start is compared where it sits in view at its start time.
- Laps (D16) no longer affect tap notes, since they don't ride the surface. Pop-up gating still applies.

### D19. Sliders: a tap note with a path; random cardinal sliders for now (owner's design, 2026-10-19)
The owner asked for sliders "that take us in a direction for a second", of varying length, in a random cardinal direction. Answers to the follow-up questions: "some notes are just notes, some notes include a slider; both will be involved when we eventually make rotating 3D objects"; direction is "random for now just because we are developing; eventually every level will have a design I'll make related to the song"; input is pinch, hold, drag.
- **Model:** `TapNote.slider: Slider?` (`durationMs` + view-space `path` after the head). Path-based rather than direction + length, so designed levels can bend sliders later without a format change. `Slider.cardinal(...)` builds straight ones.
- **Play:** superseded by D20 (the first version scored the drag against a ball that moved on its own).
- **Input:** `DragGesture(minimumDistance: 0).targetedToAnyEntity()` runs *simultaneously* with the existing `SpatialTapGesture`. The drag reports the press (`.dragBegan`), movement and release. The tap reports the release (`.tap`). Whichever reaches the session first judges a note, and the other is ignored as already judged. This keeps the tap path the owner already verified. **Drag mapping is relative (`DragTracker`).** The first build converted the absolute drag location into the placement entity (`value.convert(location3D, from: .local, to: placement)`). The placement entity sits under a head `AnchorEntity`, whose transform visionOS hides from apps, so every drag landed near latitude 78°, close to the top of the sphere. In the owner's run, a Perfect head plus a correct follow scored "follow 0%" and a Miss. Now the drag is anchored to the pinched entity's position in the placement frame (relative transforms under the same anchor are reliable) plus the hand's movement in **scene** space since the pinch: point = target + (location − startLocation), projected onto the sphere. This assumes the placement axes match the scene axes. That holds because the head anchor resolves when the immersive space opens, and the space's axes are set from the player's facing direction at that moment. Device check: launch while looking off to the side. A pinch off the note's center becomes a constant offset (at most the note radius, about 7°). The input log prints each drag's start and end (lat, lon), and the white `DragCursor` dot shows where the drag lands. The alternative, ARKit `WorldTrackingProvider` device pose so content can live in plain world space, still needs the owner's approval (D4).
- **Release grace:** a first version gave 150 ms of grace for letting go early; D20 removed it, since a slider now finishes the moment the knob reaches the end.
- **Speed:** the owner asked for quicker sliders. Random durations went from 1–4 beats to 1–2 beats (0.5–1 s at 120 BPM), and the speed cap from 60°/s to 75°/s.
- **Random sliders (development):** `RandomSliders.add(to:tuning:seed:)` attaches cardinal sliders where a note has room before the next one, and keeps a candidate only if the map stays valid. It is seeded (`SeededRandom`, SplitMix64), so a layout can be replayed: the seed is logged, and `-sliderSeed N` fixes it. It is on by default (launcher toggle). Remove or turn off once levels are designed.
- The test map's opening and closing sections were respaced to one note per 2 s, so there is room for sliders up to 1.5 s.

### D20. Sliders are timed: the knob follows the drag, and the finish is judged against a target time (owner's design, 2026-10-19)
The owner: "I need the button on the slider to follow the cursor… each slider needs to have a predetermined time in which I should take to finish it. If I finish it early it should say early and if I don't finish it in time then miss. I haven't decided how to show this in game, so for now put a little timer on top of the slider where 0 is perfect. Give some grace period for perfects."
- **Knob follows the drag** (`SliderProgress`): each drag sample is projected onto the track (`StrokePath.closest`). While it's within `sliderGrabRadiusDeg` (15°), the knob moves to that point, and it never moves backward. Further away, the knob stops and shows orange. Reaching `sliderEndToleranceDeg` (1.5°) of the end finishes the slider at that moment. Release isn't needed after that.
- **Timing, not path accuracy, is judged:** finish delta = finish time − (head time + duration), judged with slider-specific windows (Perfect ±100 ms "grace", Great ±180, Good ±260; taps are ±60/110/170). Finishing earlier is Early (Miss). Not finishing by the end of the Good window, or letting go first, is a Miss. Final = the worse of head and finish (`GameSession.sliderJudgment`). The follow scorer (`PathFollowScorer`) is now used only for strokes.
- **Timer** (`TimerLabel` in `SliderVisuals.swift`): above the slider, billboarded (moved beside the slider in D21, so it clears the track and the popups). Before the pinch it shows the duration. While held it counts down `endMs − now` in seconds (green inside the Perfect window). After finishing it shows the signed finish delta (e.g. −0.03) in the judgment's color for `sliderResultDisplayMs`, then fades. Placeholder UI until the owner decides how to show slider timing. Implementation note: each character slot has one pre-built entity per character and only toggles visibility. Swapping meshes made the every-frame digit vanish.
- Autoplay drags at the slider's own pace, so it finishes on target.

### D21. Design pass: readability of notes, sliders and text; launcher hidden during play (2026-10-19)
A presentation-only pass (no gameplay rule changed), judged from simulator screenshots against light rooms, which are the hard case in mixed reality.
- **Launcher hidden during play.** The launcher window sat behind the sphere and showed through the glass (a known issue). `LauncherView.open` now dismisses the window (`dismissWindow(id:)`, `WindowGroup(id: AppModel.launcherWindowID)`) once a game's immersive space has opened, and `ImmersiveRootView.onDisappear` reopens it (`openWindow(id:)`) whenever the space closes, including when the system closes it. The HUD carries an Exit button ("Back to Menu" after the song), and the launcher shows the last result above the settings. The Glass Lab keeps the window, since its variant picker is used live. `AppModel.autostartDone` stops `-autostart` from reopening the space when the window comes back. Not used: the `Window` scene (single instance, but only from visionOS 26.0 and a bigger change to how the app launches) and `pushWindow` (it is for windows, not immersive spaces).
- **Notes.** A white rim on the disc's edge, so the closing ring lands on something visible; the ring got a thin dark outline (translucent, under the white band) for contrast on light walls and on the glass rim, and is a little thicker (`approachRingThicknessM` 4 mm) and starts brighter (`approachRingStartOpacity` 0.45). Pop-in overshoots slightly (ease-out-back), the hit flash eases out, and a miss shrinks a little as it fades. The hit and miss durations moved from literals in `GameSceneController` into Tuning (`noteHitFlashMs`, `noteMissFadeMs`, same values). The animation code moved into `NoteVisuals.showApproach/showHit/showMiss`.
- **Sliders.** The track is as wide as the end ring, with white edge lines and a thin start ring, so it reads as a lane rather than a faint smear; the knob has the same white rim as a note (the fill still turns orange when lost).
- **Timer** (placeholder UI, same countdown semantics): digits are bigger (`sliderTimerFontSizeM` 3 cm, was 2.6) on a dark rounded plate, because white digits disappeared over the bright glass rim. It sits **beside** the slider instead of above it: centered below a horizontal slider, and on the outer side of a vertical one (away from the middle of the play area, where the other notes are). Above the slider it overlapped the judgment popups, which rise from the head and the end. If the owner wants it back on top, change the placement block in `SliderVisuals.init`.
- **Judgment popups** have a dark drop shadow (same glyphs, behind), settle in from 125% size, and start just above their note instead of in front of it, because from the player's eye the text covered the note's own hit or miss flash.
- **Rendering notes.** Putting the timer's glyphs in a `ModelSortGroup` made a glyph enabled that frame not draw, so the every-frame digit vanished during the countdown (seen in the simulator); the plate relies on depth instead (2 mm behind opaque glyphs). Popups use their own sort group (shadow before text); they are cloned, not toggled, and draw fine.
- **Left alone:** the glass (D10; nothing low-risk stood out), note orientation (discs lie on the glass, so notes near the edge of the play area look a little oval; facing them to the player would push their inner edge into the glass), and the HUD layout apart from the button.

## Debug tooling

### D15. Autoplay and launch arguments (M0)
`ScriptedInputSource.autoplay` feeds perfect taps through the same `InputSource` path as gestures, so the full loop runs in the simulator without clicking. Launch arguments (`-autostart game|glassLab`, `-autoplay YES`, `-autoplayEarlyMs N` to make autoplay pinch N ms early, `-exitOnFinish YES` to close the space 2 s after the song so the run ends in the launcher with the result, `-sliderSeed N` to replay a random slider layout, `-randomSliders NO`, `-glassVariant A|B|C`, `-inputOffsetMs N`; negative values can't be passed this way) let scripts open scenes directly (`scripts/run-sim.sh`). The Glass Lab spins on host time (`HostTimeClock`) because it plays no audio. **Gameplay must never use HostTimeClock.**
