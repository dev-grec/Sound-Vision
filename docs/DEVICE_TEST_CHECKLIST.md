# Device test checklist

Everything here has been checked only in the visionOS simulator, or not at all, and still needs a check on a real Vision Pro. **Nothing is "working on device" until the owner confirms it.** When the owner reports a result, tick the box, add the date and what they saw, and move any tuning changes into `Tuning.swift` (with a note in DECISIONS if it's a design change).

## Setup (first time on the headset)

- [ ] Set a development team in Xcode (Signing & Capabilities). Simulator builds don't need one; `CODE_SIGN_STYLE` is Automatic.
- [ ] The headset runs visionOS 26.0 or later (the deployment target).

## Rendering

- [ ] **Check the glass look on the headset.** Compare Glass Lab variants A, B and C (launcher → Glass variant). Does C's rim read as glass? Is C noticeably different from B? (It's subtle in the simulator. DECISIONS D10.)
- [ ] Far-side notes and strokes look like they're behind the glass, and near-side ones look in front. No sort popping as items cross the silhouette.
- [ ] No z-fighting between notes or ribbons and the glass.
- [ ] Far-side opacity (`Tuning.farSideOpacity` 0.35): can approaching notes be seen coming around without being distracting?
- [ ] Approach ring: is it easy to see where a note popped up, and to read when the ring closes onto the note's white rim? Ring start size (`approachRingStartScale` 3×), approach time (`approachMs` 1500), thickness (`approachRingThicknessM` 4 mm), start opacity (`approachRingStartOpacity` 0.45). Does the dark outline help in a bright room without looking heavy in a dim one? (D21)
- [ ] Pop-up (`noteFadeInMs` 200): noticeable without being jarring.
- [ ] Streams of one note per beat (500 ms at 120 BPM): can the eyes keep up with left-to-right / diagonal / circle streams? Do they actually lead the eye?
- [ ] Early/Late: a pinch outside the window ends the note as a Miss. Does that feel fair with real pinch latency, or does it punish slightly-early pinches too much?
- [ ] Judgment popups are readable (drop shadow) and don't block the next note; they start just above their note (D21).
- [ ] HUD above the sphere is readable, and its position is comfortable.

## Placement and comfort

- [ ] The sphere appears about 1.1 m ahead, slightly below eye level, at a comfortable size (radius 0.3 m in the test map).
- [ ] Launching with the head tilted: is the placement badly tilted? (DECISIONS D4)
- [ ] The launcher window disappears when a game starts and comes back (with the result) when the space closes: via the HUD's Exit / Back to Menu, and when the system closes the space. The app must not end up with no window and no space (D21).
- [ ] The HUD's Exit button is easy to look at and pinch without hitting notes.
- [ ] Rotation speed (12°/s, then 8°/s after beat 64 in the test map) feels slow enough to target with the eyes.
- [ ] Note spacing: `minNoteSeparationDeg` 25° between targets on screen at the same time. Is it too tight or too loose for eye targeting?

## Input

- [ ] Look-and-pinch on a note registers, and "Early"/"Late" shows for off-beat pinches. (In the simulator this has only been exercised through autoplay. Gestures on entities under a `.head` anchor with `physicsSimulation: .none` are unverified.)
- [ ] Hover highlight appears on notes once they pop up.
- [ ] Far-side notes can't be pinched through the glass.
- [ ] Note size (`noteDiameterM` 7 cm, hit radius ×1.3) is easy to target.
- [ ] Hit windows (±60/110/170 ms) feel fair with pinch latency.
- [ ] Input offset: find the value at which on-beat pinches score Perfect, and record it here as a starting default.
- [ ] Play area (45° from front): notes pop up within comfortable eye range, not too far to the sides.

## Sliders

