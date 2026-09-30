# Proctor Supervisor Console

React + Vite + TypeScript + Tailwind + Supabase Realtime.

## Setup
```bash
npm install
cp .env.example .env.local   # fill in VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY
npm run dev
```

Uses the shared schema at `../supabase/schema.sql` — run that once in the
Supabase SQL editor before starting either app in this monorepo. It already
includes `questions.points` and `exam_submissions.submitted_at`.

§0 of that file is the part a project created before it existed will *not* have:
the `grant`s that let PostgREST's `anon`/`authenticated` roles reach the schema
at all. Without them every request answers `401 {"code":"42501","message":
"permission denied for schema public"}` and this console cannot read any
account — run `../supabase/migrations/grant_api_roles_public_schema.sql` once in
the SQL editor to apply them. See **Login** below for what the form shows until
you do.

`../supabase/seed.sql` then loads mock testing data: 5 profiles (admin, lecturer,
supervisor and 2 students), 2 published exams with 5 questions each, and one
disqualified submission with 3 proctoring logs. Log in with
`supervisor@proctor.test` / `Proctor123!` to see it in this console — the lecturer
(`lecturer@proctor.test`) login uses the same demo password and reaches the same
console, since `is_staff()` in the schema treats all three staff roles alike. The
admin (`admin@proctor.test`) reaches it too, plus one page the other two do not
have: **Accounts**.

## Structure
```
src/
  components/ui/       Badge, Card, Button, Toast, ConfirmDialog, MetricCard,
                        Skeleton — shadcn-style primitives
  components/layout/   Sidebar (role-aware nav + realtime pill + profile tile
                        + Sign out), AppShell, RequireAdmin (fence for the
                        admin-only route), SignOutButton (ends the session)
  hooks/               useAuth (session, role guard, sign-in errors),
                        useRealtimeStatus,
                        useLiveIncidentFeed, useExamSubmissions,
                        useResetSubmission (clear one attempt),
                        useAccountNames (id -> "Aisha Bello"),
                        useAccounts (roster + role writes)
  lib/incidents.ts     action_type -> label, shared by every incident panel
  lib/roles.ts         the `public.user_role` vocabulary: labels, the admin
                        test, the role-change verdict and warning
  lib/api-errors.ts    a server refusal -> a sentence (deployment fault vs
                        account fault), shared by useAuth and useAccounts
  pages/               Login, DashboardOverview, ExamManager,
                        LiveMonitor, SubmissionAudit, Analytics,
                        AccountRoster (administrator only)
```

Every nav entry has a real page behind it: `/analytics` renders `Analytics`
(previously it re-rendered `DashboardOverview`, so the nav item was a no-op), and
the dead `Settings — coming soon` route is gone rather than sitting in the
sidebar. `/analytics` reports per exam — attempts, in-progress, completed,
disqualifications, the DQ rate and incident counts over a 30-day window — sorted
most-flagged first, with each exam linking straight to its live monitor.

One entry is role-conditional: **Accounts** (`/accounts`, the `Users` icon) is
rendered only when `profile.role === "admin"`, and `RequireAdmin` sends anyone
else who types that address by hand back to `/`.

The other thing in the chrome that is not a page is the sidebar footer's
**Sign out** (`components/layout/SignOutButton.tsx`), directly under the profile
tile and available to every signed-in role. It calls `useAuth().signOut` and
nothing else: clearing `profile` is what puts the login screen back, so the
control does not know or care which page it was pressed from.

## What each page does

- **Login** — the staff sign-in form, and the only screen the console shows
  without a session. Every refusal lands here as a sentence — a wrong password or
  an email that does not exist, an unconfirmed address, a profile row that is
  missing, a profile read the server refused, or a signed-in student — never as a
  raw PostgREST body. Two of those sentences describe the *deployment* rather
  than the account — a database whose API cannot reach the schema
  (`permission denied for schema public`) or one whose API does not know
  `public.profiles` yet — and they name the file an administrator has to run,
  because until it has been run no account at all can be served.
