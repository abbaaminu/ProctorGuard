# Proctoring audit — what the detectors actually do

**Scope.** The proctoring client end to end: face/pose detection on Android (ML Kit)
and on the web (browser `FaceDetector` + MediaPipe FaceLandmarker), audio level
detection, device/browser integrity, and the strike pipeline from the first signal
to `proctoring_logs`, `flagged_for_review`, supervisor review and reset.

**This is a report.** No code, no migration and no test was changed to produce it.
The only artifact is this file. Every claim below is either a line reference into
the tree or is explicitly labelled as something a machine cannot settle. The fixes it
led to came afterwards and are listed, commit by commit, in the table under *How it
was verified* — this document was not rewritten around them.

**How it was verified.** Static reading of the shipped code, plus the unit/contract
tests that run on a machine with no camera, microphone or head:

```
flutter test test/proctoring_thresholds_test.dart test/mediapipe_proctoring_service_test.dart \
  test/web_face_presence_test.dart test/audio_monitoring_test.dart \
  test/audio_noise_burst_window_test.dart test/audio_noise_detector_tuning_test.dart \
  test/proctoring_notifier_test.dart test/offline_sync_service_test.dart \
  test/exam_strike_mapping_test.dart test/web_face_detector_contract_test.dart \
  test/web_exam_guard_test.dart test/kiosk_service_test.dart \
  test/hardware_integrity_service_test.dart test/afk_watcher_test.dart
→ 253 tests, all passed (2026-11-11; re-run unchanged when this report was finished)
```

That is the *whole* of what has been proved. Nothing below has been observed on a
phone, a webcam, a real head or a real room — §7 is the plan for closing that, and
§8 is the prioritised list of what is still wrong.

**Since this report — what has been closed.** The gaps below were then worked, one
commit each, so the tree has moved under some of the line numbers:

| Item | Commit | What changed |
| --- | --- | --- |
| §8 P1-2 — the web's 300 ms glance | `e37739e` | `web_face_presence.dart` now requires the phone's 2 s for a look-away, read from the shared `lookAwaySustain`; `no_face` stays 300 ms, because absence and direction are different questions |
| §1.4 / §8 P1-2 follow-up — the 30° exemption was removed rather than shared | working tree (with the shared-constant change) | the near-sideways turn is back, but as a **shared** rule instead of a browser-only shortcut: past `lookAwayImmediateYawDegrees` (30° of yaw) `lookAwayImmediateFrames` (2) consecutive detections confirm a `looking_away` on **both** hosts, so an obviously turned head no longer waits out the 2 s hold. The browser reports it on the second detection instead of the first, which is the single bad Euler estimate the exemption used to trust |
| §1.4 follow-up — the pitch sign is used, one way, in a browser | working tree (with the pitch-sign change) | the web's pitch rule is now **signed**: `lookAwayWebDownwardPitchDegrees` (20°) lets a chin drop five degrees further in a browser than the phone's 15°, because the keyboard a browser student reads is below the screen, while a chin *raised* past 15° is a monitor mounted above it and keeps `lookAwayPitchDegrees`. The phone still compares the absolute pitch at 15° both ways (ML Kit's sign is unverified), so this is one direction on one platform. `proctor_face_detector.js` states the sign on both of its routes — positive is chin down — and the landmark route was flipped to agree with the matrix one. A wrong sign costs only the five degrees of slack, never a stricter rule |
| §8 P1-3 — no Android start-up grace | `f200a91` | `cameraStartupGrace` became a shared constant and the Android engine counts it from its **first streamed frame**, which is the web's own small bug fixed as well |
| §8 P1-4 / §6.6 D4 — the suspected double count | `web_exam_guard.dart`, `web_exam_guard_test.dart` | one act now costs one strike: a fullscreen-exit countdown that belongs to an already-struck departure (a blur or a hidden tab inside the same 5 s) closes without charging again, and staying out of fullscreen is charged once per episode. Four unit tests pin it |
| §8 P3-14 — the dangling test path | the lecturer-isolation migration (still uncommitted with the feature it belongs to) | the comment now names `supabase/tests/supervisor_scope_check.sql`, block (l) |
| §8 P2-6 / §4.3 — a feed that goes quiet mid-session | `1073adb` | `AudioMonitor` re-arms the proof-of-life window on **every** sample, so a feed that stops delivering is no longer indistinguishable from a silent room. Expiry mid-session reports `unavailable` (visible on the chip, the paper keeps going), not `interrupted` as this report proposed: a throttled timer or a paused capture thread is an inference, and the first sample to arrive returns the state to `monitoring` by itself |
| §6.5 — the heartbeat against a superseded session | `49ee204` | `ProctoringHeartbeatService` catches `SessionSupersededException` and stops the series instead of counting a failure and retrying a refusal every 15 s for the rest of the sitting. Nothing is surfaced from the heartbeat: `SessionGate` is what signs the device out |
| §1.4 — the web pose matrix, unverified arithmetic | `580fdd8` | `matrixPose()` now has a test that builds rotation matrices from known angles and reads them back, including a scaled one and a rolled one. It confirms the documented column-major layout and the `Ry·Rx·Rz` decomposition, and shows that a row-major flattening would turn the same 20° pitch into −20°. The sign convention stays unverifiable without a real face — and unused, since Dart judges absolute angles |

Everything else in §8 — liveness (P1-1), the frame-stall watchdog (P2-5), the devtools
and split-screen notes (P2-7, P2-8), the queue cap, D3 and the three wording notes
(P3-9 … P3-13) — is open and unchanged.

None of those commits changes a single number that §7 was written to measure, and
none of them was observed on hardware: closing D4 *in the guard* was the only way to
settle it without a browser, because it does not matter whether Chromium reports the
pair — either it does and the second event is now free, or it does not and nothing
was ever charged twice.

The two newest (`1073adb`, `49ee204`) were checked the same way as the ones above:
`flutter analyze` clean, the whole `flutter test` suite (941 tests, two of them new),
no SQL touched. Neither changes a number §7 measures, but test 20 now has a companion
question it did not have before: how long a *legitimate* stall is allowed to last.

**Status vocabulary used throughout**

| Status | Meaning |
| --- | --- |
| **works as designed** | The behaviour is in the code, the rule is documented where a reviewer can read it, and a unit/contract test pins the rule. |
| **unverified on device** | The code path exists and is tested as far as a VM allows, but the *physical* outcome (an angle, a decibel, a browser API, a native channel) has never been measured on hardware. |
| **gap** | The behaviour is missing, weaker than it reads, or reachable in a way the product would not accept. |

---

## 0. Executive status

| # | Area | Status | One-line verdict |
| --- | --- | --- | --- |
| 1 | Look-away, mobile (ML Kit) | works as designed | 15°/15°, absolute on both axes, 2 s unbroken, one strike per episode, re-armed by a frame back inside the tolerances. |
| 1 | Look-away, web (MediaPipe / `FaceDetector`) | works as designed, **but a different rule** | Same 15°/15° and absolute, same one-strike-per-episode latch — sustained for **300 ms**, not 2 s, plus a 30° yaw exemption. Deliberate; §1.4 explains the arithmetic consequence. |
| 1 | Face lost mid-turn | works as designed (under-counts by design) | The turn becomes `no_face`, the look-away episode is discarded, and the clock restarts if the head comes back turned. |
| 2 | `no_face` / `multiple_faces` | works as designed | 3-frame confirmation for absence (mobile), immediate + 30 s latch for two faces, both platforms. |
| 2 | Start-up grace | **gap (mobile)** | Web: 5 s. Android: none — the first streamed frame can start a `no_face` count that lands at ~0.45 s. |
| 2 | Covered / frozen camera | works as designed on web, **gap on Android** | The JS detector has dark/blown/frozen-frame and stall detection; the phone has no frame-stall watchdog at all. |
| 2 | Count-only fallback + message | works as designed | `analyze = false` → `ExamHeadTurnUnavailableNotice` for the student, `monitoring_ok = false` for the supervisor, no violation. |
| 3 | Liveness (held-up photo / video) | **gap — nothing protects against it** | No blink, no turn challenge, no attestation. A printed photo or a looping clip passes as a present student. Design + effort in §3. |
| 4 | Audio | works as designed | One calibration per session (median of 3 s), 6 dB margin clamped to −50…−32 dBFS, 2 s continuous, 300 ms bursts ×3 or 4 s total in 60 s, latch + 10 s cooldown, window emptied by the strike. |
| 4 | Mic loss / revocation / reconnect | works as designed | Every failure is a visible state (`Mic lost`, `Mic blocked`, `Mic unavailable`), never a silent quiet room; reconnect recalibrates. Since `1073adb` a feed that goes *quiet* mid-session is one of those states too, instead of leaving the chip on `monitoring`. |
| 5 | `app_minimized` | works as designed | Lifecycle observer (Android/iOS), tab-blur/fullscreen on web, kiosk-escape poll on Android — all one violation. |
| 5 | Back-button / split screen | partial | Back is bound to the overlays (`PopScope`); split screen is **not detected** on Android. |
| 5 | Second display / virtual camera | Android-only | Native channel, 15 s poll; web and iOS report "cannot see", which is silence, not a clean bill. |
| 6 | Strike pipeline | works as designed | Client signal → per-type 2 s dedupe → optimistic overlay → snapshot (1.2 s/3 s budget) → outbox → `register_violation` (idempotent per `client_event_id`, weighted, threshold 3) → `flagged_for_review` → supervisor → reset. Loss/double-count table in §6.6. |
| 7 | Anything at all on real hardware | unverified on device | Everything in §7. |

**Where the risk actually sits.** Seven of the fifteen rows above carry a caveat, and
only one of them is a design decision rather than a fix: §3 (no liveness). Of the
rest, §2.3 (no start-up grace on Android) and §1.4 (300 ms on the web) are hours of
work each; §2.4 (no frame-stall watchdog) is a day; §5.7 (split screen) needs a
deployment decision; §5.4 and §7 are limits of the platform, not of the code. §8
lists all fourteen findings in priority order, and §7 is the 39-test plan that turns
every "unverified on device" into a fact.

---

## 1. Look-away

### 1.1 The rule, once

The numbers live in one file so the two engines cannot drift
(`mobile/lib/core/services/proctoring_thresholds.dart`):

| Constant | Value | Line |
| --- | --- | --- |
| `lookAwayYawDegrees` | 15.0 | `:53` |
| `lookAwayPitchDegrees` | 15.0 | `:64` |
| `lookAwaySustain` | 2 s | `:68` |

A frame is off screen when `abs(yaw) > 15 || abs(pitch) > 15` — *absolute* on both
axes, so a turn left and a turn right are one rule and so is a tilt up and a tilt
down (`proctoring_thresholds.dart:15-18`). The reason for the symmetry is stated in
the file: which direction a detector calls "chin down" differs between ML Kit and
the web FaceLandmarker, so a signed rule would judge the same head differently on a
phone and in a browser (`:58-61`).

It is a **look-away** only once the head has stayed off screen for 2 s *without one
frame back inside the tolerances* (`:19-22`). One episode is one strike: a latch
holds the signal until a frame returns inside the tolerances (`:23-24`).

Status: **works as designed**. Pinned by `test/proctoring_thresholds_test.dart`,
`test/mediapipe_proctoring_service_test.dart`, `test/web_face_presence_test.dart`.

### 1.2 Mobile path — ML Kit

* Engine: `google_mlkit_face_detection`, `FaceDetector` built lazily with
  `performanceMode: accurate` and `minFaceSize: 0.15`
  (`mobile/lib/core/services/mediapipe_proctoring_service.dart:172-181`). ACCURATE
  is required because FAST mode leaves the Euler angles null (`:174-177`).
  (`MediaPipeProctoringService` is a historical name — the file says so at `:28-32`.)
* Throttle: `inferenceInterval` 150 ms ≈ 6-7 FPS (`:39`), enforced at `:313`; the
  inference itself is fire-and-forget with error containment so one bad frame
  cannot wedge the pipeline (`:318-329`).
* Angles: `face.headEulerAngleY` is yaw, `headEulerAngleX` is pitch (`:349-357`).
  **When ML Kit cannot estimate the pose both are null, and the frame is then
  treated as centred** (`:587-588`, `yawDegrees ?? 0`). That is the fail-safe
  direction: no evidence is never evidence of misconduct.
* Judgement: `_handleResult` (`:526-619`).

Status: the *logic* is works as designed; the *angles themselves* are
**unverified on device** (§7, test 1). Nothing in the repository has measured what
ML Kit reports for a real 15° turn on a real phone.

### 1.3 The mobile rule in detail (and the edge cases)

`_handleResult`, in order:

1. **No face** (`:536-551`): the off-centre counters *and the look-away episode
   clock* are cleared, then `_faceMissingFrames` is incremented and `noFace` is
   emitted once at 3 frames (`missingFaceFrameThreshold = 3`, `:44`).
2. **Two or more faces** (`:558-573`): off-centre state cleared, `multipleFaces`
   emitted immediately, latched; the episode only ends after 30 s with a single
   face in frame (`multipleFacesCooldown`, `:45`, applied at `:575-585`).
3. **One face, inside the tolerances** (`:592-601`): all counters cleared, clock
   nulled, latch re-armed, `centered` emitted.
4. **One face, outside the tolerances** (`:604-618`): the first frame starts the
   clock (`_lookAwaySince`), every later frame in the run leaves it alone, and the
   signal fires once when *both* `now - since >= 2 s` and
   `consecutiveFrameThreshold` (1) frames have been seen. The latch
   (`_lookAwayFlagged`) makes it once per episode.

Two properties worth stating explicitly, because they are what the numbers buy:

* **A glance cannot accumulate.** Any frame back inside the tolerances resets the
  clock (`:597-599`), so it is *consecutive* time, not total time (`:594-596`).
* **A held turn is one strike, not one per frame.** Without the latch, ~7
  inferences/second would have reached the server's 3-point threshold inside half
  a second (`:611-617`; the same argument for two faces at `:212-214`).

**Behaviour when the face is lost mid-turn** — the requested case.
Step 1 runs first, so a turn steep enough to lose the face entirely is **not** a
`looking_away`: it is `no_face`, and the in-progress look-away episode is discarded
(`:540-542`). If the head comes back still turned, the 2 s clock starts again from
that frame (`:607`). Consequences:

* Status: **works as designed**, and it is an under-count on purpose. The student
  is still warned — absence is a counted strike of its own — and the two signals
  are never allowed to describe the same seconds twice.
* The log will therefore show `no_face` where a human watching would say "they
  turned away". A supervisor reading only action types should know that; the
  *score* is unaffected because both types weigh 1
  (`supabase/schema.sql:2463-2474`).
* The same ordering means a **single** dropped frame during a turn (one frame with
  no face) restarts the whole 2 s clock even though the head never returned to the
  screen. At ~7 FPS that is the honest cost of "consecutive frames", but it is the
  knob to understand before tightening anything.

### 1.4 Web path — `window.FaceDetector`, falling back to MediaPipe

Detection lives in the page, not in the app: `mobile/web/proctor_face_detector.js`,
loaded by `mobile/web/index.html:160`, self-starting on `DOMContentLoaded` or
immediately (`proctor_face_detector.js:1646-1658`). It polls every
`INTERVAL_MS = 350` (`:150`).

* Native `window.FaceDetector` (Shape Detection API) is used where it exists
  (`:769-782`); if it reports one face but no pose, MediaPipe FaceLandmarker (WASM,
  `mobile/web/mediapipe/`) is asked for yaw/pitch (`:826-844`).
* Yaw/pitch from the native API's landmarks: nose offset from the eye midpoint,
  normalised by half the eye span, smoothed by a median over `POSE_WINDOW = 3`
  samples (`:212`, `:216-218`, `:920-970`).
* From MediaPipe's facial transformation matrix, Euler angles are derived
  (`:1268-1309`): the 4x4 is read **column-major**—element (row, column) at
  `column * 4 + row`—and decomposed as R = Ry(yaw)·Rx(pitch)·Rz(roll), so
  `pitch = asin(-R[1][2])` and `yaw = atan2(R[0][2], R[2][2])`. The arithmetic is
  pinned by `tools/detector_eval/test/pose_matrix.test.mjs` (`580fdd8`), which builds
  matrices from angles known in advance and compares what comes back: both axes,
  both signs, roll moving neither angle, a uniformly scaled matrix reading the same,
  the 90° collapse reported as yaw 0 rather than invented, a value past `asin`'s
  domain clamped rather than NaN, and no matrix answering null. That test also shows
  the layout is load-bearing: flattened row-major, the same 20° pitch reads −20°.
  What it cannot settle is the sign convention, and which of the model's axes is
  called yaw — that needs a real face (§7 B), and it is deliberately not corrected
  here because Dart judges `abs(yaw)` and `abs(pitch)`, where a mirrored angle is
  the same evidence.
* The page emits **angles, not a verdict** — `pose:<yaw>,<pitch>` — so the
  threshold applied is the app's, not the page's (`:37-42`, `:1496-1501`). A page
  that cannot measure says `centered` for a live picture and reports
  `proctorGuardFaceAnalysis(false)` (`:1382`, `:1488-1494`) — see §2.6.

Judgement is Dart: `WebFacePresenceMonitor`
(`mobile/lib/core/services/web_face_presence.dart`).

| Rule | Mobile (ML Kit) | Web (page detector) | Line (web) |
| --- | --- | --- | --- |
| Yaw tolerance | 15° | 15° | `:84` |
| Pitch tolerance | 15° | 15° | `:85` |
| "Held" measured in | consecutive frames **and** 2 s | **300 ms elapsed** | `:77` |
| Absence confirmation | 3 frames (~0.45 s) | 300 ms | `:289` |
| Two faces | immediate, latch 30 s | immediate, latch 30 s | `:79`, `:232-244` |
| Near-sideways exemption | none | yaw > 30° fires at once | `:86`, `:268-272` |
| Start-up grace | none | 5 s | `:78`, `:230` |
| Re-arm | frame inside tolerances | `centered` message | `:310-320` |
| Face lost mid-turn | episode discarded, `no_face` | same (`_onMissing`) | `:281-292` |
| Unparseable measurement | null angles → treated centred | `pose:` rejected, ignored | `:336-354` |

The two "held" units are deliberate and documented in both files: a page's detector
runs at 2-3 Hz, so counting detections would make a slower detector a quieter one
(`web_face_presence.dart:65-72`, `:116-126`).

**What that difference costs.** 300 ms is not two seconds. A browser student who
glances down at their own notes for 0.3 s earns the same strike as a phone student
who stares off screen for two, and `looking_away` weighs 1
(`mobile/lib/features/proctoring/domain/entities/violation.dart:104-118`) against a
server threshold of 3 (`supabase/schema.sql:3288`). Three such glances in one
sitting is `flagged_for_review`. This is defensible — the web has no better sensor,
and a page's own verdict is trusted only for exactly this — but it is **not** the
same exam on the two platforms, and it is the biggest false-positive risk for
honest web students (§7, tests 12-14). Status: **works as designed, with a parity
gap recorded in §8.**

---

## 2. Face presence

### 2.1 `no_face`

* **Mobile**: 3 consecutive frames without a face (`missingFaceFrameThreshold = 3`,
  `mediapipe_proctoring_service.dart:44`), then one signal per episode; any frame
  with a face resets the count (`:536-556`). Why three: a blink behind glasses, a
  hand across the lens or one frame of motion blur also produces "no face"
  (`:132-137`).
* **Web**: the page reports `no_face` for a live-but-empty frame, a blank frame, a
  dark/blown frame, an ended/muted track, or a preview that has stalled (§2.4); the
  monitor sustains it 300 ms and latches (`web_face_presence.dart:246-249`,
  `:281-292`).
* On both, the *notifier* then sets `faceMissing`, which is what covers the paper
  (`mobile/lib/features/proctoring/presentation/providers/proctoring_provider.dart:418-421`,
  `:435-438`) — and it clears the flag the moment a face is reported again
  (`:405-410`).
* The strike itself is separate from that flag: `faceMissing` is *current state*,
  `warningCount` is *events* (`proctoring_provider.dart:58-66`).

Status: **works as designed** (tests: `mediapipe_proctoring_service_test.dart`,
`web_face_presence_test.dart`); the physical frame rate that decides whether "3
frames" is 0.45 s or 1.5 s is **unverified on device**.

### 2.2 `multiple_faces`

Immediate on both platforms — two people need no measuring — then latched until the
student has been alone for 30 s, measured from the *last* two-face frame so a
detector flickering between one and two faces at the frame edge cannot re-open the
episode (`mediapipe_proctoring_service.dart:558-585`, `:203-215`;
`web_face_presence.dart:232-244`, `:322-334`). Without that latch the signal fired
once per inference and closed an attempt within a second of a guest leaning in
(`mediapipe_proctoring_service.dart:212-214`).

The web page reports `multiple_faces` whenever the count is greater than one —
including three faces — and the JS asks the native API for `maxDetectedFaces: 2`
(`proctor_face_detector.js:775`), so "3" is only visible through MediaPipe.

Status: **works as designed**.

### 2.3 Start-up grace — different on the two platforms, and missing on the phone

* **Web, browser events**: 5 s of silence after the guard starts, so the camera
  permission dialog, the fullscreen transition and the browser's own media
  indicator cannot become `app_minimized`. Lockdown events (copy/paste,
  right-click, devtools) are deliberately **exempt** — a copy attempt is not
  something a permission dialog causes (`web_exam_guard.dart:54-60`, `:115-118`,
  `:128-145`).
* **Web, face signals**: 5 s from `WebFacePresenceMonitor.start()`, during which
  *every* message is dropped (`web_face_presence.dart:78`, `:228-230`). Caveat
  worth recording: the clock starts when the monitor is constructed in
  `_startFacePresence` (`exam_taking_page.dart:1222-1244`), i.e. **before** the
  camera is opened (`:592-631`). A browser that takes longer than 5 s to hand over
  a stream (a cold `getUserMedia`, a slow laptop) spends its grace before the first
  frame, so its first detections are judged immediately — the same exposure as the
  phone below.
* **Android: no grace at all.** Nothing in `MediaPipeProctoringService`,
  `ProctoringNotifier` or `ExamTakingPage` exempts the first seconds from
  `no_face`/`looking_away`. The engine is armed by `_setCameraStreaming(true)`
  right after `startImageStream` (`exam_taking_page.dart:612-631`), the notifier's
  camera gate defaults open (`proctoring_provider.dart:296`), the engine's stream
  flag defaults open (`mediapipe_proctoring_service.dart:222`), and absence is
  reported after 3 frames (`:44`). So **a student whose face is not in frame in the
  first ~0.45 s of streaming earns a `no_face` strike and has the paper covered**
  by `EquipmentBlockOverlay` (`exam_taking_page.dart:1040-1051`).

Status: **gap.** The window is small and the equipment overlay tells the student
what to do, but the strike is permanent and counted (weight 1). An honest student
who taps "Start" while still lifting the phone off the desk can begin the exam on
1 of 3. §8 item 3.

### 2.4 Covered or frozen camera

* **Web: handled, and thoroughly** (`proctor_face_detector.js`):
  * a 48×36 luma sample of the preview is taken every tick (`:164-165`, `:691-705`);
  * an all-dark frame (`DARK_MEAN = 90`, `DARK_SPREAD = 12`, `:182-183`) or an
    all-blown one (`BLOWN_MEAN = 250`, `BLOWN_SPREAD = 6`, `:186-187`) is
    `no_face` (`:1453-1456`) — a covered lens and a torch at the lens are both
    "nobody can be seen";
  * an identical frame for `FROZEN_TICKS = 3` ticks is a frozen preview (`:193`,
    `:724`), and a track that is ended, muted or on a paused/hidden element is
    inactive (`:576-628`, `:1430-1451`);
  * a preview that has *never* been live gets `STALL_MS = 5000` before it counts
    (`:199`, `:1438-1444`) — a camera the app could not feed is not an accusation;
  * while the document is hidden the tick does nothing, so a suspended preview is
    never read as `no_face` (`:1399-1408`).
* **Android: not handled at frame level.** A covered lens is simply "no face" after
  3 frames (correct). But there is **no watchdog for a frame stream that stops**:
  if the camera stops delivering `CameraImage`s while the controller still reports
  itself healthy (a wedged HAL, a vendor driver after a fold, an OS that quietly
  killed the stream), `onCameraFrame` is never called again, so no signal is
  produced at all and the attempt looks clean. The only detection in place is
  `_onCameraValueChanged` reacting to `value.hasError`
  (`exam_taking_page.dart:770-782`), which a silently stalled stream does not set.
  The heartbeat keeps reporting `camera_ok = true` throughout.

Status: **works as designed on web** (each branch pinned by
`test/web_face_detector_contract_test.dart`); **gap on Android** — no frame-stall
watchdog. §8 item 4.

### 2.5 Camera pause and resume

* The page owns a boolean, `_cameraStreaming`, kept in sync with the controller
  (`exam_taking_page.dart:770-808`), and pushes it to the notifier through
  `setCameraActive`.
* `ProctoringNotifier.setCameraActive` (`proctoring_provider.dart:324-344`) drops
  every gaze signal while false (`:402`), clears the per-type dedupe stamps so a
  resume cannot inherit one (`:336`), clears the engine's counters (`:337`,
  `setStreamActive`), clears `faceMissing` (`:343`), and tells the heartbeat
  `camera_ok` / `monitoring_ok` (`:332-333`).