- [ ] **Drag mapping:** the white drag dot starts on the slider head and follows the hand, so you can stay on the ball. It's relative tracking (DECISIONS D19); also try launching the game while looking off to one side.
- [ ] Slider finish windows (Perfect ±100, Great ±180, Good ±260 ms): fair for dragging with real latency?
- [ ] Grab radius (15°): the knob keeps following during natural hand wobble but stops when you're clearly off the track. End tolerance (1.5°): reaching the end feels deliberate, not accidental.
- [ ] The timer beside the slider (below horizontal, outside vertical ones; 3 cm digits on a dark plate) is readable, easy to glance at while dragging, and useful as a pacing cue (placeholder UI; DECISIONS D20, D21). Does a timer outside the sphere's silhouette feel detached?
- [ ] Hand travel: a 45° slider on a 0.3 m sphere is about 24 cm of arc. Comfortable over 0.5–2 s?
- [ ] Slider speed limit (75°/s), random lengths (20–45°) and durations (1–2 beats).
- [ ] The timer's digits and the knob show at once when the head is hit (no blank digit or missing knob for a moment; fixed in the simulator in the debug pass).
- [ ] Track (lane with white edges), end ring and knob are readable; the lost color (orange) is noticeable.
- [ ] Simultaneous tap and drag gestures don't interfere: plain notes still register reliably.

## Audio and timing

- [ ] Click track plays with no crackle, and accents land on beat 1.
- [ ] A/V sync: approach rings close exactly on the click (AudioEngineClock subtracts `outputLatency`; check it isn't off by a constant).
- [ ] Rotation is smooth, with no stepping from the render-buffer clock updates (now about 5 ms, interpolated both ways).
- [ ] Song end: the rotation freezes and the result shows in the launcher.

## Latency (DECISIONS D22)

Read the log with `log stream --predicate 'subsystem == "com.devgrec.SoundVision"'` (or Console.app with the headset connected) while playing.
- [ ] **Which gesture judges notes.** Each hit line ends with "via press (drag)" or "via release (tap)". Expect "via press" for nearly every hit. If taps are judging notes, the drag press isn't arriving first, and those notes are judged a whole pinch late.
- [ ] **Event-time stamping works.** "drag began … (event time, N ms before callback)": N should be small and steady (a few ms to a few tens of ms). "event time too old" or "in the future" means `DragGesture.Value.time` isn't usable on device; then set `useInputEventTimestamps` false and note it in D22. The end-of-play "input stats" line summarizes presses, mean and max backdating, and fallbacks.
- [ ] **Timing jitter A/B.** Play the same section twice, once plain and once launched with `-inputEventTimestamps NO`, pinching on the beat. Compare the spread of "delta" values in the hit lines. Event-time stamping should give a tighter spread; if not, say so in D22.
- [ ] **Audio session.** The "audio started" line shows the granted IO buffer (5 ms asked) and output latency. Note both here. Any crackle with the smaller buffer?
- [ ] **Clock health.** The "clock stats" line at the end: held backward steps should be rare and tiny (well under 1 ms); the start-up pre-roll is not counted (debug pass). The simulator showed 0 over a whole song. Many or large ones mean the render timestamp's host time doesn't mean what D2 assumes.
- [ ] **Hit tick.** It sounds at the pinch, is distinct from the metronome, and doesn't feel late. Does it help or distract? Volume (`hitSoundVolume` 0.35; `-hitSoundVolume 0` turns it off).
- [ ] **Feel A/B for judging on arrival.** Compare with `-processInputOnArrival NO`. Expect little visible difference; the tick may feel a touch quicker with it on.
- [ ] **Delivery grace.** An unhit note now turns Miss 50 ms after its window (`inputDeliveryGraceMs`). Not noticeable? Late-but-in-window pinches no longer get lost?

## Not yet implemented (listed so it isn't forgotten)

- Stroke drags (M1): drag mapping onto the surface, guide following, color reveal timing (`revealAnimationMs`).
- Walking around the finished artwork (M2).
