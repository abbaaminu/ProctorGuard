# ProctorGuard — Flutter app notes

## Layout
```
lib/
  core/services/           # Supabase bootstrap, permissions, ML Kit face-
                            # detection engine, lifecycle observer, kiosk bridge,
                            # browser guards (tab switch/blur/fullscreen),
                            # microphone level monitor + audio-noise rules
  features/
    auth/                   # sign-in form, `profiles.role` profile lookup,
                            # post-login RoleGate router
    admin/                  # admin roster: create/delete accounts and manage roles
    exam/                   # domain entities, repo, student portal,
                            # exam-taking UI (the page delegates to
                            # ExamSessionController + extracted session widgets)
    proctoring/             # violation domain model, repo, Riverpod
                            # escalation notifier, full-screen overlay
    dashboard/              # staff analytics, supervisor monitoring and resets
supabase/schema.sql         # tables, RLS policies, RPCs
supabase/functions/         # server-side account creation and deletion
android/.../MainActivity.kt # kiosk bridge: lock_task_channel::startLock/stopLock
```

## Wiring order (what to do first)
1. Run `../supabase/schema.sql` in the Supabase SQL editor (or via CLI
   migrations). It
   creates all 5 tables, the RLS policies, the `questions_public` safe view and
   four RPCs: `register_violation` (server-enforced 3-strike rule),
   `submit_exam` (server-side grading + close), `merge_submission_answer`
   (race-safe autosave for choices) and `merge_submission_text_answer` (the same
   for typed answers).
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
4. Routing is wired: `RoleGate` reads `profiles.role` after sign-in and routes on
   the four values of the `public.user_role` enum — students to
   `StudentExamPortalPage` (published exams → `ExamTakingPage`), `lecturer` to the
   authoring console (`LecturerConsolePage`, whose app bar opens the same supervisor
   console), `supervisor` to `SupervisorExamPickerPage` →
   `SupervisorDashboardPage`, and `admin` to `AdminDashboardPage`. Admins manage
   accounts and can open the exam monitor; `admin`, `supervisor` and `lecturer` can
   reset attempts (`is_attempt_resetter()`, because the paper's author is the one
   who repairs a wrong key); all staff can open analytics. Account creation and
   deletion use `admin-create-user` and `admin-delete-user` Edge
   Functions because auth users cannot be managed through ordinary client
   table writes. Drop in `go_router` (`go_router` is *not* a dependency yet)
   when deep links matter — every page takes plain constructor args.
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
(`flutter doctor` needs a green Android toolchain), checks for release signing
material *before* it spends time on `pub get`, then prints the artifact paths and
the `adb install -r` line. A release APK is signed with the keystore named by
`android/key.properties`; without that file Gradle refuses the build (see
"Release builds" below).

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
  `proctoring_logs` policy), no client may *update* a snapshot, and deleting one is
  the reset's own purge, allowed only for `is_attempt_resetter()`
  (`Proctor snapshots supervisor purge`) — a student can never erase their own
  evidence.

## Testing without a camera (`MOCK_CAMERA`)

```powershell
.\run_app.ps1 -Mock
# equivalent to: flutter run --dart-define=MOCK_CAMERA=true --dart-define=... 
```

With `MOCK_CAMERA=true` the pre-exam device check is skipped — its checklist says
**MOCK HARDWARE … nothing here is proctored** and "Start Exam" is enabled without
touching the hardware — and the exam page never opens a camera either (the
self-view shows a "MOCK CAMERA" tile instead). The gate is the only thing that
honours the flag: without it, a camera or a microphone that cannot be opened
blocks the exam.

`MOCK_CAMERA` does not mock the microphone either: audio proctoring still opens its own
session, so a build with no input device shows `Mic unavailable` on the chip. Add
`--dart-define=AUDIO_MONITORING=false` for a demo or CI run that has no microphone at
all — the chip then reads `Audio off`, and the exam is otherwise unaffected.

`MediaPipeProctoringService` emits a
simulated `no_face` → `looking_away` → `no_face` … gaze deviation every 12
seconds (`-Mock` is the flag; `-MockCamera` is kept as an alias).
That walks the **real** escalation ladder (3 strikes → auto-disqualification →
forced exit) against your Supabase project, so emulators, desktop targets and CI
runners can exercise the overlay, the log rows and the supervisor's live feed
without a physical camera. Simulated violations carry no snapshot (there is
nothing to capture). Tune the cadence with the service's `mockInterval`.

A dart-define is a compile-time constant and cannot be faked at runtime, so
`ExamTakingPage` also takes `mockCamera` (null = follow the flag). That is what
`mobile/test/exam_taking_page_test.dart` uses to exercise the question half of
the screen — numbering, option taps, the fill-in-the-blank field and the submit
flush — without a camera.

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
| `fullscreenchange` | left fullscreen **after** entering it (ESC, F11) | `app_minimized`, after a 5s countdown (below) |
| `fullscreenchange` | fullscreen came back | none — it cancels that countdown |

`blur` is suppressed while the document is hidden, so one tab switch is one event
rather than two.

`WebExamGuard` (`web_exam_guard.dart`) owns the session rules and is what the exam
page drives: it requests fullscreen when the session starts, forwards events to
`ProctoringNotifier.reportAppMinimized()`, and `stop()` leaves fullscreen and
detaches the listeners, so a finished exam neither traps the student nor keeps
counting strikes. Three deliberate mitigations:

- **Start-up grace (5s).** Opening an exam legitimately disturbs focus — camera
  permission prompt, fullscreen transition, the browser's media indicator. Those
  first seconds are ignored; a student who switches away after reading question 1
  is still caught.
- **An exit only counts after a confirmed entry.** If the browser never granted
  fullscreen, "not fullscreen" is not a violation. Chromium requires a **user
  gesture** for `requestFullscreen()`, so an automatic attempt from a navigation
  often fails — the page then shows a "Fullscreen is required for this exam"
  prompt whose button *is* that gesture, and the guard is armed from there.
- **A fullscreen exit gets a 5-second countdown, not an instant strike.** It is the
  one signal that is recoverable by the student in a couple of seconds, so
  `WebExamGuard.fullscreenGrace` opens a window: `FullscreenLockOverlay` covers the
  exam (blocking, so nothing can be read or typed behind it), counts down from 5,
  and its **Return to fullscreen** button supplies the gesture Chromium needs.
  Coming back inside the window logs nothing (`fullscreenEntered` cancels the
  window); letting it run out logs exactly one `app_minimized`. The guard owns the
  deadline and a `Timer` backstop, the page owns the pixels, and
  `expireFullscreenGrace()` is idempotent so the two racing is harmless. A session
  that ends mid-countdown logs nothing at all (leaving fullscreen on the way out is
  not cheating), and `reassertFullscreen()` re-opens the window when the page comes
  back to the foreground still out of fullscreen.

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

## Offline resilience (answers, violations, the banner)

An exam is the worst place to lose a network: a dropped connection used to mean an
answer that never reached the server (grading reads the server copy) and a
proctoring row that silently vanished. `core/services/offline_sync_service.dart`
(`OfflineSyncService`) is now the single write path for both, and it is
**local-first**: the device is written first, the network is caught up afterwards.

