# Proctor

AI exam proctoring system: a Flutter mobile app for students (it also carries the
admin dashboard) and a React staff dashboard, sharing one Supabase backend.

```
proctor/
  mobile/       Flutter app (students take exams; on-device ML Kit
                face-detection proctoring logs violations)
  dashboard/    React + Vite web app (supervisors build exams, monitor
                live sessions, audit submissions)
  supabase/
    schema.sql  Single source of truth for both apps: tables, RLS
                policies, and RPCs. Run this once per environment.
    functions/  admin-create-user — the Edge Function that creates staff
                logins. It is the only place a service_role key is used,
                and it never leaves Supabase's servers. The
                `tsconfig.json` / `package.json` beside it are dev-only:
                types for the editor, not part of a deployment.
```

Roles live in the `public.user_role` enum: `student`, `lecturer`, `supervisor`
and `admin`. Students take exams in the mobile app, `lecturer` and `supervisor`
sign into this console (`is_staff()`), and `admin` additionally gets the roster and
role-management screen — in the mobile app, and as the dashboard's one admin-only
page (`/accounts`). Every signed-in account leaves the console from the sidebar
footer's **Sign out**, which ends the session and puts the login form back.

## Getting started
1. Create a Supabase project, run `supabase/schema.sql` in its SQL editor,
   then optionally `supabase/seed.sql` to load demo users, exams and
   questions (see the header of that file for the demo logins).
2. Deploy the account-creation function — `supabase functions deploy
   admin-create-user` (needs the Supabase CLI linked to the project, or paste
   `supabase/functions/admin-create-user/index.ts` into the dashboard's Edge
   Functions editor). `SUPABASE_URL`, `SUPABASE_ANON_KEY` and
   `SUPABASE_SERVICE_ROLE_KEY` are injected automatically, so there is nothing
   to configure; without it only the seeded logins exist.
3. Mobile: see `mobile/README.md` (`flutter pub get`, then `flutter run
   --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...`).
4. Dashboard: see `dashboard/README.md` (`npm install`, copy
   `.env.example` to `.env.local`, `npm run dev`).

Both apps read/write the same tables, so a submission a student makes in
`mobile` shows up live in `dashboard`'s monitor view via Supabase Realtime.

## Production checklist

`supabase/migrations/` holds the same statements packaged for a project that is
already deployed, where re-running all of `schema.sql` is too blunt. Run the
migrations you have not run yet — each one says what it does and how to verify
it. Beyond that:

- [ ] **Turn off public sign-ups** (Supabase → Authentication → Sign In /
      Providers). The schema lets a self-provisioned account create *only* a
      `student` profile row (`profiles_insert_self_student` forces the role
      server-side), and the `profiles_guard_role_change` trigger makes
      `profiles.role` immutable for every caller below `admin` — so it cannot
      self-promote. But an open sign-up form still lets strangers into the exam
      portal. Create the first staff accounts yourself (or invite them, then set
      their `role` in the SQL editor as `postgres`); after that, use the app's
      Admin Dashboard. RLS rejects `role in ('admin','lecturer','supervisor')`
      written from a client, so a staff row written by hand has to come from the
      SQL editor or the Edge Function — not from the Flutter/React apps.
- [ ] **Give the API roles their privileges on `public`** on any project created
      before §0 of `schema.sql` existed. Without them PostgREST answers every
      request with `401 {"code":"42501","message":"permission denied for schema
      public"}` *before* a policy is looked at: sign-in still succeeds (GoTrue
      never touches `public`), and the console then reports that it cannot read
      profiles, for every account. Run
      `supabase/migrations/grant_api_roles_public_schema.sql` once in the SQL
      editor — a fresh `schema.sql` includes the same statements.
- [ ] **Deploy `admin-create-user`** (`supabase functions deploy admin-create-user`).
      It is the only path that mints a staff login: it re-reads the caller's JWT
      against `profiles` with the anon key, refuses anything that is not an
      `admin`, and only then switches to the `service_role` key — which never
      reaches a client. Skip it and the Admin Dashboard says so — the repository
      turns the 404 into "The admin-create-user function is not deployed on this
      project" instead of pretending the create failed.
