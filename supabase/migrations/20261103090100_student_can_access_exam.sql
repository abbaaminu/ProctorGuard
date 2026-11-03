-- =====================================================================
-- PROCTORGUARD - ONE NAME FOR "MAY THIS STUDENT SIT THIS PAPER?"
-- Adds `public.student_can_access_exam(uuid)`: published, and aimed at the caller
-- either by the paper's faculty/department/level or by its borrow list.
--
-- WHY THIS FILE EXISTS
--   Three places ask this question and only one of them used to answer it:
--   `exams_select` (may I see the paper?) carried the rule; `questions_public`
--   (may I read its questions?) and `submissions_insert_own_ongoing` (may I start
--   it?) never checked it at all, so a paper could be started - and its questions
--   read - by a student the paper was never offered to. The three cannot share a
--   policy and cannot ask each other, because a policy on `exam_submissions` or a
--   definer view may not assume the caller can read `exams`, `profiles` or
--   `exam_allowed_students` without re-entering those tables' policies (and, for
--   `exams`, re-entering `exams_select` itself). Copying the expression into each
--   caller would be three copies for the next targeting fix to find, so the rule
--   is named once here.
--
-- THE RULE (the strict one, from strict_targeting_null_profiles.sql, unchanged)
--   * `is_published = true` - a draft is nobody's to sit.
--   * Each of the paper's three labels narrows, and NULL/blank means "no
--     narrowing": a paper that names a faculty matches only a student whose own
--     faculty is recorded (`nullif(btrim(...), '') is not null`) and equal after
--     trim + lower(). A blank profile field does not widen access - that was the
--     loophole `strict_targeting_null_profiles.sql` closed, and this function must
--     not reopen it.
--   * The borrow list (`exam_allowed_students`) is its own OR branch: it admits a
--     student the labels exclude, and is the only way in for a student whose
--     labels were never recorded.
--
-- WHAT IT DELIBERATELY DOES NOT DO
--   * No schedule window. "May this student ever sit this paper" and "is the
--     window open now" are different questions; `exams_select` needs the first
--     (a paper must not vanish from a student's own history when it closes) and
--     the callers that need the second already ask it themselves
--     (`submissions_insert_own_ongoing`, and `questions_public` for `starts_at`).
--   * No `is_staff()` arm. Staff access does not depend on being aimed at, so the
--     callers OR in `is_exam_supervisor()` / `owns_exam()` themselves; folded in
--     here it could not be bypassed by a caller that means to bypass it.
--   * No `role = 'student'` test. The question is about the caller's *labels*, and
--     a lecturer who is also enrolled is exactly the borrow-list case.
--   * No GRANTs beyond the function's own EXECUTE - this reads three tables, it
--     never writes.
--
-- SECURITY DEFINER, for the same reason as `is_staff()` / `owns_exam()`: the
-- question has to be answerable from a policy on `exam_submissions` and from a
-- definer view, neither of which may assume the caller can read `profiles`.
-- `set search_path = public` pins the three lookups so a hijacked search_path
-- cannot swap a table underneath them.
--
-- SAFETY
--   * Safe to re-run: `create or replace function`.
--   * Additive: nothing calls it until `20261103090200_exams_select.sql` and the
--     two files after it are applied, so applying this alone changes no access.
--   * PREREQUISITES: `schema.sql` §2 (exams, profiles, exam_allowed_students) or
--     `academic_targeting.sql` + `strict_targeting_null_profiles.sql` +
--     `profile_identity_numbers.sql` on an existing project.
--   * APPLY ORDER: after `strict_targeting_null_profiles.sql` and after
--     `20261103090000_guard_profile_labels.sql` (the rule it encodes is only
--     trustworthy once a student cannot retarget itself), before
--     `20261103090200_exams_select.sql`, `20261103090300_questions_public.sql`
--     and `20261103090400_submissions_insert_own_ongoing.sql`.
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/20261103090100_student_can_access_exam.sql
--   * Verify (expect one row, prosecdef = true):
--       select proname, prosecdef, proacl from pg_proc
--        where pronamespace = 'public'::regnamespace
--          and proname = 'student_can_access_exam';
-- =====================================================================

create or replace function public.student_can_access_exam(p_exam_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1
    from public.exams e
    where e.id = p_exam_id
      and e.is_published = true
      and (
        exists (
          select 1
          from public.profiles p
          where p.id = auth.uid()
            and (nullif(btrim(e.faculty), '') is null
                 or (nullif(btrim(p.faculty), '') is not null
                     and lower(btrim(p.faculty)) = lower(btrim(e.faculty))))
            and (nullif(btrim(e.department), '') is null
                 or (nullif(btrim(p.department), '') is not null
                     and lower(btrim(p.department)) = lower(btrim(e.department))))
            and (nullif(btrim(e.level), '') is null
                 or (nullif(btrim(p.level), '') is not null
                     and lower(btrim(p.level)) = lower(btrim(e.level))))
        )
        or exists (
          select 1
          from public.exam_allowed_students a
          where a.exam_id = e.id and a.student_id = auth.uid()
        )
      )
  );
$$;

comment on function public.student_can_access_exam(uuid) is
  'True when the paper is offered to the caller: published, and matched either by its faculty/department/level labels (blank label = no narrowing, blank profile field = no match) or by the exam_allowed_students borrow list. Not a schedule-window test and not a staff test.';

revoke execute on function public.student_can_access_exam(uuid) from public, anon;
grant execute on function public.student_can_access_exam(uuid) to authenticated, service_role;
