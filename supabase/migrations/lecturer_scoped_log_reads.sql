-- =====================================================================
-- PROCTORGUARD - SCOPED EVIDENCE READS FOR THE PAPER'S LECTURER (upgrade path)
--
-- Who may read what was recorded *inside* a sitting:
--
--   * `proctoring_logs`   - the incident rows (the monitor's live feed).
--   * `session_reset_logs` - the audit rows written when an attempt is cleared.
--
-- Before this file both were asked of a role alone: the incident feed was
-- `is_exam_supervisor()` (admin, supervisor) and the reset trail was `is_staff()`
-- (admin, supervisor, lecturer). The result was wrong in *both* directions - a
-- lecturer's monitor showed an empty feed for a paper they had written, because
-- RLS filtered away evidence they authored the exam for, while any lecturer could
-- read every reset in the institution, including papers that are none of their
-- business.
--
-- This file makes both policies answer the same question:
--
--   own attempt  |  is_exam_supervisor()  |  owns_exam(<the row's exam>)
--
-- so a lecturer reads the evidence of their own papers, the intervention tier
-- keeps reading everything, and a student reads only their own rows.
--
-- WHAT IT DOES NOT CHANGE
--   * `submissions_select_own_or_supervisor` stays `is_staff()`: the roster a
--     monitor renders is deliberately readable by every staff member (a lecturer
--     may watch any sitting, see who is still working and who has finished). Only
--     the *evidence* is scoped.
--   * Writes: there is still no insert, update or delete policy on either table.
--     `register_violation()` and the console's reset remain the only writers.
--   * `is_attempt_resetter()` (who may *clear* an attempt) is untouched: the tier
--     that repairs a paper and the tier that reads its evidence are different
--     questions, and both now name the lecturer for the right reason.
--
-- SAFETY
--   * Safe to re-run: the function is `create or replace`, and each policy is
--     dropped by name before being recreated.
--   * ONE POLICY GETS NARROWER for lecturers: `session_reset_logs_select_staff`.
--     A lecturer keeps the resets of the exams they own (`exams.created_by`) and
--     loses the rest; admin and supervisor are unaffected. That reduction is the
--     point - see the header of
--     supabase/migrations/session_reset_logs.sql, where the same policy lives.
--   * The audit policy is created inside a guard, because `session_reset_logs`
--     only exists once `session_reset_logs.sql` (or section 7 of `schema.sql`)
--     has been applied and `create policy` on a missing table fails with 42P01.
--     `proctoring_logs` is part of the base schema, so it is not guarded.
--   * Apply after `secure_exam_access_and_deadlines.sql`,
--     `session_reset_logs.sql` and `staff_attempt_resets.sql` (the file name
--     sorts after all three).
--   * Verify with (as a lecturer who owns exam X, in the SQL editor's role
--     simulator):
--       select public.owns_exam('<exam X id>');            -- true
--       select public.owns_exam('<someone else''s exam>');  -- false
--       select polname, pg_get_expr(polqual, polrelid) from pg_policy
--        where polname in ('logs_select_own_or_supervisor',
--                          'session_reset_logs_select_staff');
--     both expressions should name `owns_exam`.
-- =====================================================================

create or replace function public.owns_exam(p_exam_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.exams
    where id = p_exam_id and created_by = auth.uid()
  );
$$;

-- 1. The incident feed. `proctoring_logs` carries no exam id of its own - it
--    hangs off `submission_id` - so the ownership test hops through the attempt.
--    That hop is the same one the student arm already made, so the row is still
--    fetched once for either reader.
drop policy if exists "logs_select_own_or_supervisor" on public.proctoring_logs;
create policy "logs_select_own_or_supervisor"
  on public.proctoring_logs for select
  to authenticated
  using (
    exists (
      select 1 from public.exam_submissions s
      where s.id = submission_id
        and (s.student_id = auth.uid() or public.owns_exam(s.exam_id))
    )
    or public.is_exam_supervisor()
  );

-- 2. The reset audit trail. Guarded: a project that has not applied
--    session_reset_logs.sql has no table to put this policy on.
do $$
begin
  if to_regclass('public.session_reset_logs') is not null then
    execute 'drop policy if exists "session_reset_logs_select_staff" '
         || 'on public.session_reset_logs';
    execute 'create policy "session_reset_logs_select_staff" '
         || 'on public.session_reset_logs for select '
         || 'to authenticated '
         || 'using (public.is_exam_supervisor() or public.owns_exam(exam_id))';
  end if;
end $$;