- [ ] **Client keys only.** Dashboard: `VITE_SUPABASE_URL` +
      `VITE_SUPABASE_ANON_KEY`. Mobile: `SUPABASE_URL` +
      `SUPABASE_PUBLISHABLE_KEY` (via `mobile/run_app.ps1` / `build_apk.ps1`).
      Never a `service_role` / `sb_secret_` key — it bypasses every policy.
- [ ] **Decide the `proctor-snapshots` bucket's visibility.** It ships *public* so
      the console can render evidence with a plain `<img>` (the object paths are
      unguessable submission UUIDs). If violation stills are sensitive, flip the
      bucket to private and sign URLs server-side in the console.
- [ ] **Keep the free-tier project awake.** `.github/workflows/keep_alive.yml`
      pings the REST API twice a week; set the `SUPABASE_URL` and `SUPABASE_KEY`
      repository secrets, or delete the workflow if you are on a paid plan.
- [ ] **Verify both builds.** `cd mobile && flutter analyze && flutter test`, then
      `cd dashboard && npm run build`.
- [ ] **Deploy the dashboard with the right Vercel settings.** The Vercel project's
      **Root Directory must be `dashboard`**: that is what gives the build a
      `package.json` to run and what makes `dashboard/vercel.json` apply (it pins
      Build Command `npm run build` and Output Directory `dist` — the Vite
      defaults, stated explicitly so a mis-detected framework preset cannot
      change them). Its SPA rewrite sends unknown paths to `index.html`, so a hard
      refresh on `/exams/:id/monitor` or `/submissions/:id` loads the console
      instead of Vercel's 404. Static files still win over that rewrite (Vercel
      resolves the file system *before* the rewrites phase), so `/assets/*.js` and
      `/icon.png` are unaffected. Also set `VITE_SUPABASE_URL` and
      `VITE_SUPABASE_ANON_KEY` as project environment variables —
      `src/lib/supabase.ts` throws at boot without them.

## Verifying a change

A fresh clone has never had its dependencies installed, so run `flutter pub get`
once (and `npm install` in `dashboard/` and `supabase/functions/`) **before** the
checks below — with an empty pub cache `flutter analyze` reports hundreds of
phantom errors (`Target of URI doesn't exist: 'package:flutter_riverpod/...'`)
that are all just missing packages, not broken code.

```
cd mobile   && flutter pub get && flutter analyze && flutter test   # 256 tests, no device needed
cd dashboard && npm install && npm run build                       # tsc -b && vite build
cd supabase/functions && npm install && npm run typecheck          # the Deno Edge Function
```

The last line is the only check the Edge Function has: this repo carries no Deno
toolchain, so `supabase/functions/tsconfig.json` (`"types": ["deno"]` +
`npm-imports.d.ts`) is what lets an editor, or `tsc`, see `Deno.serve` /
`Deno.env` and the `npm:` import inside `admin-create-user/index.ts` at all — the
same trick `dashboard/tsconfig.node.json` plays for `path` / `__dirname`. It
type-checks only; `supabase functions deploy` still bundles the function with
Deno.

The Flutter suite pins the client↔database contract (`mobile/test/schema_contract_test.dart`:
RPC names, argument names — including the `register_violation` idempotency key and
client timestamp — and the `action_type` values), so a schema change that breaks the
app fails there rather than at runtime. It reads `supabase/schema.sql` directly for
that half of the check, so re-run `flutter test` after editing the schema. The same
file carries the role contract: the `student`/`lecturer`/`supervisor`/`admin` values
of `public.user_role`, the `profiles` roster read (oldest first), the role-change
PATCH, and the `admin-create-user` request/response shapes, so a renamed column or
a moved endpoint fails in CI instead of on someone's phone.

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