* The engine's `setStreamActive(false)` also calls `resetSustained()`, which zeroes
  every counter, latch **and the episode clock**
  (`mediapipe_proctoring_service.dart:266-289`), so a feed that comes back judges
  frames from scratch instead of inheriting seconds from before the drop.
* The student gets a blocking overlay ("Your camera has stopped", "Restart
  camera"), and that button drops the dead controller and re-runs the whole
  bootstrap (`exam_taking_page.dart:992-1003`, `:820-838`).

Status: **works as designed**. Whether `value.hasError` fires, and whether a
resumed stream really re-streams on the target devices, is **unverified on device**
(§7, test 6).

### 2.6 The count-only fallback and what the student is told

When the page cannot measure a head angle — no Shape Detection API, the WASM model
still loading or failed, no landmark for the single face, or the file not served —
the JS says `centered` for a live picture (`proctor_face_detector.js:1458-1467`,
`:1488-1494`) and publishes `false` on `window.proctorGuardFaceAnalysis`
(`:115`, `:1382`).

That flag travels: `WebFaceSignalSourceImpl` accepts only a real boolean
(`web_face_signal_source_web.dart:102-107`) → `ExamTakingPage` sets local state and
calls `notifier.setFaceAnalysisAvailable(false)` (`exam_taking_page.dart:1240-1244`)
→ the notifier re-sends `monitoring_ok = false` on the next beat
(`proctoring_provider.dart:371-376`) and **never logs a violation** for it
(`:349-367`).

The student sees a permanent, non-dismissible strip above the paper:

> "Head turns are not being checked in this browser. Your camera and microphone are
> still monitored - keep your face toward the screen."

(`exam_session_widgets.dart:249-281`, text at `:268-270`, rendered at
`exam_taking_page.dart:1733-1734`.)

Status: **works as designed**, and it is the pattern to copy for liveness (§3): a
missing sensor is reported, never punished. The cost to accept is that in a
locked-down corporate browser (no `mediapipe/` served and no Shape Detection API)
the strongest signal silently drops to presence-only — visible to the supervisor,
but only via `proctoring_coverage()`.

---

## 3. Liveness — what stops a held-up photo or a video today

### 3.1 The honest answer: nothing

There is **no liveness challenge anywhere in the tree**. Confirmed by search rather
than by memory: no `blink`, no `eyeOpen`, no `leftEyeOpenProbability`, no challenge
prompt; the only hits for "liveness" are the *heartbeat* ("a client was running")
and the *session* liveness gate ("this login is still current"), neither of which is
about a person (`mobile/lib/core/services/proctoring_heartbeat.dart:18-25`,
`mobile/lib/core/services/session_gate.dart:37-52`). `README.md:133` says it in
plain words: "there is no liveness challenge (no blink / turn / read-a-phrase
prompt)". The risk register carries it as the top row: *Impersonation / a stand-in
on camera* (`README.md:207`).

So the specific question — *what protects against a held-up photo or a playing
video today?* — resolves to four indirect things, none of which is liveness:

| Attacker | What the current stack does | Outcome |
| --- | --- | --- |
| Printed photo of the student held at the lens | ML Kit sees exactly one face, frontal, within 15°, forever. `no_face` never fires, `looking_away` never fires, `multiple_faces` never fires. | **Zero signals.** The attempt is indistinguishable from an honest one, unless a human watches the stills. |
| The same photo on a tablet/phone | Same, plus the device itself may be caught if it is an Android external/virtual camera (`virtual_camera_detected`) — but a phone held in front of the lens is not a camera substitution. | **Zero signals** on the phone path. |
| A looping video clip of the student | Same as above, and the *web* detector's frozen-frame test will not help: a looping clip is not a still frame (`proctor_face_detector.js:193`, `:724`). | **Zero signals.** |
| A stand-in who resembles the student | Detected only if they move out of frame, turn away, or bring a second person — i.e. on *behaviour*, not identity. | Behavioural strikes only; may never fire. |

The mitigations that exist are procedural, and they should be described as such:
supervisor review of the evidence stills (`proctoring_logs.snapshot_url`), the
consent record (that a notice was accepted, not that it was read —
`README.md:326-331`), and the heartbeat (that *a client* was running, explicitly
"never that it was doing its job" — `proctoring_heartbeat.dart:18-25`).

Status: **gap**, the largest one in this audit. §8 item 1.

### 3.2 A minimal design (not implemented)

The goal is not to defeat a determined deepfake. It is to make "hold up a photo" and
"play a loop" fail, cheaply, using sensors the app already reads — and to fail into
**a supervisor's queue**, never into an automatic disqualification.

**Challenge types, both judged from data that already exists**

1. **Random head turn.** "Turn your head to your **left** and hold it." Judged from
   the same yaw the look-away rule already consumes: `|yaw| > 20°` in the *named*
   direction, held 400-800 ms, then released. Direction is randomised per challenge
   so a pre-recorded loop cannot satisfy it. It works on every platform where
   `looking_away` works (Euler angles on the phone, `pose:` on the web) and degrades
   to §2.6's "cannot check" where that does not.
2. **Two blinks inside 3 s.** Requires eye state, which the current stack does not
   read:
   * Android: ML Kit already returns `leftEyeOpenProbability` /
     `rightEyeOpenProbability` when `FaceDetectorOptions(enableClassification:
     true)` is set — which is *off* today
     (`mediapipe_proctoring_service.dart:172-181`), and `FaceFrameResult` has no
     field for it (`:14-19`). So: one option flag, two fields, one threshold.
   * Web: MediaPipe's FaceLandmarker exposes blendshapes (`eyeBlinkLeft` /
     `eyeBlinkRight`) or the eye landmarks can give an eye-aspect-ratio
     (`proctor_face_detector.js:893-936` already walks the landmark groups). The
     native Shape Detection `FaceDetector` cannot report eye state at all, so a
     browser with no MediaPipe model gets **head-turn only** and says so through
     the existing `proctorGuardFaceAnalysis` channel.

