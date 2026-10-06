-- =====================================================================
-- PROCTORGUARD - SESSION RESET LOGS (THE AUDIT TRAIL FOR "Reset attempt")
-- Adds `public.session_reset_logs`: one row per attempt a supervisor or admin
-- clears, naming the attempt, the student, the exam, how much evidence went with
-- it and who did it.
--
-- WHY THE TABLE EXISTS
--   Reset is the one destructive staff action in the console: it deletes the
--   `exam_submissions` row (which cascades to the student's answers and every
--   `proctoring_logs` incident row) and then purges the snapshot objects that
--   belonged to it. Until now that left no trace on the server beyond its own
--   absence. This table is written by the same call that does the deleting
--   (`DashboardRepositoryImpl.resetSubmission()`), so "Aisha's attempt is gone"
--   always has an answer to "gone because somebody cleared it, or because it
--   was never there".
--
-- WHY THIS FILE EXISTS SEPARATELY
--   `schema.sql` creates the table with `create table if not exists`, so a
--   re-run of that file is a no-op on a database that already has it - which is
--   every installation that predates this change. Those would keep accepting
--   resets while the client's audit insert failed with
--   `42P01 relation "public.session_reset_logs" does not exist`
--   (reported in the console as `auditWarning`). This file is the upgrade path.
--   `schema.sql` section 7 carries the same DDL for fresh installs.
--
--   Keep the two copies in step: `mobile/test/schema_contract_test.dart` fails
--   if `schema.sql` stops matching the columns the Flutter repository inserts.
--
-- SAFETY
--   * Safe to re-run: `create table if not exists` for the table, `enable row
--     level security` is idempotent, and both policies are dropped by name
--     before being recreated.
--   * Additive only: nothing existing is altered, and no data is touched. The
--     table starts empty on a project that has been live for a while - resets
--     performed before this migration are not reconstructable, and are simply
--     absent from the trail.
--   * Written by the client through PostgREST, so it needs the ordinary
--     privileges from section 0 of `schema.sql`. A project that predates that
--     section should run supabase/migrations/grant_api_roles_public_schema.sql
--     as well.
--   * Verify with:
--       select count(*) from public.session_reset_logs;
--       select * from public.session_reset_logs order by created_at desc limit 5;
--     after clearing one attempt from the supervisor console: the newest row
--     should name that attempt, carry the actor the database derived from the
--     caller's JWT, and be the only one there.
-- =====================================================================

create table if not exists public.session_reset_logs (
  id              uuid primary key default uuid_generate_v4(),
  submission_id   uuid not null,
  student_id      uuid not null,
  exam_id         uuid not null,
  incidents       integer not null default 0 check (incidents >= 0),
  snapshots       integer not null default 0 check (snapshots >= 0),
  storage_warning text,
  actor_id        uuid not null default auth.uid(),
  created_at      timestamptz not null default now()
);

alter table public.session_reset_logs enable row level security;

drop policy if exists "session_reset_logs_select_staff" on public.session_reset_logs;
drop policy if exists "session_reset_logs_insert_supervisor" on public.session_reset_logs;

-- Read: the staff tier, matching the visibility of the attempts and incident
-- rows themselves (`submissions_select_own_or_supervisor`,
-- `logs_select_own_or_supervisor`). Students read nothing: the row names the
-- member of staff who ran the reset.
create policy "session_reset_logs_select_staff"
  on public.session_reset_logs for select
  to authenticated
  using (public.is_staff());

-- Write: the tier that may delete an attempt at all (`is_exam_supervisor()` is
-- what `submissions_delete_supervisor` uses) and only in the caller's own name -
-- `actor_id` defaults to auth.uid() and this check rejects a client that tries to
-- name somebody else as the actor.
create policy "session_reset_logs_insert_supervisor"
  on public.session_reset_logs for insert
  to authenticated
  with check (public.is_exam_supervisor() and actor_id = auth.uid());

-- Deliberately no UPDATE and no DELETE policy: the trail is append-only for
-- every client, admin included.
create index if not exists idx_session_reset_logs_created_at
  on public.session_reset_logs(created_at desc);
create index if not exists idx_session_reset_logs_exam_id
  on public.session_reset_logs(exam_id);
