# Exam Proctor — Architecture Notes

## Layout
```
lib/
  core/services/           # Supabase bootstrap, permissions, ML Kit face-
                            # detection engine, lifecycle observer, kiosk bridge,
                            # browser guards (tab switch/blur/fullscreen)
  features/
    auth/                   # sign-in form, `users.role` profile lookup,
                            # post-login RoleGate router
    exam/                   # domain entities, repo, student portal,
                            # exam-taking UI
    proctoring/             # violation domain model, repo, Riverpod
                            # escalation notifier, full-screen overlay
    dashboard/              # supervisor exam picker + live monitoring page
supabase/schema.sql         # tables, RLS policies, RPCs
android/.../MainActivity.kt # kiosk bridge: lock_task_channel::startLock/stopLock
```

## Wiring order (what to do first)
1. Run `../supabase/schema.sql` in the Supabase SQL editor (or via CLI
   migrations) — shared with the `../dashboard` app in this monorepo. It
   creates all 5 tables, the RLS policies, the `questions_public` safe view and
   three RPCs: `register_violation` (server-enforced 3-strike rule),
   `submit_exam` (server-side grading + close) and `merge_submission_answer`
   (race-safe autosave).
2. `flutter pub get`, then run with:
   ```
   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=...
   ```
   `SUPABASE_ANON_KEY` is still read as a fallback (Supabase renamed the
   "anon" key to "publishable" key). Or let `.\run_app.ps1` do it — see
   "Helper scripts" below.
3. Face detection is already wired: `MediaPipeProctoringService` converts each
   camera frame into a single-plane NV21 (Android) / BGRA8888 (iOS) buffer and
   runs Google ML Kit Face Detection (`google_mlkit_face_detection`) on it,
   which returns the face count and head-pose Euler angles. Throttling, angle
   math and the `GazeSignal` contract stay plugin-agnostic — to swap in another
   model (MediaPipe Face Mesh, a TFLite landmarker, …) replace `_runInference`
   and use `estimateHeadPose` when your model emits 3D (x/y/z) landmarks.
   **On the web there is no ML Kit**, so a browser session runs either in mock
   mode (`.\run_app.ps1 -Mock`, or `--dart-define=MOCK_CAMERA=true`) or with a
   webcam and no face signals; the audio hook (`reportAudioLevel`) and the
   browser guards below are platform-independent and work either way.
4. Routing is wired: `RoleGate` reads `users.role` after sign-in and sends
   students to `StudentExamPortalPage` (published exams → `ExamTakingPage`) and
   supervisors to `SupervisorExamPickerPage` → `SupervisorDashboardPage`. Drop in
   `go_router` (`go_router` is *not* a dependency yet) when deep links matter —
   every page takes plain constructor args.
5. Nothing else to download — ML Kit bundles its face model inside the app, so
   no `assets/models/face_landmarker.task` file is needed any more.
6. `flutter test` runs the unit/widget tests in `test/` (head-pose geometry,
   engine defaults, violation overlay) — no device required.

## Helper scripts (PowerShell)

`run_app.ps1` and `build_apk.ps1` exist because the two values the app reads
at startup (`SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`) must be passed as
`--dart-define` constants. Both resolve them in this order:
**parameter → environment variable → prompt**.

```powershell
# one-time per shell (or set them as user environment variables)
$env:SUPABASE_URL = 'https://<project-ref>.supabase.co'
$env:SUPABASE_PUBLISHABLE_KEY = '<publishable/anon key>'

.\run_app.ps1                        # flutter run + --dart-define
.\run_app.ps1 -Device emulator-5554  # target one device
.\run_app.ps1 -Release               # release mode instead of debug
.\run_app.ps1 -Mock                  # no camera: simulated gaze deviations every 12s
.\run_app.ps1 -DryRun                # print the exact command, run nothing
.\run_app.ps1 -ListDevices           # what -Device accepts

.\build_apk.ps1                      # flutter build apk --release --split-per-abi
.\build_apk.ps1 -Single -Clean       # one universal APK, from a clean tree
```

Both accept `-Url` / `-Key` instead of the environment variables and
`-NonInteractive` (fail instead of prompting — handy for CI). `run_app.ps1`
forwards extra flags via `-FlutterArgs '--verbose'`. If Windows refuses to
run them, use
`powershell -ExecutionPolicy Bypass -File .\run_app.ps1`.

