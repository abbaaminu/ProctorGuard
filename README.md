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
  `supabase/schema.sql`.
- `.github/workflows/keep_alive.yml` pings the Supabase REST API twice a week;
  configure its repository secrets or remove the workflow on a paid plan.

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
