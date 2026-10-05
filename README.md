# ProctorGuard

ProctorGuard is a Flutter exam-proctoring application backed by Supabase. The
mobile/web Flutter app provides student exam sessions, supervisor monitoring and
attempt resets, analytics for staff, and an admin account-management console.

```
mobile/       Flutter app and staff/admin interfaces
supabase/     Schema, migrations, seed data, and Edge Functions
```

## Staff features

- **Administrators** can list accounts, create logins, change roles, and
  permanently delete accounts from the Admin Dashboard. Creation and deletion
  use the `admin-create-user` and `admin-delete-user` Edge Functions.
- **Supervisors** can choose a published exam, monitor attempts and incidents in
  real time, and reset an attempt. Reset removes the submission and cascaded
  incident records so the student can start over; associated snapshots are
  removed through Supabase Storage.
- **Administrators, supervisors, and lecturers** can review analytics and
  submission activity. Server-side row-level security remains authoritative for
  every operation.

Roles are stored in the `public.user_role` enum: `student`, `lecturer`,
`supervisor`, and `admin`. Lecturers can review attempts and analytics but
cannot reset them. Only admins can manage accounts.

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
| Evidence retention / privacy | Snapshots in `proctor-snapshots` are personal data with no automatic TTL by default | Set the bucket's visibility and a retention policy for your institution; snapshots are already deleted on an attempt reset |

The client is never the authority: **grading and the strike rule live on the
server** (see `supabase/schema.sql`), so a modified or compromised client can
lose proctoring signals but cannot change a result.

## Getting started

1. Create a Supabase project and run `supabase/schema.sql` in its SQL editor.
   For an existing project, run any unapplied files in `supabase/migrations/`;
   each migration documents its purpose and verification steps.
2. Deploy the account-management functions:
   ```powershell
   supabase functions deploy admin-create-user
   supabase functions deploy admin-delete-user
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
- Ensure the `admin-create-user` and `admin-delete-user` functions are deployed.
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