| Step | What happens |
| --- | --- |
| Student taps an option | `ExamSyncBanner` stays quiet; `cacheChoice` writes the draft **and** a queue row to `KeyValueStore`, and the session advances immediately |
| Student types | `cacheTextDraft` mirrors the keystroke into the draft cache (no network write — the server does not need every character) |
| "Save & next" / keyboard done | `cacheText` does the same, plus a queue row |
| The write reaches Supabase | the queue row is dropped, the banner disappears |
| The write fails | the row stays queued, the banner turns into **"Offline - syncing locally"**, and the session carries on |
| The connection comes back | the queue drains by itself: the browser's `online` event, the app's resume hook (`AppLifecycleListener`), or the retry backoff (2s, doubling to 60s) |
| Submit, with the queue still full | the attempt is *held*, not lost: a "Waiting for a connection" screen with **Submit again** / **Leave**, and leaving keeps the attempt `ongoing` with its answers on the device |

Details worth knowing:

- **One instance, one queue, app-scoped.** `offlineSyncServiceProvider` lives in
  `core/di/providers.dart` (next to the repository providers, which moved there so
  the service and the notifier cannot form an import cycle; `proctoring_provider.dart`
  re-exports them, so every existing import site is unchanged). Because it is not
  `autoDispose`, work cached during an exam survives leaving the screen, a browser
  refresh and a restart — the queue and the drafts are on disk.
- **`KeyValueStore` never throws.** `shared_preferences` is the production store
  (localStorage on web, prefs/plist on mobile); a runtime that refuses it — private
  mode, partitioned storage, a `flutter test` binding with no plugin — degrades to
  an in-memory map for the session instead of failing a save.
- **Timers only run while there is something to send.** An idle session schedules
  nothing, so a finished exam does no background work (and a widget test never ends
  with a pending timer).
- **Violations ride the same queue, with an idempotency key.** A failing
  `register_violation` call is queued with the client-minted `clientEventId` of that
  one event, and the retry replays it unchanged: the `on conflict` in
  `supabase/schema.sql` inserts the row or nothing, so a lost response cannot turn
  one violation into two strikes. `ProctoringNotifier` still counts the strike
  optimistically and the UI still warns; `ViolationOutbox.deferredRulings` hands it
  the server's ruling when the row does land, which is how a third strike taken
  offline still ends the attempt.
- **The server keeps the authoritative timeline.** Every row carries
  `client_timestamp` (when the violation happened on the device) *and* the server's
  own `timestamp`, so a violation delivered late is still placed correctly in the
  audit trail without trusting a device clock for ordering.
- **The banner says what it knows.** It appears only while something is queued, and
  it distinguishes "Syncing your answers…" from "Offline - syncing locally"; it
  repaints only when what it renders actually changes, so an offline exam does not
  spin frames for as long as the connection is down.

`mobile/test/offline_sync_service_test.dart` covers the queue rules (durability
before the network, drain on recovery, backoff without help, one queued row per
question, restore after a restart, corrupt-storage tolerance, the same event id on
retry, a bounded queue, and the probe's events);
`mobile/test/exam_taking_page_test.dart` covers what the student sees (the banner,
the answer kept and later synced, the resumed draft) and the fullscreen countdown.

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
    -d "$env:TEMP\kiosk-out" mobile\android\app\src\main\kotlin\com\stackbuildco\proctorguard\MainActivity.kt
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

1. takes the auth user id and reads **`public.profiles`** for it
   (`ProfileRepositoryImpl` → `select().eq('id', userId).maybeSingle()`, allowed by
   the `profiles_select_own_or_staff` policy, whose `id = auth.uid()` half covers
   your own row even as a student);
2. shows "Loading your profile…" with a spinner while that read is in flight —
   **including while a late row is retried.** Signing in can report the session a
   moment before the `handle_new_user` trigger's row is visible to a read, so
   `getProfile` looks again on an increasing delay (0.25s, 0.7s, 1.5s: about 2.5s
   at the outside) and the future simply stays **pending** for the whole window.
   Nothing is reported in the meantime, so a fresh account never sees "We could
   not load your profile" for a row that is about to arrive — after 1.5s the
   loading screen only adds a "Still trying…" hint so it does not look frozen.
   Only a row that is *still* absent after the window, a refused read, or an
   unrecognised role becomes the retryable error below — and a row that is still
   absent is first given back (see "A missing profile row is given back");
3. routes on the four values of the `public.user_role` enum:
   * `student` → `StudentExamPortalPage`
   * `lecturer` → `LecturerConsolePage` — the authoring and marking console for
     the papers that account owns; the proctoring console (monitor + analytics)
     is one tap away in its app bar
   * `supervisor` → `SupervisorExamPickerPage`
   * `admin` → `AdminDashboardPage`

### A missing profile row is given back

`ProfileRepositoryImpl.getProfile` does not stop at reporting the absence. Once
every read in the window has found nothing it performs the one insert
`profiles_insert_self_student` authorises — **its own** id (`id = auth.uid()`) with
`role = 'student'`, and the name from the session's `user_metadata` (or the address
when there is none) — and then reads the row back. An account created outside the
app's own provisioning (by hand in the Supabase dashboard, or a seed whose
`profiles` rows carry different ids) signs in perfectly well and then had nothing
for that read to find, which is the "We could not load your profile — this account
has no profile row yet" screen students were stuck on at *every* sign-in.

The repair is deliberately the narrowest one that works:

* it only runs once every read has failed, never alongside one;
* it only runs when the session can name the account — with no session there is
  nothing to write *about*, and the caller gets the same retryable message as
  before;
* it can never mint a staff login: the policy's `with check (role = 'student')`
  refuses any other role, and the client sends nothing else;
* it is best-effort — a refusal, a duplicate key or a dropped connection is logged
  and left to the re-read, because a repair failing must still end on the honest
  "ask your administrator" screen rather than a new crash.

Every supported way of creating a staff account (`admin-create-user`, `seed.sql`,
the SQL editor) writes the `profiles` row together with the account, so a staff
login never reaches this path. An account hand-created in the Auth dashboard that
*should* have been staff lands here as a student — the one case an administrator
then fixes by setting the role, which `profiles_admin_all` allows.

`userProfileProvider` is also `autoDispose`: signing out drops the family entry, so
the next sign-in reads `profiles` again instead of being handed the previous answer
— including the previous *error*, which used to make a transient failure look
permanent until somebody pressed Try again.

### Coming back to the app re-reads the shared lists

`main.dart` wraps the router in `RefreshOnResume`
(`lib/core/widgets/refresh_on_resume.dart`). The shared lists — published exams,
the admin roster, the lecturer's own papers and the analytics report — are plain
`FutureProvider`s that keep their first answer, which is what makes a second visit
instant and also why a change made elsewhere (a paper published from a laptop, an
account an administrator created) stayed invisible until the refresh button was
found. A resume is the moment the user is entitled to expect "now", so that is when
those answers are dropped. It is deliberately the *only* lifecycle event that does
it: the permission dialog, the camera prompt and the notification shade all pass
through `inactive`, and re-reading four lists for each of those would be noise. The
same reasoning is why the list providers are `autoDispose` (reopening a screen
reads again) and why the student portal and the supervisor picker invalidate the
exam list themselves when they come back from a session or a monitor.
`mobile/test/refresh_on_resume_test.dart` drives the real `flutter/lifecycle`
messages through the binding, so the rule is pinned without a device.

Lecturers and supervisors share `is_staff()` in the database, which is what lets
both read every attempt on the monitor roster
(`submissions_select_own_or_supervisor`), but what was recorded *inside* a sitting
is scoped more tightly: the incident feed (`proctoring_logs`) and the reset audit
(`session_reset_logs`) are readable for every paper by the intervention tier
(`is_exam_supervisor()`) and — for the paperwork a lecturer is accountable for —
by the author of the paper the log belongs to (`owns_exam()` →
`exams.created_by = auth.uid()`). Those stay *evidence* reads: a student still
reads the incidents recorded on their own attempt, and the reset audit has no
student tier at all, because a reset row names the member of staff who ran it. The
two roles do different work:
a lecturer owns the papers they wrote — only the author may edit a question or
award the marks on an essay, and `grade_submission()` re-checks that — while a
supervisor runs the sitting and is the tier `is_exam_supervisor()` names for
resetting an attempt. Lecturers therefore land on the authoring console and reach
the monitor through it, rather than sharing one screen that only fits one of the
two jobs.