`build_apk.ps1` warns when the Android SDK is missing or incomplete
(`flutter doctor` needs a green Android toolchain), then prints the artifact
paths and the `adb install -r` line. Release builds are still signed with the
debug keystore until a real signing config is added to
`android/app/build.gradle.kts`, so those APKs are for testing, not for the
Play Store.

> These values are compiled into the binary: use the **publishable/anon** key
> only. Never the `service_role`/secret key — anyone who unpacks the APK would
> get full database access. `supabase_defines.ps1` rejects `sb_secret_` keys.

## Violation snapshots (Supabase Storage)

When the engine reports a violation, the notifier pulls a still from the live
camera (`CameraController.takePicture`) and uploads it to the public
`proctor-snapshots` bucket as `<submissionId>/<action_type>_<epoch-ms>.jpg`,
then stores the public URL on the log row (`proctoring_logs.snapshot_url`, which
the supervisor console already renders).

- Capture and upload are **best-effort and time-boxed (5 s each)**: if the
  camera refuses a still while streaming, or Storage rejects the upload, the
  violation is still logged — just without a picture — so evidence collection
  can never delay the 3-strike escalation.
- `register_violation(p_submission_id, p_action_type, p_snapshot_url)` now
  carries the URL; the third argument is optional so older clients keep working.
- `register_violation` is `SECURITY DEFINER` (a student may neither insert into
  `proctoring_logs` nor update `exam_submissions`), so it re-checks that the
  caller owns the submission before writing anything. Without that guard any
  signed-in account could disqualify a classmate by calling the RPC with their
  submission id. A violation that arrives *after* the attempt closed is reported
  rather than logged, so late frames cannot pad the evidence.
- The bucket, its size/mime limits and its policies live in
  `../supabase/schema.sql` §6: an authenticated student may only upload into
  their **own, still-ongoing** submission folder (mirroring the append-only
  `proctoring_logs` policy), and no client may update or delete snapshots.

## Testing without a camera (`MOCK_CAMERA`)

```powershell
.\run_app.ps1 -Mock
# equivalent to: flutter run --dart-define=MOCK_CAMERA=true --dart-define=... 
```

With `MOCK_CAMERA=true` the exam page never opens a camera (the self-view shows
a "MOCK CAMERA" tile instead) and `MediaPipeProctoringService` emits a
simulated `no_face` → `looking_away` → `no_face` … gaze deviation every 12
seconds (`-Mock` is the flag; `-MockCamera` is kept as an alias).
That walks the **real** escalation ladder (3 strikes → auto-disqualification →
forced exit) against your Supabase project, so emulators, desktop targets and CI
runners can exercise the overlay, the log rows and the supervisor's live feed
without a physical camera. Simulated violations carry no snapshot (there is
nothing to capture). Tune the cadence with the service's `mockInterval`.

> Web is a buildable target too (`flutter run -d chrome`), which is why
> `PermissionService` skips Android-only permissions such as
> `systemAlertWindow` there instead of throwing. Real face detection still needs
> mock mode on the web — Google ML Kit has no web implementation.

## Browser guards (Chrome/Edge): tab switch + HTML5 fullscreen

`WebGuards` (`lib/core/services/web_guards.dart`) is the browser counterpart of
the Android lock task, created through a **conditional import**: the DOM code
(`web_guards_web.dart`, `package:web` + `dart:js_interop`, Wasm-safe) only exists
in a web build, while Android/iOS/desktop and the Dart VM that runs `flutter test`
get `UnsupportedWebGuards` — `isSupported == false`, silent.

What it listens to, and what each event becomes:

| Browser event | Condition | Violation |
| --- | --- | --- |
| `visibilitychange` | `document.visibilityState == 'hidden'` (other tab, minimised window, discarded page) | `app_minimized` |
| `blur` on `window` | focus left while the document stays `visible` (second monitor, another app in front) | `app_minimized` |
| `fullscreenchange` | left fullscreen **after** entering it (ESC, F11) | `app_minimized` |

`blur` is suppressed while the document is hidden, so one tab switch is one event
rather than two.

`WebExamGuard` (`web_exam_guard.dart`) owns the session rules and is what the exam
page drives: it requests fullscreen when the session starts, forwards events to
`ProctoringNotifier.reportAppMinimized()`, and `stop()` leaves fullscreen and
detaches the listeners, so a finished exam neither traps the student nor keeps
counting strikes. Two deliberate mitigations:

- **Start-up grace (5s).** Opening an exam legitimately disturbs focus — camera
  permission prompt, fullscreen transition, the browser's media indicator. Those
  first seconds are ignored; a student who switches away after reading question 1
  is still caught.
