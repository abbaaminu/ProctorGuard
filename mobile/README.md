# Exam Proctor — Architecture Notes

## Layout
```
lib/
  core/services/           # Supabase bootstrap, permissions, ML Kit face-
                            # detection engine, lifecycle observer, kiosk bridge,
                            # browser guards (tab switch/blur/fullscreen)
  features/
    auth/                   # email/password sign-in form (Supabase Auth)
    exam/                   # domain entities, repo, exam-taking UI
    proctoring/             # violation domain model, repo, Riverpod
                            # escalation notifier, full-screen overlay
    dashboard/              # supervisor real-time monitoring page
supabase/schema.sql         # tables, RLS policies, RPCs
android/.../MainActivity.kt # kiosk bridge: lock_task_channel::startLock/stopLock
```

## Wiring order (what to do first)
1. Run `../supabase/schema.sql` in the Supabase SQL editor (or via CLI
   migrations) — shared with the `../dashboard` app in this monorepo. It
   creates all 5 tables, RLS policies, the `questions_public` safe view,
   and two RPCs: `register_violation` (server-enforced 3-strike rule) and
   `merge_submission_answer` (race-safe autosave).
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
4. Wire your router (`go_router` is *not* a dependency yet) using the page
   constructors already built: `ExamTakingPage(examId, submissionId)`,
   `SupervisorDashboardPage(examId, examTitle)`.
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
`_RoleGate` renders whenever there is no session — the `"Login page goes here"`
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

Role routing after sign-in is still a placeholder: `_RoleGate` rebuilds on
`SupabaseService.signedInChanges`, so a successful sign-in swaps this page out,
but the student/supervisor split (reading `users.role`) is the next step.

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
  unhandled stream error. `_RoleGate` rebuilds from `signedInChanges`, which is
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
  excluded from the `questions_public` view the exam-taking page reads
  from; RLS also blocks students from selecting the raw `questions` table
  directly.
- **Append-only violation log.** `proctoring_logs` has insert + select
  policies but no update/delete policy, so RLS makes tampering with
  history impossible from the client.
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