A failed lookup (offline, no row, unrecognised role) renders a retryable error
with a **Sign out** escape hatch instead of guessing a role — an unknown
`profiles.role` throws in `UserRole.fromDb` rather than defaulting to `student`.
`profileRepositoryProvider` is bound in `main()` next to the exam/proctoring
repositories, and `userProfileProvider` is keyed by the auth user id, so signing
in as a different account resolves a different profile.

### Admin dashboard

`AdminDashboardPage`
(`lib/features/admin/presentation/pages/admin_dashboard_page.dart`) is what
`RoleGate` renders for `admin` and nobody else: the account roster (every
`profiles` row with its role) plus a create-account form, backed by
`AdminUserRepository` → `AdminUserRepositoryImpl`:

| Action | What happens |
| --- | --- |
| List | `select().from('profiles')` ordered oldest-first (`created_at.asc.nullslast`), so a freshly created account appears at the end |
| Change a role | `update({role}).eq('id', …)` with `.select('*')`; a row count of zero is treated as a failure, not a silent success. Your own row is not editable — it renders a plain `role (you)` chip |
| Create an account | POSTs email, full name, a temporary password and a role to `/functions/v1/admin-create-user`, which answers `200` with the created row (`full_name`, also accepted as `fullName`) |
| Reset a password | POSTs the account id and the new password to `/functions/v1/admin-reset-password` — `admin` only, and the one action allowed on your own row — then shows the password once |

Every failure surfaces as one `AdminAccountException` whose message is already a
sentence: PostgREST `42501` (a policy, or the `profiles_guard_role_change` trigger
refusing "profiles.role is immutable for non-admins") becomes "Only an
administrator may change accounts.", and the function's own status codes are
mapped too — no connection, 401/403, and a 404 that names
`supabase/functions/admin-create-user` when the function is not deployed.

The roster also supports permanent account deletion through
`admin-delete-user`. A confirmation explains that the sign-in and related exams,
attempts, and incidents are removed. The signed-in administrator cannot delete
their own account, and the function independently enforces that rule.

Passwords are reset through **`admin-reset-password`**. It is the one account
action an administrator may also point at their **own** row: a password change
cannot lock anybody out of a screen, and with no "forgot password" mail flow in
this deployment, minting a temporary password and handing it over is how a
locked-out person gets back in. The dialog takes it twice
(`admin-new-password` / `admin-confirm-password`) — a typo in a field nobody can
read back would otherwise become somebody's permanent password — and both fields
are held to `adminMinPasswordLength`, the `MIN_PASSWORD_LENGTH = 6` floor the
function enforces, so a password the server would refuse never leaves the dialog.
On success the password is shown **once**, in a `SelectableText` the
administrator has to dismiss: a temporary password nobody wrote down is not a
reset. The roster itself does not change (a password is not a column), so nothing
is refetched, and the row stops showing its spinner *before* that dialog opens —
the work is already done, and a spinner turning behind a modal only hides the
row's own actions.

The role check is the server's, exactly as in `admin-create-user`: the JWT
establishes *who* is asking, the caller's own `profiles.role` is read back
through a client carrying the caller's token (so RLS filters it) and only then is
the `service_role` key used. `admin` is the only role in `RESETTER_ROLES` —
resetting an *attempt* is a proctoring action (`is_attempt_resetter()`), resetting
a *password* is an identity action, and the schema keeps those in different
hands — so a supervisor who calls it gets 403 and no write. A `404` from Auth is
reported as "That account no longer exists — reload the list and try again."
rather than as a refusal, because a stale roster row and a refused write are two
different answers. Changing a password writes no `session_reset_logs` row: that
table records the resets that destroy proctoring evidence, and Supabase Auth
keeps its own record against `auth.users`.

Creating a login needs the Edge Function because `profiles_insert_self_student`
only lets a client insert its *own* row with `role = 'student'`; the function
re-reads the caller's JWT against `profiles` with the anon key, refuses anyone
who is not an admin, and only then uses the `service_role` key to create the auth
user (which is why it must be deployed with `supabase functions deploy
admin-create-user` and why the key never reaches the app).

### Supervisor console and staff analytics

