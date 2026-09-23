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
                        useLiveIncidentFeed, useExamSubmissions
  pages/               Login, DashboardOverview, ExamManager,
                        LiveMonitor, SubmissionAudit
```

## Design decisions
- **Token system, not raw slate.** `tailwind.config.ts` defines
  `surface` / `surface-raised` / `surface-inset` / `accent` (teal, not
  green) / `alert` (red) / `warn` / `ok` on top of the base palette. The
  brief asked for a slate/zinc enterprise theme with color-coded status —
  this reads as a security operations console rather than a generic dark
  SaaS dashboard, while still matching every requirement in the brief
  (dark, high-density, badges, glow indicator).
- **Realtime connection pill watches the socket, not a channel.** A
  Postgres changes channel can report `SUBSCRIBED` while the underlying
  WebSocket is reconnecting after a network blip — `useRealtimeStatus`
  listens to `supabase.realtime.onOpen/onClose/onError` directly.
- **Incident feed scoped client-side.** `proctoring_logs` has no
  `exam_id` column (only `submission_id`), so the live feed filters
  against the exam's current submission IDs in the subscription callback
  rather than re-subscribing on every roster change, which would drop
  buffered rows.
- **Grading stays visible to supervisors only.** `SubmissionAudit` reads
  `correct_option` directly since RLS should already restrict the raw
  `questions` table to supervisors + published-exam students (mirror the
  policy from the Flutter app's schema) — never expose that query path to
  a student-facing client.
- **Visual ping instead of a toast.** New incidents flash the feed
  header background briefly (0.5s) instead of stacking toasts, since a
  supervisor's eyes are expected to already be on this panel during a
  live session. A sound-effect toggle is stubbed as a further step —
  wire an `<audio>` element behind a Switch in the header once you have
  an alert sound asset.

## Not yet wired (left as clearly-marked next steps)
- Snapshot images assume `snapshot_url` is a public or signed Supabase
  Storage URL. The mobile app now uploads violation stills to the public
  `proctor-snapshots` bucket and writes the resulting URL onto the log row
  (see `../supabase/schema.sql` §6); if you ever flip that bucket to private,
  sign URLs server-side instead.
- `ExamManager`'s edit action is a stub (`Pencil` button, no handler yet).
- Sound-effect toggle for new incidents.