- **DashboardOverview** — live metrics (`Live exams now` counts exams with an
  `ongoing` submission, not merely published ones), the 24h incident breakdown
  and the completions/disqualifications timeline. A failed read is shown with a
  **Try again**, instead of quietly rendering zeros.
- **ExamManager** — create an exam with its question bank, publish/unpublish,
  delete, and edit an existing exam (title, duration *and* its questions).
  **Publish / Unpublish** is an explicit per-row button that writes
  `exams.is_published` optimistically: the badge moves to *Published* before the
  round trip (and rolls back with a reason if the server refuses), then confirms
  with a short-lived toast.
  Each draft question is numbered ("Question 2 of 5"), has a
  **Multiple choice / Fill in the blank** selector, and shows either the option
  list with its correct-option radio or the accepted answer for a typed question.
- **LiveMonitor** — the roster for one exam with per-candidate flag counts, a
  confirmed **Disqualify** (the attempt closes irreversibly, and a refused write
  is reported instead of silently doing nothing), a confirmed **Reset** that
  clears one attempt outright, and an **Audit** link per candidate that opens
  `SubmissionAudit`.
- **SubmissionAudit** — the incident timeline next to the numbered
  question-by-question breakdown, with the student's name in the header. A
  fill-in-the-blank answer is compared to `correct_text_answer` exactly as
  `submit_exam` grades it (trimmed, case-insensitive). Its header carries
  **Reset attempt** (see *Resetting an attempt* below), and a successful reset
  replaces the page with a short "attempt cleared" note linking back to the
  monitor, since there is nothing left to audit.
- **Analytics** — one row per exam: attempts, in progress, completed,
  disqualified, DQ rate (with a bar) and incidents, sorted most-flagged first so
  the exam that needs attention is at the top. Each title links to that exam's
  live monitor. The incident columns are windowed to the last 30 days
  (`WINDOW_DAYS`) because `proctoring_logs` only grows — an unbounded "all time"
  read would get slower every term — while attempts and scores come from
  `exam_submissions`, which is bounded by the roster.
- **Accounts (administrator only)** — the roster: every `profiles` row with the
  role it signs in with. A role is moved with a per-row select and an explicit
  **Save**, confirmed by a dialog that spells out what the new role can do before
  anything is written, and the administrator's own row carries no control at all
  (demoting yourself would revoke the page that undoes it). A refused write is
  reported in the page banner with a **Try again** rather than a toast that
  disappears — and the write asks for the row back, because a policy-filtered
  `UPDATE` matches zero rows while PostgREST still reports success. **Add an
  account** goes through `admin-create-user`, the only way to mint a non-student
  login. See *Role-based rendering* under Design decisions for why nothing else in
  the console is branched on role.

## Loading behaviour (no blocking loaders)

The console never replaces itself with a spinner. Three rules:

1. **The shell paints first.** `App.tsx` renders `AppShell` (sidebar + page area)
   on the very first frame; the session check only decides what goes *inside* the
   page area, and while it runs the sidebar's profile tile shows a skeleton. The
   old `RequireSupervisor` swapped the whole app — chrome included — for a
   `min-h-screen` "Loading…" element, so the first paint looked like a hang and
   the layout re-mounted on every auth event.
2. **Every panel owns its own fetch, loading flag and error.** `DashboardOverview`,
   `ExamManager`, `LiveMonitor`, `SubmissionAudit` and `Analytics` each fetch what
   they render, so a slow query only freezes the panel that needs it. Placeholders
   are skeletons from `components/ui/skeleton.tsx` (`animate-pulse` +
   `bg-slate-800/50`) shaped like the real content — metric cards, chart panels,
   candidate cards, feed rows, table rows, audit panels — so nothing jumps when the
   data lands.
3. **Errors sit next to the content, not instead of it.** A failed read renders an
   inline banner (with **Try again** on the dashboard and analytics pages) *above*
   the panels, which stay mounted and keep whatever did load. A failed read is never
   disguised as an empty list: the roster, the dashboard and the analytics table all
   say what went wrong. The live monitor's incident feed and its `id -> name` map
   used to be the exception — `useLiveIncidentFeed` and `useAccountNames` swallowed
   the error and reported "No incidents reported yet." over a broken query, which is
   exactly the misreading this rule exists to prevent; both now return an `error`
   that the monitor renders (the roster falls back to a short id meanwhile, and says
   so).

