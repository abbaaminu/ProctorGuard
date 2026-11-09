# ProctorGuard

ProctorGuard is a Flutter exam-proctoring application backed by Supabase. The
mobile/web Flutter app provides student exam sessions, lecturer question
authoring and marking, supervisor monitoring and attempt resets, analytics for
staff, and an admin account-management console.

```
mobile/       Flutter app and staff/admin interfaces
supabase/     Schema, migrations, seed data, and Edge Functions
```

## Staff features

- **Administrators** can list accounts, create logins, change roles, permanently
  delete accounts, and correct the academic labels an account is targeted by —
  one row at a time, or for a whole class from a CSV — from the Admin Dashboard.
  Creation and deletion use the `admin-create-user` and `admin-delete-user` Edge
  Functions; a label correction goes through `admin-update-profile`, because the
  student it is for is refused that write by `guard_profile_labels()`. A blank or
  misspelt `faculty` / `department` / `level` is the usual reason a student never
  sees the paper set for their class, and repairing it is the administrator's job
  rather than theirs.
- **Lecturers** author the papers they own — multiple-choice, true/false,
  fill-in-the-blank and essay questions — publish them when they are ready, and
  mark the essays that come back. Only the paper's owner (or an administrator)
  may change it or award marks on it: `grade_submission()` re-checks that
  server-side, and the marks land in `public.question_grades`. Scheduling is
  **optional**: a new paper has no window and can be sat as soon as it is
  published, while a start and/or end time confines it — enforced on the attempt
  insert and by `attempt_deadline()`, not by the client.
- **Supervisors and lecturers** can choose an exam they are responsible for, monitor
  attempts and incidents in real time, and reset an attempt. A supervisor's picker
  offers the papers an administrator **assigned to them**
  (`supervisor_exam_assignments`, read by `can_supervise_exam()`) and shows that
  paper's evidence; a lecturer's reads the evidence recorded on the papers they
  wrote, on any sitting's roster. Reset removes the submission and cascaded incident
  records so the student can start over; associated snapshots are removed through
  Supabase Storage.
- **Administrators, supervisors, and lecturers** can review analytics and
  submission activity. Server-side row-level security remains authoritative for
  every operation.

Roles are stored in the `public.user_role` enum: `student`, `lecturer`,
`supervisor`, and `admin`. Lecturers own the papers they write: they author its
questions and award the marks on its essays. Supervisors run the sitting. Both
share the sitting's tools — the live monitor and the attempt reset — because
`is_attempt_resetter()` names `admin`, `supervisor` **and** `lecturer`: the paper's
author is the one who has to repair a wrong answer key or a disqualification
aimed at the wrong candidate. The narrower tier that remains is
**Who may intervene in a given paper** is the assignment table, not the tier:
`supervisor_exam_assignments` lists the supervisor each sitting was handed to,
`can_supervise_exam(exam_id)` answers "an administrator, or that supervisor", and
every policy that used to ask the role tier (`is_exam_supervisor()`) now asks that
question with the paper the row belongs to — so a supervisor's console lists their
own sittings, and their reads, resets, review decisions and snapshot access are
confined to them, while an administrator needs no row and still reaches every
paper. The same scope decides whose **names** the console can print: a supervisor
reads the profile of a student who sat, was granted or is aimed at a paper they run
(`can_read_profile()`), where `is_staff()` used to hand them every profile row in the
institution — name, matriculation number, faculty, department, level and photograph —
assigned or not. That tier used to read *every*
paper's evidence — the incident feed and the reset audit. A lecturer reads the
evidence recorded on their **own** papers and nothing else's: those two policies
ask `owns_exam()` (`exams.created_by = auth.uid()`) as well as the scope
predicate, so the roster a lecturer may see is wider than the logs they may read for
it. See [mobile/README.md](./mobile/README.md), "Role routing (post-login)".
Only admins can manage accounts.

An attempt is graded by the same call that closes it. `submit_exam()` computes
the score from the answers it can grade and answers with
`(result_status, final_score)`, so a student sees an **instant result** whenever
the paper has nothing on it that needs a person: a paper of multiple-choice,
true/false and fill-in-the-blank questions is finished before they are back on the
exam list, and the mark is shown then — "You scored 7 of 10", with the total taken
from the paper's own `questions.points`. A paper with an essay on it says so in
the same place instead of showing a number: the written answers are marked
afterwards by the paper's owner through `grade_submission()`, so the score is not
final and is not presented as if it were.

Students meet the same two rules before an attempt exists. A scheduled paper is
listed but inert outside its window ("It opens …" / "It closed …"), and **both**
pre-exam screens — the student portal and the device check — open a two-tab
instructions dialog: **How the proctor works** (the camera and its snapshots, the
microphone's noise floor, the kiosk/browser rules, three strikes and the reset
that can undo one) and **Exam rules** (the clock, when a mark appears, one attempt
per paper, what the device check requires). See
[mobile/README.md](./mobile/README.md), "Pre-exam instructions (the proctor guide
and the exam rules)".

Two things save a student a support call. If the signed-in account has no
`profiles` row at all — one created by hand in the Auth dashboard, or a seed whose
rows carry different ids — the app now writes the account its **own** `student` row
(the only insert `profiles_insert_self_student` authorises) and signs in, instead
of showing "we could not load your profile" at every attempt. And returning to the
app re-reads the shared lists (published exams, the roster, the lecturer's papers,
analytics), so a change made elsewhere appears without hunting for a refresh
button. See [mobile/README.md](./mobile/README.md), "Role routing (post-login)".

## Proctoring boundaries and risk register

ProctorGuard is a **signal, not a proof**. The detectors below establish
presence, loudness and device state; they do not establish identity, intent or
what was said. Every strike is an input to a human supervisor's judgement, so
the boundary of each signal is documented here — and catalogued as a risk —
rather than left to be mistaken for more than it is.

**What the signals are — and are not**

- **Face detection is presence, not biometric identity.**
  `google_mlkit_face_detection` returns a face *count* and head-pose Euler
  angles; the client turns those into `no_face`, `multiple_faces` and
  `looking_away`. It performs **no** face recognition and matches no template, so
  it cannot tell a student apart from a similarly-shaped stand-in, and there is
  no liveness challenge (no blink / turn / read-a-phrase prompt).
- **Audio is loudness, not content.** The microphone is sampled for level
  (dBFS) only; energy above the room's measured floor, held for **two seconds
  without dropping below it**, raises `audio_noise` — and one continuous episode is
  one strike. **No audio is recorded, transmitted or stored** — only the
  decibel numbers the detector reads, in memory. It flags "someone is talking",
  not *what* was said, and cannot separate speech from a television at a similar
  loudness.
