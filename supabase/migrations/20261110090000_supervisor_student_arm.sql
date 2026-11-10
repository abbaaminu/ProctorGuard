-- =====================================================================
-- PROCTORGUARD - THE STUDENT ARMS ARE FOR STUDENTS
-- Closes `public.student_can_access_exam()` to a supervisor, so the four arms
-- built on it - the paper list, the question feed, the attempt insert and
-- `record_consent()` - stop offering a supervisor a paper nobody assigned.
--
-- WHY THIS FILE EXISTS
--   `exams_select` ends with `or public.student_can_access_exam(id)`, and that
--   predicate asks about the caller's *labels* only. `20261103090100` says so in
--   as many words: "No `role = 'student'` test. The question is about the caller's
--   labels". The supervisor scope (`20261109090000`) narrowed the *staff* arm and
--   left the student arm exactly as it was - correctly, for students - and that
--   left one way in:
--
--     a paper whose faculty/department/level are NULL or blank is *untargeted*
--     (a NULL label = no narrowing), and a profile whose labels are NULL matches
--     it. A staff profile is exactly that: the admin console creates accounts with
--     a role, a name and an email, and nothing else. So an unassigned supervisor
--     passed the student arm on every published untargeted paper - which was then
--     offered by the console list, had its questions read through
--     `questions_public` while the window was open, and could even be *started*,
--     through `submissions_insert_own_ongoing` and a consent row of their own.
--
--   `supabase/tests/supervisor_scope_check.sql` block (b) is what found it: the
--   supervisor was offered 2 papers where the scope says 1, and the second one was
--   an untargeted paper created by the fixture's lecturer and assigned to nobody.
--
-- WHAT CHANGES
--   One function, `public.student_can_access_exam(uuid)`, re-created with
--   `not public.is_supervisor_only() and` in front of the EXISTS it already had.
--   No policy, view, grant, table or RPC is touched: the four callers ask the
--   function at run time, so all four inherit the answer at once - which is the
--   whole reason the rule was named in one place to begin with.
--     * `exams_select`                    - the console's paper list
--     * `questions_public` arm 3          - the student question feed
--     * `submissions_insert_own_ongoing`  - "may I start it?"
--     * `record_consent()`                - "may I accept the notice for it?"
--   A supervisor keeps every arm that names a paper they are accountable for:
--   `can_supervise_exam(e.id)` in `exams_select` and `questions_public`,
--   `submissions_select_own_or_supervisor`, the incident feed, the stills, the
--   reset and the review decision. What goes is the *student* arm on a paper no
--   administrator assigned to them.
--
-- WHAT IT DOES NOT DO
--   * No `role = 'student'` test, and no narrowing of anybody else.
--     `20261103090100` deliberately has no such test - "a lecturer who is also
--     enrolled is exactly the borrow-list case" - and that case is preserved:
--     `is_supervisor_only()` is false for a lecturer and for an administrator, so
--     both answer through the union exactly as they did. The guard names one role,
--     the way every other supervisor rule in this repository does.
--   * No change to `is_supervisor_only()`, `can_supervise_exam()`,
--     `can_read_profile()` or `supervisor_exam_assignments`.
--   * No row is rewritten: an attempt a supervisor opened before this file ran
--     keeps its answers, its log and its status, and its student-facing read
--     (`questions_public` arm 4, the ongoing attempt) still resolves to them.
--   * No backfill, and no promotion or demotion of any account.
--
-- SAFETY
--   * Safe to re-run: `create or replace function`, same signature.
--   * Fail-closed: it removes access from one role and grants nothing to anybody.
--   * PREREQUISITES: `public.is_supervisor_only()` - `schema.sql` section 1, or
--     `20261109090000_supervisor_exam_assignments.sql` on an older project.
--
-- APPLY ORDER
--   `20261109090000_supervisor_exam_assignments.sql` first, then this file, last of
--   all. On a project that does not carry the scope yet this is harmless, but it does
--   not narrow the tier arm - run the scope file first.
--
--   Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/20261110090000_supervisor_student_arm.sql
--   Verify (the block at the bottom of this file raises on a project where the guard
--   did not land; by hand):
--       select prosrc like '%is_supervisor_only%' as guarded
--         from pg_proc
--        where pronamespace = 'public'::regnamespace
--          and proname = 'student_can_access_exam';
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. THE ONE PREDICATE
-- ---------------------------------------------------------------------
-- The body is `20261103090100`'s, unchanged, behind one extra term: the caller is
-- not the supervisor tier. `is_supervisor_only()` is the predicate the scope
-- migration already uses for exactly this sentence, so this adds no new public API
-- and cannot drift from the rest of the narrowing.
--
-- The comment inside the body is deliberate: the arm this predicate once provided
-- to a supervisor - wrongly - is `can_supervise_exam()` in the callers, and saying
-- so here is what stops the next reader from folding the staff arm back in.
create or replace function public.student_can_access_exam(p_exam_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select not public.is_supervisor_only()
     and exists (
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
  'True when the paper is offered to the caller: published, and matched either by its faculty/department/level labels (blank label = no narrowing, blank profile field = no match) or by the exam_allowed_students borrow list. False for a supervisor, whose reach is can_supervise_exam() instead. Not a schedule-window test and not a staff test.';

revoke execute on function public.student_can_access_exam(uuid) from public, anon;
grant execute on function public.student_can_access_exam(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. VERIFY
-- ---------------------------------------------------------------------
-- Raises rather than reporting success on a project where the guard did not land:
-- every statement above is `create or replace`, so a half-applied file - or one run
-- where `search_path` resolved an older copy of the function - would otherwise look
-- clean, and the leak it leaves behind is silent (a supervisor offered a paper
-- nobody assigned them).
do $$
declare
  v_src text;
begin
  if to_regprocedure('public.is_supervisor_only()') is null then
    raise exception 'FAIL: is_supervisor_only() is missing - apply 20261109090000_supervisor_exam_assignments.sql first';
  end if;

  select p.prosrc into v_src
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = 'student_can_access_exam';

  if v_src is null then
    raise exception 'FAIL: public.student_can_access_exam(uuid) does not exist';
  end if;

  -- The guard, and the four terms it must not have replaced.
  if v_src not like '%is_supervisor_only%' then
    raise exception 'FAIL: student_can_access_exam() still answers for a supervisor';
  end if;
  if v_src not like '%e.is_published = true%' then
    raise exception 'FAIL: the publication test left the predicate';
  end if;
  if v_src not like '%exam_allowed_students%' then
    raise exception 'FAIL: the borrow-list arm left the predicate';
  end if;
  if v_src not like '%nullif(btrim(e.level)%' then
    raise exception 'FAIL: the level label arm left the predicate';
  end if;

  raise notice 'student arms closed to a supervisor: student_can_access_exam() answers false for the supervisor-only tier, and every other role answers as it did';
end $$;
