# Status

Update this at the end of every session: what changed, what's in progress, known bugs, what's next. Newest session first in the log at the bottom.

## Current state: M0 complete in the simulator (2026-10-19)

Nothing has been run on a Vision Pro yet. Everything that needs the headset is in `DEVICE_TEST_CHECKLIST.md`.

### Done (M0)

- **Scaffold**: hand-written `SoundVision.xcodeproj` (visionOS 26.0 target, Swift 6) plus the `RhythmCore` local package. Scripts: `scripts/test.sh`, `scripts/build.sh`, `scripts/run-sim.sh`.
- **Docs**: CLAUDE.md, ARCHITECTURE, BEATMAP_FORMAT, DECISIONS, DEVICE_TEST_CHECKLIST, this file.
- **Beatmap format v1**, with loader (version check first) and validator (format rules plus playability rules: zone placement, crowding, rotation speed, stroke rules).
- **Test map** `Maps/test-metronome/beatmap.json`: 120 BPM, 30 bars, synthesized click, 29 tap notes spread around the play area, 2 strokes (strokes load but aren't playable until M1), and a rotation speed change at beat 64. Validates with no errors or warnings.
- **RhythmCore engine** with 93 unit tests: geometry, rotation schedule, playfield and play area, note approach (pop-up and ring), tap judging, scoring and combo, GameSession (inputs, auto-miss, offset, laps), scripted input and autoplay, stroke path, follow scoring, reveal state.
- **Audio master clock** (`AudioEngineClock`) and the runtime click synthesizer.
- **Glass rendering prototype** (Glass Lab, variants A/B/C). Findings are in DECISIONS D10. C is the gameplay default.
- **Tap-note gameplay** (approach-ring design, DECISIONS D17): a slowly rotating glass sphere in front of the player. Notes pop up around its front, and a shrinking ring closes on each note exactly on the beat. Look-and-pinch via `SpatialTapGesture` on entities. Judgment popups, plus "Early"/"Late" for off-beat pinches, a HUD (with an orange AUTOPLAY badge when autoplay is on), and a result summary in the launcher. Autoplay plays the whole map through the same input protocol.

### Verified in the simulator

- Build succeeds with no Swift warnings. All 93 tests pass.
- Glass Lab A/B/C render as described in D10 (screenshots).
- Full autoplay run of the test map: 29/29 Perfect, max combo 29, score 8700. The song ends 61.5 s after audio start (60 s plus a 1.5 s tail), which matches the audio clock.
- A debug-build log compared each note's rendered position (RealityKit, relative to the placement entity) with RhythmCore's `Playfield.worldPosition`. They agree to about 1e-7 m.
- Without autoplay (screenshots): notes pop up at different spots with a wide faint ring that tightens onto them, and turn into Misses when their window passes.

### Not verified anywhere yet

- **Manual pinching in the simulator** (click a note when its ring closes). This is still unconfirmed. The owner's first attempts ran with autoplay accidentally on (left over from a scripted launch), so the scripted player hit everything. Every pinch is now logged at info level ("pinch gesture on …", "hit …", "pinch on … ignored: …"): read it with `xcrun simctl spawn booted log show --last 10m --info --predicate 'subsystem == "com.devgrec.SoundVision"'`. If no "pinch gesture" lines appear when clicking, gestures aren't reaching the app; check DECISIONS D4 (`physicsSimulation: .none` on the head anchor) first.
- File-based audio (`"audio": {"file": ...}`). Implemented, but untested until real audio is supplied.

## Known issues

- The launcher window stays open behind the sphere during play and shows through the glass. Consider hiding it during play (M2 menus).
- Far/near sorting assumes the player is in front (fixed front direction). This needs the live viewpoint when walking around the artwork in M2 (D4, D10).
- `Tuning`'s synthesized Decodable needs every key, so it needs a tolerant decoder before persisting settings in M2 (D14).

## Next

- **M1, stroke notes.** Render guided paths as ribbons (use `MeshBuilders.surfaceRibbon`). Add a moving guide marker from `StrokeFollowScorer.guidePoint`. Make stroke starts pinch targets. Add `DragGesture().targetedToAnyEntity()`: convert the location into `surfaceRoot` space, project with `Playfield.surfacePoint(fromObjectLocal:)`, and feed `.dragBegan/Changed/Ended` into the session. Extend `GameSession` to judge stroke starts and score follow. Add color reveal from `RevealState`. Generate autoplay drags for strokes. Add the device checklist items for drag mapping.
- **M2**: end-of-song artwork reveal (object stops, walk around), results screen, menus, song select, settings with offset calibration.
- **M3**: beatmap editor, other shapes, visual polish (possibly a Reality Composer Pro ShaderGraph glass), the owner's designs and music.

## Session log

### 2026-10-19, session 1 (M0)
Built everything listed under "Done". Environment: Xcode 26.6, visionOS 26.5 SDK and simulator, Swift 6.3.3.
Bug found and fixed in the simulator: notes due on a later revolution showed as hittable next to the current ones (see DECISIONS D16). The fix made the crowding rule stricter, which flagged the first test map, so it was re-spaced (29 notes became 24).
Owner feedback, same day: "buttons should pop up around the view of the player, and an outside ring tells you exactly when to click", not notes scrolling to the center. Redesigned to that (D17): pop-up notes, approach rings, a 45° play area, on-screen crowding; the test map was rewritten to spread notes around (29 notes). The owner's earlier runs had autoplay on by accident (the simulator was still running a scripted `-autoplay YES` launch); added the AUTOPLAY badge, Early/Late feedback and pinch logging.
**Rule for future sessions:** after scripted simulator runs, relaunch the app plain (`xcrun simctl launch booted com.devgrec.SoundVision`) so the owner doesn't inherit autoplay.
Simulator verification is scripted: `scripts/run-sim.sh -autostart game -autoplay YES`, then `xcrun simctl io booted screenshot <file>`. The game logs `started`/`finished` lines under subsystem `com.devgrec.SoundVision`; read them with `xcrun simctl spawn booted log stream --predicate 'subsystem == "com.devgrec.SoundVision"'`.
