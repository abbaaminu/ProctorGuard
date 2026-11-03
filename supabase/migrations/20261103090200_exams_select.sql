-- =====================================================================
-- PROCTORGUARD - exams_select, EXPRESSED THROUGH THE NAMED RULE
-- Replaces the `exams_select` policy with the same three branches it already
-- had, one of which is now `public.student_can_access_exam(id)` instead of an
-- inline copy of the targeting rule.
--
-- WHY THIS FILE EXISTS
--   `strict_targeting_null_profiles.sql` put the strict rule in this policy and
--   nowhere else, so a student could not *see* an out-of-cohort paper but could
--   still start an attempt on it and read its questions - the two other checks
--   did not exist. The rule now has a name (`student_can_access_exam`), and this
--   file makes the policy ask for it, which is what keeps the three checks in
--   step: if the rule is ever corrected again, all three callers move with it
--   instead of one of them quietly keeping the old reading.
--
-- WHAT CHANGES
--   Nothing observable, for any caller:
--     * staff (`is_staff()`) still see every paper, published or not - an
--       invigilator opens sittings in every department and the supervisor
--       console's paper picker depends on it;
--     * an author still sees their own drafts (`created_by = auth.uid()`);
--     * a student still sees a published paper only when it is aimed at them -
--       cohort targeting stays *in this policy*, because this is the policy that
--       decides whether the paper appears in the student's list at all, and it is
--       the helper that now enforces it (published + faculty/department/level +
--       borrow list).
--
-- WHAT IT DELIBERATELY DOES NOT DO
--   * No schedule window. `starts_at` / `ends_at` are a separate question, asked
--     where an attempt begins (`submissions_insert_own_ongoing`) and one-sided
--     where questions are read (`questions_public`). Folded in here, a paper
--     would vanish from the student's own list the moment it closed, and their
--     history, their result and their evidence would have no paper to name - the
--     console would render an attempt pointing at a row the student cannot read.
--   * No `submissions` subquery: "may I see it" must not depend on whether an
--     attempt exists.
--   * No GRANT/REVOKE - a policy is not an object with an owner.
--
-- SAFETY
--   * Safe to re-run: `drop policy if exists` + `create policy`.
--   * PREREQUISITES: `public.is_staff()` (`schema.sql` §1) and
--     `public.student_can_access_exam(uuid)`
--     (`20261103090100_student_can_access_exam.sql`) - this file calls it, and
--     fails loudly if it is missing, which is the intended failure.
--   * APPLY ORDER: after `strict_targeting_null_profiles.sql` (this replaces the
--     policy it creates, and supersedes it, so re-running that older file would
--     undo this one - see its "DO NOT RE-RUN" header) and after
--     `20261103090100_student_can_access_exam.sql`, before
--     `20261103090300_questions_public.sql`.
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/20261103090200_exams_select.sql
--   * Verify (expect one row naming student_can_access_exam):
--       select polname, pg_get_expr(polqual, polrelid) as using_expr
--         from pg_policy
--        where polrelid = 'public.exams'::regclass
--          and polname = 'exams_select';
-- =====================================================================

drop policy if exists "exams_select" on public.exams;

create policy "exams_select"
  on public.exams for select
  to authenticated
  using (
    public.is_staff()
    or created_by = auth.uid()
    or public.student_can_access_exam(id)
  );

-- Verify, as above, that the policy now carries the call rather than the rule:
-- the plan for a student's `select ... from exams` shows one call to
-- `student_can_access_exam(exams.id)` in the filter, not four EXISTS nodes.
-- =====================================================================
