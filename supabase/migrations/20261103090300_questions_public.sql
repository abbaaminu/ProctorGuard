-- =====================================================================
-- PROCTORGUARD - questions_public: A FEED, NOT A DOOR
-- Rebuilds the student question feed so a row is visible only to somebody the
-- paper was actually opened for, and narrows the raw-table staff read that
-- currently hands any lecturer another lecturer's draft questions.
--
-- WHY THIS FILE EXISTS
--   The view was `join exams ... where e.is_published = true`, i.e. "every
--   published paper's questions, to every signed-in account": no cohort, no
--   window, no attempt. A student who could not even *see* a paper in their list
--   (`exams_select`) could read its questions by guessing or copying its id -
--   exam ids travel in links, roster exports and the console UI - and a paper
--   not yet open was readable the moment it was published, so a student who
--   opened the app early read the paper before `starts_at`.
--
-- THE NEW PREDICATE (one OR per audience, and nothing else)
--   1. `public.is_exam_supervisor()` - admin or supervisor. The intervention tier
--      plus the paper's author is the whole audience for a paper that is not a
--      student's: not `is_staff()`, which would still hand any lecturer any
--      paper's questions.
--   2. `e.created_by = auth.uid()` - the author, who authored these rows.
--   3. `public.student_can_access_exam(e.id)` **and** the window passes
--      (`starts_at` NULL or reached, `ends_at` NULL or not passed) - the same
--      cohort rule the paper list uses, plus "it is open now". This is the branch
--      that closes both the guessing hole and the early read.
--   4. An `'ongoing'` attempt of the caller's own that has not yet expired -
--      `now() < s.started_at + make_interval(mins => e.duration_minutes)`. This is
--      what keeps a paper readable *after* `ends_at` (branch 3 stops matching the
--      moment the window closes) for the student still inside their attempt: they
--      must be able to finish it, and `attempt_deadline()` caps the submission
--      separately.
--   The ongoing branch is joined, not sub-queried: `exam_submissions` is
--   `unique (student_id, exam_id)` (schema.sql §4), so the LEFT JOIN adds at most
--   one row per question and cannot multiply the feed.
--
-- THE SECOND STATEMENT (raw table) - the other half of the review's "(b)"
--   `questions_select_supervisor` is `using (public.is_staff())`: every lecturer
--   reads every paper's questions, drafts included. That is what the required
--   negative test - "a lecturer cannot read another lecturer's draft questions" -
--   asserts must stop, and it cannot be fixed in the view, because the view is not
--   the object that grants it. It is replaced with
--   `is_exam_supervisor() or owns_exam(exam_id)`. A lecturer keeps full access to
--   their own papers (through `owns_exam()` and through `questions_select_owner`,
--   which is left untouched), supervisors and admins keep the institution-wide
--   reach the monitor console needs, and the authoring console only ever queries
--   papers it scoped to the signed-in author
--   (`mobile/lib/features/authoring/.../question_authoring_repository_impl.dart`),
--   so no in-app path reads another author's rows.
--
-- WHAT THIS DOES NOT DO
--   * No change to the answer keys: neither `correct_option` nor
--     `correct_text_answer` appears in the column list, and there is still no
--     student SELECT policy on the raw `questions` table.
--   * No `is_published` filter of its own. Branch 3 already requires publication
--     (`student_can_access_exam` returns false for a draft), and a blanket
--     `e.is_published = true` would also hide a draft from its own author and from
--     the supervisors who open its sitting.
--   * No `security_invoker` change: it stays OFF (definer view). With invoker
--     semantics the view would run under the caller's own `questions` policies,
--     which are the policies that hand out the answer key.
--   * No window on the *ongoing* branch beyond the attempt's own deadline, and no
--     use of `attempt_deadline()` here: the requirement for this branch is
--     `started_at + duration_minutes`, and the ends_at cap is enforced where an
--     attempt is submitted.
--
-- SAFETY
--   * `drop view` + `create view`: a view's WHERE clause cannot be replaced in
--     place, and the column list must not move (the clients select named columns
--     and `mobile/lib/.../question.dart` parses them). The DROP loses the view's
--     ACL, so `grant select ... to authenticated` and `revoke all ... from anon`
--     are re-applied in this same file - without them a re-run of this migration
--     would hand the feed to the anonymous key (`schema.sql` §0's default
--     privileges are why the revoke is needed at all).
--   * Safe to re-run: `drop view if exists` + `drop policy if exists` + `create`.
--   * PREREQUISITES: `public.is_exam_supervisor()`, `public.owns_exam(uuid)`,
--     `public.student_can_access_exam(uuid)` (20261103090100...),
--     `exams.starts_at` / `exams.ends_at` (`optional_exam_scheduling.sql`) and
--     `exams.duration_minutes` (`not null`, check > 0).
--   * APPLY ORDER: after `20261103090100_student_can_access_exam.sql` and
--     `20261103090200_exams_select.sql`; before
--     `20261103090400_submissions_insert_own_ongoing.sql`.
--   * `supabase/schema.sql` §3 carries the same view for fresh installs, and the
--     two must be kept in step. No test reads this view back (the contract test
--     pins the reset tier, not the feed), so the two copies are the only guard
--     against drift.
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/20261103090300_questions_public.sql
--   * Verify (expect the four OR branches in `pg_get_viewdef`):
--       select pg_get_viewdef('public.questions_public'::regclass, true);
-- =====================================================================

drop view if exists public.questions_public;

create view public.questions_public as
  select q.id,
         q.exam_id,
         q.question_text,
         q.question_type,
         q.options,
         q.points,
         q.created_at
  from public.questions q
  join public.exams e on e.id = q.exam_id
  left join public.exam_submissions s
         on s.exam_id = e.id
        and s.student_id = auth.uid()
  where public.is_exam_supervisor()
     or e.created_by = auth.uid()
     or (
       public.student_can_access_exam(e.id)
       and (e.starts_at is null or now() >= e.starts_at)
       and (e.ends_at   is null or now() <= e.ends_at)
     )
     or (
       s.status = 'ongoing'
       and s.started_at + make_interval(mins => e.duration_minutes) > now()
     );

alter view public.questions_public set (security_invoker = false);

comment on view public.questions_public is
  'Student-facing question feed: neither answer key; one row per audience - supervisor/admin, the paper''s author, a student the paper is offered to while its window is open, or the owner of an ongoing attempt until its deadline.';

grant select on public.questions_public to authenticated;
revoke all on public.questions_public from anon;

-- ... and the raw table, which no student may read at all, and which no longer
-- opens another author's draft to any lecturer:
drop policy if exists "questions_select_supervisor" on public.questions;

create policy "questions_select_supervisor"
  on public.questions for select
  to authenticated
  using (
    public.is_exam_supervisor()
    or public.owns_exam(exam_id)
  );