- **An exit only counts after a confirmed entry.** If the browser never granted
  fullscreen, "not fullscreen" is not a violation. Chromium requires a **user
  gesture** for `requestFullscreen()`, so an automatic attempt from a navigation
  often fails — the page then shows a "Fullscreen is required for this exam"
  prompt whose button *is* that gesture, and the guard is armed from there.

That makes this enforcement rather than suggestion: on Chrome and Edge, switching
tabs, blurring the window or dropping out of fullscreen each log a violation
through `register_violation` and escalate under the same 3-strike rule as the
camera signals.

To check the DOM half still compiles for a browser without a router or an exam
session, build the smoke target:

```powershell
flutter build web -t tool/web_guard_smoke.dart
```

(It imports `WebGuards`, so `web_guards_web.dart` stays reachable.)

## Verifying the native kiosk bridge without a full APK build

`flutter build apk` needs `cmdline-tools` installed (Android Studio → SDK
Manager → SDK Tools → *Android SDK Command-line Tools*) and a JDK 17+; when that
toolchain is broken you can still type-check `MainActivity.kt` on its own, which
is enough to catch a wrong Android API or a bad override:

```powershell
$kotlinc = "$env:ProgramFiles\Android\Android Studio\plugins\Kotlin\kotlinc\bin\kotlinc.bat"
$android = "$env:LOCALAPPDATA\Android\Sdk\platforms\android-36.1\android.jar"
$flutter = Get-ChildItem "$env:USERPROFILE\.gradle\caches\modules-2\files-2.1\io.flutter\flutter_embedding_release" -Recurse -Filter *.jar |
    Select-Object -First 1 -ExpandProperty FullName
$androidx = Get-ChildItem "$env:USERPROFILE\.gradle\caches\transforms-*" -Recurse -Filter classes.jar |
    Where-Object { $_.FullName -match 'lifecycle|annotation|activity|core' } | ForEach-Object FullName
& $kotlinc -classpath ((@($android, $flutter) + $androidx) -join ';') -jvm-target 17 `
    -d "$env:TEMP\kiosk-out" mobile\android\app\src\main\kotlin\com\example\exam_proctor\MainActivity.kt