**Schedule.** One challenge before the paper unlocks (it doubles as "a live person
is in front of the lens at t=0", which is exactly the window the photo attack needs),
then random intervals — 6-12 minutes, at most one per 5 minutes, 3-6 per sitting —
seeded per attempt so the schedule can be replayed during an appeal. The interval
floor is what keeps an honest student from being interrupted mid-answer repeatedly.

**Failure path.** Prompt with a 15 s countdown; on timeout, re-prompt once; only a
second timeout records a strike. The strike is `liveness_missed`, and reaching the
server threshold flags the attempt for review — the paper closes, a human decides.
It must never call `mark_disqualified` on its own (that path is
`ProctoringNotifier._forceDisqualify`, `proctoring_provider.dart:697-720`).

**One thing the design must get right.** A challenge asks the student to do the very
thing `looking_away` punishes. While a challenge is open, the look-away rule must be
*suspended for that type only*, or every honest student earns a strike for obeying
the prompt. The clean seam is the notifier, not the engine: the challenge controller
holds a flag, and `_handleGazeSignal`'s `lookingAway` arm
(`proctoring_provider.dart:411-417`) skips `_registerViolation` while it is set. The
engine keeps counting; the strike is simply attributed to the challenge instead.

### 3.3 Where it would live

| Piece | File | Why there |
| --- | --- | --- |
| Rules + state machine (pure, clock-injected, no plugins) | new `mobile/lib/core/services/liveness_challenge.dart` | Same shape as `AudioNoiseDetector` (rules) and `WebFacePresenceMonitor` (rules) — testable on the VM, with the platform half elsewhere. |
| Eye state on the phone | `mediapipe_proctoring_service.dart:14-19` (`FaceFrameResult` + `eyeOpenProbability`), `:172-181` (`enableClassification: true`) | The detector is already there; nothing new is opened. |
| Eye state on the web | `mobile/web/proctor_face_detector.js:893-936` / `:1203-1230` (blendshapes or EAR), published on the existing bridge | Keeps the "page measures, app judges" split intact. |
| Strike entry point | `proctoring_provider.dart` — one new `reportLivenessMissed()`, following `reportAudioNoise()` (`:452`) | Every signal already enters through one `_registerViolation`, so the overlay, snapshot, outbox and escalation come for free. |
| Prompt UI | new `mobile/lib/features/proctoring/presentation/widgets/liveness_challenge_overlay.dart`, painted in `exam_taking_page.dart:_proctoringOverlays` (`:1814-1884`) | Same place the equipment block and fullscreen countdown live; must sit **below** the equipment block and **above** the violation overlay. |
| Wiring | `exam_taking_page.dart:1222-1244` (next to `_startFacePresence`) | Where the other web/session bridges are started and released. |
| Server | `supabase/schema.sql` §5 check constraint + `violation_weights` (`:2460-2479`), `register_violation` needs **no** change | The RPC is type-agnostic; only the vocabulary and the weight table grow. |

**New action type and weight.** One type, `liveness_missed`, `weight = 1`,
`counts_toward_dq = true` — the same tier as `no_face`/`multiple_faces`, because
"the person I was shown is not there" is the same class of fact. Not `weight = 2`:
a challenge can be missed for honest reasons (a seizure, a carer walking in, a
laptop camera that lost focus), and the review queue is the right destination.
Add `ViolationType.livenessMissed` (`violation.dart:3-45`, `:67-81`, `:104-118`),
and a deliberate `livenessUnavailable` **is not needed** — the existing
`monitoring_ok = false` heartbeat column already says "this sitting could not be
fully judged", which is the honest way to record it (`proctoring_provider.dart:358-376`).

**False-positive risks, named**

| Risk | Why it happens | Mitigation in the design |
| --- | --- | --- |
| Dark room / backlit window | Eye landmarks vanish; a blink reads as "eyes closed" permanently | Blink challenges only where eye state is *measurable*; head-turn is the primary type |
| Glasses glare, thick frames | Eye landmarks jitter; EAR is noisy | Median over 3 frames (the pattern already used at `proctor_face_detector.js:212`) and a 3 s window for two blinks |
| Hijab, cap, headscarf | Yaw estimation degrades when the face outline is occluded; blink is unaffected | Judge the turn on the *nose/eye* landmarks the model still finds, and accept a turn in either direction if the named one does not register within 8 s |
| Low laptop, camera below the chin | Baseline pitch is already 20-30° down; a "look up" challenge is easy but a blink window is short | Judge turn/blink *relative to the student's own baseline*, captured during the first minute |
| Slow device (350 ms poll, 150 ms mobile cadence) | A 200 ms blink falls between samples | Require **two** blinks in 3 s, not one; never fail a challenge on a single missing sample |
| Accessibility (ptosis, nystagmus, one eye, tremor, motor disability) | The student physically cannot satisfy a blink/turn prompt | (a) never disqualify on this signal, (b) an institution-side accommodation flag that disables the challenge, (c) the supervisor sees `liveness_missed` with the snapshot and can clear it with a note (`resolve_flagged_attempt`, `schema.sql:3968-4065`) |
| Network stall during a challenge | The strike is queued offline and arrives late | Already handled: the outbox is durable and the server recomputes the score (`offline_sync_service.dart:169-179`) |

**Effort (estimate, one engineer, not measured):**

| Work | Estimate |
| --- | --- |
| Rules + state machine + unit tests (both challenge types, schedule, failure ladder) | 1.5 days |
| ML Kit `enableClassification` + eye probability plumbed into `FaceFrameResult` and the engine's frame path | 0.5 day |
| Web: blendshape/EAR measurement in `proctor_face_detector.js`, publishes through the existing hook, contract test extended | 1.5 days |
| Prompt UI + wiring + the look-away suspension flag | 1 day |
| Server: check constraint, `violation_weights` row, `schema_contract_test.dart`, `weighted_strikes_check.sql` | 0.5 day |
| **On-device calibration with honest students** (glasses, hijab, dark room, low laptop, slow phone) — the part that decides the thresholds | 2-3 days |
| Total | **~7-9 working days**, of which more than a third is hardware |

The calibration is the real cost, and it cannot be shortened by more code: every
number in the table above is a guess until §7 has been run.

---

## 4. Audio

### 4.1 The rules, with the numbers

Rules live in `mobile/lib/core/services/audio_noise_detector.dart` (pure Dart, no
microphone, no timers — one `add()` per dBFS sample returns `true` when the student
should be warned, `:6-11`). Constants live in `proctoring_thresholds.dart` and are
taken as constructor defaults, so nothing can drift (`audio_noise_detector.dart:67-69`,
`:80-97`):

| Rule | Value | Evidence |
| --- | --- | --- |
| Calibration window | 3 s | `audio_noise_detector.dart:81`, `:138-150` |
| Calibration method | **median** of the readings (bounded at 128, needs ≥5) | `:90-91`, `:598-601`, `:578-596` |
| Threshold | room floor + 6 dB, clamped to −50…−32 dBFS | `proctoring_thresholds.dart:122`, `:131-132`; applied `:599-601` |
| Silence sentinel | −160 dBFS clamped to −100 before it can be the "room" | `:251-259`, applied `:411-414` |
| Sustained rule | level **continuously** above threshold for 2 s | `proctoring_thresholds.dart:91`; `:489-492` |
| Release grace / hysteresis | **both zero** — one sample under the line restarts the window | `:102`, `:110`; `:434-450`, `:472-483` |
| Latch | one strike per episode until a dip below the line | `:333-340`, `:464-467` |
| Cooldown | 10 s of total deafness after a strike | `:85`, `:204-212`, `:395-399`, `:452-462` |
| Burst rule A | 3 bursts of ≥300 ms inside 60 s | `:93-95` |
| Burst rule B | 4 s of above-threshold time in total inside 60 s | `:96`, `:562-576` |
| Window emptied by a report | yes, deliberately | `:512-528` |

How a sample is judged (`add`, `:406-500`): NaN/infinite rejected (`:409`) → clamp
of the silence sentinel (`:414`) → calibration while uncalibrated (`:420-423`) →
below the line: release the latch, close the current run, and *judge the window
here*, because the third phrase in a minute is a finding when it **ends**
(`:434-450`) → inside the cooldown: ignore the level entirely and accrue no time
(`:452-462`) → latched: nothing (`:467`) → sustain check (`:489-492`) → window check
(`:494-498`).

Status: **works as designed**. Pinned by `test/audio_noise_detector_tuning_test.dart`,
`test/audio_noise_burst_window_test.dart`, `test/audio_monitoring_test.dart`. Every
*dBFS number* is **unverified on device** — a phone's dBFS and a laptop's dBFS for
the same room are not the same measurement (§7, tests 15-19).

### 4.2 The two rules, and why both exist

Rule 2 (2 s continuous) is the product requirement, and it is deliberately strict:
a dip of any length restarts the window (`:159-173`). Its cost is that a student
reading the paper aloud in phrases never fills it. Rule 5 (burst count / burst
total) is the second way of asking the same question, and it is *additive, not a
replacement*: a phrase is a burst, three phrases in a minute is a strike, and a
stream of syllables each too short to be a burst still reaches the 4 s total
(`:50-56`, `:139-143`, `:171-182`). Both end in the same `_report`, which empties
the window so one conversation cannot stack two strikes (`:512-518`).

### 4.3 Microphone loss, permission revocation, reconnect

The transport is `AudioMonitor` (`mobile/lib/core/services/audio_monitor.dart`); the
governing requirement is that a microphone problem is **visible, never a silent
quiet room** (`:9-14`, `:256-272`).

| Situation | State | What the student sees |
| --- | --- | --- |
| `AUDIO_MONITORING=false` | `disabled` | "Audio off" (`:45-46`, `:68`, `:399-402`) |
| No capture path | `unavailable` | "Mic unavailable" (`:404-408`, `:66`) |
| Access refused | `permissionDenied` | Blocking overlay "Your microphone is switched off" + Try again / Open settings (`:466-473`, `exam_taking_page.dart:1006-1020`) |
| Device cannot open | `unavailable` | "could not be opened… in use by another app" (`:498-504`) |
| No levels within 4 s of `start()` | `unavailable` | "not reporting any sound levels… audio proctoring is off" (`:278`, `:547-553`) |
| **Samples stop mid-session** | `unavailable` | "stopped reporting sound levels… paused for this attempt" — chip only, the paper keeps going (`:539-578`, re-armed at `:534-537`, `:620`) |
| Stream errors mid-session (revoked, taken, unplugged) | `interrupted` | Blocking overlay "Your microphone was disconnected" + Reconnect (`:634-647`, `exam_taking_page.dart:1021-1031`) |
| Stream closes mid-session | `interrupted` | same (`:649-662`) |
| Reconnect | `retry()` stops, **resets the detector** (recalibrates), starts | `audio_monitoring_provider.dart:177-183` |

Two deliberate details: a `begin()` that outlives the timeout is closed when it
lands, so a late session cannot hold the device (and the OS recording dot) for the
rest of the sitting (`:484-497`, `:592-601`); and the release is time-boxed because
`record` serialises platform calls through one permit (`:315-324`, `:695-697`).

Status: **works as designed** at the state-machine level; **unverified on device**
for every row of the table, because `record`'s behaviour differs per platform (§7,
tests 20-22).

**The one gap found here is closed (`1073adb`, §8 item 6).** `levelTimeout` used to
guard only the *first* level: the timer was cancelled on the first sample and never
re-armed, so a microphone that stalled **silently** afterwards — no error, no `done`,
the platform just stops pushing amplitudes — left the state at `monitoring` with the
detector receiving nothing: no violation, no `interrupted`, `monitoring_ok` still
`true`. That is the failure mode the class exists to prevent, one tick later than it
was written for.

The window is now the gap *between* samples, re-armed by every one of them
(`:534-537`, called from `:519` and `:620`), and an expiry after the first sample
reports `unavailable` rather than the `interrupted` this report proposed. That part is
deliberate, and it is the interesting half: an errored stream is the device saying
goodbye and the exam page rightly blocks on it, but a feed that merely stops talking is
an *inference* — a backgrounded tab throttles its timers, the OS can pause a capture
thread, a platform bridge can miss a cadence — and every one of those heals itself on
the next sample. Blocking a paper on an inference is the false positive this monitor
exists to avoid, so the expiry only makes the gap visible on the chip, and the state
returns to `monitoring` on its own because the subscription is never dropped. What is
still unmeasured is the **number**: 4 s is a dozen missed 250 ms samples (`:119`),
which is a guess about how long a legitimate stall may last (tests 20-22).

### 4.4 Web and mobile parity

One implementation for every target: `RecordAudioLevelSource` uses the `record`
package, which reports dBFS on Android, iOS, web, Windows, macOS and Linux through
the same API, so there is **no per-platform branching**, only per-device capability
discovered at runtime (`audio_monitor.dart:107-116`). Capture is locked shut where it
matters: PCM16, 16 kHz, mono, `autoGain: false`, `echoCancel: false`,
`noiseSuppress: false` (`:172-184`) — gain or suppression would flatten exactly the
room-versus-voice difference the calibration is built on (`:178-183`). The PCM bytes
are drained and discarded and **no file is written** (`:114-116`, `:190-192`); only
numbers travel (and the consent text says so — `proctor_contract.dart` aside, see
`proctor_consent.dart:124`).

Where the platforms genuinely differ:

| Aspect | Phone | Web | Consequence |
| --- | --- | --- | --- |
| What `record` reports | smoothed amplitude envelope | **peak** of a short analyser window | A browser reads several dB hotter and spikier for the same room — which is why the speech margin was raised 4→6 dB (`audio_noise_detector.dart:214-227`) |
| Silence | `−160` when nothing to report | same sentinel | Both are clamped to −100 so the sentinel cannot become the room (`:251-259`) |
| Permission model | OS dialog, `permission_handler` also pre-checked (`exam_taking_page.dart:509-527`) | browser prompt, no `permission_handler` status | Messages differ by `kIsWeb` (`audio_monitor.dart:449-457`, `:466-473`) |
| Background behaviour | app backgrounded = `app_minimized` | hidden tab = `app_minimized`, and the timer may be throttled | Sustains are measured on the clock, not on sample counts, so a throttled page is not made "quieter" (`:161-162` of the detector) |

Status: **works as designed** as a single code path; **the calibration is not the
same measurement on the two platforms**, which is why §7 must measure both. It is
worth saying plainly: "6 dB above the room" is a different physical claim on a
phone and in Chrome, and only hardware can tell us whether 6 is right for both.

---

## 5. Device and browser integrity

### 5.1 What each signal is, and where it comes from

| Signal | Trigger | Platform | Evidence |
| --- | --- | --- | --- |
| `app_minimized` (lifecycle) | `paused`, `inactive` or `hidden`, once per background, re-armed on `resumed` | Android/iOS | `exam_lifecycle_observer.dart:28-45`, attached at `proctoring_provider.dart:205-207` |
| `app_minimized` (kiosk escape) | two consecutive `isLockTaskActive == false` polls, 1 s apart, after pinning was confirmed | Android | `kiosk_service.dart:136-161`, `:66-69`; reported at `exam_taking_page.dart:429` |
| `app_minimized` (web) | `visibilitychange` → hidden, `window.blur`, fullscreen exit whose grace ran out | Web | `web_guards_web.dart:18-29`, `web_exam_guard.dart:104-126`, `exam_strike_mapping.dart:39-49` |
| `copy_paste_attempt` | `copy`/`cut`/`paste` blocked | Web | `index.html:287-331`, `web_guards_web.dart:113-116` |
| `right_click_blocked` | `contextmenu` blocked | Web | same |
| `devtools_detected` | F12 / Ctrl-Shift-I/J/C, **or** a viewport-to-window gap > 160 px sustained over two probes 2 s apart | Web | `proctor_face_detector.js`-independent: `index.html:293-331`, `web_guards_web.dart:81-98` |
| `secondary_display_detected` | another display attached (HDMI/DP, cast, mirror) | Android **only** | `hardware_integrity_service.dart:10-23`, `:99-140`; 15 s poll (`:127-133`) |
| `virtual_camera_detected` | the lens in use is external or an emulator's synthetic camera | Android **only** | same |
| `idle_afk` | no pointer or keyboard input for 3 min, once per episode | All | `afk_watcher.dart:24-48`, `:70-76` |

### 5.2 Fullscreen

Required on the web, and the exit is the only *recoverable* signal: leaving fullscreen
opens a countdown (5 s, `exam_taking_page.dart:294-297`) with a blocking overlay and a
"return" button that supplies the user gesture Chromium needs
(`exam_taking_page.dart:1098-1158`, `web_exam_guard.dart:179-194`). A fullscreen
*exit* only counts once fullscreen was actually entered — an exam opened by
navigation often cannot enter without a gesture, and a page that was never fullscreen
must not fire violations for a state it was never in (`web_guards_web.dart:26-29`,
`web_exam_guard.dart:93-102`, `:120-123`). If the automatic attempt is refused, the
page offers the tap (`exam_taking_page.dart:452-457`).

Status: **works as designed** (test: `web_exam_guard_test.dart`).