- **Hardware integrity is Android-native.** The second-display and
  virtual-camera probes live in the Android native layer (a platform channel
  behind `HardwareIntegrityService`). On web, iOS and desktop they report
  **"cannot see"** (silence), not a finding.
- **Kiosk pinning is best-effort without Device Owner.** Android lock task is
  fully enforced only when a device owner whitelists the app; otherwise it
  degrades to screen pinning, which a long-press of Back + Recents can still
  escape (the app then logs `app_minimized`). Browsers get the DOM lockdown
  (HTML5 fullscreen plus tab/blur detection) instead.
- **The web ships a browser-native face detector.** `web/proctor_face_detector.js`
  loads the browser's built-in `window.FaceDetector` (Shape Detection API) where
  available, and falls back to a **MediaPipe FaceLandmarker** WASM model
  (`web/mediapipe/`) in browsers that support WebAssembly but not the native API.
  It reports camera presence, covered or frozen frame, face count and 3D head pose
  (yaw/pitch) on every polling tick. If the WASM binary or model files fail to load,
  the detector degrades gracefully to presence-only checks (pixel-level covered/blank
  detection) and logs a warning. A page reduced to counting does not claim to judge
  head turns: it publishes `false` on a second hook
  (`window.proctorGuardFaceAnalysis`), the exam screen tells the student that head
  turns are not being checked in that browser, and the heartbeat records
  `monitoring_ok = false` for the sitting — reported, not punished (see
  [mobile/README.md](./mobile/README.md#face-signals-on-the-web-the-host-page-bridge)).
  The same detector listens for a host page's
  own signals through the `window.proctorGuardFaceSignal` bridge (see
  [mobile/README.md](./mobile/README.md#face-signals-on-the-web-the-host-page-bridge)),
  so the app's proctoring works equally well with the shipped model and with an
  institution-provided detector. The web build is otherwise a
  fully supported host: the device check probes the camera and the microphone with two
  separate `getUserMedia` calls, releasing each stream before the next one opens
  (one combined call is all-or-nothing, so a laptop with no microphone used to be
  reported as a blocked camera), and it opens no capture session of its own — that
  is what Chromium reports as "another app or tab is already using the camera".
  The session asks `CameraPlatform.instance.supportsImageStreaming()` before
  `startImageStream`, because `camera_web` has no image stream to offer. The app's own
  frame loop is what a browser cannot run, and the shipped detector above replaces it;
  the preview, the still-frame evidence and the browser guards are the phone build's.
- **Android is the only *native* proctoring host.** The repository ships an
  `android/` runner, an `ios/` scaffold and a `web/` target. The `windows/` and
  `linux/` runners have been removed: they built and started, but could **never
  proctor** — no `camera` implementation exists for a desktop target and no
  desktop ML Kit does, so the device check blocked the exam and named that as the
  reason instead of reporting a broken camera it could never fix
  (`lib/core/services/platform_capabilities.dart`). A macOS, Windows or Linux
  machine therefore takes part through the web build in a browser, so the
  browser-detector description above applies there too. The web build is
  **desktop-only**: `lib/core/widgets/desktop_only_web_guard.dart` shows a
  "desktop browser required" notice on a phone or tablet browser, so the console is
  reached from a computer or from the Android app. The **exam** inside it has its
  own, narrower rule
  (`lib/features/exam/presentation/widgets/mobile_exam_only.dart`): the Android
  app and **any desktop browser** (Windows, macOS, Linux) may sit a paper, while a
  phone or tablet browser is refused and told to install the app — so a student
  with no Android phone is not locked out of the exam. That rule deliberately does
  not read the viewport: 768 px is the console's layout limit, and a desktop window
  dragged narrow is still a desktop. See
  [mobile/README.md → Supported platforms](./mobile/README.md#supported-platforms-and-what-proctoring-each-one-gets).

**Risk register**

| Risk | Inherent limit | Mitigation in place |
| --- | --- | --- |
| Impersonation / a stand-in on camera | Face detection is not face recognition and has no liveness check | Supervisor review of the attempt's evidence; add an identity-match + liveness step where the stakes require it |
| A helper off-camera or on another device | The camera only sees in front of the lens; audio is level-only | `multiple_faces`, `no_face`, `looking_away`, `idle_afk` and `secondary_display_detected` signals, plus supervisor judgement |
| Sound that is not plain talking (TV, music, a second speaker) | Loudness cannot be attributed to a person or separated from other sound | Sustained-threshold rules (a median-calibrated room floor plus a 6 dB speech margin, held for 2 s with no dip below the line, one episode = one strike) keep one-offs out; content is deliberately never captured. A noisy room **can** reach three counted strikes and close the sitting for review — the rule is strict on purpose and the review is a human's |
| A microphone that fails mid-session (unplugged, grant revoked, another app took the input) | Level is the only audio signal, so a dead mic stops speech being detected at all | The chip reports `Mic lost` / `Mic unavailable` / `Mic blocked` — **never a false "quiet"** — and the paper is held shut behind the opaque equipment block, with **Reconnect** / **Open settings** / **Leave** (the `unavailable` case stays on the indicator: a barrier nobody can clear would strand the student). A lost mic is an **unproctored gap, not a strike**, so no attempt is ended for it — but nothing can be read or typed behind the block either, so the gap cannot pass as a clean run |
| Escape from the locked exam surface | Screen pinning (no Device Owner) and browser fullscreen can be left | An escape or a fullscreen exit becomes an `app_minimized` strike; the kiosk badge shows whether pinning is enforced or best-effort |
| Detector evasion (rooted/virtualised device, camera spoof) | Client-side detectors can be defeated by a determined, technically capable student | Treat the client as untrusted: grading and the weighted strike rule are enforced **server-side** (`register_violation`, `submit_exam`, `resolve_flagged_attempt`) |
| A fabricated heartbeat series | A beat is the client's own claim: a patched build can report "camera up, monitor running" while nothing is running, and no app attestation (Play Integrity / App Attest) verifies the build yet | The series is a **positive** signal only - an attempt that never checked in, or went quiet, is shown as *not reporting*, never as clean. Writes go through `record_heartbeat()` alone (the table has no insert policy), on the server clock, idempotent per `client_event_id` and rate-limited to one stored beat per 8 s, so a client can neither backfill history nor rewrite it - and `proctoring_coverage()` can only flag an attempt for a human, never end one |
| Evidence retention / privacy | Snapshots in `proctor-snapshots` are personal data, and no scheduled job deletes them unless an operator sets one up | The bucket is **private**: a still is only ever readable through a 10-minute signed URL, and only the owning student or staff can mint one. A `proctor_snapshots` window (30 days) lives in `public.retention_policies`, enforced by the `purge-snapshots` Edge Function - the one route that also removes the *file*, and the only one that runs on hosted Supabase, where `storage.protect_delete()` refuses a SQL delete with `42501` (a self-hosted project without that guard can use `public.purge_expired_snapshots()` instead). Both keep the incident row and null its pointer, and a reset deletes an attempt's stills immediately, which `session_reset_logs` records. The photograph has a lifetime now; see [Scheduling the snapshot purge](#scheduling-the-snapshot-purge) for the job itself, which is deliberately left to the operator |

**What is *not* verified — read this before trusting a number**

Four things are written down here rather than left implicit, because each is the
kind of detail a pilot finds out the hard way:

- **The look-away gate has never been measured on a device.** The rule (15 deg of
  yaw and 15 deg of pitch, absolute, held for two seconds) is unit-tested against
  both engines, including the boundary and the symmetry, but no real head has been
  put in front of it here. The number that decides whether it is safe is the
  false-positive rate: a candidate who works with the laptop low, or who reads a
  printed answer sheet on the desk, is the case to measure before a
  timer-driven disqualification is trusted.
- **The audio threshold has never been measured in a real room either.** The rule is
  a median-calibrated floor plus 6 dB, clamped to −50…−32 dBFS, held for two seconds
  continuously (`AudioNoiseDetector`, `proctoring_thresholds.dart`). It is unit-
  tested at the meter's real 250 ms rate, but no corridor, hall, fan, television or
  busy canteen has been used to check it. Two errors are possible and only one of
  them is quiet: a room loud enough to clear the line for two unbroken seconds now
  earns a **counted** strike (three of those close the sitting for review — never an
  automatic disqualification, and a supervisor can clear it), while speech that dips
  between words may never fill the window at all. Measure both directions before a
  pilot relies on either.
- **The sign of the pitch a browser detector reports is unverified.** The shipped
  FaceLandmarker path reads a rotation matrix, a host page sends `pose:` degrees,
  and the two need not agree on which direction is "up". The app therefore compares
  the **absolute** pitch, so a wrong sign costs nothing — and keeps no rule that
  would depend on one.
- **A web-only "a chin 20 deg down counts sooner than 20 deg up" rule was requested
  and is deferred**, for exactly the reason above: it is asymmetric in a way the
  phone build is not, and shipping it before the sign is confirmed on real devices
  would flag one direction of head movement and ignore the other. Pitch stays
  symmetric at 15 deg until that is measured.
- **Whether a browser has really handed the lens back cannot be observed.** The
  device check stops every `MediaStreamTrack` it opened before the exam route is
  pushed, and the phone build's release is awaited, but "the OS has finished
  releasing the device" is not something a page can query: the exam screen therefore
  re-opens its own session **once** on `NotReadableError` (the "another app or tab
  is already using the camera" case) rather than assuming the handover was instant.

The client is never the authority: **grading and the strike rule live on the
server** (see `supabase/schema.sql`), so a modified or compromised client can
lose proctoring signals but cannot change a result.

**Did the proctoring client actually run?**

An empty violation feed is ambiguous: it can mean *nothing happened* or *the
client was not running*, and the two look identical on a dashboard. The app
closes that gap with a **heartbeat**: every 15 seconds the exam page calls
`public.record_heartbeat()`, which stores a row in `proctor_heartbeats` and
stamps `exam_submissions.last_heartbeat_at` in the same transaction. The
supervisor roster reads that column and shows one of three states per live
attempt - *proctoring live*, *proctoring silent 3m* once a beat is 45 s overdue,
or *no proctoring signal* for an attempt that never checked in, which is
deliberately not worded as "no violations" - and the summary counts the attempts
that are not reporting.
`public.proctoring_coverage(submission_id)` turns the same series into numbers a
supervisor can check (beats received vs expected for that attempt's own length,
longest gap including the ends, camera-down beats, share of expected beats)
with a `risk_flag` that means **look at this**, never *punish this*.

What a heartbeat proves, and what it cannot:

- it proves a client of ours was running and in reach of the server at that
  moment, and it carries what that client said about the camera and the monitor
  (`camera_ok`, `monitoring_ok`) - the "running but blind" case an empty log
  feed used to hide completely;
- it does **not** prove the client was honest. Nothing here is attested to
  Google or Apple, so a patched build could call the RPC on a timer from a spare
  room with the phone face down. App attestation (Play Integrity / App Attest)
  is **not** implemented yet; that is the step that would make the claim
  expensive to fake, and it is listed in the risk register below;
- so a gap is a **flag for human review, never a disqualification**. Coverage
  never touches `exam_submissions.status`: a dropped network and a closed laptop
  produce exactly the same silence as a determined cheat, and only a person with
  the rest of the evidence can tell them apart.

**Is the student on record as having agreed to any of this?**

Until the consent gate existed, no. The camera, the stills and the supervisor who
reads them all rested on a paragraph in an instructions dialog nobody could prove
had been shown: consent was a claim the client made by *starting*, which is not a
record. It is a record now.

- `public.proctoring_consents` holds one row per acceptance - **who**, **which
  paper** (or `NULL` for a general acceptance that covers every paper), **which
  wording version**, **when** (the server's clock) and from what client (the
  transport's own `User-Agent`, not one the body claims).
- `public.proctoring_consent_config` names the version currently in force. The
  server decides what "current" means; the app carries the matching text
  (`ProctorConsentConfig` in
  `mobile/lib/features/exam/domain/entities/proctor_consent.dart`) and the two are
  pinned together by `mobile/test/schema_contract_test.dart`. A build showing
  older wording still records what it showed - `record_consent()` answers
  `is_current: false` - and the screen tells the student to update rather than
  letting them accept text the institution has replaced.
- `submissions_insert_own_ongoing` **requires** a current-version acceptance for
  that paper (or a general one) before an attempt row can exist, so a dismissed
  dialog, a patched build or a hand-written POST gets a `42501` and no attempt.
  The refusal lives in the same place as every other "you may not start this".
- the record is write-once: `record_consent()` is the only writer, acceptance has
  no UPDATE or DELETE policy and no grant, and the student can read their own
  rows, and an administrator or the supervisor **of the paper the acceptance names**
  can read them too (a general acceptance is its subject's alone either way). A
  consent record its subject can rewrite is not a record.
- **what this does not do**: it records that a notice was accepted, not that it
  was *read*, and it is not legal advice. The wording is plain-language
  placeholder text with `TODO(institution)` markers wherever your notices office
  must supply the real sentences (lawful basis, controller identity, complaints
  route). Bump `ProctorConsentConfig.version` **and**
  `proctoring_consent_config.current_version` together when they do.

**And the photographs?**

The consent notice says a still is deleted after 30 days, so something has to make
that true. The `proctor_snapshots` window lives in `public.retention_policies`
beside the incident and heartbeat windows, and there are two ways to enforce it -
but on a hosted Supabase project only one of them actually runs:

- the **`purge-snapshots` Edge Function** (the supported path, and on hosted
  Supabase the only one): it goes through the Storage API, so the file goes with
  the row, deletes only objects older than the window whose attempt is **not**
  `ongoing`, and then nulls `proctoring_logs.snapshot_url` for each. The incident
  row survives - the flag happened, the photograph expired;
- **`public.purge_expired_snapshots(p_older_than, p_dry_run)`**, for a
  self-hosted or base deployment that cannot use Edge Functions. Two things to
  know before you rely on it. First, **on a hosted Supabase project it refuses and
  purges nothing**: `storage.objects` there carries the `protect_delete` trigger
  (`storage.protect_delete()`), which refuses every SQL DELETE with `42501`
  *Direct deletion from storage tables is not allowed*, and the function
  deliberately does not switch that guard off - it raises `42501` naming the
  Edge Function instead. Second,
  even where the guard is absent it can only delete Storage's *bookkeeping* row,
  so the object in the bucket is left behind and - because the row is gone -
  becomes invisible to the Storage API from then on. **Do not run both on the same
  window.**

The function's dry run (`p_dry_run => true`) is safe anywhere, trigger or no
trigger: it counts what would expire and deletes nothing.

Neither is scheduled by the migrations: a job that deletes photographs is an
operator's decision. See
[Scheduling the snapshot purge](#scheduling-the-snapshot-purge).

## Getting started

1. Create a Supabase project and run three files, in this order:
   `supabase/schema.sql`, then `supabase/migrations/retention_policy.sql`, then
   `supabase/migrations/20261106090100_snapshot_retention.sql`.
   `schema.sql` is the database — tables, policies, RPCs, the storage bucket, the
   seeded catalogues — but it is **not** the whole of it: `public.retention_policies`
   and the three purge functions (`purge_expired_proctoring_logs`,
   `purge_expired_proctor_heartbeats`, `purge_expired_snapshots`) live only in the
   other two files, and the second one refuses to run without the table the first
   one creates (it says so by name and stops). Skip them and a fresh project keeps
   every heartbeat, every incident row and every still for ever, with no window to
   enforce. Every *other* file in `supabase/migrations/` is an *upgrade path for a
   project that already exists*: applying it to a new project is unnecessary, and
   for the two files called out in the warning below it is not harmless either —
   they cannot be re-run once `20261104090100_weighted_strikes_and_flagged_review.sql`
   has run.
   For an existing project, run any unapplied files in `supabase/migrations/`;
   each migration documents its purpose and verification steps, and one can be
   applied on its own through the CLI:
   ```powershell
   supabase db query --linked -f supabase/migrations/session_reset_logs.sql
   supabase db query --linked -f supabase/migrations/question_types_and_grading.sql
   supabase db query --linked -f supabase/migrations/optional_exam_scheduling.sql
   supabase db query --linked -f supabase/migrations/private_proctor_snapshots.sql
   supabase db query --linked -f supabase/migrations/academic_targeting.sql
   supabase db query --linked -f supabase/migrations/profile_identity_numbers.sql
   supabase db query --linked -f supabase/migrations/strict_targeting_null_profiles.sql
   supabase db query --linked -f supabase/migrations/20261103090000_guard_profile_labels.sql
   supabase db query --linked -f supabase/migrations/20261103090100_student_can_access_exam.sql
   supabase db query --linked -f supabase/migrations/20261103090200_exams_select.sql
   supabase db query --linked -f supabase/migrations/20261103090300_questions_public.sql
   supabase db query --linked -f supabase/migrations/20261103090400_submissions_insert_own_ongoing.sql
   supabase db query --linked -f supabase/migrations/20261103090500_snapshot_read_policy.sql
   supabase db query --linked -f supabase/migrations/20261103090600_submissions_delete_supervisor.sql
   supabase db query --linked -f supabase/migrations/20261103090700_register_violation_snapshot_path.sql
   supabase db query --linked -f supabase/migrations/20261103090800_snapshot_purge_not_live_attempt.sql
   supabase db query --linked -f supabase/migrations/20261104090000_violation_weights.sql
   supabase db query --linked -f supabase/migrations/20261104090100_weighted_strikes_and_flagged_review.sql
   supabase db query --linked -f supabase/migrations/optional_question_shuffling.sql
   supabase db query --linked -f supabase/migrations/20261105090000_proctor_heartbeats.sql
   supabase db query --linked -f supabase/migrations/retention_policy.sql
   supabase db query --linked -f supabase/migrations/20261106090000_proctoring_consents.sql
   supabase db query --linked -f supabase/migrations/20261106090100_snapshot_retention.sql
   supabase db query --linked -f supabase/migrations/20261108090000_looking_away_and_noise_count.sql
supabase db query --linked -f supabase/migrations/20261109090000_supervisor_exam_assignments.sql
   ```
   `session_reset_logs.sql` is the one to check for on a project installed
   earlier: without it, an attempt reset from the staff console still works, but
   its audit row cannot be written and the console reports the gap
   (`session_reset_logs` in [mobile/README.md](./mobile/README.md)).
   `question_types_and_grading.sql` is the other: it widens `questions` from two
   types to four and adds `question_grades` with `grade_submission()`. Without
   it, a lecturer console can still author multiple-choice and fill-in-the-blank
   questions, but the database refuses a true/false or essay row with
   `questions_question_type_check`, and marking an essay fails with the file's
   name in the message.
   `optional_exam_scheduling.sql` adds the nullable `exams.starts_at` / `ends_at`
   window (and the three rules that enforce it). It is what a project that predates
   scheduling needs before a scheduled paper can be authored: the console lists
   papers by reading those columns, and an un-applied project refuses that read, so
   the console reports "This project has no exam scheduling columns yet" with this
   file's name instead of an empty list. Unscheduled papers work either way — no
   window is sent — so this is the one migration that can wait for the first
   scheduled exam. Apply them in this order: both
   `question_types_and_grading.sql` and `optional_exam_scheduling.sql` replace
   `submit_exam()`, and the latter — which extends the former's body — has to be
   the last of the two. Re-running the older
   `secure_exam_access_and_deadlines.sql` after either would restore a body that
   scores multiple-choice and fill-in-the-blank only, with no window cap.
   `private_proctor_snapshots.sql` is the evidence-privacy one: it flips an
   existing `proctor-snapshots` bucket to **private** (a fresh `schema.sql` already
   creates it that way) and re-asserts its read/upload/purge policies. Until it
   runs, every stored still is reachable through the permanent public URL the
   older build wrote into `proctoring_logs.snapshot_url`; afterwards evidence is
   only served through a short-lived signed URL. It is additive and re-runnable,
   and it does not move or delete a single object — the app normalises the old URLs
   back to object paths, so existing evidence stays reviewable and a reset still
   purges it.
   `academic_targeting.sql` adds the `faculty` / `department` / `level` columns an
   account and a paper are labelled with (plus the per-paper borrow list), and
   `profile_identity_numbers.sql` adds the optional `profiles.matric_number` /
   `staff_id` that the admin console records beside them. Both are
   `add column if not exists` and re-runnable: without them the console still
   creates accounts, it just leaves those columns unset, and every existing
   account and paper keeps the access it had.
   `strict_targeting_null_profiles.sql` **must** come after
   `academic_targeting.sql` — it replaces the same `exams_select` policy with a
   stricter version. Re-running `academic_targeting.sql` after it restores the
   original NULL-matches-all rule, so always apply both together.
   The nine `2026110309*.sql` files are one hardening pass and are listed above in
   the order they must be applied, after `strict_targeting_null_profiles.sql`:
   `…090000_guard_profile_labels` (an account cannot rewrite the labels a policy
   compares), `…090100_student_can_access_exam` (the cohort rule gets a name),
   `…090200_exams_select` (the paper list asks that name instead of quoting the
   rule), `…090300_questions_public` (the feed is aimed, windowed and
   attempt-aware, and a lecturer no longer reads another lecturer's drafts),
   `…090400_submissions_insert_own_ongoing` (an attempt can be started only for a
   paper the student may sit, inside its window), `…090500_snapshot_read_policy` (a
   still is readable by the owning student, the paper's author or the supervisor of
   tier — not by every employee), `…090600_submissions_delete_supervisor` ("Reset
   attempt" is the supervisor of that paper or its author),
   `…090700_register_violation_snapshot_path` (a stored `snapshot_url` must be this
   attempt's own `<action_type>_<epoch-ms>.(jpg|png)` object, or it is stored as
   `NULL` and the strike still counts) and
   `…090800_snapshot_purge_not_live_attempt` (a snapshot is purgeable only once its
   attempt row is gone — the order the console's reset already uses, which is what
   stops a live sitting's evidence being deleted).
   Each file's header names its prerequisites and the file it must follow.
   Re-running the nine in the order listed above is safe, with one exception that
   arrived later: `…090700_register_violation_snapshot_path` recreates
   `register_violation()` with the two-column `(warning_count, disqualified)`
   return shape, and `20261104090100_weighted_strikes_and_flagged_review.sql`
   replaces that function with a three-column one. `create or replace` cannot
   change a return type, so once `…04090100` is installed, re-running `…090700` (or
   `secure_exam_access_and_deadlines.sql`, which installs the same two-column
   version) fails with `42P13` — "cannot change return type of existing function" —
   with the statements above it in the file already applied. **Do not re-run either
   file once `…04090100` is in place**; if one is run by mistake, re-apply
   `20261104090100_weighted_strikes_and_flagged_review.sql` (which drops the
   two-column signature before recreating it, so it repairs the project either
   way).
   Two older files recreate policies these replace:
   re-running `private_proctor_snapshots.sql` undoes `…090500`/`…090800`, and
   re-running `staff_attempt_resets.sql` undoes `…090600`/`…090800` — re-apply the
   `…0905*`, `…0906*` and `…0908*` files if that ever happens.
   `optional_question_shuffling.sql` adds the `shuffle_questions` column and is
   independent of every other migration.
2. Deploy the account-management functions, and the snapshot purge:
   ```powershell
   supabase functions deploy admin-create-user
   supabase functions deploy admin-delete-user
   supabase functions deploy admin-reset-password
   supabase functions deploy admin-update-profile
   supabase functions deploy purge-snapshots
   ```
   The project supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY` (or
   `SUPABASE_PUBLISHABLE_KEY`), and `SUPABASE_SERVICE_ROLE_KEY` to the
   functions. The service-role key is used only on Supabase servers.
   `admin-update-profile` is what the console's Edit dialog and its corrections
   file call: it checks the labels against the app's academic catalogue before
   writing (the columns are free text, so an unvalidated `"computer science"`
   beside a paper's `"Computer Science"` would be a correction that fixed
   nothing), and it answers a *page* of a corrections file with
   `{ updated, failed }` — one refused row travels beside the rows written rather
   than failing the request.
   `purge-snapshots` is deployed **without** `--no-verify-jwt`: the platform's
   JWT check is not its authorization decision (that is the role check inside it,
   or the service-role key a scheduler presents), but leaving it on means a
   forged or expired token never reaches the code.
3. Optionally run `supabase/seed.sql` to load demo accounts, exams, and
   questions. Demo credentials and account roles are documented at the top of
   that file.
## Scheduling the snapshot purge

Nothing in this repository schedules a photograph deletion. The function and the
Edge Function are both there, the window is a row, and the decision - *when*, and
*with which appeals period in front of you* - is the institution's. Two
supported routes, both run at an hour when no sitting is closing:

**Dashboard -> Edge Functions -> Schedules (simplest).** Pick `purge-snapshots`,
choose a daily cron (`7 4 * * *` matches the other retention jobs), and set the
authorization header to `Bearer <service-role key>`. No request body is needed:
the window comes from `retention_policies`, so changing it there changes the job
without touching the schedule.

**pg_cron from the database.** `pg_cron` plus `pg_net` (Dashboard -> Database ->
Extensions), then:

```sql
select cron.schedule(
  'proctor-snapshots-retention',
  '7 4 * * *',
  $$
  select net.http_post(
    url     := 'https://<project-ref>.supabase.co/functions/v1/purge-snapshots',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer <service-role key>'),
    body    := '{}'::jsonb
  );
  $$
);
```

Both routes end up in the same place. **Dry run first**, either by hand or as a
one-off: it reports what would go and deletes nothing.

```powershell
# a person, signed in as an admin - the function checks profiles.role
curl -X POST "https://<project-ref>.supabase.co/functions/v1/purge-snapshots" `
  -H "Authorization: Bearer <admin access token>" `
  -H "Content-Type: application/json" `
  -d '{"dry_run":true}'
# { "bucket":"proctor-snapshots", "window_days":30, "dry_run":true,
#   "folders":412, "scanned":95, "expired":7, "removed":0, "nulled":0,
#   "kept_live":2, "capped":false }
```

Things worth knowing before you turn it on:

- it **never** touches a still whose attempt is still `ongoing`, whatever its age
  (an abandoned attempt therefore keeps its evidence), and it never touches
  anything inside the window;
- it nulls `proctoring_logs.snapshot_url` for each object it removes and keeps the
  incident row: after the purge the log still says *looking_away at 14:02*, and
  the still is gone;
- it responds `"capped": true` when a backlog is larger than one run
  (`MAX_OBJECTS` in `supabase/functions/purge-snapshots/index.ts`), which means
  "run me again", not "done";
- the **SQL fallback** (`public.purge_expired_snapshots(...)`) is for a
  self-hosted deployment that cannot use Edge Functions, and **on a hosted
  Supabase project it raises `42501` and purges nothing**:
  `storage.protect_delete()` refuses the SQL delete and the function says so
  rather than bypassing that guard, because a SQL delete would remove the
  bookkeeping row and leave the file behind, invisible to the Storage API from
  then on. Its `p_dry_run => true` form works everywhere and deletes nothing. Run
  the Edge Function, or that function, never both on the same window;
- an hour of distance from `proctoring-logs-retention` (03:23) and
  `proctor-heartbeats-retention` (04:07) keeps three deleting jobs from walking
  `exam_submissions` at the same moment.


4. See [mobile/README.md](./mobile/README.md) for Flutter setup, configuration,
   and run/build commands.

## Production checklist

- Turn off public sign-ups if the institution provisions student accounts
  separately. Self-sign-up is limited to the `student` role by database policy.
- Apply `supabase/migrations/question_types_and_grading.sql` on any project that
  predates the four question types. Until it runs, the lecturer console cannot
  store a true/false or essay question, and cannot mark one.
- Apply `supabase/migrations/optional_exam_scheduling.sql` before the first
  scheduled paper is authored (or run it against a project that already has
  scheduling data — it is additive and re-runnable, and every existing paper stays
  unscheduled). Until then the console's own list reports the missing columns by
  name, and only unscheduled papers can be created.
- Apply `supabase/migrations/private_proctor_snapshots.sql` on any project whose
  `proctor-snapshots` bucket was created public (the pre-migration default). It is
  additive and re-runnable, changes no object, and is what makes the bucket's
  evidence reachable only through signed URLs.
- Apply `supabase/migrations/academic_targeting.sql` and
  `supabase/migrations/strict_targeting_null_profiles.sql` together (in that
  order) on any project that predates the academic labels.
  `strict_targeting_null_profiles.sql` must come **after** `academic_targeting.sql`
  because it replaces the same `exams_select` policy. Re-running
  `academic_targeting.sql` afterwards restores the original NULL-matches-all rule.
  Apply `supabase/migrations/profile_identity_numbers.sql` on any project whose
  `profiles` row predates the academic labels and identity numbers. Both are
  additive and re-runnable. Without them the admin console still creates
  accounts — a field left blank is sent as nothing and the column stays `NULL` —
  but the roster has no faculty, department, level, matriculation number or staff
  ID to show, no paper can be targeted at a cohort, and a filled-in label is
  refused with a message naming the file to apply. Correcting a label afterwards
  — the Edit dialog, or a class's corrections file — goes through
  `admin-update-profile`, which answers the missing column by that same file name
  rather than as a database fault.
- Apply the nine `supabase/migrations/2026110309*.sql` files, in filename order,
  on every project (they are the exam-visibility hardening pass: the label guard,
  the named cohort rule, the paper list, the question feed, the attempt insert, the
  snapshot read policy, the attempt delete, the snapshot-path check and the snapshot
  purge). They are re-runnable, and a fresh `schema.sql` already carries all nine —
  the only reason to run them is an existing project. One exception to
  "re-runnable": `20261103090700_register_violation_snapshot_path.sql` cannot be
  re-run after `20261104090100_weighted_strikes_and_flagged_review.sql`, which
  replaces its function with a wider return shape (`create or replace` cannot
  change a return type: the re-run fails with `42P13` and leaves the caller
  thinking the path rule was re-applied). If that happens, re-apply
  `20261104090100_weighted_strikes_and_flagged_review.sql`.
   `secure_exam_access_and_deadlines.sql` installs the same two-column
   version, so that warning covers it too, and the same re-apply repairs it.
   Two older files recreate
  policies they replace, so re-apply `20261103090500_snapshot_read_policy.sql`,
  `…090600_submissions_delete_supervisor.sql` and
  `…090800_snapshot_purge_not_live_attempt.sql` after re-running
  `private_proctor_snapshots.sql` or `staff_attempt_resets.sql`.
- Apply `supabase/migrations/20261104090000_violation_weights.sql` and then
  `20261104090100_weighted_strikes_and_flagged_review.sql`, in that order, on every
  project. The first creates and seeds `public.violation_weights`; the second moves
  the escalation onto it, widens `exam_submissions.status` with
  `flagged_for_review`, and adds `resolve_flagged_attempt()` and its audit table.
  Until they run, `register_violation` still disqualifies on the third row of
  anything. Once they run, an attempt that reaches the threshold **waits for a
  supervisor** — make sure somebody holds the `supervisor` role (or that the paper's
  author is around), because nothing resolves a review automatically. Neither file
  rewrites a `proctoring_logs` row or re-reads an existing attempt: see
  [Tuning the violation weights](#tuning-the-violation-weights).
- Apply `supabase/migrations/20261109090000_supervisor_exam_assignments.sql` **last**,
  on every project. It creates `public.supervisor_exam_assignments` (one
  `(paper, supervisor)` row per sitting), the `can_supervise_exam()` /
  `is_supervisor_only()` predicates, and re-creates every policy and RPC that used to
  ask the role tier `is_exam_supervisor()` so that the supervisor arm asks the scope
  question instead. It changes **who may read and write**, never what is stored: no
  row of `proctoring_logs`, `exam_submissions`, `proctor_heartbeats`,
  `proctoring_consents`, `session_reset_logs` or `attempt_review_logs` is rewritten.
  Lecturers keep exactly what they had (`owns_exam()` and the `is_staff()` roster
  read are untouched) and administrators need no row. The one read it narrows that is
  not about a paper's evidence is the roster itself: `profiles_select_own_or_staff`
  let **any** supervisor read **every** profile row in the institution — name,
  matriculation number, faculty, department, level and photograph — by being
  `is_staff()`, assigned or not, and it now asks `can_read_profile(id)`: the students
  who sat a paper the supervisor runs, who were granted one, or whom a labelled paper
  of theirs is aimed at. The monitor's names still resolve, because they are exactly
  those students. It is safe to re-run, and it
  **does not backfill**: a supervisor who existed before it runs sees an empty console
  until an administrator assigns them a sitting on the admin console's **Assign
  supervisors** screen, which is the deliberate fail-closed default. It refuses to
  report success if any policy still asks the tier question, and
  `supabase/tests/supervisor_scope_check.sql` proves the scope end to end (assigned
  vs unassigned paper, roster, incident feed, stills, review decision, reset, the RPCs,
  the demotion path and the profile roster read). Verify with
  `select exam_id, supervisor_id from public.supervisor_exam_assignments;`.
- Apply `supabase/migrations/20261108090000_looking_away_and_noise_count.sql` after
  those two, on every project. It is one `UPDATE` that turns `looking_away` and
  `audio_noise` from "recorded for review only" (weight 0) into counted strikes
  (weight 1), so three of either now closes the sitting for review. It is safe to
  re-run, and it is the only way those two rows change on a live database:
  re-applying `schema.sql` or `20261104090000` will not push the new values into a
  table that already holds the old ones (`on conflict … do nothing`). Verify with
  `select action_type, weight, counts_toward_dq from public.violation_weights where
  action_type in ('looking_away','audio_noise');` — expect `1 / true` twice. Nothing
  is backfilled: existing evidence keeps its rows and existing attempts keep their
  status.
- Apply `supabase/migrations/optional_question_shuffling.sql` before the first
  paper that has question-order shuffling enabled. Until it runs, the
  `shuffle_questions` column does not exist: the authoring console reports the
  missing column by name, and student-facing paths default to `false` (no
  shuffle). It is additive and re-runnable.
- Apply `supabase/migrations/20261105090000_proctor_heartbeats.sql` (a new
  project gets all of it from `schema.sql`). It adds
  `exam_submissions.last_heartbeat_at`, the `proctor_heartbeats` table and the two
  functions the dashboard reads - `record_heartbeat()` and
  `proctoring_coverage()`. It is additive and re-runnable; until it runs there is
  no pulse to show, every live attempt reads as *no proctoring signal*, and that
  is the honest reading - "no data" is not "no violations".
- A **fresh** project is three files, in this order: `supabase/schema.sql`, then
  `supabase/migrations/retention_policy.sql`, then
  `supabase/migrations/20261106090100_snapshot_retention.sql`. `schema.sql` does
  not carry `public.retention_policies` or any `purge_expired_*` function, and the
  snapshot file seeds rows into the table the retention file creates - which is why
  the order is fixed. Skipping either leaves a project that keeps every proctoring
  log row, every heartbeat and every snapshot for ever, with nothing scheduled to
  remove them. Everything else a fresh project needs is in `schema.sql`.
- Apply `supabase/migrations/retention_policy.sql` and enable `pg_cron`
  (Dashboard → Database → Extensions). `proctoring_logs` and
  `proctor_heartbeats` are the tables that grow without bound; the migration
  seeds a 30-day window in
  `public.retention_policies` and schedules a nightly purge of rows belonging to
  **closed** attempts. Rows of an attempt still `ongoing` are never deleted, so the
   weighted score cannot be eroded and a report still being written cannot lose
  beats. Without `pg_cron` the functions are still created
  and can be called from the SQL editor or an external scheduler:
  `select public.purge_expired_proctoring_logs(p_dry_run => true);` and
  `select public.purge_expired_proctor_heartbeats(p_dry_run => true);` first. The
  per-attempt snapshots are **not** deleted by either — see the file's header for why
  (`storage.objects` deletes through SQL orphan the S3 object) and use a Storage
  lifecycle rule for the bucket.
- Apply `supabase/migrations/20261106090000_proctoring_consents.sql` **together
  with the app build that carries the consent screen**. It adds the consent
  tables and `record_consent()`, and it recreates
  `submissions_insert_own_ongoing` with one new arm: an attempt cannot be created
  until the student has accepted the notice currently in force. Applied against an
  older client, every start is refused with a `42501` until that build ships - so
  deploy both, and re-apply this file after anything that recreates that policy
  (`20261103090400_submissions_insert_own_ongoing.sql` does). A fresh project gets
  all of it from `schema.sql`.
- Apply `supabase/migrations/20261106090100_snapshot_retention.sql` after
  `retention_policy.sql`. It seeds the `proctor_snapshots` (30 day), `profiles`
  (180 day) and `exam_submissions` (180 day) windows - **align the two 180s with
  your appeals period** - and creates `public.purge_expired_snapshots()`, the
  fallback purge described in
  [And the photographs?](#and-the-photographs). On a hosted project that function
  refuses with `42501` (`storage.protect_delete()`) and the `purge-snapshots` Edge
  Function is the route; its dry run still works there. It schedules nothing: no
  still is deleted until an operator runs a purge, which is the next section.
- Set `--dart-define=SENTRY_DSN=...` on a build that should report crashes
  (`mobile/README.md#crash-reporting-sentry--off-until-configured`). Unset is the
  default and installs nothing. A self-hosted Sentry also needs its ingest origin
  added to the web build's CSP `connect-src`.
- Serve `build/web` with `Content-Security-Policy: frame-ancestors 'none'` (or
  `X-Frame-Options: DENY`). The meta tag in `web/index.html` pins scripts and
  network destinations, but browsers ignore `frame-ancestors` in a meta tag; a
  self-hosted Supabase also needs its API/websocket origin added there
  (`mobile/README.md#content-security-policy-the-browser-build`).
- Ensure the `admin-create-user`, `admin-delete-user` and `admin-reset-password`
  functions are deployed, and `purge-snapshots` if you want the snapshot window
  enforced through the Storage API (see
  [Scheduling the snapshot purge](#scheduling-the-snapshot-purge)).
- Set the `ALLOWED_ORIGIN` environment variable on each deployed admin function
  **and on `purge-snapshots`** to a comma-separated list of permitted origins (for
  example, `https://console.example.com,https://admin.example.com`). The
  function's CORS response echoes the request's `Origin` header only when it is in
  that list, and adds `Vary: Origin`. If the variable is not set the function logs
  a warning and keeps the previous wide-open behaviour
  (`Access-Control-Allow-Origin: *`), so existing deployments are not broken
  before the variable is configured.
- Configure the Flutter app with the Supabase project URL and a publishable
  client key. Never embed a service-role or secret key in the app.
- Review the private `proctor-snapshots` bucket's retention policy in
  `supabase/schema.sql` §6 (it is created `public = false`, so stills are only
  readable through a short-lived signed URL); the boundaries of every proctoring
  signal are catalogued in
  [Proctoring boundaries and risk register](#proctoring-boundaries-and-risk-register).
- `.github/workflows/proctorguard_pipeline.yml` is the whole pipeline, in one
  file, on every push, pull request, `v*` tag and manual dispatch. Its gate jobs
  are `analyze_and_test` (analysis, the schema/Android manifest contract tests,
  the full suite), `typecheck_supabase` (`npm run typecheck` in
  `supabase/functions`, so a mis-resolved Deno import fails CI rather than
  `supabase functions deploy` on a live project), `build_web`
  (`flutter build web --release`), `build_android_debug`
  (`flutter build apk --debug`) and `build_ios` (unsigned, on a macOS runner).
  The build jobs `needs:` the analyze/test job and are otherwise independent of
  each other, so a single run reports a broken Gradle file and a broken Podfile
  together. The APK in `build_android_debug` is deliberately a debug build — a
  release APK needs the keystore secrets that are unavailable to pull requests.
- `build_and_publish` in that same file builds the release APKs on every push to
  `main` (and every `v*` tag) and mirrors only those artifacts into the separate
  `abbaaminu/proctorguard-release` repository, so the app can be downloaded
  without publishing this source. Its secrets - `RELEASE_PAT`,
  `SUPABASE_PUBLISHABLE_KEY` and the four `ANDROID_KEYSTORE_*` - are documented at
  the top of the job; a run without the signing ones stops with the keytool
  instructions instead of publishing an APK signed with the public debug key.
- `testflight` in that same file signs and uploads to TestFlight on
  `workflow_dispatch`, on a push to `main` and on a `v*` tag — never on a pull
  request. It is inert until its secrets exist — `APPLE_TEAM_ID`, the distribution
  certificate pair, the App Store Connect API key, and optionally the
  provisioning profile pair — all listed in
  [mobile/ios/README.md](./mobile/ios/README.md#testflight-from-ci).
- `.github/workflows/keep_alive.yml` pings the Supabase REST API twice a week;
  configure its repository secrets or remove the workflow on a paid plan. It
  stays a file of its own: it is a `schedule`-triggered ping, not part of a
  push's pipeline.

## Tuning the violation weights

`register_violation()` does not count rows. It adds up the `weight` of every signal
whose `public.violation_weights` row has `counts_toward_dq = true`, and when the
total reaches **3** it closes the sitting as `flagged_for_review` — the student is
told a supervisor will review it, and `resolve_flagged_attempt()` records that
supervisor's decision. The seeded policy:

| Weight | Counts | Signals |
|--------|--------|---------|
| 1 | yes | `multiple_faces`, `no_face`, `app_minimized`, `devtools_detected`, `secondary_display_detected`, `virtual_camera_detected`, **`looking_away`**, **`audio_noise`** |
| 0 | no | `copy_paste_attempt`, `right_click_blocked`, `idle_afk` |

**Three glances off screen close the sitting, and so do three sustained noisy-room
episodes.** Both signals count now
(`supabase/migrations/20261108090000_looking_away_and_noise_count.sql`), because a
candidate reading a second screen and a candidate talking the paper through with
somebody in the room are exactly what a camera-and-microphone proctor is good at —
and neither used to move the score at all. Neither is a single frame or a single
sample: the client only reports a look-away after 15° of yaw **and** 15° of pitch
have been held for 2 seconds, and a noisy room only after the level has stayed above
the room's own measured threshold for 2 seconds continuously (a dip resets the
timer, and one episode is one strike). The old values, for a project comparing
notes with an older install:

| Signal | Before 20261108090000 | Now |
|--------|----------------------|-----|
| `looking_away` | weight 0, not counted | weight 1, counted |
| `audio_noise` | weight 0, not counted | weight 1, counted |
| everything else | unchanged | unchanged |

Every signal is still stored in `proctoring_logs` and still shown to the
supervisor; the weight only decides which ones may end an attempt on their own.

**Two of these numbers have not been tested with real people.** The 15° / 2 s
look-away rule and the audio threshold (the room's median floor plus 6 dB, clamped
to −50…−32 dBFS, held for 2 s) are unit-tested and pinned, but no real head has been
put in front of one here and no real room behind the other. The rate that decides
whether they are safe is the false-positive rate, and it has not been measured. Two
consequences to go in with your eyes open:

- a student who works with the laptop low, reads a printed sheet on the desk, or
  sits in a corridor, a hall or beside a television **can reach three counted
  strikes and lose the sitting** — which is why the third strike produces
  `flagged_for_review` and never an automatic disqualification: a human reads it,
  and `resolve_flagged_attempt('clear')` puts the attempt back in the marking queue;
- the audio rule is strict on purpose (a dip below the threshold restarts the 2 s
  window), so speech that breaks up between words may never fill it. That direction
  of error is silence, not a false strike; the noisy room above is the other one.

Change one with a single statement — no migration, no redeploy:

```sql
-- A blocked paste becomes a counted strike: a full point, so it can be the third
-- one that closes a sitting. (It is uncounted today, and it stays uncounted here
-- for a blocked right-click.)
update public.violation_weights
   set weight = 1, counts_toward_dq = true
 where action_type = 'copy_paste_attempt';

update public.violation_weights
   set weight = 0, counts_toward_dq = false
 where action_type = 'right_click_blocked';
```

To see what a change would do before making it, ask the same question the RPC asks:

```sql
select s.id, s.status,
       coalesce(sum(case when coalesce(w.counts_toward_dq, true)
                         then coalesce(w.weight, 1) else 0 end), 0) as weighted_score
  from public.exam_submissions s
  left join public.proctoring_logs l on l.submission_id = s.id
  left join public.violation_weights w on w.action_type = l.action_type
 group by s.id, s.status
 order by weighted_score desc;
```

What a change does **not** do:

- **It does not touch existing evidence.** No `proctoring_logs` row is rewritten,
  and neither migration backfills anything.
- **It does not change a decision already made.** An attempt that was
  `disqualified` or `flagged_for_review` keeps that status, and one that is still
  `ongoing` simply accumulates under the new weights from the next signal onwards.
  Re-opening a decided attempt is `resolve_flagged_attempt()` (for a review) or
  "Reset attempt" in the console — not a side effect of an UPDATE.
- **It does not get reset by re-running the schema.** The seed uses
  `on conflict (action_type) do nothing`, so `schema.sql` and
  `20261104090000_violation_weights.sql` can be replayed without undoing a tuned
  value. Only an explicit `UPDATE` (or a `DELETE` of the row, which makes the type
  score as hard, fail-closed) changes it.
- **It is not enforced by the client.** The app mirrors the weights for display
  only; `schema_contract_test.dart` fails if the mirror and the seed drift apart.

The threshold itself is `c_flag_threshold` in `register_violation()`
(`supabase/schema.sql`, mirrored by `ProctoringRisk.disqualificationThreshold`).
Raising or lowering it — 4 for a more forgiving paper, 2 for a stricter one — is a
migration, because it changes code rather than policy data.


From `mobile/`:

```powershell
flutter pub get
flutter analyze
flutter test
```

The Flutter contract tests read `supabase/schema.sql` and the Edge Function
source to ensure the client payloads and database contracts stay aligned. They
also read `mobile/web/manifest.json`, `mobile/web/index.html` and the PNGs those
two point at, so a browser install keeps ProctorGuard's own icon (relative URLs,
real files, the artwork's `#14284B`) rather than Flutter's template logo — see
[mobile/README.md](./mobile/README.md#web-install-surface-icons-manifest-favicon).

The Edge Functions are Deno, so `flutter test` never compiles them. Type-check
them the way CI does, from `supabase/functions/`:

```powershell
npm ci
npm run typecheck
```

Zero TypeScript errors is the gate (`admin-reset-password` importing
`https://esm.sh/...` was the one thing that failed it). It installs dev-only
types from the checked-in `package-lock.json` and deploys nothing.
