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
  delete, and edit an existing exam (title, duration *and* its questions).
  Each draft question is numbered ("Question 2 of 5"), has a
  **Multiple choice / Fill in the blank** selector, and shows either the option
  list with its correct-option radio or the accepted answer for a typed question.
- **LiveMonitor** — the roster for one exam with per-candidate flag counts, a
  confirmed **Disqualify** (the attempt closes irreversibly, and a refused write
  is reported instead of silently doing nothing) and an **Audit** link per
  candidate that opens `SubmissionAudit`.
- **SubmissionAudit** — the incident timeline next to the numbered
  question-by-question breakdown, with the student's name in the header. A
  fill-in-the-blank answer is compared to `correct_text_answer` exactly as
  `submit_exam` grades it (trimmed, case-insensitive).

## Loading behaviour (no blocking loaders)

The console never replaces itself with a spinner. Three rules:

1. **The shell paints first.** `App.tsx` renders `AppShell` (sidebar + page area)
   on the very first frame; the session check only decides what goes *inside* the
   page area, and while it runs the sidebar's profile tile shows a skeleton. The
   old `RequireSupervisor` swapped the whole app — chrome included — for a
   `min-h-screen` "Loading…" element, so the first paint looked like a hang and
   the layout re-mounted on every auth event.
2. **Every panel owns its own fetch, loading flag and error.** `DashboardOverview`,
   `ExamManager`, `LiveMonitor` and `SubmissionAudit` each fetch what they render,
   so a slow query only freezes the panel that needs it. Placeholders are skeletons
   from `components/ui/skeleton.tsx` (`animate-pulse` + `bg-slate-800/50`) shaped
   like the real content — metric cards, chart panels, candidate cards, feed rows,
   table rows, audit panels — so nothing jumps when the data lands.
3. **Errors sit next to the content, not instead of it.** A failed read renders an
   inline banner (with **Try again** on the dashboard) *above* the panels, which
   stay mounted and keep whatever did load. A failed read is never disguised as an
   empty list: the roster, the incident feed and the dashboard all say what went
   wrong.

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
- Deleting a question that already exists (see "Question types" above: recorded
  answers reference the row by id). A safe version would delete only when no
  `exam_submissions.answers` key matches, and otherwise offer to archive it.
- Multiple accepted wordings for a fill-in-the-blank answer. One
  `correct_text_answer` per row today; a `text[]` (or a tolerance table) would let
  "HyperText Transfer Protocol" and "HTTP" both count.
- Sound-effect toggle for new incidents.