```

That is how the invalid `override fun onLockTaskModeExiting()` was caught:
`Activity` has no such callback in the public API (only `DeviceAdminReceiver`
has one, and that needs device-owner status), which is why escape detection polls
`getLockTaskModeState()` from Dart instead.

## Sign-in (email + password)

`LoginPage` (`lib/features/auth/presentation/pages/login_page.dart`) is what
`RoleGate` renders whenever there is no session — the `"Login page goes here"`
placeholder is gone. It:

- validates both fields before touching the network (whitespace counts as
  empty) and trims email **and** password before the call, since phone keyboards
  like to append a trailing space;
- disables the form and swaps the button label for a spinner while the request
  is in flight, so a double tap cannot start two sign-ins;
- reports failures in a `SnackBar` using `AuthOutcome.message`. Supabase's
  `Invalid login credentials` and `Email not confirmed` are rephrased, anything
  else passes through, and a message-less failure still says something useful.
  The form stays in place, ready for another attempt;
- delegates to `SupabaseService.instance.signInWithPassword(...)`, i.e. the
  `auth.signInWithPassword(email:, password:)` call, wrapped by the service so
  no exception reaches the widget layer — that service is the only place that
  imports `supabase_flutter`. In a build booted without credentials it returns
  "Backend not configured", which the form shows like any other error instead of
  crashing.

`LoginPage` takes an optional `signIn:` callback for exactly that reason: the
tests drive success, rejection, a hung request and the unconfigured path with no
backend at all (`mobile/test/login_page_test.dart`).

Role routing after sign-in is covered in "Role routing (post-login)" below.

## Role routing (post-login)

`RoleGate` (`lib/features/auth/presentation/widgets/role_gate.dart`) is the whole
router today. Once `SupabaseService.signedInChanges` reports a session it:

1. takes the auth user id and reads **`public.users`** for it
   (`ProfileRepositoryImpl` → `select().eq('id', userId).maybeSingle()`, allowed by
   the "Authenticated users can read profiles" policy);
2. shows "Loading your profile…" with a spinner while that read is in flight;
3. routes on the role:
   * `student` → `StudentExamPortalPage`
   * `supervisor` → `SupervisorExamPickerPage`

A failed lookup (offline, no row, unrecognised role) renders a retryable error
with a **Sign out** escape hatch instead of guessing a role — an unknown
`users.role` throws in `UserRole.fromDb` rather than defaulting to `student`.
`profileRepositoryProvider` is bound in `main()` next to the exam/proctoring
repositories, and `userProfileProvider` is keyed by the auth user id, so signing
in as a different account resolves a different profile.

### Student Exam Portal

`StudentExamPortalPage` lists every published exam (CS101 and MAT201 in
`seed.sql`) through `PublishedExamList`, and on tap:

* calls `startOrResumeSubmission(examId)` — the schema's
  `unique(student_id, exam_id)` means a second tap resumes rather than duplicates;
* an `ongoing` attempt pushes `ExamTakingPage(examId, submissionId, durationMinutes,
  startedAt)`: the session screen with the camera (or the `MOCK_CAMERA` feed),
  question navigation, the countdown, the 3-strike overlay, Android kiosk pinning
  and the browser guards;
* an attempt that is already `submitted` **or `disqualified`** is reported in a
  SnackBar and *not* reopened — exactly what Aisha hits on CS101 in the seed data,
  where the server disqualified her after three strikes;
* a failed start shows "Could not start …" instead of a silent no-op.

### The exam session screen

`ExamTakingPage` owns one attempt end to end, and every way it can fail ends
somewhere the student can leave from — the chrome deliberately has no back button
mid-exam, so a silent failure would strand them:

| Situation | What the student sees |
| --- | --- |
| Camera/mic permission refused (Android/iOS) | "This exam needs camera and microphone access…" + **Try again** / **Leave** |
| No camera, or the camera refuses to start | the same blocking screen with the plugin's error code |
| Question feed unreachable | "Could not load the questions for this exam." + **Try again** / **Leave** |
| Exam has no questions yet | "No questions yet" + **Leave** (the attempt stays `ongoing`, so it can be resumed after a supervisor adds them) |
| Clock ran out | auto-submit; if the server cannot be reached, a "Time is up" screen with **Send again** / **Leave** |

Details worth knowing:

* **`exams.duration_minutes` is enforced.** The countdown is anchored on
  `exam_submissions.started_at` (not on "now"), so a resumed attempt keeps its
  remaining time and one that is already past its deadline is submitted on the
  first tick. The chip in the app bar turns amber under 5 minutes and red under 1.
* **Answers are painted locally and saved through `merge_submission_answer`.** A
  failed autosave says so and *stays on the question* instead of advancing past
  the only chance to save that answer — grading reads the server copy.
* **Submitting goes through `submit_exam`** (see `../supabase/schema.sql`): the
  server grades and closes the attempt, and `score` is never written by the
  client. There is no student `UPDATE` policy on `exam_submissions` at all.
* **Retry re-runs only the failed stage** — the permissions, camera, kiosk pin or
  question feed that already succeeded is not reopened.
* **The kiosk bridge and permission status queries are time-boxed**
  (`KioskService.commandTimeout`, `PermissionService.statusTimeout`). A platform
  channel that never answers used to leave the bootstrap waiting forever, i.e. the
  spinner above; now the session degrades to "not pinned" / "not granted" and the
  screen explains itself. A lock-task *state* query that times out is treated as
  "unknown" rather than as an escape, so a slow device cannot burn a strike.
* **Startup permission prompts do not block the first frame.** `main()` fires the
  permission pass without awaiting it (an OS dialog can stay open indefinitely,
  and blocking `runApp` on it is the blank-page startup failure the boot order
  exists to avoid); the exam screen re-checks the critical statuses before opening
  the camera.

`mobile/test/role_routing_test.dart` covers the portal path with injected
repositories: role parsing, both routes, the loading state, the retry after a
failure, the disqualified guard, and the exam/submission ids handed to the session
screen. `mobile/test/exam_taking_page_test.dart` covers the blocking state and its
retry/leave actions.

## Web authentication (and startup safety)

Web builds are configured **entirely through `--dart-define`** (there is no
`.env` at runtime in a browser):

```powershell
flutter run -d chrome `
  --dart-define=SUPABASE_URL=https://<project-ref>.supabase.co `
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<publishable/anon key>
```

What `SupabaseService` guarantees on web:

* **`SUPABASE_PUBLISHABLE_KEY` falls back to the legacy `SUPABASE_ANON_KEY`**;
  placeholders (`your-project…`, `YOUR_KEY`) and scheme-less URLs are treated as
  "not configured", so a half-filled command can't silently boot against a bogus
  backend.
* **Initialisation never throws.** It reports `SupabaseInitStatus`
  (`ready` / `notConfigured` / `failed`) and the app renders
  `SetupRequiredPage` with the exact command to run instead of a blank page. Use
  `clientOrNull` on startup paths — the old `late final client` threw
  `LateInitializationError` whenever configuration was missing.
* **Session persistence is probed before init.** The SDK reads
  `window.localStorage` while initialising, and browsers can refuse it (Safari
  private mode, partitioned third-party storage, sandboxed iframes). When that
  happens the service logs a warning, disables persistence deliberately
  (`persistSession: false` + an in-memory PKCE store) and keeps working —
  `sessionPersistenceAvailable` is `false`, and the setup/role screens warn that
  a refresh will sign you out. Otherwise the session survives refreshes.
* **Auth calls return `AuthOutcome` instead of throwing**:
  `signInWithPassword`, `sendMagicLink`, `refreshSession`, `signOut`. Expected
  failures (wrong password, unconfirmed email) surface `AuthException.message`;
  everything else (channel, storage, offline) becomes a generic failure message.
* **Auth events are streamed safely.** `authStateChanges` (raw `AuthState`) and
  `signedInChanges` (`bool`, so widgets need no `supabase_flutter` import) are
  backed by a listener that routes errors to `debugPrint` with
  `cancelOnError: false`, so a failed token refresh can never become an
  unhandled stream error. `RoleGate` rebuilds from `signedInChanges`, which is
  how a restored session reaches the UI after a refresh.
* **Redirect flows.** The client uses PKCE with `detectSessionInUri: true`, so
  the `?code=…` (or `#access_token=…`) that Supabase appends on the way back is
  exchanged for a session and then cleared from the address bar. Register the URL
  the app is served from — `authRedirectUrl` returns `Uri.base.origin` on web —
  under **Authentication → URL Configuration → Redirect URLs**, and pass
  `redirectTo` to `sendMagicLink` if you serve the app from a sub-path.