Realtime is treated as a bonus, never a gate: `useRealtimeStatus` reports
`connecting` / `connected` / `reconnecting` through one shared copy map
(`REALTIME_STATUS_COPY`), which drives both the sidebar footer pill and the live
monitor's header badge — so the two can never disagree, and the badge can no
longer claim "Live sync active" on a dead socket. Each state carries a tooltip
explaining that on-demand loading still works; nothing about the socket can hold
up a render.

Accessibility note: skeleton blocks are `aria-hidden` and each group carries one
`role="status"` announcement ("Loading candidates", "Loading incidents", …), so a
screen reader hears one sentence instead of dozens of empty boxes.
`index.css` already disables the pulse under `prefers-reduced-motion`.

## Question types

| Type | Stored as | Graded by |
| --- | --- | --- |
| `multiple_choice` | `options` jsonb + `correct_option` index | `submit_exam`: the stored index equals `correct_option` |
| `fill_in_the_blank` | `correct_text_answer` (no options) | `submit_exam`: `lower(btrim(answer)) = lower(btrim(correct_text_answer))` |

A `questions_answer_key_shape` check constraint allows exactly one answer key per
row, so the form always sends `correct_option: null` for a typed question and
`correct_text_answer: null` for a choice one.

Editing an exam updates its questions **in place** (the row ids survive), because
`exam_submissions.answers` is keyed by question id and `submit_exam` joins on it —
replacing the rows would orphan every answer already recorded. For the same
reason the form offers no delete on a question that already exists; add a new
question instead, or create a new exam.

## Design decisions
- **Token system, not raw slate.** `tailwind.config.ts` defines
  `surface` / `surface-raised` / `surface-inset` / `accent` (teal, not
  green) / `alert` (red) / `warn` / `ok` on top of the base palette. The
  brief asked for a slate/zinc enterprise theme with color-coded status —
  this reads as a security operations console rather than a generic dark
  SaaS dashboard, while still matching every requirement in the brief
  (dark, high-density, badges, glow indicator).
- **Realtime connection pill polls the supported accessors.** `@supabase/realtime-js`
  dropped the public `onOpen` / `onClose` / `onError` callbacks, so
  `useRealtimeStatus` polls `realtime.isConnected()` every 3s instead — a channel
  can report `SUBSCRIBED` while the socket underneath is mid-reconnect.
- **Incident feed scoped client-side.** `proctoring_logs` has no
  `exam_id` column (only `submission_id`), so the live feed filters
  against the exam's current submission IDs in the subscription callback
  rather than re-subscribing on every roster change, which would drop
  buffered rows.
- **Grading stays visible to supervisors only.** `SubmissionAudit` reads
  `correct_option` directly: `questions` is supervisor-readable and has **no**
  student SELECT policy at all, so the answer key can only reach a supervisor's
  browser. Students read the `questions_public` view (published exams, no answer
  key) from the Flutter app.
- **The console cannot forge a score.** `score`, `status` and `submitted_at` are
  written server-side — `submit_exam` grades from the stored answers and
  `register_violation` applies the 3-strike rule — so the roster shows the
  server's numbers. The console's own write path is a supervisor intervention
  (the confirmed **Disqualify**), which `submissions_update_supervisor` allows.
- **Names, not uuids.** `useAccountNames` maps `profiles.id -> full_name` — falling
  back to the email, then "Unknown account" — and refetches on any `profiles` change,
  so the roster and the incident feed read like a class list. RLS is what makes
  that safe: only staff (admin, lecturer or supervisor) may read every profile row.
