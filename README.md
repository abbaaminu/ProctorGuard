# Proctor

AI exam proctoring system: a Flutter mobile app for students and a React
supervisor dashboard, sharing one Supabase backend.

```
proctor/
  mobile/       Flutter app (students take exams; on-device ML Kit
                face-detection proctoring logs violations)
  dashboard/    React + Vite web app (supervisors build exams, monitor
                live sessions, audit submissions)
  supabase/
    schema.sql  Single source of truth for both apps: tables, RLS
                policies, and RPCs. Run this once per environment.
```

## Getting started
1. Create a Supabase project, run `supabase/schema.sql` in its SQL editor,
   then optionally `supabase/seed.sql` to load demo users, exams and
   questions (see the header of that file for the demo logins).
2. Mobile: see `mobile/README.md` (`flutter pub get`, then `flutter run
   --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...`).
3. Dashboard: see `dashboard/README.md` (`npm install`, copy
   `.env.example` to `.env.local`, `npm run dev`).

Both apps read/write the same tables, so a submission a student makes in
`mobile` shows up live in `dashboard`'s monitor view via Supabase Realtime.

## Pushing to GitHub
From this folder:
```bash
git init
git add .
git commit -m "Initial commit: mobile + dashboard + shared schema"
git branch -M main
git remote add origin <your-empty-github-repo-url>
git push -u origin main
```
