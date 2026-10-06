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

- **Administrators** can list accounts, create logins, change roles, and
  permanently delete accounts from the Admin Dashboard. Creation and deletion
  use the `admin-create-user` and `admin-delete-user` Edge Functions.
- **Lecturers** author the papers they own — multiple-choice, true/false,
  fill-in-the-blank and essay questions — publish them when they are ready, and
  mark the essays that come back. Only the paper's owner (or an administrator)
  may change it or award marks on it: `grade_submission()` re-checks that
  server-side, and the marks land in `public.question_grades`. Scheduling is
  **optional**: a new paper has no window and can be sat as soon as it is
  published, while a start and/or end time confines it — enforced on the attempt
  insert and by `attempt_deadline()`, not by the client.
- **Supervisors and lecturers** can choose a published exam, monitor attempts and
  incidents in real time, and reset an attempt. A supervisor's monitor reads
  every paper's evidence; a lecturer's reads the evidence recorded on the papers
  they wrote. Reset removes the submission and cascaded incident records so the
  student can start over; associated snapshots are removed through Supabase
  Storage.
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
`is_exam_supervisor()`, which still guards writing into somebody else's attempt
row in place (a status change, an after-the-fact re-grade) and reads *every*
paper's evidence — the incident feed and the reset audit. A lecturer reads the
evidence recorded on their **own** papers and nothing else's: those two policies
ask `owns_exam()` (`exams.created_by = auth.uid()`) as well as the intervention
tier, so the roster a lecturer may see is wider than the logs they may read for
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
  (dBFS) only; sustained energy above the room's measured floor raises
  `audio_noise`. **No audio is recorded, transmitted or stored** — only the
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
- **No on-device AI on the web.** There is no ML Kit for browsers, so a web
  session runs the browser guards and audio level only (or an explicit
  mock/simulated session), with no face signals.

**Risk register**

| Risk | Inherent limit | Mitigation in place |
| --- | --- | --- |
| Impersonation / a stand-in on camera | Face detection is not face recognition and has no liveness check | Supervisor review of the attempt's evidence; add an identity-match + liveness step where the stakes require it |
| A helper off-camera or on another device | The camera only sees in front of the lens; audio is level-only | `multiple_faces`, `no_face`, `looking_away`, `idle_afk` and `secondary_display_detected` signals, plus supervisor judgement |
| Sound that is not plain talking (TV, music, a second speaker) | Loudness cannot be attributed to a person or separated from other sound | Sustained-threshold rules (a median-calibrated room floor, a 2s window that tolerates the gaps between words) keep one-offs out; content is deliberately never captured |
| Escape from the locked exam surface | Screen pinning (no Device Owner) and browser fullscreen can be left | An escape or a fullscreen exit becomes an `app_minimized` strike; the kiosk badge shows whether pinning is enforced or best-effort |
| Detector evasion (rooted/virtualised device, camera spoof) | Client-side detectors can be defeated by a determined, technically capable student | Treat the client as untrusted: grading and the 3-strike rule are enforced **server-side** (`register_violation`, `submit_exam`) |
| Evidence retention / privacy | Snapshots in `proctor-snapshots` are personal data with no automatic TTL by default | Set the bucket's visibility and a retention policy for your institution; snapshots are already deleted on an attempt reset, which `session_reset_logs` records (who cleared which attempt, for whom, and how much evidence went with it) |

The client is never the authority: **grading and the strike rule live on the
server** (see `supabase/schema.sql`), so a modified or compromised client can
lose proctoring signals but cannot change a result.

## Getting started

1. Create a Supabase project and run `supabase/schema.sql` in its SQL editor.
   For an existing project, run any unapplied files in `supabase/migrations/`;
   each migration documents its purpose and verification steps, and one can be
   applied on its own through the CLI:
   ```powershell
   supabase db query --linked -f supabase/migrations/session_reset_logs.sql
   supabase db query --linked -f supabase/migrations/question_types_and_grading.sql
   supabase db query --linked -f supabase/migrations/optional_exam_scheduling.sql
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
2. Deploy the account-management functions:
   ```powershell
   supabase functions deploy admin-create-user
   supabase functions deploy admin-delete-user
   supabase functions deploy admin-reset-password
   ```
   The project supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY` (or
   `SUPABASE_PUBLISHABLE_KEY`), and `SUPABASE_SERVICE_ROLE_KEY` to the
   functions. The service-role key is used only on Supabase servers.
3. Optionally run `supabase/seed.sql` to load demo accounts, exams, and
   questions. Demo credentials and account roles are documented at the top of
   that file.
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
- Ensure the `admin-create-user`, `admin-delete-user` and `admin-reset-password`
  functions are deployed.
- Configure the Flutter app with the Supabase project URL and a publishable
  client key. Never embed a service-role or secret key in the app.
- Review the `proctor-snapshots` bucket visibility and retention policy in
  `supabase/schema.sql`; the boundaries of every proctoring signal are catalogued
  in [Proctoring boundaries and risk register](#proctoring-boundaries-and-risk-register).
- `.github/workflows/keep_alive.yml` pings the Supabase REST API twice a week;
  configure its repository secrets or remove the workflow on a paid plan.
- `.github/workflows/sync_release.yml` builds the release APKs on every push to
  `main` (and every `v*` tag) and mirrors only those artifacts into the separate
  `abbaaminu/proctorguard-release` repository, so the app can be downloaded
  without publishing this source. Its secrets - `RELEASE_PAT`,
  `SUPABASE_PUBLISHABLE_KEY` and the four `ANDROID_KEYSTORE_*` - are documented at
  the top of the workflow; a run without the signing ones stops with the keytool
  instructions instead of publishing an APK signed with the public debug key.

## Verification

From `mobile/`:

```powershell
flutter pub get
flutter analyze
flutter test
```

The Flutter contract tests read `supabase/schema.sql` and the Edge Function
source to ensure the client payloads and database contracts stay aligned.
`supabase/functions/` also includes a TypeScript type-check for its Deno
functions; see its `package.json`.