- **Role-based rendering is the exception, not the rule.** The dashboard, exams,
  monitoring, analytics and the audit trail are `is_staff()` screens that all
  three staff roles share, so the *only* branch on `profile.role` in the console
  is the Accounts entry and its route — `lib/roles.ts` holds the vocabulary from
  `public.user_role` and the single predicate (`canManageAccounts`) that the
  sidebar, the route fence and the page all ask. The Flutter app splits the same
  way (`RoleGate` -> `SupervisorExamPickerPage` / `AdminDashboardPage`). Rendering
  is never the boundary: `profiles_admin_all` is `is_admin()` and
  `profiles_guard_role_change` raises `42501` for anyone below admin, so a fence
  bypassed in devtools still gets a refusal from PostgREST instead of a granted
  write.
- **Empty is not an error.** Every panel distinguishes "nothing has happened yet"
  from "the read failed": the roster, the incident feed and the dashboard all
  surface the underlying message with a retry instead of an empty list.
- **A session this console cannot use is ended, not left dangling.** `useAuth`
  reads `public.profiles` with `maybeSingle()`, so an account whose row does not
  exist is an ordinary zero-row answer — `profiles_select_own_or_staff` filters it
  out at HTTP `200` — instead of the `PGRST116` error `.single()` turned it into.
  Every outcome then becomes a sentence: the credentials (`Incorrect email or
  password.`, deliberately one wording for a wrong password and an email that does
  not exist, since the server will not say which), a missing row, a *refused* read
  (`42501` / `PGRST301`), or a student account. A row-less, refused or non-staff
  account is also signed out: a login form drawn over a live session is a form
  that can never succeed, because every retry re-fails and every refresh loops the
  same message. That is `RoleGate`'s *Sign out* escape hatch in the Flutter app,
  done for the user here because this console shows a login screen rather than a
  dedicated error page. Only a *connection* failure keeps the session, since
  re-reading it can actually succeed. A *deployment* fault keeps the session too
  — a missing schema/table grant (`permission denied for schema public`) or a
  `public.profiles` the API has never seen — because the account is fine and the
  fix happens server-side: signing the person out would only throw away a valid
  session for a database an administrator is about to repair.
- **Signing out by hand obeys the same rule as signing out automatically.** The
  footer control is a thin layer over `useAuth().signOut`, which *reports* rather
  than assumes: supabase-js clears the stored session only once its revoke call
  has succeeded, so a refusal or a dropped connection means the session is still
  live on the device. The console therefore stays where it is and says so in the
  footer — inline, not in a toast that would vanish before it was read, and not
  by painting the login form over a live session, which is the trap the bullet
  above describes. There is no `navigate()` anywhere in the path: `profile` going
  null is what renders `LoginPage`, so the button works from any route.
- **Visual ping instead of a toast — in the live feed.** New incidents flash the
  feed header background briefly (0.5s) instead of stacking toasts, since a
  supervisor's eyes are expected to already be on this panel during a live
  session. A *user-initiated* write is the exception: the ExamManager publish
  toggle and the **Reset** actions confirm with one short-lived toast (`components/ui/toast.tsx` — a
  single slot, never a stack), because there the supervisor is looking at the row
  they just clicked and the action is atomic rather than a stream. A sound-effect
  toggle is stubbed as a further step — wire an `<audio>` element behind a Switch
  in the header once you have an alert sound asset.
- **A refused write has to be visible.** `exams_update_owner` lets only the
  supervisor who created an exam write to it, and PostgREST reports a
  policy-filtered `UPDATE` as *success* while matching **zero rows**. The publish
  toggle therefore asks for the written row back (`.select("id")`) and treats an
  empty result as a failure — that is the other half of the optimistic badge:
  without a real rollback, "Published" would only be a guess.

## Resetting an attempt

A supervisor can clear one student's attempt — **Reset** on the monitor's roster
card, or **Reset attempt** on the submission audit. It is the counterpart to
**Disqualify**: disqualify closes an attempt and *keeps* the evidence, reset
deletes the attempt and the evidence with it, and afterwards the student can
start the exam again. It exists for the crashed laptop, the mis-assigned retake
and the test run that must not stay on the roster.

The confirmation is a real dialog (`components/ui/confirm-dialog.tsx`, the only
modal in the app) rather than `window.confirm`, because a destructive action can
name its own blast radius: the incident count, the stored answers, the snapshot
images, and the fact that a mid-exam student is logged out of it. The dialog
stays open while the write is in flight — both buttons disable, the confirm
button shows a spinner — so a slow request never looks like a dead click.

