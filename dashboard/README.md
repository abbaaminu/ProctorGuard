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

`../supabase/seed.sql` then loads mock testing data: 1 supervisor + 2 student
profiles, 2 published exams with 5 questions each, and one disqualified
submission with 3 proctoring logs. Log in with
`supervisor@proctor.test` / `Proctor123!` to see it in this console.

## Structure
```
src/
  components/ui/       Badge, Card, Button — shadcn-style primitives
  components/layout/   Sidebar (nav + realtime pill + profile tile), AppShell
  hooks/               useAuth (role guard), useRealtimeStatus,
                        useLiveIncidentFeed, useExamSubmissions,
                        useAccountNames (id -> "Aisha Bello")
  pages/               Login, DashboardOverview, ExamManager,
                        LiveMonitor, SubmissionAudit
```

## What each page does

- **DashboardOverview** — live metrics (`Live exams now` counts exams with an
  `ongoing` submission, not merely published ones), the 24h incident breakdown
  and the completions/disqualifications timeline. A failed read is shown with a
  **Try again**, instead of quietly rendering zeros.
- **ExamManager** — create an exam with its question bank, publish/unpublish,
  delete, and edit an existing exam's metadata (title + duration).
- **LiveMonitor** — the roster for one exam with per-candidate flag counts, a
  confirmed **Disqualify** (the attempt closes irreversibly, and a refused write
  is reported instead of silently doing nothing) and an **Audit** link per
  candidate that opens `SubmissionAudit`.
- **SubmissionAudit** — the incident timeline next to the question-by-question
  breakdown, with the student's name in the header.

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
- **Names, not uuids.** `useAccountNames` maps `users.id -> name` and refetches on
  any `users` change, so the roster and the incident feed read like a class list.
  RLS is what makes that safe: only a supervisor may read every profile row.
- **Empty is not an error.** Every panel distinguishes "nothing has happened yet"
  from "the read failed": the roster, the incident feed and the dashboard all
  surface the underlying message with a retry instead of an empty list.
- **Visual ping instead of a toast.** New incidents flash the feed
  header background briefly (0.5s) instead of stacking toasts, since a
  supervisor's eyes are expected to already be on this panel during a
  live session. A sound-effect toggle is stubbed as a further step —
  wire an `<audio>` element behind a Switch in the header once you have
  an alert sound asset.

## Not yet wired (left as clearly-marked next steps)
- Snapshot images assume `snapshot_url` is a public or signed Supabase
  Storage URL. The mobile app uploads violation stills to the public
  `proctor-snapshots` bucket and writes the resulting URL onto the log row
  (see `../supabase/schema.sql` §6); if you ever flip that bucket to private,
  sign URLs server-side instead.
- Question *editing* for an exam that already exists. `ExamManager` can change an
  exam's title and duration, but not its questions: recorded answers reference
  those rows by id (`submit_exam` joins on them), so replacing them would orphan
  every answer already stored. Add a per-question edit that updates rows in place
  instead of deleting and re-inserting.
- Sound-effect toggle for new incidents.