### 5.3 Developer tools

Two independent probes, both web-only:

* **Keystrokes**: F12, and Ctrl/Cmd+Shift+I/J/C, blocked and reported from the
  bootstrap script before Flutter boots (`index.html:293-331`); a keystroke that is
  a browser shortcut the platform does not define is not guessed at
  (`index.html:293-296`).
* **Geometry**: no page can ask whether DevTools is open, so the guard watches the
  gap between the window's outer box and the viewport — what a *docked* panel
  widens. It is slow (one probe per 2 s), confirmed over two probes, reported once
  per episode, and the threshold is deliberately generous: 160 px clears every
  piece of ordinary browser chrome that has been measured, because a false
  acceleration ("you used developer tools") is worse than missing a thin panel
  (`web_guards_web.dart:44-49`, `:81-98`).

Status: **works as designed, as a heuristic**. What it cannot see: an **undocked**
DevTools window (which has no geometry signature at all), a panel opened in a second
browser window, or a student using a keyboard shortcut the page does not catch. Those
are **gaps by nature**, listed in §8 (item 7) rather than fixable by tightening a
number.

### 5.4 Second display and virtual camera

Android-only, through `hardware_integrity_channel` in `MainActivity.kt`
(`hardware_integrity_service.dart:99-114`). Policy lives in Dart: a 15 s poll (a
`DisplayManager` read plus a camera-id list, no camera opened), reported **when a
finding appears** rather than while it lasts (`:110-114`), never reported for a
platform that cannot answer (`:27-30`, `:41-48`), and skipped entirely for mock
sessions because an emulator's camera *is* synthetic (`exam_taking_page.dart:482-495`).
Both findings map to counted strikes through the one mapping module
(`exam_strike_mapping.dart:55-58`) and both are `isCritical`
(`violation.dart:67-81`), i.e. their evidence budget is 1.2 s so the row that stops
the attempt is not delayed by a photograph (`proctoring_provider.dart:247-259`).

Status: **works as designed on Android**; **unverified on device** — the rules
(`LENS_FACING_EXTERNAL`, emulator fingerprints) live in Kotlin and no test here can
exercise them (§7, test 24). On **web and iOS the answer is silence, not a clean
bill** (`README.md:146-149`), which is the honest direction but should not be read
as "no second screen".

### 5.5 Kiosk

Android lock task, best-effort without Device Owner (`kiosk_service.dart:45-64`).
Strict pinning requires the app to be device-owner whitelisted; otherwise it degrades
to screen pinning, which a long-press of Back + Recents can escape — and the escape
poll turns that into `app_minimized` (`:55-61`, `:136-161`). While pinned,
`FLAG_SECURE` blocks screenshots, screen recording and the recents thumbnail
(`:45-52`, `:74-83`). Two guards make it safe: a command round-trip is time-boxed to
2 s and a state query to 1 s, a timeout is "unknown" and never an escape
(`:85-96`, `:141-144`), and overlapping calls join the one in flight so one bootstrap
is one pin and one poll (`:111-130`).

On iOS, desktop and web `startLock` returns `KioskResult.unsupported` (`:38-42`, the
message says so) — the browser's equivalent is the DOM lockdown plus fullscreen.

Status: **works as designed**; **unverified on device**, and specifically:
whether the escape poll fires on the OEMs in use, and whether `FLAG_SECURE` survives
a fold/unfold (§7, test 25).

### 5.6 The hardware back button

`PopScope` in the exam page: back cannot pop the attempt while a violation overlay or
an equipment block is up (`exam_taking_page.dart:1832-1841`). While a warning is
showing, back dismisses the warning exactly as its own button does; while an
equipment block is up, back does nothing, and the block's own "Leave" is the one way
out (`:951-960`, `:1826-1831`). Once the attempt is decided neither screen is
dismissible (`:1835`, `proctoring_provider.dart:769-773`).

Status: **works as designed**. The Android system back *gesture* is the same
callback, so it is covered; the recents/home escape is `app_minimized` via the
lifecycle observer.

### 5.7 Split screen — not detected