`useResetSubmission` does its three steps in the only order that works:

1. **Read the evidence first.** The attempt's `proctoring_logs` rows go with the
   submission (FK cascade), and `snapshot_url` is the only record of which
   objects in `proctor-snapshots` belonged to it: lost, they could never be
   cleaned up. Object paths are derived from the bucket segment of the URL, so
   both the `/object/public/...` and `/object/sign/...?token=...` shapes work,
   and a URL that is not ours (a hand-seeded placeholder) is skipped rather than
   failing the whole reset.
2. **Delete the submission** with `.select("id")`, so a DELETE that RLS filtered
   out — PostgREST reports it as *success* while matching zero rows — is told
   apart from a real one and reported, instead of being toasted as a reset that
   never happened. Same zero-row check as the publish toggle, for the same
   reason.
3. **Purge the stills** through the Storage API; deleting the `storage.objects`
   rows in SQL would drop the metadata and leave the blob in the bucket. This
   step is best effort on purpose: the attempt is already gone at that point, so
   a Storage failure is surfaced as a *warning* ("…but N snapshot images could
   not be removed") instead of a "the reset failed" that would be a lie, or a
   silence that would leave an orphaned image in a public bucket.

Schema side (`../supabase/schema.sql` — re-run it to pick these up; both are
`drop policy if exists` + `create policy`, so the documented idempotent re-run
applies them):

- `submissions_delete_supervisor` is the new DELETE policy: the exam's author or
  a supervisor, never the student. A student who could delete their own row could
  erase a graded attempt — and the evidence behind a disqualification — and then
  simply start the exam again.
- `proctoring_logs` needs no twin policy: referential actions run outside row
  security, which is exactly why the one policy on the parent is enough to let
  the evidence go with the attempt.
- `Proctor snapshots supervisor purge` is the supervisor-only Storage DELETE that
  step 3 needs. It deliberately cannot be anchored to the submission folder,
  because by then that folder no longer resolves to a submission row.

The roster refreshes through `useExamSubmissions().reload()` rather than waiting
for a realtime DELETE that the `exam_id` filter may never deliver — the row is
gone on the server the moment the supervisor clicked, and the card should
disappear because of that, not eventually. `useLiveIncidentFeed` now handles
deleted rows too, so an incident belonging to an attempt that no longer exists
cannot linger in the feed.

## Bundle

`vite.config.ts` splits the vendor trees into their own chunks (`react`,
`charts`, `supabase`) via `build.rollupOptions.output.manualChunks`. Everything
used to land in a single ~850 kB chunk, which Vite warned about, so any one-line
page change invalidated React, Recharts, d3, lodash and the Supabase client along
with it. The production build is now four chunks — app ~83 kB, react ~164 kB,
supabase ~227 kB, charts ~384 kB (all under the 500 kB warning threshold) — so a
deploy re-downloads only the small app chunk while the vendor chunks stay cached.

## Incident labels

`lib/incidents.ts` is the single `action_type -> label` map (`incidentLabel()`),
used by the dashboard's breakdown chart, the live monitor's feed and the
submission audit. It used to be copy-pasted into all three pages, so adding a
violation type meant remembering three files.

## Not yet wired (left as clearly-marked next steps)
- Snapshot images assume `snapshot_url` is a public or signed Supabase
  Storage URL. The mobile app uploads violation stills to the public
  `proctor-snapshots` bucket and writes the resulting URL onto the log row
  (see `../supabase/schema.sql` §6); if you ever flip that bucket to private,
  sign URLs server-side instead.
- Deleting a question that already exists (see "Question types" above: recorded
  answers reference the row by id). A safe version would delete only when no
  `exam_submissions.answers` key matches, and otherwise offer to archive it.
- Multiple accepted wordings for a fill-in-the-blank answer. One
  `correct_text_answer` per row today; a `text[]` (or a tolerance table) would let
  "HyperText Transfer Protocol" and "HTTP" both count.
- Sound-effect toggle for new incidents.