`SupervisorExamPickerPage` lists published exams and opens
`SupervisorDashboardPage`, whose roster and incident feed are Supabase Realtime
streams. Whether the roster offers the reset control is decided in one place,
`UserRole.canResetAttempts` — `admin`, `supervisor` **and** `lecturer`, which is
`is_attempt_resetter()`'s own list in `supabase/schema.sql` read back out of the
file by `schema_contract_test.dart`, so the role gate, the admin dashboard, the
lecturer console and the live monitor cannot disagree about it. Lecturers reach
this same console from their own home (the app bar's Monitor action) and can watch
a sitting; what the lecturer's monitor shows *less* of is evidence — its incident
feed comes back scoped to the papers they wrote (`owns_exam()`), where a
supervisor's reads every paper's. `AdminDashboardPage` mounts its picker with the
flag set, because only an admin can reach that screen.

A reset deletes the attempt with its cascaded incident rows, purges the snapshot
objects those rows pointed at through the Storage API, and then records what it
did in **`public.session_reset_logs`** (`schema.sql` §7): the attempt, student
and exam ids, the incident and snapshot counts, and the actor. `actor_id` defaults
to `auth.uid()` and the insert policy re-checks `actor_id = auth.uid()`, so *who*
cleared an attempt is the database's answer rather than this client's claim, and
there is no UPDATE and no DELETE policy — the trail is append-only for every
client, admin included. `supabase/migrations/session_reset_logs.sql` adds the
table to a project that predates it; without it the reset still succeeds, and the
console says so instead of hiding the gap.

Both halves that can fail *after* the attempt is gone — the Storage purge and the
audit insert — come back on the successful result rather than being thrown: the
attempt no longer exists, so a raised failure would invite a retry against
nothing, and a plain success would hide the gap. The console appends them to the
confirmation ("Attempt reset, but …"), each naming the half that did not finish,
and a failed purge counts zero snapshots removed, so the number never claims
cleanup that did not happen.

`AnalyticsPage` is available from the staff and admin homes and the live monitor.
It reports attempts, completions, disqualification rate, mean scored result, and
per-exam status totals. Incident counts are bounded to the last 30 days and the
repository pages through the full result sets so PostgREST row limits do not
silently truncate the report. Read failures are surfaced with a retry action.

Every console screen (the supervisor/lecturer home, the live monitor, analytics,
the admin dashboard) carries the same **Home** control, `core/widgets/home_button.dart`.
It pops to the *first* route of the stack, which is the landing page the role gate
mounted, so one button works from any depth without a screen having to know which
console it was opened from — three levels down (home → monitor → analytics) the
alternative is a browser, where the platform back gesture does not exist. On the
landing page itself there is nothing above it and the button keeps its place.

### Lecturer console (question authoring and marking)

`LecturerConsolePage` (`lib/features/authoring/presentation/pages/`) is what
`RoleGate` renders for `lecturer`: the papers **this account owns**
(`created_by = auth.uid()` — `exams_select` would otherwise list every paper in
the institution, and only the author may change one), each with its question and
attempt counts, and the four things a lecturer does with a paper.

| Screen | What it does |
| --- | --- |
| `LecturerConsolePage` | Lists the account's papers, creates one (a **draft** by default — a paper with no questions cannot be sat, so publishing one is refused with the fix named), publishes/unpublishes, deletes (naming the cascade), and opens either screen below |
| `QuestionAuthoringPage` + `QuestionEditorDialog` | Adds, edits and deletes questions of all four shapes, with the answer key read back in words — the one client surface that holds a key |
| `AttemptGradingPage` | Every handed-in attempt, newest first, with the ones still waiting for marks flagged ("1 to mark"), and the running total the server holds |
| `AttemptReviewPage` | One attempt: each question with the student's stored answer, the automatic verdict (right / wrong / not answered) beside the key it was compared against, and marks + feedback boxes for the essays |

**Optional scheduling.** `exams.starts_at` and `exams.ends_at` are both nullable,
and "New paper" leaves them blank by default: an unscheduled paper is offered the
moment it is published, which is how every paper behaved before scheduling existed
— and every paper authored before the columns did. Setting either bound narrows
that window:

* the dialog picks a date and a time per bound (`showDatePicker` →
  `showTimePicker`, `new-exam-starts-at` / `new-exam-ends-at`), with a clear
  control on each so an accidental window is undone without leaving the dialog;
* the pickers work in the author's own zone and `createExam()` sends **UTC**
  (`timestamptz`), because the columns store instants;
* an unset bound is **omitted** from the insert rather than sent as null, so the
  request says out loud which kind of paper it is and the column keeps its NULL
  default;
* a window that does not end *after* it opens is refused in the dialog
  (`new-exam-window-error`) as well as by the database's `exams_window_ordered`
  check — the constraint is the backstop, not the first line;
* the tile prints the window (`Exam.scheduleLabel`) and the half-open cases are
  meaningful: "opens Monday" with no close, or a hard close with no opening time.

`supabase/migrations/optional_exam_scheduling.sql` is the upgrade path for a
project created before the columns, and carries the three server rules the window
widens — see "Student Exam Portal" below and the migration's own header.

**The four shapes.** `questions.question_type` holds `multiple_choice`,
`true_false`, `fill_in_the_blank` or `subjective`; the editor swaps its answer
fields with the type, and the paper's list labels each row with how it is marked:

| Type | Answer key | Marked by |
| --- | --- | --- |
| Multiple choice | `correct_option`, the 0-based index into `options` | `submit_exam()` |
| True / false | `correct_text_answer` is the word `true` / `false` | `submit_exam()` |
| Fill in the blank | `correct_text_answer`, trimmed and case-insensitive | `submit_exam()` |
| Essay (`subjective`) | *none* — the absence of a key **is** the shape | a person, through `grade_submission()` |

`QuestionDraft.problem` mirrors `questions_answer_key_shape` and the new
`points >= 0` floor, so the editor refuses locally what the database would refuse
with a bare `23514` — and `toRow()` writes the key for the type in front of it and
clears the others, so editing a row into another shape cannot leave a stale key
behind. The database keeps its own copy of every rule.

**Marking an essay.** `question_grades` (`schema.sql` §8) holds one row per
hand-marked answer — `submission_id`, `question_id`, `awarded`, `feedback`,
`graded_by` — with `unique (submission_id, question_id)`, so a re-mark is an
update of the same row rather than a second award. It is deliberately *not* a key
inside `exam_submissions.answers`: `guard_submission_immutability` freezes those
answers the moment an attempt closes, which is exactly what makes a re-mark read
the words the student actually submitted. Staff may read the table and **nobody
may write it directly** — no insert, update or delete policy, the shape
`proctoring_logs` uses for violations — because `grade_submission()` is the single
write path. It checks the caller owns the paper (or is an administrator), refuses
an attempt that is still in progress or was disqualified, refuses a question that
is not `subjective`, refuses marks outside `0 … points`, upserts, and recomputes

```
exam_submissions.score = auto_graded_score(submission) + Σ question_grades.awarded
```

**Why `auto_graded_score()` exists.** The automatic part of a score used to be an
inline sum inside `submit_exam()`. It now lives in one function that both the
close and every re-mark call, so "which answers count" cannot drift between them —
and it is where true/false grading was added, since the word comparison
fill-in-the-blank already used is exactly what a true/false key needs.

**What the marking screen reports.** "Waiting for marks" is derived from the rows,
not from `status`: an attempt whose paper contains an essay is only *partly*
graded when it is handed in, so the queue is exactly "which essays have no
`question_grades` row yet". The running total shown is the server's own `score`,
and the sentence after a save (`GradingOutcome.summary`) is built from the RPC's
returned row — nothing on the screen is the client's arithmetic. An empty marks
box means *not marked* rather than zero, so a first pass can save the essays that
have been read without awarding nothing for the ones that have not.

**Invigilation is not duplicated.** The console's app bar opens the *same*
supervisor console (`SupervisorExamPickerPage` → the live monitor) rather than a
second monitor screen, and its reset control is asked of the role
(`UserRole.lecturer.canResetAttempts`) so this screen and the role gate cannot
disagree — `is_attempt_resetter()` does name `lecturer`, because the paper's author
is the one who repairs a wrong answer key. A lecturer can watch a sitting and read
every attempt (`is_staff()` on the roster), but what was *recorded* in a sitting
stays scoped to the papers they wrote (`owns_exam()`) — see "Role routing
(post-login)" — where the supervisor tier reads every paper's.

**Seeded to try it on.** `seed.sql` gives the lecturer a published paper of their
own (`GES301: Software Engineering Midterm`) with one question of each shape, and
one handed-in attempt by Chidi whose essay is deliberately **unmarked** — so the
console's list, the editor's four answer fields and the "1 to mark" queue all have
something real in them on a fresh project.

### Student Exam Portal

`StudentExamPortalPage` lists every published exam (CS101, MAT201 and the
lecturer's GES301 in `seed.sql`) through `PublishedExamList`, and on tap:

* runs the **mandatory device check first** (`ExamHardwareGatePage`): a real
  camera *and* a real microphone have to be opened and verified before anything
  else happens, and "Start Exam" stays disabled until both are. Backing out — or
  a failure — returns to the list untouched: **no submission row is created**, so
  a student whose device cannot be proctored never leaves an `ongoing` attempt
  behind;
* then calls `startOrResumeSubmission(examId)` — the schema's
  `unique(student_id, exam_id)` means a second tap resumes rather than duplicates;
* an `ongoing` attempt pushes `ExamTakingPage(examId, submissionId, durationMinutes,
  startedAt)`: the session screen with the camera (or the `MOCK_CAMERA` feed),
  question navigation, the countdown, the 3-strike overlay, Android kiosk pinning
  and the browser guards;
* an attempt that is already `submitted` **or `disqualified`** is reported in a
  SnackBar and *not* reopened — exactly what Aisha hits on CS101 in the seed data,
  where the server disqualified her after three strikes;
* a failed start shows "Could not start …" instead of a silent no-op.

**The window, when the paper has one.** A tile prints its window
(`5 Jan 2026, 09:00 – 17:00`), and a paper that has not opened yet — or has already
closed — is **inert**: `PublishedExamList(lockWhenNotOpen: true)`, which is the
*portal's* setting. The supervisor's picker deliberately leaves it off, because
opening the monitor on a sitting that has closed is exactly what it is for. A
locked tile swaps its chevron for the bound and says why ("It opens …" / "It
closed …") instead of offering a tap the server would refuse, and `_openExam`
re-checks the window before the device check, because the list was rendered from
an earlier `now`. Nothing polls the clock: a student waiting for a paper to open
pulls to refresh (or uses the app bar's refresh button).

What actually enforces it is the database, in three places
(`supabase/migrations/optional_exam_scheduling.sql`):

| Rule | Effect |
| --- | --- |
| `submissions_insert_own_ongoing` | no attempt row before `starts_at` or after `ends_at`, so a patched client gets no session either |
| `attempt_deadline()` | the attempt's own duration **capped by** `ends_at` — a paper that closes at 17:00 does not hand an attempt started at 16:50 a full hour |
| `submit_exam()` | records that same deadline as `submitted_at`, and still grades from the answers that landed before it |

A paper with neither bound is unaffected by all three: `coalesce(ends_at,
'infinity')` is what keeps the pre-scheduling arithmetic identical.

### Pre-exam instructions (the proctor guide and the exam rules)

`ExamInstructionsDialog` (`lib/features/exam/presentation/widgets/`) is opened by
`showExamInstructions(context, exam: …)` from the two places a student stands
**before** a session — the portal's app bar (`portal-instructions`, before a paper
is chosen) and the device-check gate (`gate-instructions`, "How the proctor
works", sitting above "Start Exam"). It is a dialog rather than a page on purpose:
neither screen loses its state (the checklist, the list) while it is read, and
nothing in it is a decision to make. Two tabs:

| Tab | What the student is told |
| --- | --- |
| `instructions-tab-proctor` | the camera (on for the whole sitting, faces checked on-device, a snapshot kept with each incident, and that a person reviews the recording), the microphone (noise above the room's own floor is what counts, the indicator shows the level, and a refused or unplugged mic says so instead of passing as fine), staying in the exam (the kiosk pin on a phone, the browser guards — tab/focus/fullscreen, copy/paste, back/reload), and that three confirmed strikes close the attempt as disqualified — including that a wrong one can be reset by the paper's author or a supervisor |
| `instructions-tab-exam` | the clock (the paper's own duration from the start, a scheduled paper also closing at `ends_at`, answers saved as you go including offline, an unanswered question scoring nothing), when a mark appears (instantly for a paper with no written answers; after the lecturer marks the essays otherwise), one attempt per paper and what a reset clears, what the device check requires (and that a browser flags faces by review, not live), and what to do if something goes wrong |

The wording deliberately matches the screens the student is about to meet — the
audio indicator's "Mic unavailable", the kiosk badge, the portal's result dialog —
so a state hit mid-session is one they have already read about.
`mobile/test/exam_instructions_test.dart` pins both halves of the feature: the copy
inside the tabs, and that **both** pre-exam screens actually reach the dialog (the
portal with no paper chosen, the gate with its checklist still passed when the
dialog closes).

### The exam session screen

`ExamTakingPage` owns one attempt end to end, and every way it can fail ends
somewhere the student can leave from — the chrome deliberately has no back button
mid-exam, so a silent failure would strand them:

| Situation | What the student sees |
| --- | --- |
| Camera/mic permission refused (Android/iOS) | "This exam needs camera and microphone access…" + **Try again** / **Leave** (the gate normally catches this before the session opens) |
| No camera, or the camera refuses to start | the same blocking screen with the plugin's error code |
| Question feed unreachable | "Could not load the questions for this exam." + **Try again** / **Leave** |
| Exam has no questions yet | "No questions yet" + **Leave** (the attempt stays `ongoing`, so it can be resumed after a supervisor adds them) |
| Clock ran out | auto-submit; if the server cannot be reached, a "Time is up" screen with **Send again** / **Leave** |

There is no silent stand-in for a camera that is not working. The self-view shows
a live preview, the loud **MOCK CAMERA** tile *only* in an explicit `MOCK_CAMERA`
build, or a red **CAMERA OFFLINE** tile underneath the blocking error — the
neutral crossed-out placeholder that made an unproctored session look normal is
gone, and `_cameraFailure`/`_imageFormatGroup` live in
`core/services/hardware_verification_service.dart` so the gate and the session
screen word a refused camera identically.

Details worth knowing:

* **Every question is numbered explicitly** — "Question 3 of 5" in the app bar
  (both shapes), and the app bar also shows how many answers the *server* has
  stored ("3 of 5 answered").
* **Four question shapes**, and the input follows the shape. `multiple_choice`
  renders tap targets and saves the option index through
  `merge_submission_answer`; `true_false` renders two tap targets (True / False)
  and saves the **word** through `merge_submission_text_answer`, because that is
  what a true/false row's key is compared against; `fill_in_the_blank` and
  `subjective` (an essay) render a text field and save through
  `merge_submission_text_answer`, graded server-side case-insensitively after
  trimming for the first of those two (so `"  http "` scores for `"HTTP"`) and
  marked by the lecturer afterwards for the second. A typed answer is written by
  "Save & next", the keyboard's done action, or the submit flush below — the field
  shows "Answer saved" once it is stored, and an essay says plainly that nothing
  is scored as the student types (`ExamEssayField`).
* **One question per screen, with the whole paper one tap away.** The session is
  paginated rather than one long scroll: the app bar shows "Question X of Y", the
  action bar carries **Previous** and **Next** side by side (multiple choice and
  true/false, which both record on tap) or **Save & next** (a typed answer, which
  has no auto-advance to trigger on), and **Submit exam** replaces Next on the last
  question. Previous is always on screen — inert on question 1 rather than absent,
  because a control that only appears on question 2 is a control nobody knows
  exists. Above the question sits the review grid (`ExamQuestionPalette`, in
  `widgets/exam_session_widgets.dart`): one tappable tile per question, **answered**
  tiles filled and check-marked, **unattempted** ones neutral, the current one
  ringed, and a "N answered • M not answered" counter. Tapping a tile jumps to that
  question through the same `goTo()` the buttons use. Moving between questions
  flushes an unsaved typed answer first, so navigating never drops one.
* **`exams.duration_minutes` is enforced.** The countdown is anchored on
  `exam_submissions.started_at` (not on "now"), so a resumed attempt keeps its
  remaining time and one that is already past its deadline is submitted on the
  first tick. The chip in the app bar turns amber under 5 minutes and red under 1.
* **Camera loss pauses proctoring and prompts the student.** The page listens to
  the `CameraController`; if the feed reports an error mid-session it calls
  `ProctoringNotifier.setCameraActive(false)`, which drops further `GazeSignal`s,
  clears the engine's frame counters and shows a "restore the camera" prompt - an
  offline feed no longer accumulates `no_face`/`looking_away` strikes. Frames
  that arrive before the stream is live are ignored too
  (`MediaPipeProctoringService.setStreamActive`), so initialising a camera is
  never read as "no face".
* **The camera is video-only; the microphone belongs to audio proctoring.**
  `CameraController` is created with `enableAudio: false`. The camera plugin's own
  audio capture is not used for anything — nothing here records sound — and asking
  it for the microphone puts two clients on one input device, which is how the
  independent `record` session behind `AudioMonitor` ends up unable to open and
  audio proctoring sits in "Mic unavailable" for the whole attempt. The session
  opens the microphone itself ([below](#microphone-proctoring-levels-not-recordings))
  and reports a refusal with **Open settings** when the OS will not prompt again.
* **Speaking is proctored from the microphone's own level, and the chip always says
  what the room sounds like.** A second, independent capture session
  (`AudioMonitor`, `record`'s `getAmplitude()`) streams dBFS samples into
  `AudioNoiseDetector`, which measures the room's own noise floor first and then
  treats *sustained* speech above it as `audio_noise`. No audio is ever written to a
  file. A lost or refused microphone is **not** a strike — it is an unproctored gap —
  so the page prompts **Reconnect** (**Open settings** when the OS will not ask
  again) rather than letting proctoring go quietly dark. The state machine and the
  rules are in [Microphone proctoring](#microphone-proctoring-levels-not-recordings).
* **Web: access is requested *before* the camera is enumerated.** `camera_web`
  drops every device whose `deviceId` is empty, which is exactly what a browser
  reports *before* the camera grant — so `availableCameras()` legitimately
  returns an empty list on a page that has never been granted access, and a
  session used to conclude "no camera" and show the crossed-out placeholder.
  `WebCameraPermission.probe` now runs one `getUserMedia` (releasing the probe
  tracks immediately) and reports *which* devices came back, and the enumeration
  is retried, so the browser's own prompt appears instead. The **gate** answers
  from that same probe rather than opening a capture session of its own: opening
  one is what Chromium reports as `NotReadableError` — "another app or tab is
  already using the camera" — while it is still releasing the device
  `availableCameras()` just probed, and it bought nothing the probe had not
  already proved (on the web there is no ML Kit to feed, and the session the exam
  screen opens is the one that records). Fewer opens also means the checklist's
  microphone row is reported from the same grant as the camera row instead of
  being inferred from a session that may never have started.
* **Raw camera frames only exist where the platform offers them.** The exam
  screen asks `CameraPlatform.instance.supportsImageStreaming()` before calling
  `startImageStream`: `camera_android_camerax` and `camera_avfoundation` answer
  true, `camera_web` answers false — and calling it anyway threw
  `UnimplementedError`, which is the "Proctoring could not start on this device"
  screen a browser student used to get on a perfectly working camera. The preview
  and the still-frame evidence are unaffected; what the web cannot do is pick a
  face out of the feed, which the gate says out loud before the paper starts. A
  camera the browser reports as **still in use** is re-opened once, after
  `webCameraOpenRetryDelay`, because that one is a timing failure rather than a
  broken device (`isDeviceBusyCameraCode` names the codes it covers).
* **Answers are painted locally and saved through the RPCs.** The tap is durable
  on the device first (`OfflineSyncService`), so the round-trip to Supabase is off
  the critical path and a dropped connection no longer costs the answer — the
  banner reports the sync instead of an error and the session carries on. Grading
  still reads the *server* copy, which is why the submit path below refuses to
  close an attempt whose queue has not drained.
* **Submitting goes through `submit_exam`** (see `../supabase/schema.sql`): the
  server grades both shapes and closes the attempt, and `score` is never written
  by the client. There is no student `UPDATE` policy on `exam_submissions` at
  all. Submitting flushes an unsaved fill-in-the-blank answer first and then
  requires the queue to be empty: if the answers cannot reach the server, the
  attempt stays `ongoing` behind a "Waiting for a connection" screen rather than
  closing with half of them missing.
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

`mobile/test/role_routing_test.dart` covers the routing with injected
repositories: role parsing, one group per role (`student` portal, `lecturer` and
`supervisor` console, `admin` dashboard), the loading state, the retry after a
failure, the disqualified guard, and the exam/submission ids handed to the session
screen. Its admin group also pins the parts of account management a widget test
can see: the self row is not re-roleable, another row re-roles through the
repository, and a refused roster renders the repository's prose with a retry —
pumped on a 1400x1200 surface (`useDesktopSurface`) so the side-by-side layout is
the one under test.
`mobile/test/exam_taking_page_test.dart` covers the blocking state and its
retry/leave actions.

## Supported platforms (and what proctoring each one gets)

Only the runner folders that actually exist under `mobile/` are targets:
`android/`, `ios/` and `web/`. The app compiles for all three, and **Android is
the shipped one** — `build_apk.ps1` and `.github/workflows/sync_release.yml`
publish the signed, split-per-ABI APKs students install.

| Host | Builds | Face signals | Mic level | Screen lockdown |
| --- | --- | --- | --- | --- |
| Android (phone) | `flutter build apk` | ML Kit, on-device | `record` | Lock task / screen pinning + immersive chrome |
| iOS | `flutter build ios` — needs the Podfile work in `ios/README.md` first | ML Kit, on-device | `record` | Best-effort only (`startLock` reports `granted: false`) |
| Web (Chrome/Edge) | `flutter build web` | **none** — no ML Kit for browsers | `record` behind `getUserMedia` | HTML5 fullscreen + tab/blur guards |
| macOS / Windows / Linux | — | — | — | — |

**There is no `macos/`, `windows/` or `linux/` runner here, and that is a scope
decision rather than an unfinished port.** A desktop machine takes part as a
**browser host** — the `web` target above, sized for a wide window by
`ResponsiveLayout` — which is why the "no on-device AI on the web" boundary in
the root README applies to it. A native desktop build would ship a proctoring
client that (on macOS in particular) cannot enter the lockdown the exam surface
rests on and cannot reach ML Kit without another plugin, so it would *add* a
supported platform whose proctoring is weaker than the browser's. Adding one is
a new target with its own privacy and security review, not a `flutter create`
away.

## Responsive layout (Android phone + desktop browser)

The same screens run on a 320 dp phone and on a 1440 px Chrome/Edge window, so
the layouts are driven by the **available width** (`LayoutBuilder` +
`MediaQuery.sizeOf`) rather than by the platform. `core/widgets/responsive_layout.dart`
holds the shared pieces:

* `Breakpoints` / `ResponsiveSizing` — 600 dp and 900 dp breakpoints, and gutters
  that grow from 16 dp (phone) to 24/32 dp (tablet/desktop), so a phone layout is
  never stretched across a monitor.
* `ResponsiveContent` — centres and width-clamps a pane (the exam list and the
  greeting are capped at 720 dp instead of spanning the whole window).
* `ResponsiveScrollView` — fills the viewport, centres its content while it fits
  and scrolls the moment it does not (landscape phone, on-screen keyboard, large
  text scale). The sign-in form and every blocking screen use it.

Per screen:

* **Sign In** — the old `Center > SingleChildScrollView > ConstrainedBox(420)`
  became `ResponsiveScrollView(maxWidth: 440)`; the brand mark scales with the
  viewport and the fields, not the container, set the height.
* **Exam Portal** — greeting and tiles share one centred 720 dp column.
* **Exam session** — `LayoutBuilder` decides between one column (phone: the
  self-view is a compact 128x96 strip above the question) and two (>= 900 dp: a
  300x220 preview pane beside it). The question/option list scrolls inside
  `Expanded`, the action bar is pinned below it (so "Submit exam" can no longer be
  pushed off-screen by a long option list), and the app bar carries only the
  countdown — the answered count and kiosk badge moved into a `Wrap` in the
  question header, which is what used to overflow a 360 dp app bar. The preview
  uses `BoxFit.cover`, so it fills its box whatever aspect ratio the platform
  reports instead of distorting.
* **Admin dashboard** — driven by `ResponsiveSizing.isExpanded(context)` (>= 900
  dp): below it the header stays pinned and the create form and the roster scroll
  together in one `ListView` (form first — provisioning is the primary action); at
  or above it a `Row` puts the form in a `SingleChildScrollView` on the left and
  the roster in one on the right, so a wide window shows the roster beside the
  form instead of pushing it below the fold. Both halves scroll independently, so
  a long roster on a short laptop window is still reachable.

`mobile/test/hardware_gate_test.dart` and the two viewport tests in
`mobile/test/exam_taking_page_test.dart` pump these screens at 320x568, 360x640
and 1440x900 and fail on any `RenderFlex` overflow. The admin dashboard's
side-by-side branch gets the same treatment at 1400x1200 from
`mobile/test/role_routing_test.dart`.

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
| ML Kit face detection | no face / several faces / head pose off-axis, each held for three consecutive frames before it counts | `no_face`, `multiple_faces`, `looking_away` |
| `ExamLifecycleObserver` | `paused` / `inactive` / `hidden` (app switch, notification shade, incoming call) | `app_minimized` |
| `KioskService.escapes` | lock task state polls inactive twice while the exam runs (the student escaped screen pinning) | `app_minimized` |
| `WebGuards` (Chrome/Edge) | tab hidden, window blurred, or HTML5 fullscreen left | `app_minimized` |
| `AudioMonitor` + `AudioNoiseDetector` | a `record` capture session streams dBFS samples; the room's own floor is measured first, then speech sustained above it ([details below](#microphone-proctoring-levels-not-recordings)) | `audio_noise` |

Camera signals are **counted in frames**, not measured in seconds: `looking_away`
fires only after three *consecutive* frames show the head past ~28 deg yaw / ~30 deg
pitch, and `no_face` after three consecutive frames with no face in them
(`consecutiveFrameThreshold`). Frames are the honest unit here — `inferenceInterval`
decides how much wall time a frame stands for and is throttling, not evidence — and
at the ~7 FPS the engine throttles to, three frames is about 0.45 s: long enough that
a blink, one dropped frame or one glance at the keyboard cannot burn a strike, short
enough that a student who has really left the frame or turned to a second screen is
reported while they are still doing it. Any frame back in the tolerated pose resets
that count, so only an unbroken run counts, and each episode reports once.
`multiple_faces` is the exception: two people in frame needs no measuring, so it
reports immediately and is latched per episode instead.
`ProctoringNotifier.setCameraActive` gates the whole camera set while the feed is not
streaming.

Audio is judged the same way, and the rules are deliberately pure Dart
(`core/services/audio_noise_detector.dart`) so they can be tested without a
microphone: the first 4s (`calibrationWindow`) measure the room's floor, taking the
**median** rather than the mean so a student who starts talking immediately cannot
drag the floor up to their own voice; the threshold becomes that floor + 6 dB
(`speechMarginDb`), clamped to −55…−32 dBFS (`minThresholdDb`/`maxThresholdDb`). The
margin is deliberately small — 6 dB is a clear, *sustained* doubling of acoustic power
— and the band is deliberately low, so the rule flags **little and background sound**
(quiet speech, a second voice, a television, traffic, a generator) rather than only a
raised voice. The upper clamp does the heavy lifting in a noisy room: without it a room
that is already loud on its own would raise the bar to "shout only" and log nothing,
whereas pinned below the room's own floor that steady background *is* the finding. The
lower clamp keeps a dead-silent room's threshold above the microphone's own self-noise,
which would otherwise read as "talking". The level must then add up to 2s above it
(`sustain`) — roughly one spoken sentence — and a gap below the threshold ends the
episode only once it has lasted longer than 400 ms (`releaseGrace`). That gap allowance
is what makes the rule catch **talking** rather than only an unbroken shout: at four
samples a second a real sentence drops below the threshold between words, so a rule
that reset on any single low sample never filled its window and logged nothing at all.
A cough, a chair creak or a breath is still far too brief to add up, a room that has
genuinely gone quiet ends the episode inside the grace, and after a strike the detector
ignores the level for 5s (`cooldown`), so one long outburst is one strike rather than
one every sample. Calibration doubles as the start-of-session grace period: nothing can
be logged before it finishes.

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
`mobile/test/proctoring_notifier_test.dart` covers the strike escalation. The audio
half adds `mobile/test/audio_monitoring_test.dart` (the detector's rules and the
monitor's state machine) and the `audio proctoring` group in
`mobile/test/exam_taking_page_test.dart` (the chip, driven through a fake microphone).

## Microphone proctoring (levels, not recordings)

`AudioMonitor` (`core/services/audio_monitor.dart`) opens its own capture session
through `record`, alongside the camera's audio track, and feeds `getAmplitude()`
samples — four a second (`sampleInterval`) — to `AudioNoiseDetector`. That session
**streams PCM and writes no file**: the bytes are drained and thrown away (never
analysed, never stored), so all that leaves the microphone is a stream of decibel
numbers. Nothing about the room is recorded, buffered to disk or uploaded.

The monitor is a small state machine rather than a bag of futures, because every way
a microphone can fail has to land somewhere the student can act:

| Situation | State | Chrome shows | Recovery |
| --- | --- | --- | --- |
| Streaming levels | `monitoring` | `Mic live` + live meter | — |
| Asking for access / waiting for the first sample | `starting` | `Mic starting` | — |
| Student or OS refuses access | `permissionDenied` | `Mic blocked` | **Open settings** — the OS will not prompt twice |
| No capture path on this platform | `unavailable` | `Mic unavailable` | retry, or carry on |
| Device cannot be opened (busy, no input) | `unavailable` | `Mic unavailable` | retry |
| Bridge never answers (8s `startTimeout`) | `unavailable` | `Mic unavailable` | retry |
| No levels at all for 4s (`levelTimeout`) | `unavailable` | `Mic unavailable` | retry — never pretends to monitor |
| Stream dies mid-session (headset unplugged, grant revoked, another app took the input) | `interrupted` | `Mic lost` | **Reconnect** prompt |
| `--dart-define=AUDIO_MONITORING=false` | `disabled` | `Audio off` | — |

Two of those rows are the point of the feature. A device that cannot be opened, or
that never reports a single level, is reported as `unavailable` instead of looking
exactly like an empty room — **not listening must never be mistaken for quiet**. And
losing the microphone is *not* a strike: it is an unproctored gap, so it surfaces as a
prompt with an action, and the session's violation count only ever counts sustained
speech. A refused or unavailable microphone never blocks the exam either; it is
visible and recoverable, never fatal.

Every wait in the monitor is time-boxed, the release included. `record` sends all of its
platform calls through a single permit, so a call the device never answered — the
microphone pulled out mid-session — would queue the next one behind it *forever*, and the
reconnect is precisely the action that has to keep working. A release that does not come
back inside 3s (`endTimeout`) is logged and given up on; the start that follows asks the
device itself and reports what it finds, inside `startTimeout`.

The level itself is validated on the way in rather than trusted. `record` reports
**dBFS**: negative, 0 being full scale, with `-160` as the sentinel for "nothing to
report" on every platform it ships to (Android's `DEFAULT_AMPLITUDE_DB`, iOS's
`minAmplitudeDB`, the web delegates' `kMinAmplitude`) — so a normal exam room sits
around −60…−20 and the meter's −60…0 window is the useful part of the scale rather than
an arbitrary one. Anything non-finite, or outside that band, is dropped or clamped
before it can reach the detector, where one bad sample would shift the calibration
median the whole room is judged against. Two debug lines make the feature auditable
from a console: `AudioMonitor` logs the first level of a session (`levels are flowing`,
with the reading) and `AudioMonitoringNotifier` logs each classification (the level, the
threshold it crossed, the measured floor and the sustain window). Without them, "audio
proctoring never flagged anything" is indistinguishable from "the room was quiet".

`AudioMonitoringNotifier` (`features/proctoring/.../audio_monitoring_provider.dart`)
joins the two halves: the monitor owns the device, the detector owns the rules, and a
confirmed ruling is handed to `ProctoringNotifier.reportAudioNoise()`, so
`audio_noise` takes exactly the same path as `no_face` or `app_minimized` — overlay,
server-side count via `register_violation`, 3-strike escalation and the offline queue
included. The notifier used to carry its own threshold-plus-sustain counter
(`reportAudioLevel` with `audioNoiseThresholdDb`/`audioNoiseSustain`), written before the
detector landed; it was deleted rather than kept as a second path, because two places
deciding what "too loud" means is two places to get it wrong — and the surviving one
measures *this room's* floor instead of a constant that would have to be right for every
device. `reportAudioNoise()` is therefore the notifier's only audio entry point, and
`mobile/test/proctoring_notifier_test.dart` guards against the old method being
reintroduced. `retry()` re-opens
the session *and* resets the detector, because a new microphone (a headset, another
room) is a new noise floor: reusing the old one would either deafen or over-sensitise
the room the student actually moved to.

The seam is `audioLevelSourceProvider`, which is `null` in the app — meaning "the real
`record` source" — and is overridden with a fake in tests. `flutter test` runs on the
Dart VM, where no audio plugin is registered, so injecting a source is the only way to
drive a working microphone, a refused one, or one unplugged mid-session, instead of
asserting on a chip that can only ever say `unavailable`.

## Release builds (signing, shrinking, ABIs)

The release build type is not the debug one with a different name. Signing material is
required, R8 shrinks the app, and the Android platform policy is enforced by the merge —
here is what a deployer has to do and what the build refuses to do:

```powershell
cd mobile\android
keytool -genkey -v -keystore upload-keystore.jks -storetype JKS `
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
Copy-Item key.properties.example key.properties   # then fill in the four values
```

`key.properties` names the keystore and its passwords; `..\build_apk.ps1` (which wraps
`flutter build apk --release --split-per-abi --dart-define=...`) then signs with it.
Without that file the build **fails on purpose**, with the keytool command in the error:
the shared Android debug key is public, so an APK signed with it can be replaced by a
forged "upgrade" that already has camera permission and the kiosk pin. Both
`android/key.properties` and the `.jks` are git-ignored; keep a copy of the keystore
outside this repository, because losing it means losing the ability to update the
published app. `proctorGuard.debugSigning=true` in `android/gradle.properties` is the
written-down opt-out for a throwaway demo build and never for one a student runs.

- **R8 is on** (`isMinifyEnabled`/`isShrinkResources`), with the keeps in
  `android/app/proguard-rules.pro`. The build writes
  `build/app/outputs/mapping/release/mapping.txt` — keep that file per release, it is
  the only way to read a crash report from a student's phone (the rules keep
  `SourceFile`/`LineNumberTable` precisely for that). ML Kit face detection and the
  `record` capture path are the two surfaces a shrinker can break *silently* (every face
  signal degrading to `no_face`), so a release APK gets one on-device pass over face
  detection and the mic on a real phone before it goes to a school.
- **Ship `--split-per-abi`** (the script's default) or an app bundle. A plain
  `--target-platform android-arm64` build still carries the plugins' armeabi-v7a and
  x86_64 `.so` files while holding `libflutter.so`/`libapp.so` for arm64 only, so a
  32-bit phone installs it happily and then crashes on startup — arm64 phones are fine,
  32-bit ones need the split (or `-Single` for one universal APK).
- **`android/gradle.properties` asks the Gradle daemon for `-Xmx8G`** with a 4G
  metaspace (Flutter's template default). On a machine with less free RAM than that the
  daemon never comes up and `flutter build apk --release` sits on
  `Running Gradle task 'assembleRelease'...` indefinitely, with nothing in the log —
  lower those numbers for such a machine, or override per run with
  `-Porg.gradle.jvmargs="-Xmx2g -XX:MaxMetaspaceSize=1g"`. `gradlew --stop` clears
  daemons left behind by earlier builds.
- **The Android surface is asserted by a test.**
  `mobile/test/android_manifest_contract_test.dart` fails if the merged manifest regains
  `SYSTEM_ALERT_WINDOW`, drops `allowBackup="false"`, loses the `networkSecurityConfig`
  reference, or if that config ever permits cleartext outside loopback.
- **iOS has no target.** `mobile/ios/README.md` records that decision and the checklist
  for porting to it; the Dart services degrade to `granted: false` / `unavailable`
  instead of throwing, so nothing in `lib/` has to change first.
- **CI publishes these builds.** `.github/workflows/sync_release.yml` runs the same
  `flutter build apk --release --split-per-abi` on every push to `main` (and every
  `vX.Y.Z` tag) and mirrors the APKs, their SHA-256 checksums and a `latest.json`
  into the public `abbaaminu/proctorguard-release` repository, which is what a
  student downloads from. It rebuilds `android/key.properties` from repository
  secrets instead of committing one, publishes no source and never keeps R8's
  `mapping.txt` in the public repository; the secrets and the reasoning are listed
  at the top of that workflow.

## Key design decisions worth knowing about
- **Server-enforced escalation.** The 3-strike disqualify rule lives in
  the `register_violation` Postgres function, not just in Dart. A student
  patching the client can't spoof past it — the client's `warningCount`
  is reconciled against the RPC's authoritative return value every time.
- **Grading never touches the device.** Neither answer key
  (`questions.correct_option`, `questions.correct_text_answer`) is exposed by the
  `questions_public` view the exam-taking page reads (a definer view filtered to
  published exams), and there is **no** student SELECT policy on the raw
  `questions` table at all — so the answers cannot reach a student device.
  `submit_exam` grades both shapes from the stored answers on the server.
- **Append-only violation log.** `proctoring_logs` has no insert, update or
  delete policy: `register_violation` is the only writer, and it re-checks that
  the caller owns the submission, so RLS makes tampering with evidence
  impossible from a client.
- **The reset trail is append-only too.** Clearing an attempt is the one
  destructive staff action, so the same call that deletes the row writes
  `public.session_reset_logs` (`schema.sql` §7): the attempt, student and exam
  ids, the incident and snapshot counts, and the actor the database derived from
  the caller's JWT — `actor_id` defaults to `auth.uid()` and the insert policy
  re-checks it, so nobody can name somebody else as the actor. There is no
  UPDATE and no DELETE policy, so no client, admin included, can rewrite or
  erase the trail. A project that predates the table keeps resetting; the
  console reports the missing audit row instead of pretending it was written
  (`supabase/migrations/session_reset_logs.sql` is the fix).
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
  dependency surface) small. Re-add them as each feature lands. Audio proctoring is
  the case in point: its hooks already existed
  (`ProctoringNotifier.reportAudioNoise()` and the `audio_noise` action type), and
  when the detector landed it added `record` (^7.1.1) — the one package that exposes
  amplitude on every target this app ships to — rather than `noise_meter`, which is
  still unused. The notifier's own `reportAudioLevel(double)` went the same way once
  the detector existed — see "Microphone proctoring" above.
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
- **`profiles.role` is the security boundary, so only an admin may move it.** The
  four values (`student`, `lecturer`, `supervisor`, `admin`) come from the
  `public.user_role` enum, and `schema.sql` asks about it through the role
  predicates — `is_staff()`, `is_admin()`, `is_exam_supervisor()`,
  `is_attempt_resetter()` — and through ownership: `owns_exam()` scopes the
  incident feed and the reset audit to the papers the reader wrote. RLS cannot
  restrict a *column*, so the
  `profiles_guard_role_change` trigger raises `42501`
  ("profiles.role is immutable for non-admins") when a non-admin edits it —
  `profiles_admin_all` is the matching policy half, which is what the admin
  dashboard relies on. A client can only ever self-provision a `student` row
  (`profiles_insert_self_student`), and staff logins are minted by the
  `admin-create-user` Edge Function, which holds the only `service_role` key in
  the system and re-checks the caller's JWT before using it.
