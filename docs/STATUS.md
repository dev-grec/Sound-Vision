# Status

Update this at the end of every session: what changed, what's in progress, known bugs, what's next. Newest session first in the log at the bottom.

## Current state: M0 complete in the simulator (2026-10-19)

Nothing has been run on a Vision Pro yet. Everything that needs the headset is in `DEVICE_TEST_CHECKLIST.md`.

### Done (M0)

- **Scaffold**: hand-written `SoundVision.xcodeproj` (visionOS 26.0 target, Swift 6) plus the `RhythmCore` local package. Scripts: `scripts/test.sh`, `scripts/build.sh`, `scripts/run-sim.sh`.
- **Docs**: CLAUDE.md, ARCHITECTURE, BEATMAP_FORMAT, DECISIONS, DEVICE_TEST_CHECKLIST, this file.
- **Beatmap format v1**, with loader (version check first) and validator (format rules plus playability rules: zone placement, crowding, rotation speed, stroke rules).
- **Test map** `Maps/test-metronome/beatmap.json`: 120 BPM, 30 bars, synthesized click, 34 view-fixed tap notes: an opening and a closing section at one note per 2 s (room for sliders), and streams in between (left to right, right to left, diagonals, a circle). 2 strokes (load, not playable yet). A rotation speed change at beat 64. No sliders written in; random ones are added at runtime.
- **RhythmCore engine** with 145 unit tests: geometry, rotation schedule, playfield and play area, note approach (pop-up and ring), tap judging, sliders (model, session, validation, random generator), scoring and combo, GameSession (inputs, auto-miss, offset, delivery grace), input event-time stamping, audio clock math, scripted input and autoplay (including sliders), stroke path, follow scoring, reveal state.
- **Audio master clock** (`AudioEngineClock`) and the runtime click synthesizer.
- **Glass rendering prototype** (Glass Lab, variants A/B/C). Findings are in DECISIONS D10. C is the gameplay default.
- **Tap-note gameplay** (DECISIONS D17, D18, D9): a slowly rotating glass sphere in front of the player. Notes pop up at fixed spots around its front (they don't move), and a shrinking ring closes on each note exactly on the beat. Look-and-pinch via `SpatialTapGesture` on entities. A pinch outside the window ends the note as a Miss shown as "Early"/"Late". Judgment popups, a HUD (with an orange AUTOPLAY badge when autoplay is on), and a result summary in the launcher. Autoplay plays the whole map through the same input protocol.
- **Sliders** (DECISIONS D19, D20): some notes carry a slider: pinch the head on the beat, then drag the knob (it follows the drag) along the track and reach the end at the target time. A countdown timer beside the slider reads 0.00 at Perfect (±100 ms). Early is a Miss, and so is late or never reaching the end. Random up/down/left/right sliders are added each play for development (launcher toggle; seed logged; `-sliderSeed N` replays).

### Verified in the simulator

- Build succeeds with no Swift warnings (clean build, debug pass). All 145 tests pass.
- Glass Lab A/B/C render as described in D10 (screenshots).
- Full autoplay run of the test map (34 notes, with random sliders): 34/34 Perfect. The song ends 61.5 s after audio start (60 s plus a 1.5 s tail), which matches the audio clock.
- A debug-build log compared each note's rendered position (RealityKit, relative to the placement entity) with RhythmCore's `Playfield.worldPosition`. They agree to about 1e-7 m.
- Without autoplay (screenshots): notes pop up at different spots with a wide faint ring that tightens onto them, and turn into Misses when their window passes.
- Autoplay shifted 400 ms early (`-autoplayEarlyMs 400`): every pinch ends its note as a Miss with "Early" (log: `hit n01: miss, delta -400 ms`).
- Sliders with autoplay: random layouts per play, all four directions, 0.5–1 s. Screenshots show the track, end marker, knob, and the timer counting down (0.57, then 0.15) and then showing the finish delta (−0.03, Perfect color). Full run (seed 1261861787, 5 sliders): 34/34 Perfect; slider finishes landed 16–66 ms before target.
- Design pass (D21), screenshots: the launcher is gone during play and comes back with the result after the song (`-exitOnFinish YES`); notes, rings, slider lanes, the timer plate and popup shadows read clearly over the light simulator room; the countdown shows every digit. Full autoplay run (seed 3, 7 sliders): 34/34 Perfect.
- Merged app (design pass D21 + latency pass D22), debug pass with autoplay: full run 34/34 Perfect (seed 3, 7 sliders), song ends 61.55 s after audio start with the hit tick on and with `-hitSoundVolume 0`; `-autoplayEarlyMs 400` gives 34 Early Misses (delta -400 ms) with "Early" popups; `-exitOnFinish YES` brings the launcher back with the result; the Glass Lab keeps the launcher; `-processInputOnArrival NO -inputEventTimestamps NO` runs clean. Simulator audio: IO buffer 2.7 ms granted (5 asked), output latency 0.1 ms; clock stats 0 held backward steps over a whole song (after the pre-roll fix). The slider timer shows every digit and the knob right after the head hit (after the scale-hiding fix).
- **Owner, in the simulator: clicking works.** The log of the owner's session showed Perfect/Great/Good hits with deltas between -104 and +165 ms.

### Not verified anywhere yet

- Anything on the Vision Pro (see DEVICE_TEST_CHECKLIST.md).
- **Hand input since the latency pass (D22).** Event-time stamping (`drag began … (event time, N ms before callback)`), judging from the gesture callback, the hit tick on a real pinch, and the end-of-play `input stats` line have not run with real gestures anywhere: autoplay bypasses gestures, and the debug pass could not script clicks in the simulator. The owner clicking a few notes in the simulator and sending the log would cover the simulator side.
- **Dragging a slider by hand with the relative DragTracker.** The owner's first hand test exposed the absolute-conversion bug (D19). The fix is unit-tested in RhythmCore (`DragTrackerTests`: a hidden anchor offset cancels out), but no one has dragged with it yet. Check the input log: "drag began … point lat,lon" should now match the head's position.
- File-based audio (`"audio": {"file": ...}`). Implemented, but untested until real audio is supplied.

## Debugging input

Every pinch is logged at info level ("pinch gesture on …", "drag began on … (event time, N ms before callback)", "hit … via press (drag), judged N ms after it", "pinch on … ignored: …"): read it with `xcrun simctl spawn booted log show --last 10m --info --predicate 'subsystem == "com.devgrec.SoundVision"'`. If no "pinch gesture" lines appear when clicking, gestures aren't reaching the app; check DECISIONS D4 (`physicsSimulation: .none` on the head anchor) first.

## Known issues

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
Owner feedback, round 4: "sliders a bit quicker" and "Perfect on the click, followed the whole way, let go at the end bubble, and it counts as a Miss". The log showed every drag point near latitude 78°: the absolute gesture conversion was broken by the hidden head-anchor transform. Fixed with relative DragTracker (D19), added release grace, and sped up random sliders (0.5–1 s, cap 75°/s).
Owner feedback, round 5: "the button on the slider should follow the cursor… each slider needs a predetermined time to finish… early = early, not in time = miss… a little timer on top where 0 is perfect… some grace for perfects." Done (D20): knob follows the drag, finish judged against the target time with wider slider windows, timer above each slider. The timer's digits vanished on every-frame mesh swaps in the simulator; it now toggles pre-built glyph entities.
Latency pass (agent/latency branch, same day; DECISIONS D22): drag events (the pinch press, movement, release) are now stamped at their own event time (`DragGesture.Value.time`) carried onto the audio clock, instead of when the callback ran; taps (release, no time available) are still stamped on arrival. Gesture callbacks run the game step immediately, and a runtime-synthesized hit tick plays on hits (`hitSoundVolume`). The audio clock interpolates both ways (it used to jump ahead and stall each buffer), asks for a 5 ms IO buffer, and caches output latency. Auto-misses wait 50 ms of delivery grace. New logs: which gesture judged each hit and how late, per-play input stats, audio session values, clock health. 143 tests pass; the build is clean. Not run in the simulator or on device in this pass (the simulator was in use); the checks are in DEVICE_TEST_CHECKLIST, "Latency".
**Rule for future sessions:** after scripted simulator runs, relaunch the app plain (`xcrun simctl launch booted com.devgrec.SoundVision`) so the owner doesn't inherit autoplay.
Simulator verification is scripted: `scripts/run-sim.sh -autostart game -autoplay YES`, then `xcrun simctl io booted screenshot <file>`. The game logs `started`/`finished` lines under subsystem `com.devgrec.SoundVision`; read them with `xcrun simctl spawn booted log stream --predicate 'subsystem == "com.devgrec.SoundVision"'`.

### 2026-10-19, design pass (D21)
Presentation only; no gameplay rule changed. The launcher window is dismissed while a game is open and reopened when the space closes (the HUD has Exit / Back to Menu), which fixes the known issue of the window showing through the glass. Notes got a white rim and the approach ring a dark outline; sliders a lane with white edges and a rimmed knob; the slider timer bigger digits on a dark plate, moved beside the slider (below horizontal ones, outside vertical ones) so it clears the track and popups; judgment popups a drop shadow, starting just above their note. New Tuning entries: `approachRingThicknessM`, `approachRingStartOpacity`, `noteHitFlashMs`, `noteMissFadeMs`, `sliderTimerFontSizeM`. New launch argument `-exitOnFinish YES`. All simulator-only; new items are on the device checklist.

### 2026-10-19, debug pass (merged D21 + D22)
Ran: clean build (no Swift warnings), 145 tests, and the merged app in the simulator with autoplay: full runs (seed 3, hit tick on and off), the early run, `-exitOnFinish YES`, Glass Lab B, the latency A/B switches, and screenshot bursts during sliders and Early misses. Results are under "Verified in the simulator".
Found and fixed (each with a commit; the RhythmCore ones with a failing test first):
- Clock health stat counted the start-up pre-roll (about 30 ms of negative readings while the first buffers are queued) as backward steps, so every run reported "5-6 held backward steps (max ~32 ms)" for a healthy clock. Not counted any more; 0 over a whole song now.
- Slider timer digits and the knob were missing for a few frames when first shown (e.g. "0. 9" just after the head hit): an entity enabled for the first time didn't draw at once. Hidden glyphs and the knob are now scaled to zero instead of disabled (D20 note). The design pass had not reintroduced mesh swaps.
- Hitting a slider head while another slider was still held dropped the held slider's end event (no popup, timer result or log).
- Launcher: if the space closed before `openImmersiveSpace` returned, the window was still hidden afterwards, leaving no window and no space.
- Docs: stale lines (test count, drag mapping in ARCHITECTURE, timer position in BEATMAP_FORMAT). The D21/D22 renumbering checked out: every D22 reference is the latency pass, every D21 one the design pass.
Still unverified: everything on device; hand input through the new D22 gesture path (see "Not verified"); the HUD Exit button pressed by hand (only the scripted `-exitOnFinish` path was run).
Left for the owner (not bugs, or not fixed here): a judgment popup can also miss its first frame or two (they are cloned on spawn; a pool would fix it); a slider whose head is missed keeps showing its duration on the timer while it fades, instead of "miss"; if a drag is cancelled without `onEnded`, `GestureInputSource` would stay in "dragging" and the next pinch would be judged by the tap release (not seen; worth watching in device logs).