## Anti-cheating surface (kiosk, lifecycle, strikes)

Five independent detectors feed one escalation path, and every signal ends in
the same `register_violation` RPC, so the server stays the source of truth for
the 3-strike rule:

| Detector | Signal | `action_type` |
| --- | --- | --- |
| ML Kit face detection | no face / several faces / head pose off-axis | `no_face`, `multiple_faces`, `looking_away` |
| `ExamLifecycleObserver` | `paused` / `inactive` / `hidden` (app switch, notification shade, incoming call) | `app_minimized` |
| `KioskService.escapes` | lock task state polls inactive twice while the exam runs (the student escaped screen pinning) | `app_minimized` |
| `WebGuards` (Chrome/Edge) | tab hidden, window blurred, or HTML5 fullscreen left | `app_minimized` |
| `reportAudioLevel(double)` | dBFS above threshold, sustained | `audio_noise` |

Kiosk bridge contract — MethodChannel `lock_task_channel`:

| Method | Direction | Payload |
| --- | --- | --- |
| `startLock` | Dart → Android | `{granted: bool, strict: bool, canDetectEscape: bool, message: String?}`; `strict` is true only when a device owner whitelisted the app, `canDetectEscape` when `getLockTaskModeState()` is available (API 23+) |
| `stopLock` | Dart → Android | `null`; restores the system bars |
| `isLockTaskActive` | Dart → Android | `bool`; polled while the exam runs |
| `isLockTaskPermitted` | Dart → Android | `bool`; device-owner whitelist status |

`Activity` has **no public "lock task ended" callback** (only
`DeviceAdminReceiver` has one, and it needs device-owner status), so
`KioskService` polls `isLockTaskActive` every `escapePollInterval` (1s) while the
exam runs: two consecutive inactive reports, after the platform confirmed
pinning at least once, mean the student escaped screen pinning. That is the only
escape signal that works on a non-managed device.