Android multi-window (and a vendor's resizable split view) keeps the activity
`resumed`, so the lifecycle observer does not fire, the kiosk pin is what normally
prevents it, and nothing else watches the window size. On the web the equivalent —
a resized window beside another window — is caught only by `window.blur`, i.e. only
if focus actually leaves. The exam layout is responsive
(`exam_taking_page.dart:1713-1780`) so a split window renders fine, which is exactly
what makes it easy to miss.

Status: **gap.** In practice the mitigation is the kiosk pin, which is best-effort
without Device Owner. §8 item 8.

### 5.8 Android-only, and what the browser cannot see

| Capability | Android | iOS | Web |
| --- | --- | --- | --- |
| Frame-level face/pose detection in the app | yes (ML Kit) | yes (ML Kit ships for iOS) | no — a page script does it instead |
| Second display / virtual camera | yes | no | no |
| Kiosk / lock task / `FLAG_SECURE` | yes (best-effort) | no | DOM lockdown + fullscreen |
| Tab switch / blur detection | n/a | n/a | yes |
| Contract copy / context menu / devtools | n/a | n/a | yes |
| Frame-stall detection | **no** (§2.4) | no | yes |
| Split-screen detection | **no** (§5.7) | no | blur only |
| Liveness | **no** (§3) | no | **no** |

What the web **cannot** see, stated once: a second physical screen, a virtual camera,
whether the page is mirrored to a TV through the OS rather than through a `MediaStream`,
an undocked DevTools window, a second browser window that never takes focus, and
(everywhere) whether the person in frame is alive.

---

## 6. The strike pipeline, end to end

### 6.1 The client half

1. **A signal is produced.** Camera: the engine's stream, subscribed once in the
   notifier's constructor (`proctoring_provider.dart:198`). Web: the page's verdicts
   through `reportGazeSignal` (`:393`), which enters the *same* handler (`:395-427`).
   Audio: `AudioMonitoringNotifier` calls `reportAudioNoise` (`:452`) when its
   detector says so (`audio_monitoring_provider.dart:195-212`). Lifecycle, kiosk,
   browser guards and integrity probes each have one `report*` method
   (`:452-504`), all funnelling into the same place.
2. **`_registerViolation`** (`:523-600`) — three gates and a write:
   * `mounted` (`:530`) and `!state.ended` (`:531`);
   * a **per-type 2 s dedupe window** (`:534-540`, `_dedupeWindow` at `:291`);
   * optimistic UI *first*, so the student sees the warning before any round trip:
     `warningCount + 1`, overlay, `lastViolation`, and the type appended to the
     session's own evidence list (`:546-551`).
3. **Evidence, best-effort and time-boxed** (`:642-683`): the page hands the notifier
   a still grabber (`exam_taking_page.dart:603`), the notifier captures and uploads
   under **one** budget — 3 s normally, 1.2 s for the four identity-breaking strikes
   (`:238-259`, `:666-667`). Failure/timeout ⇒ the row goes without a picture
   (`:654-657`).
4. **Delivery** (`:565-573`): one `Violation` with a fresh `uuidV4()` as
   `client_event_id` (`:571`) goes to the outbox. The outbox either reaches the
   backend now or persists the row for replay.
5. **The server answers** `warning_count`, `disqualified`, `flagged`
   (`:589-599`). The count is *reconciled*, never incremented: the server recomputes
   it from the rows it holds (`schema.sql:3390-3412`).
6. **The ending is the server's**: `disqualified` ⇒ `_forceDisqualify` (`:697-720`),
   `flagged` ⇒ `_endForReview` (`:734-741`), neither ⇒ keep going.
7. **A late ruling** (a queued row delivered after the network returned) arrives on
   `deferredRulings` and is applied only if it is for this attempt, only raises the
   count, and ends the attempt if it is what crossed the line (`:608-621`).
8. **Both endings stop the work**: `_haltTracking` closes the camera gate and drops
   the gaze subscription (`:758-767`), the page releases the image stream, the
   controller, the microphone and the session watchers (`exam_taking_page.dart:932-949`).

### 6.2 The server half

`register_violation` (`supabase/schema.sql:3269-3431`) is the only write path, and
each guard is load-bearing:

| Guard | Line | Why |
| --- | --- | --- |
| Authenticated, and `is_current_session()` | `:3296-3310` | One login per account; a superseded device gets `PT409`, which the client treats as "signed in elsewhere" (`proctoring_repository_impl.dart:57-63`) |
| The submission belongs to the caller | `:3312-3327` | `SECURITY DEFINER` without this would let any account disqualify a classmate |
| Status must be `ongoing` | `:3329-3341` | A late frame cannot append evidence or resurrect a closed attempt — it returns the final state instead of raising |
| Snapshot path must match `<own id>/<action>_<epoch>.jpg\|png` | `:3343-3376` | Evidence poisoning, delete-by-proxy and folder-shaped names are all stored as `NULL`; a malformed path never buys a strike back |
| `on conflict (client_event_id) do nothing` | `:3378-3388` | A retried or replayed delivery inserts nothing — the idempotency that makes the offline queue safe |
| Weighted sum over the rows held, missing weight = 1 point | `:3394-3412` | Fail-closed: a new action type cannot be a free pass (`:3399-3402`) |
| `>= 3` ⇒ `flagged_for_review`, `submitted_at` once, `score` cleared | `:3414-3427` | The sitting closes; **nobody has decided anything** |

Weights: eight counted types at 1 (`multiple_faces`, `no_face`, `app_minimized`,
`devtools_detected`, `secondary_display_detected`, `virtual_camera_detected`,
`looking_away`, `audio_noise`) and three soft at 0 (`copy_paste_attempt`,
`right_click_blocked`, `idle_afk`) — `schema.sql:2460-2479`, mirrored client-side for
display only (`violation.dart:83-124`), pinned together by
`test/schema_contract_test.dart`.

Note what the RPC does **not** do: it never writes `disqualified`. The only writers
of that status are `resolve_flagged_attempt('disqualify')`
(`schema.sql:4032-4046`) and `submit_exam(p_disqualified => true)`, which the client
calls as bookkeeping after a ruling (`exam_repository_impl.dart:124-139`) — exactly
the "the client must not decide" property the state was designed around
(`proctoring_provider.dart:42-51`, `:722-732`).

### 6.3 Offline queue and replay

`OfflineSyncService` is a `ViolationOutbox` (`offline_sync_service.dart:347`):

* **Try once, then queue.** `log()` attempts the RPC with a 10 s deadline
  (`:812-822`, `:193`); on *any* failure the row is appended to a durable queue, the
  queue is trimmed (cap **200**, oldest dropped first — `:355`, `:876-887`), the
  whole queue is persisted, the state flips to offline, the retry backoff is reset
  to its floor (2 s, doubling to 60 s — `:353-354`, `:852-854`) and, for a critical
  type, one immediate flush is fired (`:855-862`).
* **Replay.** `_drain` (`:647-765`) walks the queue, increments `attempts`, delivers,
  removes on success and emits a **deferred ruling** so a third strike that landed
  while the network was down can still end the attempt (`:672-685`). It writes the
  queue back once per pass rather than per row (`:651-658`), and stops a pass after
  3 failures without dropping the rows (`:696-700`, `:403`).
* **Session superseded.** `PT409` ends the pass instead of burning its failure budget,
  keeps the rows (they are still true) and lets the session gate sign the device out
  (`:686-695`).
* **Why replay is safe.** Every queued row carries the `client_event_id` minted when
  the event was seen (`proctoring_provider.dart:571`), and the server inserts it or
  nothing (`schema.sql:3388`); the score is recomputed from stored rows, never
  incremented (`schema.sql:3394-3412`). This is stated as a contract at
  `offline_sync_service.dart:169-179`.
* **Hydration is lossy by design.** A queued row whose `action_type` the build no
  longer knows is dropped with a log line, rather than logged as some other
  violation (`:106-124`, `:891-900`).
* Without a queue, `DirectViolationOutbox` returns `null` on failure and the local
  count simply stands (`:212-253`) — the unit-test path.

Status: **works as designed** (tests: `offline_sync_service_test.dart`,
`proctoring_notifier_test.dart`). The cap of 200 and the "drop the oldest" policy
are the one place a strike can be silently lost (§6.6).

### 6.4 Lock-out, review, and reset

* **Flagged for review.** `_endForReview` sets `underReview`, halts tracking and
  exits; it deliberately does **not** call `markDisqualified`, because on a flagged
  attempt that call would overwrite the review it just asked for (`:722-741`). The
  student's screen says a supervisor will decide and who can unlock it
  (`violation_overlay.dart:23-33`), and it has no dismiss (`:770-773`).
* **Disqualified.** `_forceDisqualify` is idempotent, halts tracking *before* the
  network write, and exits whether or not the write succeeded — a student whose
  confirmation cannot be persisted used to be left sitting in an exam that had
  already ended (`:685-720`).
* **Supervisor resolution.** `DashboardRepositoryImpl.resolveFlaggedAttempt` calls
  the RPC (`dashboard_repository_impl.dart:128-152`); the server checks the tier
  *before* the status so an unauthorised caller cannot even learn whether an attempt
  is flagged (`schema.sql:4010-4017`), then writes the status and one
  `attempt_review_logs` row with the decision and note (`:4042-4061`). `clear`
  restores `submitted` **and recomputes the automatic score**, so it lands where a
  normal hand-in would (`:4035-4040`). Idempotent: a replay reports the stored
  outcome and writes nothing (`:4024-4030`).
* **Reset.** `resetSubmission` (`dashboard_repository_impl.dart:154-238`) reads the
  attempt's evidence paths, deletes the submission row *returning* `id, student_id,
  exam_id` (RLS refuses silently, so an empty result is reported as "not allowed"),
  removes the snapshot objects, and writes the audit row in `session_reset_logs`
  (`:252-282`). A storage or audit failure is returned as a **warning**, never thrown,
  because the attempt is already deleted and raising would invite a retry against a
  row that no longer exists (`:210-247`).

Status: **works as designed**; the SQL side is covered statically by
`supabase/tests/weighted_strikes_check.sql` and `supervisor_scope_check.sql`, which
cannot be executed here (no `psql`/`supabase`/`docker` on this machine — §7 preamble).

### 6.5 The heartbeat, and what it is not

Every 15 s (`proctoring_heartbeat.dart:52-58`) with a 4 s per-beat deadline (`:60-66`)
the client calls `record_heartbeat`, carrying `camera_ok` and `monitoring_ok`
(`proctoring_provider.dart:212-219`, `:332-333`, `:371-376`). **Nothing is queued**:
a late beat would fill the very gap it is meant to expose (`proctoring_heartbeat.dart:28-39`).
It stops with the session, not after it (`proctoring_provider.dart:794-800`). The
server rate-limits to one stored beat per 8 s and stamps
`exam_submissions.last_heartbeat_at`; `proctoring_coverage()` turns the series into
numbers for a supervisor, and it never touches `exam_submissions.status`
(`README.md:265-296`).

Status: **works as designed**. Its limitation is the one it states about itself: it
proves a client was running, not that it was watching.

**One loop that used to retry a refusal, closed (`49ee204`).** `record_heartbeat`
refuses a superseded session with `PT409` and the repository reports that as
`SessionSupersededException` for exactly one reason — "so the beat loop stops hammering
a session that cannot write" (`proctoring_repository_impl.dart:57-63`) — but the
heartbeat had no branch for it and fell into the generic catch: one refused round trip
every 15 s for the rest of the sitting, on every device that had been signed out
mid-exam. It now counts the refusal, logs it, and stops the series (`:230-244`).
Nothing is surfaced from the heartbeat, because `SessionGate` polls on its own and is
what signs the device out; a later `start()` (a resume) re-arms it and is refused once
more, which is the right answer from a session that is no longer current.

### 6.6 Every place a signal can be lost or double counted

**Lost (the signal never becomes a row):**

| # | Where | What happens | Deliberate? |
| --- | --- | --- | --- |
| L1 | `proctoring_provider.dart:530-531` | A signal arriving after the attempt ended, or after the page was popped, is dropped | Yes — there is no session left to attribute it to |
| L2 | `:402` | Every face signal while the camera gate is closed (initialising, lost, blocked) | Yes — a dead camera's silence is the camera's finding, not the student's |
| L3 | `:534-540` | A second event **of the same type** within 2 s is swallowed. Two distinct `app_minimized` events 1.5 s apart cost one strike | Yes, but it is the one place a *real* second event is lost — and it is invisible in the log |
| L4 | `mediapipe_proctoring_service.dart:611-617`, `web_face_presence.dart:302-307` | The engine/monitor latch: one episode, one strike | Yes — this is what stops one turn becoming seven strikes |
| L5 | `mediapipe_proctoring_service.dart:536-542` | A turn that loses the face is recorded as `no_face`, and the look-away episode is discarded (§1.3) | Yes, documented under-count |
| L6 | `proctoring_provider.dart:642-657` | The snapshot is discarded on timeout (3 s / 1.2 s); the row still goes | Yes — evidence is illustrative, the row is the record |
| L7 | `offline_sync_service.dart:876-887` | Queue cap 200, oldest dropped first. A long offline sitting can lose its **earliest** strikes | By policy, but it is silent to everyone except the debug console |
| L8 | `offline_sync_service.dart:106-124` | A queued row with an `action_type` this build does not know is dropped | Yes — mis-logging it would be false evidence |
| L9 | `proctoring_heartbeat.dart:28-39` | Beats are never queued; an unreachable beat is gone | Yes, and correct: a replayed beat would fill the gap it exists to expose |
| L10 | `proctoring_provider.dart:579` | If the page is gone by the time the outbox answers, the local session does not apply the ruling | The **server** has the strike; only the local UI misses it (the next read of the attempt shows the status) |
| L11 | `proctoring_provider.dart:609` | A deferred ruling for a session that is already torn down is ignored | Same as L10 |
| L12 | `web_face_presence.dart:230` | Everything inside the 5 s web grace is dropped | Yes (§2.3) |
| L13 | `exam_taking_page.dart:1086-1095` | `takePicture` failing while streaming (some Android devices) ⇒ no snapshot | Yes |

**Double counted (one act, two rows):**

| # | Where | What happens | Status |
| --- | --- | --- | --- |
| D1 | Replay of a queued row | Same `client_event_id` ⇒ `on conflict do nothing` (`schema.sql:3388`) | **Cannot double count.** Pinned by `offline_sync_service_test.dart` |
| D2 | Late ruling vs live ruling | `_handleDeferredRuling` only *raises* the count, and only to the server's number (`proctoring_provider.dart:613-615`) | **Cannot double count** |
| D3 | A host page that calls `proctorGuardFaceSignal` **and** also loads the shipped detector | Two sources into one vocabulary; the 2 s dedupe absorbs overlap, but two `no_face` messages 3 s apart are two strikes | **Risk** — `README.md:168-172` treats "shipped model" and "institution detector" as alternatives, not as a pair; nothing asserts that |
| D4 | One window minimised on the web that both fires `visibilitychange`/`blur` **and** leaves fullscreen | The blur/tab strike lands immediately; the fullscreen exit opened its own 5 s grace and landed a **second** `app_minimized` afterwards — outside the 2 s dedupe (`web_exam_guard.dart:120-126`, `exam_strike_mapping.dart:40-42`) | **Closed.** The guard no longer needs the browser to be quiet: a countdown opened by an exit inside the departure window (`fullscreenGrace`) of a strike already logged closes without a violation, so one act is one row *whether or not* Chromium reports the pair. `web_exam_guard_test.dart`: "…and the fullscreen exit it causes are one strike" (blur and tab), "an ESC from inside fullscreen is a strike, however recent the blur", "staying out of fullscreen is charged once…" |
| D5 | `no_face` while a `looking_away` episode was open | The two types are different, so the dedupe does not merge them — but only one can be open at a time by construction (§1.3 step 1) | **Cannot double count** |

D3 is the entry to keep in mind when reading a student's log; it is open, and nothing
asserts the page picks one face-signal source. D4 was the other, and it is closed in
the guard (see the row above): the double count is now impossible rather than
unconfirmed, because the second event closes a countdown that no longer charges.

---

## 7. What cannot be verified without hardware — a manual test plan

**Nothing in this section has been run.** These are the checks that need a real
phone, a real webcam, a real head and a real room. They are written so a second
person can run them without reading the code, and so a failure names the file to
look at.

**Kit required:** an Android phone with a working front camera (plus a second Android
device for the "another app took the camera" cases), a laptop with a webcam running
Chrome or Edge, a Firefox install, a headset with a microphone, a USB webcam, an HDMI
monitor or a Chromecast, a second account with supervisor rights, and a way to
throttle the network (airplane mode is enough for the offline cases).
**Where to look:** the app's debug console (`proctorLog` lines), and, per attempt,
`select action_type, timestamp, snapshot_url from proctoring_logs where
submission_id = '…' order by timestamp;` plus `select * from proctor_heartbeats
where submission_id = '…' order by received_at;`.

**The plan, in six parts** — 39 tests, about two days of a careful person's time:

| Part | Tests | What it settles |
| --- | --- | --- |
| A | 1-7 | Look-away and face presence on the phone: the 15°/2 s rule, the episode latch, two faces, camera loss, and the §2.3 start-up gap |
| B | 8-14 | The same on the web, where the sensor and the sustain both differ (§1.4), plus the suspected double count D4 |
| C | 15-23 | Audio: calibration, the 6 dB margin, bursts, one-off noises, cooldown, mic loss and reconnect, and phone-vs-laptop parity |
| D | 24-27 | Device and browser integrity: second display, virtual camera, kiosk, hardware Back, split screen |
| E | 28-32 | The strike pipeline: offline replay, slow network, heartbeat gaps, review, reset |
| F | 33-39 | Honest students: glasses, hijab/cap, a low laptop, a noisy room, a slow network, a dark room, a long sitting |

Run part A and test 11 first: they are the cheapest way to find a false positive, and
test 7 and test 11 are the only two that can confirm a *gap* rather than a design.

### A. Look-away (mobile)

**1. The 15° / 2 s rule, on a phone.**
*Steps:* start an attempt; hold the head still facing the screen 10 s; turn to 10°
(measured with a phone compass app or a protractor taped to the desk), hold 5 s;
return; turn to 25°, hold 1 s; return; turn to 25°, hold 3 s; return.
*Expected:* no `looking_away` at 10°. None for the 1 s turn. Exactly **one**
`looking_away` for the 3 s turn, with a snapshot.
*What it proves:* the 15° gate and the 2 s sustain on real ML Kit output — the single
most important unknown in §1.2. *Record:* any angles the console logs, and whether
the 1 s turn produced anything.
*If it fails:* `proctoring_thresholds.dart:53`, `:64`, `:68` are the only numbers to
change; `mediapipe_proctoring_service.dart:587-590` is where they are applied.

**2. One episode is one strike, and it re-arms.**
*Steps:* turn 30° away and hold 15 s; return to the screen for 3 s; turn away again
for 3 s.
*Expected:* **two** `looking_away` rows total, not five and not one.
*Status:* `mediapipe_proctoring_service.dart:611-618` (the latch).

**3. The face lost mid-turn.**
*Steps:* turn far enough that the face leaves the frame (near 90°), hold 10 s, come
back.
*Expected:* `no_face`, **no** `looking_away`, and the paper covered by "We cannot see
your face" while away.
*Status:* the documented under-count in §1.3.

**4. Two people.**
*Steps:* have a second person lean into frame for 2 s, leave; 10 s later, lean in
again for 2 s; then wait 35 s alone and lean in a third time.
*Expected:* one `multiple_faces` for the first lean-in; **nothing** for the second
(the 30 s latch has not expired); a second row for the third.
*Status:* `mediapipe_proctoring_service.dart:558-585`.

**5. Absence and the equipment overlay.**
*Steps:* cover the lens with a hand for 1 s, uncover; then cover for 5 s.
*Expected:* nothing for 1 s (below 3 frames at ~7 FPS — if a row appears, the real
frame rate is far lower than assumed, which is itself a finding); for the 5 s cover,
one `no_face` and the blocking overlay within about half a second, clearing by itself
when the hand goes.
*Status:* `:44`, `:536-551`, `exam_taking_page.dart:1040-1051`.

**6. Camera pause and resume.**
*Steps:* mid-attempt, open the camera app (or a video-call app) so Android takes the
lens; wait 5 s; come back.
*Expected:* "Your camera has stopped" overlay; **no** `no_face` or `looking_away`
logged while it was down; "Restart camera" reopens it; counting restarts from zero
(the first two seconds after resume must not be a strike).
*Status:* §2.5. If the app instead logs `no_face`, `value.hasError` is not what
Android reports, and `_onCameraValueChanged` needs a second trigger.

**7. The start-up window (the §2.3 gap).**
*Steps:* tap Start, and deliberately keep the phone pointed at the ceiling for the
first 3 s, then bring it up.
*Expected, current behaviour (i.e. the gap):* a `no_face` strike **and** the
equipment block. *Desired:* no strike inside a start-of-session grace.
*Status:* this test exists to confirm the gap is real and to size it — note how long
until the first row appears.

### B. Look-away and presence (web)

**8. The web actually measures an angle.**
*Steps:* open the exam in Chrome on the laptop; run
`ProctorGuardFaceDetector.diagnostics()` in the console; sit facing the screen; turn
10° for 2 s; turn 25° for 2 s.
*Expected:* `diagnostics()` names the detector and the pose source (native or
MediaPipe); no row at 10°; **one** `looking_away` at 25° after about 0.3-0.7 s
(300 ms sustain plus a 350 ms tick).
*Status:* `proctor_face_detector.js:1575-1602` (diagnostics),
`web_face_presence.dart:77`, `:273-275`.

**9. The near-sideways start.**
*Steps:* turn 40° for a single detection (under 150 ms on the phone, one 350 ms tick
in a browser); face the screen again; then turn 40° and stay there for a second.
*Expected:* the first turn is **no** row — one detection is a frame, not a student —
and the second is one `looking_away`, landing within about 0.3 s on the phone and
0.7 s in the browser rather than after the 2 s hold: past
`lookAwayImmediateYawDegrees` (30°) two consecutive detections confirm the turn, and
both hosts read the same two constants. If ordinary 15-20° turns produce rows this
fast, the angle is being applied below the gate it belongs to.
*Status:* `mediapipe_proctoring_service.dart` (`immediateYawDegrees`,
`immediateFrameThreshold`), `web_face_presence.dart` (`immediateYawDegrees`,
`immediateConfirmations`), both defaulted from `proctoring_thresholds.dart`.

**10. Covered, dark and frozen camera.**
*Steps:* cover the lens for 3 s; uncover; turn the lights off for 5 s; then hold a
still frame in front of the lens (a virtual camera with a fixed picture is the
cleanest way to simulate this).
*Expected:* `no_face` in each case, the last one after 3 frozen ticks; and **no** row
for the first 5 s of a camera that never opened.
*Status:* `proctor_face_detector.js:1430-1456` (`inactiveReason`, `frameIsBlank`).

**11. One window minimise — how many rows? (D4, closed in the guard.)**
*Steps:* mid-attempt, minimise the browser window (not a tab switch), wait 15 s,
restore, return to fullscreen.
*Expected:* **one** `app_minimized` — the blur or tab strike; the fullscreen exit that
follows it is the same act and closes its countdown without a second row.
*Status:* the rule is pinned on the VM (`web_exam_guard_test.dart`, four tests), so the
device run is now a *browser* question rather than a product one: it tells you whether
Chromium reports the pair at all, and whether the 5 s overlay appears before the
strike lands. A second row here would mean the second event came more than
`fullscreenGrace` after the first.

**12. Honest glances (the false-positive floor).**
*Steps:* sit normally and look down at a sheet of paper on the desk five times for
under 0.3 s each, spread over a minute.
*Expected:* **no rows.** Any row here means the 300 ms web sustain is too tight for a
real head at a real desk (`web_face_presence.dart:114-127`).

**13. A real glance.**
*Steps:* look down at the paper for 1 s, five times over two minutes.
*Expected:* five `looking_away` rows — and three of them close the sitting for
review. That is the intended behaviour *and* the web's biggest false-positive risk
(§1.4). Record it, then decide as a product whether the web sustain or the weight
should differ from the phone's.

**14. A browser that cannot measure (count-only).**
*Steps:* serve the build **without** `web/mediapipe/` and open it in Firefox (no
Shape Detection API).
*Expected:* the strip "Head turns are not being checked in this browser…" appears;
`proctorGuardFaceAnalysis` reports `false` in the console; that attempt's heartbeat
rows carry `monitoring_ok = false`; **no violation** is logged for it; turning 30°
away produces **no** `looking_away` row.
*Status:* §2.6.

### C. Audio (15-19 rules, 20-22 loss, 23 parity)

**15. Calibration and speech in a quiet room.**
*Steps:* sit in a quiet room and start an attempt; stay silent 5 s; read a paragraph
aloud at normal volume for 10 s; stop.
*Expected:* the chip shows calibrating for ~3 s then a threshold; **one**
`audio_noise` for the paragraph, with a snapshot, and a console line giving the floor,
the threshold and the level (`audio_monitoring_provider.dart:202-208`).
*Record:* those three numbers — they are what says whether 6 dB is right
(`audio_noise_detector.dart:214-227`).

**16. A loud room.**
*Steps:* play a television at conversational volume for 10 s during an attempt, once
with calibration done *before* the TV starts and once with the TV already on.
*Expected:* a strike in the first case (it is >6 dB over the measured floor), no
strike in the second (the room *is* the TV). Both are correct — record which happened.

**17. The burst rule.**
*Steps:* read aloud in short phrases with pauses — about 1 s of speech every 4 s, for
90 s, never 2 s continuously.
*Expected:* one `audio_noise`, landing when the third burst or the 4 s total falls
inside the 60 s window (`audio_noise_detector.dart:494-510`).

**18. One-offs.**
*Steps:* cough loudly twice, scrape a chair, type loudly, close a door — spread over
two minutes, otherwise silent.
*Expected:* **no** `audio_noise`. A single cough that strikes means the calibration
floor or the clamp is wrong for that device.

**19. Cooldown and the emptied window.**
*Steps:* talk continuously 20 s; stay quiet 5 s; talk continuously 5 s.
*Expected:* one strike for the first episode, then **one** more once the 10 s cooldown
has elapsed — not a stack, and not silence for the rest of the attempt.

**20. Headset unplugged mid-session.**
*Steps:* start with a wired headset, unplug it during the attempt.
*Expected:* `Mic lost` and the blocking "Your microphone was disconnected" overlay
with Reconnect; **no** false "quiet room"; replug + Reconnect ⇒ monitoring resumes and
the detector recalibrates (a new calibration appears in the console).

**21. Permission revoked mid-session.**
*Steps:* on Android, revoke the microphone permission from system settings while the
exam runs; on the web, block the microphone from the site-permission panel.
*Expected:* the same `Mic lost` / `Mic blocked` treatment, never a silent gap.
**If the app keeps saying "Mic live" with a flat level, that is the §4.3 silent-stall
gap — record it precisely.**

**22. Reconnect after a failure.**
*Steps:* tap Reconnect from the blocked overlay without fixing anything; then fix the
permission and tap again.
*Expected:* the first attempt fails visibly (never silently), the second resumes, and
neither leaves the OS recording indicator on. Check the camera is unaffected.

**23. Web/mobile parity.**
*Steps:* run tests 15 and 16 on the phone and on the laptop, in the same room, with
the same text read at the same volume.
*Expected:* both fire; record floor and threshold on each. **This is the measurement
the 6 dB margin has never had** — if a laptop's floor calibrates 10 dB hotter for the
same room, the margin needs a per-platform default.

### D. Device and browser integrity

**24. Second display and virtual camera (Android).**
*Steps:* mid-attempt, plug in an HDMI monitor (or start a cast); then, in a separate
attempt, feed the app a USB webcam.
*Expected:* one `secondary_display_detected` and one `virtual_camera_detected`, each
with a snapshot, each appearing at the moment it is attached and **not** repeating
while it stays attached (15 s poll, report-on-appearance).
*Status:* `hardware_integrity_service.dart:110-114`. On a non-Android platform the
expected answer is **nothing at all** — that is silence, not a clean bill.

**25. Kiosk.**
*Steps:* run once on a device with ProctorGuard as Device Owner, and once without.
*Expected:* with Device Owner: home/recents blocked, screenshots refused; without:
screen pinning, escapable by long-press Back + Recents, and the escape produces
`app_minimized` within about 2 s (`kiosk_service.dart:136-161`). Both runs: the exit
is **not** logged as an escape.

**26. Hardware back.**
*Steps:* press Back while a warning overlay is up; then while the "camera stopped"
block is up; then on the review screen.
*Expected:* the warning is dismissed (same as its button); the equipment block is not
dismissible by Back (only its Leave); the review/disqualification screen cannot be
backed out of.

**27. Split screen.**
*Steps:* on Android, put the exam into split view with another app.
*Expected, current behaviour:* **nothing is logged** (§5.7 gap). Record it so the gap
is on the record rather than assumed.

### E. The strike pipeline

**28. Strikes taken while offline, then replayed.**
*Steps:* put the phone in airplane mode; commit three counted strikes (e.g. three
look-aways); stay offline 60 s; turn the network back on; wait 30 s.
*Expected:* the student sees three warnings offline; on reconnect the attempt closes
as "with a supervisor" (the deferred ruling crossing the threshold), the server holds
**exactly three** rows, and no row has a duplicate `client_event_id`.
*Status:* `offline_sync_service.dart:672-685`, `proctoring_provider.dart:608-621`.

**29. Slow network and the evidence budget.**
*Steps:* throttle to a very slow connection (or use a proxy that stalls); trigger one
ordinary strike and one critical one (`multiple_faces`).
*Expected:* both rows still arrive; the ordinary one may carry a snapshot and the
critical one may not (1.2 s budget); neither takes longer than ~10 s to be decided,
and a failed delivery is queued rather than lost.
*Status:* `proctoring_provider.dart:642-667`, `offline_sync_service.dart:193`.

**30. The heartbeat gap.**
*Steps:* disconnect the network for 2 minutes mid-attempt, then reconnect and
finish.
*Expected:* `proctor_heartbeats` has a **gap** for those two minutes, the rosters
show "proctoring silent", `proctoring_coverage()` reports it, and **no** violation is
logged for it and the attempt's status is untouched.
*Status:* `proctoring_heartbeat.dart:28-39`, `README.md:265-296`.

**31. Flagged → reviewed.**
*Steps:* reach three counted strikes; as a supervisor open the attempt; "clear" it
with a note; repeat on another attempt and "disqualify".
*Expected:* the student's screen says a supervisor will decide; `status` is
`flagged_for_review` in between; after "clear" it is `submitted` **with a score**;
after "disqualify" it is `disqualified` with no score; `attempt_review_logs` holds one
row per decision (and a replay of the same call writes none).
*Status:* `schema.sql:4024-4061`, `dashboard_repository_impl.dart:128-152`.

**32. Reset.**
*Steps:* reset a finished attempt from the console.
*Expected:* the submission row is gone, its snapshot objects are gone, a
`session_reset_logs` row records the counts, and the student can start a fresh
attempt on the same paper. Reset an attempt you are not entitled to reset: the app
must say "the server deleted nothing… or your account may not be allowed", never a
success.
*Status:* `dashboard_repository_impl.dart:154-238`.

### F. Honest students — the false-positive suite

These are the tests that decide whether the product is usable. Each one should end
with **zero strikes** unless the student genuinely leaves the frame.

**33. Glasses.** *Steps:* sit an attempt wearing strong prescription glasses, with a
window behind you and then a lamp in front. *Expected:* no `no_face`, no
`looking_away` from the reflection. *Watch:* `no_face` flicker (3-frame threshold,
`mediapipe_proctoring_service.dart:44`) is the most likely failure.

**34. Hijab, headscarf or cap.** *Steps:* sit an attempt with the head and hair
covered. *Expected:* the face is still detected; yaw stays measurable; no strikes.
*Watch:* a detector that cannot find the face outline may report `no_face`
intermittently, and the *web* fallback (which needs eye/nose landmarks) may lose the
pose and start reporting "head turns are not being checked".

**35. Laptop below eye level.** *Steps:* sit a web attempt with the laptop on a desk
and the camera looking up at the face, then with the laptop on a low table and the
student leaning over it. *Expected:* no `looking_away` from the baseline pitch alone
(the rule is |pitch| > 15°, not "pitch != 0" — `mediapipe_proctoring_service.dart:589-590`).
*Watch:* reading on a low screen can genuinely put the chin 20° down; this is the
case where the 2 s phone sustain and 300 ms web sustain differ most.

**36. A noisy room (the honest version).** *Steps:* sit an attempt in a room with a
fan, an air-conditioner and traffic outside. *Expected:* calibration absorbs the
steady noise (it is the *floor*), no `audio_noise` for the room itself; speech still
strikes. *Watch:* if the room alone strikes, the 6 dB margin is too tight for that
device (`audio_noise_detector.dart:214-227`).

**37. Slow network.** *Steps:* sit an attempt on a throttled connection and answer
normally for 10 minutes. *Expected:* the sync banner explains the backlog, answers
are never lost, no proctoring strike is caused by the network, and the *student* is
never locked out by a delivery failure.
*Status:* `offline_sync_service.dart:647-765`, `exam_sync_banner.dart`.

**38. Dark room, backlit window.** *Steps:* sit an attempt with only a monitor as
light, then with a bright window behind the head. *Expected:* the face is still found
and **no** `no_face` is invented. On the web this is the case the JS blank/dark test
exists for (`proctor_face_detector.js:1453-1456`) — check it does not fire on a
genuinely dark but occupied frame.

**39. A long sitting.** *Steps:* sit a full-length attempt (60+ minutes) with normal
movement. *Expected:* no strikes for ordinary posture, and `proctoring_coverage()`
reports ~100 % of expected beats with `camera_ok` true throughout. This is also the
test that reveals battery/thermal throttling of the camera pipeline on a mid-range
phone — a real risk for the §2.4 frame-stall gap.

---

## 8. Gaps, prioritised

Ordered by "how much harm, to whom". P1 items either let a cheat through or charge an
honest student for something they did not do.

### P1 — fix or decide before the next sitting

**1. No liveness check at all.** A printed photo or a looping clip is a perfect
student as far as the current stack is concerned (§3.1). The mitigation in place is
supervisor review of stills. Design, action type, weight and effort: §3.2-§3.3
(~7-9 working days, over a third of it on hardware). *Decision needed first:*
whether the institution accepts review alone.

**2. The web's look-away rule was 300 ms where the phone's is 2 s — fixed (`e37739e`).**
Same 15° gate, same weight, same threshold of 3, so three ordinary one-second glances
at the desk in a two-minute web sitting used to close the paper for review (§1.4). The
web now waits the engine's own `lookAwaySustain` (2 s) through the shared thresholds
constant, so the two hosts judge a turn by one rule and `no_face` keeps its 300 ms.
Tests 12-13 are still the measurement that would say whether 2 s is the right number
for a browser at all — this only removes the *difference*.

**3. No start-of-session grace on Android — fixed (`f200a91`).** A student still
lifting the phone into position as the stream starts could begin the exam with a
`no_face` strike (§2.3, confirmed by test 7). The web's 5 s window became the shared
`cameraStartupGrace`, and the Android engine now counts it from the **first streamed
frame** — the web's own small bug (§2.3), where the window ran from page mount,
fixed in the same commit.

**4. Suspected double `app_minimized` on one window minimise (§6.6 D4) — fixed.**
The blur strike landed immediately and the fullscreen-exit grace landed another five
seconds later: two rows, five seconds apart, outside the 2 s dedupe. The guard now
treats a fullscreen exit inside the departure window (`fullscreenGrace`) of a strike
already logged as the same act — the countdown still runs, so the student is still
asked back to fullscreen, but it closes without a violation. Staying out of
fullscreen is also charged at most once per episode, however often the page re-asserts
the requirement. Four tests in `web_exam_guard_test.dart` (test 11 remains useful as
the browser-level confirmation, not as the fix).

### P2 — fix in the next maintenance window

**5. No frame-stall watchdog on Android (§2.4).** If the camera stops delivering
frames while the controller still reads healthy, proctoring silently stops and the
heartbeat keeps saying `camera_ok = true`. The web has `STALL_MS` / `FROZEN_TICKS`
(`proctor_face_detector.js:193-199`); the phone has nothing. Fix: a last-frame
timestamp in the engine and a 3-5 s watchdog that calls `setStreamActive(false)` —
which already does the right things — letting the existing "Your camera has stopped"
overlay do the rest.

**6. A microphone that stalls silently after the first sample (§4.3) — fixed
(`1073adb`).** `levelTimeout` guarded only the first level (`audio_monitor.dart:551-552`
in the audited tree); after that, a platform that stopped pushing amplitudes left the
state at `monitoring` with nothing being judged. The window is now re-armed by every
sample and an expiry mid-session reports `unavailable`, **not** the `interrupted`
proposed here: from inside the monitor a dead feed and a throttled background tab look
identical, and only one of them is the student's problem, so the state stops short of a
verdict, the chip shows the gap, and the next sample returns the state to `monitoring`
on its own. What is still open is the *number* — 4 s is a guess about how long a
legitimate stall lasts (§7, tests 20-22).

**7. Developer tools can be opened invisibly (§5.3).** Undocked panels, a second
browser window, a shortcut the page does not intercept — none is visible to a page.
Not fixable in the client: it belongs in the risk register beside liveness, and in
the invigilation instructions.

**8. Split screen is not detected (§5.7).** Android multi-window keeps the activity
resumed, so no lifecycle event fires. The only real mitigation is a Device-Owner
kiosk, which is a deployment decision, not a code change.

### P3 — record it, live with it, or tidy it

**9. The offline queue can drop the oldest strikes (cap 200).** Only reachable after
hours offline, but the drop is silent outside the debug console
(`offline_sync_service.dart:876-887`). Either raise the cap or surface "N queued
events were dropped" to the supervisor through coverage.

**10. Two face-signal sources at once (D3).** A host page that calls
`proctorGuardFaceSignal` *and* loads `proctor_face_detector.js` can produce two
strikes for one real event when they are more than 2 s apart. `README.md:168-172`
describes the two as alternatives; nothing enforces it.

**11. The per-type 2 s dedupe can swallow a genuine second event (L3).** Deliberate,
but worth a line in the supervisor's guide: "two events 1.5 s apart are one row".
There is no supervisor's guide in this repository yet (`docs/`, `README.md` and
`mobile/README.md` have no such section, checked 2026-11-12), so this and item 12 are
notes for whoever writes it rather than edits made here.

**12. Warning ordinal vs weighted score.** `ViolationOverlay` shows `warningCount` —
the row count — as "Warning N" (`exam_taking_page.dart:1842-1855`), while the chip
beside it shows the counted score. The two can therefore disagree (a soft
`copy_paste_attempt` raises N but not the score). The code says this is deliberate —
the overlay is about the event, the chip about the distance to closing — and the chip
does spell the score out, so this is a wording note for the supervisor's guide rather
than a defect: "Warning 4" does not mean the attempt is about to close. Same
destination as item 11.

**13. `estimateHeadPose` is only exercised by tests.** The landmark-based pose helper
(`mediapipe_proctoring_service.dart:465`) is not on the production path — ML Kit's
Euler angles are — so its accuracy has never mattered. If a future model swap routes
through it, it becomes load-bearing and has never been checked on real data.

**14. A documentation nit found while reading — fixed.** The lecturer-isolation
migration cited a test file that does not exist: "block (o) of
`supabase/tests/lecturer_isolation_check.sql`" at
`supabase/migrations/20261111090100_lecturer_isolation.sql:61`. There is no such
file, and no block (o) in `supervisor_scope_check.sql` either — its blocks run (a) to
(l). The comment now names block (l) of
`supabase/tests/supervisor_scope_check.sql`, which is where that overlap is discussed
(an enrolled lecturer sitting a colleague's paper) and where the fixture is
deliberately kept labelled so the check stays about the scope. That also made the
sentence truer than it was: the student arms (`student_id = auth.uid()`) never ask the
role, which is the actual reason a student who is also a lecturer keeps their student
reach.

---

## 9. What this audit changed

**Nothing, at the time it was written.** No Dart file, no SQL, no migration, no test
and no README was modified to produce this report; the only new file is this document.
The verification that was actually run is the 253-test command in the header, and it
exercises the *rules*, not the sensors.

The fixes came afterwards, one commit each, and they are listed in the table at the
top of this report: `e37739e` (web look-away by the phone's rule), `f200a91` (Android
start-up grace from the first frame), the `web_exam_guard.dart` commit that closes D4
with four new unit tests, and a comment fix in the lecturer-isolation migration, which
is still uncommitted with the rest of that feature and will ride with it. Each change
was checked with `flutter analyze` (no issues), the whole `flutter test` suite (880
tests) and `node --test "tools/detector_eval/test/*.test.mjs"` (52 tests then; 62
today, the ten pose-matrix ones added below); the only
SQL edited was a comment, so `supabase/tests/*.sql` was not re-run.

One caveat for anyone checking this with `git status`: the working tree already held
uncommitted changes when the audit began — the single-session gate, the
lecturer-isolation migration and their tests (`session_gate.dart`,
`20261111090100_lecturer_isolation.sql`, and the twelve files edited to wire them in).
Those changes are *read* by this report and are not *part* of it; the only line
touched inside them is the migration's own comment (P3-14).

The single most useful next step is still not a code change: it is the 39 tests in §7.
Run them in the order P1 → P3. §8 items 1, 11, 12 and 13, and tests 1, 11, 12, 13 and
33-39 in §7, are the ones where the answer could change a design decision rather than
merely confirm one. Test 11 is now the browser-level confirmation of a rule that is
already enforced, not the discovery of one.

The two most recent are the ones this report's own §8 asked for, and they are listed in
the same table: `1073adb` (the microphone watchdog re-arms on every sample, and a feed
that goes quiet is `unavailable`, not the `interrupted` the report proposed) and
`49ee204` (the heartbeat stops when the server says the session was superseded, instead
of retrying a refusal every 15 s). Verified the same way as the rest — `flutter analyze`
clean, the whole `flutter test` suite (941 tests, two of them new), no SQL touched — and
neither is a number §7 measures; the only new *question* for §7 is how long a legitimate
stall may last before a chip is right to say `Mic unavailable` (test 20).

The last one is not a fix but a proof, and it is the one item on this list that could
not have been settled by reading code: `580fdd8`. The web detector reads yaw and pitch
out of MediaPipe's 4x4 head-pose matrix, and a 4x4 printed in a log has no visible
handedness — row-major or column-major, both look like a matrix, and a wrong choice
turns a real head the wrong way while a level head still reads level. So the test builds
rotations from angles known in advance, flattens them the way `Matrix.data` does, and
compares: the layout is column-major as documented, the decomposition is `Ry·Rx·Rz`,
roll moves neither angle, and the same 20° pitch flattened row-major reads −20°. Ten
tests, no browser and no model; with them the node suite is 62 tests. Nothing under
`mobile/` changed, so the Dart suite and its 941 tests are untouched by that commit,
and the sign convention it cannot settle is not used: the app compares absolute angles.

### One-paragraph summary for a reader who reads only this

Proctoring today is a well-built **presence and behaviour** monitor: it knows
whether a face is there, how many, whether the head is turned for long enough,
whether the room got loud for long enough, whether the student left the app, and
whether an Android device grew a second screen or a false lens. Every one of those
signals runs through one dedupe gate, one evidence upload, one idempotent server call
and one human review queue, and none of the numbers is guessed: they are named
constants with tests on them. What it is **not** is an identity or liveness check —
a photograph held at the lens satisfies every rule in the system, and that is the
first item in the risk register and the first gap here. The three things it was most
likely to get wrong in practice were the web's 300 ms glance window, the phone's
missing start-of-session grace, and any camera or microphone that stops silently
without saying so: the first two are now judged by one shared rule on both hosts, the
third now at least stops claiming to monitor (a feed that goes quiet turns the chip to
`Mic unavailable` instead of `Mic live`), but *how long* a stall may last before that is
still a guess, and none of the three can be settled without a real device.
