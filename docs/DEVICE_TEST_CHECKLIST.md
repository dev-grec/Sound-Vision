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
- [ ] Approach ring: is it easy to see where a note popped up, and to read when the ring closes? Ring start size (`approachRingStartScale` 3×), approach time (`approachMs` 1500), thickness (3 mm).
- [ ] Pop-up (`noteFadeInMs` 200): noticeable without being jarring.
- [ ] Streams of one note per beat (500 ms at 120 BPM): can the eyes keep up with left-to-right / diagonal / circle streams? Do they actually lead the eye?
- [ ] Early/Late: a pinch outside the window ends the note as a Miss. Does that feel fair with real pinch latency, or does it punish slightly-early pinches too much?
- [ ] Judgment popups are readable and don't block the next note.
- [ ] HUD above the sphere is readable, and its position is comfortable.

## Placement and comfort

- [ ] The sphere appears about 1.1 m ahead, slightly below eye level, at a comfortable size (radius 0.3 m in the test map).
- [ ] Launching with the head tilted: is the placement badly tilted? (DECISIONS D4)
- [ ] The launcher window sits behind the sphere and shows through the glass. Is it distracting? (Possible fix: hide the window during play, M2.)
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
- [ ] Release grace (150 ms) and quicker random sliders (0.5–1 s, up to 75°/s): fair to follow?
- [ ] Follow tolerance (`sliderFollowToleranceDeg` 8°, falloff 20°): fair for hand dragging in the air?
- [ ] Hand travel: a 45° slider on a 0.3 m sphere is about 24 cm of arc. Comfortable over 0.5–2 s?
- [ ] Slider speed limit (75°/s), random lengths (20–45°) and durations (1–2 beats).
- [ ] Track, end marker, ball and follow ring are readable; the drifting color (orange) is noticeable.
- [ ] Simultaneous tap and drag gestures don't interfere: plain notes still register reliably.

## Audio and timing

- [ ] Click track plays with no crackle, and accents land on beat 1.
- [ ] A/V sync: approach rings close exactly on the click (AudioEngineClock subtracts `outputLatency`; check it isn't off by a constant).
- [ ] Rotation is smooth, with no stepping from the roughly 10 ms render-buffer clock updates.
- [ ] Song end: the rotation freezes and the result shows in the launcher.

## Not yet implemented (listed so it isn't forgotten)

- Stroke drags (M1): drag mapping onto the surface, guide following, color reveal timing (`revealAnimationMs`).
- Walking around the finished artwork (M2).
