-- =====================================================================
-- PROCTORGUARD - LECTURERS MAY RESET AN ATTEMPT (upgrade path)
--
-- Widens the *reset* tier from `is_exam_supervisor()` (admin, supervisor) to
-- `is_attempt_resetter()` (admin, supervisor, lecturer), so the lecturer who
-- wrote a paper can repair an attempt on it - the wrong answer key, a
-- disqualification aimed at the wrong candidate.
--
-- WHY THIS FILE EXISTS SEPARATELY
--   The three policies the console's "Reset attempt" rides on are created by
--   `secure_exam_access_and_deadlines.sql` and `session_reset_logs.sql` with
--   `create policy`, which is *not* idempotent: a live project has to have those
--   dropped and recreated to pick up the wider predicate. Re-running either of
--   those files does exactly that, but it is also what a project may have done
--   before this change. This file is the upgrade path, and section 2 + section 5
--   of `schema.sql` carry the same DDL for fresh installs.
--
-- WHAT IT DOES NOT CHANGE
--   * `is_exam_supervisor()` itself, and therefore `submissions_update_supervisor`
--     (a status change or an after-the-fact re-grade) and `logs_select_own_or_supervisor`
--     (the incident feed): a lecturer may not rewrite a row in place, and this
--     file grants no new *intervention* power.
--   * `register_violation()` / `submit_exam()`, whose `is_exam_supervisor()`
--     calls decide who may act on somebody else's attempt.
--   * Reads. `submissions_select_own_or_supervisor` is already `is_staff()`, so a
--     lecturer already sees the roster the reset control sits on.
--
-- SAFETY
--   * Safe to re-run: the function is `create or replace`, and each policy is
--     dropped by name before being recreated. The audit policy is created inside
--     a guard, because `session_reset_logs` only exists once
--     `session_reset_logs.sql` has been applied - and `create policy` on a table
--     that is not there fails with `42P01`.
--   * Additive only: no table, column or row is touched. Nobody loses access -
--     the new predicate is the old one plus one role.
--   * Apply after `secure_exam_access_and_deadlines.sql` and
--     `session_reset_logs.sql` (the file name sorts after both).
--   * Verify with:
--       select public.is_attempt_resetter();            -- as the lecturer, true
--       select polname, pg_get_expr(polqual, polrelid)
--       from pg_policy where polname = 'submissions_delete_supervisor';
--     the expression should read `is_attempt_resetter()`.
-- =====================================================================

create or replace function public.is_attempt_resetter()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('admin', 'supervisor', 'lecturer')
  );
$$;

-- 1. The DELETE that removes the attempt (answers and incident rows follow by
--    `on delete cascade`).
drop policy if exists "submissions_delete_supervisor" on public.exam_submissions;
create policy "submissions_delete_supervisor"
  on public.exam_submissions for delete
  to authenticated
  using (public.is_attempt_resetter());

-- 2. The Storage purge of the snapshots that belonged to it. Anchored to the
--    bucket, not to the (already deleted) submission folder - see schema.sql.
drop policy if exists "Proctor snapshots supervisor purge" on storage.objects;
create policy "Proctor snapshots supervisor purge"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'proctor-snapshots'
    and public.is_attempt_resetter()
  );

-- 3. The audit row that records the reset. Guarded: the table arrives with
--    `session_reset_logs.sql`, and a project that has not applied that file yet
--    still gets the two policies above. (An `if`, not an early return: a DO block
--    body is an anonymous function, and this keeps the file valid on every
--    supported server without relying on that.)
do $$
begin
  if to_regclass('public.session_reset_logs') is not null then
    execute 'drop policy if exists "session_reset_logs_insert_supervisor" '
         || 'on public.session_reset_logs';
    execute 'create policy "session_reset_logs_insert_supervisor" '
         || 'on public.session_reset_logs for insert '
         || 'to authenticated '
         || 'with check (public.is_attempt_resetter() and actor_id = auth.uid())';
  end if;
end $$;