The exam page creates one `KioskService` per session in `_bootstrap()`, forwards
`escapes` to `ProctoringNotifier.reportAppMinimized()`, and unpins in `dispose()`
first so finishing the exam is never an escape; the browser guards are wired the
same way (`WebExamGuard` in `_bootstrap()`, `stop()` in `dispose()`).
`mobile/test/kiosk_service_test.dart` pins this wire format (including the "our
own unpin is not an escape" and "a single inactive blip is tolerated" rules);
`mobile/test/web_exam_guard_test.dart` covers the browser rules;
`mobile/test/proctoring_notifier_test.dart` covers the strike escalation.

## Key design decisions worth knowing about
- **Server-enforced escalation.** The 3-strike disqualify rule lives in
  the `register_violation` Postgres function, not just in Dart. A student
  patching the client can't spoof past it — the client's `warningCount`
  is reconciled against the RPC's authoritative return value every time.
- **Grading never touches the device.** `questions.correct_option` is
  excluded from the `questions_public` view the exam-taking page reads (a
  definer view filtered to published exams), and there is **no** student SELECT
  policy on the raw `questions` table at all — so the answer key cannot reach a
  student device. `submit_exam` grades from the stored answers on the server.
- **Append-only violation log.** `proctoring_logs` has no insert, update or
  delete policy: `register_violation` is the only writer, and it re-checks that
  the caller owns the submission, so RLS makes tampering with evidence
  impossible from a client.
- **`app_minimized` detection accepts false positives.** `AppLifecycleState
  .inactive` fires for notification-shade pulls, incoming calls, *and*
  (on many Android builds) the screenshot flash — that's intentional
  per the spec, but expect some benign trips; the debounce window in
  `ProctoringNotifier` prevents log spam from a single event.
- **Kiosk mode is best-effort on non-managed devices.** Standard Android
  Screen Pinning (`startLockTask` without Device Owner status) still lets
  the user exit with a long-press back+recents gesture and a
  confirmation prompt — true unremovable lockdown requires enrolling the
  device via Android Enterprise. That escape is not free, though:
  `KioskService` polls the platform's lock task state once a second and the
  exam page turns two consecutive "not pinned" reports into an
  `app_minimized` strike. `KioskService` itself degrades gracefully on
  iOS, desktop and web — `granted: false` instead of an exception — so the
  exam still starts (the AppBar badge then reads "Unpinned").
- **Pinning hides the system chrome too.** `startLock` enters immersive
  mode (`WindowInsets.Type.systemBars()` hidden on API 30+, the legacy
  `SYSTEM_UI_FLAG_IMMERSIVE_STICKY` flags below that) and sets
  `FLAG_KEEP_SCREEN_ON`, putting the status bar, notification shade and
  navigation gestures out of reach for the session; `stopLock` restores
  both and stops the escape poll, so submitting an exam — or being
  disqualified — is never recorded as a violation. The activity opts in
  with `android:lockTaskMode="if_whitelisted"` in `AndroidManifest.xml`.
- **ML Kit instead of MediaPipe.** The original draft depended on
  `google_mediapipe_tasks_flutter`, which does not exist on pub.dev (404) and
  so broke `flutter pub get` outright. `google_mlkit_face_detection` fills the
  same role, needs no model download, and reports head pose directly
  (`headEulerAngleY` = yaw, `headEulerAngleX` = pitch) — which is why the
  detector runs in `FaceDetectorMode.accurate`: ML Kit only populates those
  angles in accurate mode.
- **Dependencies match actual imports.** `noise_meter`, `tflite_flutter`,
  `android_intent_plus`, `go_router`, `fl_chart`, `intl`, `uuid`,
  `riverpod_annotation`/`riverpod_generator`, `freezed`/`freezed_annotation`,
  `json_annotation`/`json_serializable` and `build_runner` were never imported
  by any file, so they were dropped to keep `pub get`/build times (and the
  dependency surface) small. Re-add them as each feature lands — most
  notably `noise_meter`, whose hooks already exist:
  `ProctoringNotifier.reportAudioLevel(double)` (dBFS samples above
  `audioNoiseThresholdDb`, sustained for `audioNoiseSustain`, become
  `audio_noise` strikes) and `reportAudioNoise()` for a source that
  classifies noise itself.
- **Android specifics for the camera pipeline.** ML Kit needs `minSdkVersion`
  21+ (Flutter's default is 24) and its byte-buffer API accepts a single plane
  only, so the exam page requests `ImageFormatGroup.nv21` on Android and
  `bgra8888` on iOS. CameraX may report an NV21 stream as `yuv420`, so the
  engine normalises both to NV21. On iOS, ML Kit additionally requires
  deployment target 15.5 and `EXCLUDED_ARCHS[sdk=*] = armv7` in the Podfile.
- **Frame throttling.** Frames are dropped, not queued, when
  inference is still busy or the 150ms window hasn't elapsed — keeps the
  camera stream from backing up on slower devices instead of processing
  stale frames late. Unusable buffers (wrong format/orientation) are skipped
  rather than counted as "no face", so they can't burn a strike.
