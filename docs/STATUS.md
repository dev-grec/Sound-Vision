# Status

Update this at the end of every session: what changed, what's in progress, known bugs, what's next. Newest session first in the log at the bottom.

## Current state: M0 complete in the simulator (2026-10-19)

Nothing has been run on a Vision Pro yet. Everything that needs the headset is in `DEVICE_TEST_CHECKLIST.md`.

### Done (M0)

- **Scaffold**: hand-written `SoundVision.xcodeproj` (visionOS 26.0 target, Swift 6) plus the `RhythmCore` local package. Scripts: `scripts/test.sh`, `scripts/build.sh`, `scripts/run-sim.sh`.
- **Docs**: CLAUDE.md, ARCHITECTURE, BEATMAP_FORMAT, DECISIONS, DEVICE_TEST_CHECKLIST, this file.
- **Beatmap format v1**, with loader (version check first) and validator (format rules plus playability rules: zone placement, crowding, rotation speed, stroke rules).
- **Test map** `Maps/test-metronome/beatmap.json`: 120 BPM, 30 bars, synthesized click, 34 view-fixed tap notes: an opening and a closing section at one note per 2 s (room for sliders), and streams in between (left to right, right to left, diagonals, a circle). 2 strokes (load, not playable yet). A rotation speed change at beat 64. No sliders written in; random ones are added at runtime.
- **RhythmCore engine** with 116 unit tests: geometry, rotation schedule, playfield and play area, note approach (pop-up and ring), tap judging, sliders (model, session, validation, random generator), scoring and combo, GameSession (inputs, auto-miss, offset), scripted input and autoplay (including sliders), stroke path, follow scoring, reveal state.
- **Audio master clock** (`AudioEngineClock`) and the runtime click synthesizer.
- **Glass rendering prototype** (Glass Lab, variants A/B/C). Findings are in DECISIONS D10. C is the gameplay default.
- **Tap-note gameplay** (DECISIONS D17, D18, D9): a slowly rotating glass sphere in front of the player. Notes pop up at fixed spots around its front (they don't move), and a shrinking ring closes on each note exactly on the beat. Look-and-pinch via `SpatialTapGesture` on entities. A pinch outside the window ends the note as a Miss shown as "Early"/"Late". Judgment popups, a HUD (with an orange AUTOPLAY badge when autoplay is on), and a result summary in the launcher. Autoplay plays the whole map through the same input protocol.
- **Sliders** (DECISIONS D19): some notes carry a slider: pinch the head on the beat, hold, and drag along a track following a ball inside a follow ring (orange when drifting). Final judgment from head timing plus follow score. Random up/down/left/right sliders are added each play for development (launcher toggle; seed logged; `-sliderSeed N` replays).

### Verified in the simulator

- Build succeeds with no Swift warnings. All 116 tests pass.
- Glass Lab A/B/C render as described in D10 (screenshots).
- Full autoplay run of the test map (34 notes, with random sliders): 34/34 Perfect. The song ends 61.5 s after audio start (60 s plus a 1.5 s tail), which matches the audio clock.
- A debug-build log compared each note's rendered position (RealityKit, relative to the placement entity) with RhythmCore's `Playfield.worldPosition`. They agree to about 1e-7 m.
- Without autoplay (screenshots): notes pop up at different spots with a wide faint ring that tightens onto them, and turn into Misses when their window passes.
- Autoplay shifted 400 ms early (`-autoplayEarlyMs 400`): every pinch ends its note as a Miss with "Early" (log: `hit n01: miss, delta -400 ms`).
- Sliders with autoplay (seeds 1–5 sampled): 5–7 random sliders per play, all four directions, 18–44°, 0.5–2 s, each followed at 100% and judged Perfect. Screenshots show the track, end marker, head with approach ring, and the ball in its follow ring moving along the track. Full run (random seed 1034298874, 6 sliders): 34/34 Perfect, max combo 34, score 10200.
- **Owner, in the simulator: clicking works.** The log of the owner's session showed Perfect/Great/Good hits with deltas between -104 and +165 ms.

### Not verified anywhere yet

- Anything on the Vision Pro (see DEVICE_TEST_CHECKLIST.md).
- **Dragging a slider by hand**, in the simulator or on device. Autoplay feeds drags straight into the session, so the gesture-to-sphere conversion is untested. Check the input log ("drag began … point lat,lon") and the white drag dot (DECISIONS D19 risk).
- File-based audio (`"audio": {"file": ...}`). Implemented, but untested until real audio is supplied.

## Debugging input

Every pinch is logged at info level ("pinch gesture on …", "hit …", "pinch on … ignored: …"): read it with `xcrun simctl spawn booted log show --last 10m --info --predicate 'subsystem == "com.devgrec.SoundVision"'`. If no "pinch gesture" lines appear when clicking, gestures aren't reaching the app; check DECISIONS D4 (`physicsSimulation: .none` on the head anchor) first.

## Known issues

- The launcher window stays open behind the sphere during play and shows through the glass. Consider hiding it during play (M2 menus).
- Far/near sorting assumes the player is in front (fixed front direction). This needs the live viewpoint when walking around the artwork in M2 (D4, D10).
- `Tuning`'s synthesized Decodable needs every key, so it needs a tolerant decoder before persisting settings in M2 (D14).

## Next

- **Next on sliders:** owner-designed slider layouts per level (format is ready; turn off random sliders then). Possibly curved paths, slider ticks or repeats, and a sound on hold.
- **M1, stroke notes.** Render guided paths as ribbons (use `MeshBuilders.surfaceRibbon`). Add a moving guide marker from `StrokeFollowScorer.guidePoint`. Make stroke starts pinch targets. Add `DragGesture().targetedToAnyEntity()`: convert the location into `surfaceRoot` space, project with `Playfield.surfacePoint(fromObjectLocal:)`, and feed `.dragBegan/Changed/Ended` into the session. Extend `GameSession` to judge stroke starts and score follow. Add color reveal from `RevealState`. Generate autoplay drags for strokes. Add the device checklist items for drag mapping.
- **M2**: end-of-song artwork reveal (object stops, walk around), results screen, menus, song select, settings with offset calibration.
- **M3**: beatmap editor, other shapes, visual polish (possibly a Reality Composer Pro ShaderGraph glass), the owner's designs and music.

## Session log

### 2026-10-19, session 1 (M0)
Built everything listed under "Done". Environment: Xcode 26.6, visionOS 26.5 SDK and simulator, Swift 6.3.3.
Bug found and fixed in the simulator: notes due on a later revolution showed as hittable next to the current ones (see DECISIONS D16). The fix made the crowding rule stricter, which flagged the first test map, so it was re-spaced (29 notes became 24).
Owner feedback, same day: "buttons should pop up around the view of the player, and an outside ring tells you exactly when to click", not notes scrolling to the center. Redesigned to that (D17): pop-up notes, approach rings, a 45° play area, on-screen crowding; the test map was rewritten to spread notes around (29 notes). The owner's earlier runs had autoplay on by accident (the simulator was still running a scripted `-autoplay YES` launch); added the AUTOPLAY badge, Early/Late feedback and pinch logging.
Owner feedback, round 2: "perfect works well, but early does not; make sure it ends on an early click" and "I don't want the buttons to be moving, rather more buttons that follow movement: to draw the eye to the right, multiple dots going left to right." Done: an off-window pinch ends the note as a Miss (D9); tap notes are fixed in view and the test map uses streams (D18).
Owner feedback, round 3: "design sliders… a slider that can take us in a direction for a second… varying length… some random cardinal direction". Clarified via questions (D19). Built sliders as tap notes with a path, pinch-hold-drag with follow scoring, and random cardinal sliders for development. Test map respaced for room.
**Rule for future sessions:** after scripted simulator runs, relaunch the app plain (`xcrun simctl launch booted com.devgrec.SoundVision`) so the owner doesn't inherit autoplay.
Simulator verification is scripted: `scripts/run-sim.sh -autostart game -autoplay YES`, then `xcrun simctl io booted screenshot <file>`. The game logs `started`/`finished` lines under subsystem `com.devgrec.SoundVision`; read them with `xcrun simctl spawn booted log stream --predicate 'subsystem == "com.devgrec.SoundVision"'`.
