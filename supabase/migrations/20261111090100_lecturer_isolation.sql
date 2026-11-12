-- =====================================================================
-- LECTURER ISOLATION  -  a paper, and everything hanging off it, belongs
--                        to the lecturer who wrote it
-- =====================================================================
-- Run on a linked project with:
--   supabase db query --linked -f supabase/migrations/20261111090100_lecturer_isolation.sql
-- or paste it into the SQL Editor. It is safe to re-run.
--
-- WHY THIS FILE EXISTS
--   `20261109090000_supervisor_exam_assignments.sql` narrowed the *supervisor*
--   to the papers an administrator assigned, and every file since has repeated
--   the same sentence about the lecturer: "unchanged - a lecturer keeps what
--   they had". What they had was the whole institution. `is_staff()` is true for
--   admin, supervisor and lecturer alike, and these policies were written when
--   that tier *was* the answer:
--
--     profiles_select_own_or_staff          every name, email, matriculation
--                                           number, staff id, department and
--                                           phone number in the institution
--     exams_select                          every paper - title, schedule,
--                                           cohort labels, roster counts
--     exam_allowed_students_select          every borrow-list row
--     submissions_select_own_or_supervisor  every attempt - answers, score,
--                                           status, of every student
--     question_grades_select_staff          every mark awarded on every paper
--     Proctor snapshots *purge*             the stills of any *reset* attempt,
--                                           and of any folder that resolves to
--                                           no attempt, in the whole bucket
--     auto_graded_score(uuid)               the automatic score of any attempt
--
--   A lecturer who was never asked to run a sitting could therefore open it in
--   the console, read the roster, watch the incident feed, sign a URL to a
--   student's face, read the marks and reset the attempt. This file makes the
--   same move for the lecturer that `20261109090000` made for the supervisor:
--   reach follows the paper, and the paper belongs to its author.
--
--
-- THE ONE PREDICATE
--   public.can_reach_exam(p_exam_id) = owns_exam() OR can_supervise_exam()
--                                    = the author, or the assigned supervisor,
--                                      or an administrator.
--   `owns_exam()` already asks `exams.created_by = auth.uid()` and
--   `can_supervise_exam()` already answers true for `is_admin()`, so the admin's
--   global reach is untouched and needs no new term anywhere.
--
--   Nine policies and one RPC are re-pointed at it. Nothing is *dropped*: a
--   policy is a union, so a leftover permissive one would silently undo the
--   scope - every one of them is `drop policy if exists` + `create policy` in
--   this file, and section 12 refuses to finish if any SELECT policy on a
--   scoped table still answers on the staff tier alone (section 13).
--
--
-- WHAT DOES NOT CHANGE
--   * an administrator: `is_admin()` inside `can_supervise_exam()`, so every
--     paper and (through `can_read_profile`) every account stays in reach. The
--     admin console's roster, the label-correction tool and
--     `admin-delete-user` are unaffected;
--   * a student: `student_id = auth.uid()` on their own attempt, their own
--     consent and their own profile row, plus `student_can_access_exam()` on
--     the paper. A student who is *also* a lecturer keeps their student reach -
--     not one of those arms asks the role. `student_can_access_exam()` is the
--     one predicate written for that overlap (an enrolled lecturer sitting a
--     colleague's paper, which is the borrow-list case), and block (l) of
--     `supabase/tests/supervisor_scope_check.sql` is where the fixture is
--     deliberately kept *labelled* so the check stays about the scope rather
--     than about that trade-off;
--   * the writing policies. `exams_update_owner`, `exams_delete_owner`,
--     `questions_*_owner`, `exam_allowed_students_*_owner` and
--     `submissions_delete_supervisor` already ask `owns_exam()`, and
--     `proctoring_logs` / `session_reset_logs` / `attempt_review_logs` /
--     `proctor_heartbeats` already read `owns_exam() or can_supervise_exam()`.
--     Nothing in this file makes a write possible that was impossible before;
--   * `is_staff()` and `is_attempt_resetter()` stay defined and stay the right
--     question for a *tier* ("is this an account that may reset an attempt at
--     all"), which the console gates the per-row control on.
--
--
-- WHAT A LECTURER LOSES, ON PURPOSE
--   opening a colleague's sitting: the monitor list, the incident feed, the
--   stills, the marks, the reset and review audit - for a paper they did not
--   write and were not assigned to. Invigilating for a colleague now requires
--   an assignment (`supervisor_exam_assignments`) or an admin account. This is
--   the same trade `20261109090000` made for the supervisor, and the reason the
--   new check file has a block for every one of those surfaces.

--
--
-- THE ONE NEW TABLE
--   `snapshot_purge_grants` exists because the stills of a *reset* attempt have
--   no attempt row left to ask about - that is the whole orphan window - so the
--   purge used to ask the tier instead: `is_attempt_resetter()`, i.e. every
--   lecturer, over the whole bucket. An `AFTER DELETE` trigger on
--   `exam_submissions` now records (submission, exam, who deleted it) as the row
--   disappears, and the two purge policies ask `may_purge_snapshot(name)`:
--   the account that performed the reset, or anybody who can reach *that paper*.
--   A folder with no grant row is a folder no reset produced - purge it with the
--   service role (the `purge-snapshots` function and `purge_expired_snapshots()`
--   both bypass RLS), not with a lecturer's token.
--
--
-- APPLY ORDER
--   After every other file, in particular after
--   `20261110090100_snapshot_orphan_check.sql` and
--   `20261111090000_single_session.sql` (both recreate policies this file also
--   recreates; the last one applied wins, so this file must be last). It mirrors
--   section by section into `supabase/schema.sql`, which
--   `mobile/test/schema_contract_test.dart` reads back out of both files and
--   compares.
-- =====================================================================


-- =====================================================================
-- 1. THE PAPER SCOPE
-- =====================================================================
-- One predicate for "may this account see this paper's data", so nine policies
-- cannot drift apart. It is the same pair the writing policies already ask one
-- at a time - `owns_exam()` for the author, `can_supervise_exam()` for an
-- administrator or the assigned supervisor - stated once, named once.
--
-- SECURITY DEFINER, `stable`, `set search_path`, for the reason every predicate
-- in this schema is: it is called from policies on tables (`profiles`,
-- `exam_submissions`, `storage.objects`) whose own policies would otherwise
-- recurse, and it must answer about a paper the caller may not be able to read.
create or replace function public.can_reach_exam(p_exam_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select p_exam_id is not null
     and (
       public.owns_exam(p_exam_id)
       or public.can_supervise_exam(p_exam_id)
     );
$$;

comment on function public.can_reach_exam(uuid) is
  'The one paper scope: true for the lecturer who wrote the paper (exams.created_by), for an administrator, and for a supervisor assigned to it in supervisor_exam_assignments - i.e. owns_exam() or can_supervise_exam(). False for a lecturer who did not write it and was not assigned to it, for a student, and for a null paper. Every lecturer-visible read asks this.';

revoke execute on function public.can_reach_exam(uuid) from public, anon;
grant execute on function public.can_reach_exam(uuid) to authenticated, service_role;



-- =====================================================================
-- 2. THE PERSON SCOPE  -  can_read_profile()
-- =====================================================================
-- Same three questions as before - did this person sit, was this person
-- granted, is this person aimed at, a paper the caller runs - with "a paper the
-- caller runs" widened from *assigned to me* to *a paper I can reach*. That is
-- the only edit: the assignments join becomes `can_reach_exam()`.
--
-- Why it has to change at all: the policy in section 3 now asks this of a
-- *lecturer* as well (it used to ask it of a supervisor only, and let every
-- lecturer through on the tier). If the body still asked
-- `supervisor_exam_assignments.supervisor_id = auth.uid()`, a lecturer's own
-- students would answer false and the marking queue, the monitor roster and the
-- exam cards would print uuids instead of names. The paper scope is the same
-- question for both staff roles, which is exactly why it is stated once.
--
-- The "aimed at" branch keeps its shape and its reasoning: the papers this
-- caller can reach are the only ones joined, a paper that names no cohort is
-- skipped ("aimed at everybody" would be the whole student body), and a student
-- whose own label is blank is not matched by a paper that names that field.
create or replace function public.can_read_profile(p_profile_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select p_profile_id is not null
     and (
       exists (
         select 1
         from public.exam_submissions s
         where s.student_id = p_profile_id
           and public.can_reach_exam(s.exam_id)
       )
       or exists (
         select 1
         from public.exam_allowed_students t
         where t.student_id = p_profile_id
           and public.can_reach_exam(t.exam_id)
       )
       or exists (
         select 1
         from public.profiles p
         join public.exams e on public.can_reach_exam(e.id)
         where p.id = p_profile_id
           and p.role = 'student'
           and (
             nullif(btrim(e.faculty), '') is not null
             or nullif(btrim(e.department), '') is not null
             or nullif(btrim(e.level), '') is not null
           )
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
     );
$$;

comment on function public.can_read_profile(uuid) is
  'Per-person scope for the profiles read: true for a student who sat, was granted or is aimed at a paper the caller can reach (can_reach_exam: the author, an administrator, or the assigned supervisor). False for another member of staff - a colleague lecturer''s own profile row is not readable through this - and for a student with no paper in common.';



-- =====================================================================
-- 3. THE ROSTER  -  profiles_select_own_or_staff
-- =====================================================================
-- Your own row; every row for an administrator; and for everybody else on the
-- staff tier, the rows section 2 answers yes about. The third arm used to read
-- `is_staff() and (not is_supervisor_only() or can_read_profile(id))`, i.e.
-- "everybody except a supervisor", which is how a lecturer kept the whole
-- roster after `20261109090000` - the compliment was the leak. It is now the
-- same per-person question for both staff roles, and `is_admin()` is written out
-- because an administrator must keep the roster even on a project with no papers
-- at all (`can_read_profile` would answer false for everybody there).
--
-- A student never reaches `can_read_profile`: their own row is the first arm and
-- `is_staff()` is false for them, so no student can enumerate the student body.
-- A lecturer reading a *colleague's* row now answers false, which is the point -
-- nothing a lecturer's screens render comes from another member of staff's row
-- (the author of a paper is a uuid the console never resolves).
drop policy if exists "profiles_select_own_or_staff" on public.profiles;
create policy "profiles_select_own_or_staff"
  on public.profiles for select
  to authenticated
  using (
    id = auth.uid()
    or public.is_admin()
    or (
      public.is_staff()
      and public.can_read_profile(id)
    )
  );


-- =====================================================================
-- 4. THE PAPERS  -  exams_select
-- =====================================================================
-- An administrator and the assigned supervisor (section 1), the paper's author
-- (also section 1, through `owns_exam()`), and a student who is offered it
-- (`student_can_access_exam()`, unchanged: published, and aimed at them by label
-- or by the borrow list).
--
-- `created_by = auth.uid()` is gone as a separate arm because `owns_exam(id)`
-- inside `can_reach_exam()` *is* that sentence, asked from the row's own id.
-- `student_can_access_exam()` still answers false for a supervisor, so an
-- unassigned paper does not come back in through the student arm, and it answers
-- true for a lecturer *who is enrolled as a student* - which is why a lecturer
-- can still sit, and read, a colleague's published paper (block (o) of the check
-- file). Sitting it does not open its roster: the attempt it creates is theirs,
-- and `submissions_select_own_or_supervisor` shows them exactly that one row.
drop policy if exists "exams_select" on public.exams;
create policy "exams_select"
  on public.exams for select
  to authenticated
  using (
    public.can_reach_exam(id)
    or public.student_can_access_exam(id)
  );


-- =====================================================================
-- 5. THE BORROW LIST  -  exam_allowed_students_select
-- =====================================================================
-- The student the row names, or the paper it names. "Any member of staff" was
-- the previous answer - who was granted an exception on a colleague's paper is
-- that paper's business. The write policies below are untouched: they already
-- ask `owns_exam(exam_id)`, so this read narrowing changes no tool.
drop policy if exists "exam_allowed_students_select" on public.exam_allowed_students;
create policy "exam_allowed_students_select"
  on public.exam_allowed_students for select
  to authenticated
  using (
    student_id = auth.uid()
    or public.can_reach_exam(exam_id)
  );



-- =====================================================================
-- 6. THE ROSTER OF ATTEMPTS  -  submissions_select_own_or_supervisor
-- =====================================================================
-- Your own attempt, or an attempt of a paper you can reach. This is the row that
-- carries `answers`, `score` and `status`, so the wide read was the loudest of
-- the leaks: any lecturer could read any student's script.
--
-- The console is unaffected for the papers it is for: the marking queue reads
-- the attempts of the papers its author wrote, the monitor reads the attempts of
-- the paper it was opened on, and an administrator reads all of them. An
-- unassigned paper's attempts are now simply absent - which is the failure
-- direction this file wants, because the monitor's empty state is a sentence
-- rather than a scrolled-through roster.
drop policy if exists "submissions_select_own_or_supervisor" on public.exam_submissions;
create policy "submissions_select_own_or_supervisor"
  on public.exam_submissions for select
  to authenticated
  using (
    student_id = auth.uid()
    or public.can_reach_exam(exam_id)
  );


-- =====================================================================
-- 7. THE ACCEPTANCES  -  consents_select_own_or_supervisor
-- =====================================================================
-- Your own acceptances, or one given for a paper you can reach. Deliberately
-- still not `is_staff()`: "did this person agree, and to what wording?" is a
-- paper's question. The author of the paper is now inside the scope - before
-- this file a lecturer could not read the acceptances of their own sitting,
-- which was the mirror image of the leak this section closes - and a general
-- acceptance (`exam_id IS NULL`) stays readable by its subject only, because
-- there is no paper to be accountable for it.
drop policy if exists "consents_select_own_or_supervisor" on public.proctoring_consents;
create policy "consents_select_own_or_supervisor"
  on public.proctoring_consents for select
  to authenticated
  using (
    student_id = auth.uid()
    or (exam_id is not null and public.can_reach_exam(exam_id))
  );


-- =====================================================================
-- 8. THE MARKS  -  question_grades_select_staff
-- =====================================================================
-- The marks of an attempt on a paper you can reach. The tier test (`is_staff()`)
-- is gone rather than narrowed: a mark is a fact about a paper, and the paper is
-- what the caller has to be able to reach. Students still read no rows here -
-- their total is on their own `exam_submissions.score` - and there is still no
-- insert, update or delete policy, because `grade_submission()` is the single
-- write path and it asks `owns_exam()`.
drop policy if exists "question_grades_select_staff" on public.question_grades;
create policy "question_grades_select_staff"
  on public.question_grades for select
  to authenticated
  using (
    exists (
      select 1
      from public.exam_submissions s
      where s.id = submission_id
        and public.can_reach_exam(s.exam_id)
    )
  );



-- =====================================================================
-- 9. THE STILLS, READ  -  "Proctor snapshots read access"
-- =====================================================================
-- The student the attempt belongs to, or the paper it is against. Already
-- `owns_exam(exam_id) or can_supervise_exam(s.exam_id)` - the evidence tier was
-- narrowed with the logs in `lecturer_scoped_log_reads.sql` - so this is the one
-- policy in this file that is *rewritten to say the same thing in one word*. It
-- is recreated anyway because `can_reach_exam()` has to be the only expression
-- of the scope: two spellings of it can drift, and the signature `storage.remove()`
-- relies on (signing is a SELECT) is worth reading in the same terms as the rest.
drop policy if exists "Proctor snapshots read access" on storage.objects;
create policy "Proctor snapshots read access"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'proctor-snapshots'
    and exists (
      select 1 from public.exam_submissions s
      where s.id::text = (storage.foldername(name))[1]
        and (
          s.student_id = auth.uid()
          or public.can_reach_exam(s.exam_id)
        )
    )
  );


-- =====================================================================
-- 10. THE STILLS OF A RESET  -  the purge grant
-- =====================================================================
-- `snapshot_attempt_exists()` settles *whether* a folder is orphaned, and
-- `is_attempt_resetter()` says *who may ever purge* (admin, supervisor,
-- lecturer). Neither says *whose* orphan it is, and that gap is the last way a
-- lecturer reached another lecturer's sitting: reset an attempt on a colleague's
-- paper (or find one already reset) and the stills were deletable, because the
-- only question asked was the tier. A photograph of a student in a paper you
-- have no reach over is exactly the evidence this file is about.
--
-- The reset itself already deletes the attempt row - that is the order
-- `DashboardRepositoryImpl.resetSubmission()` uses, and the order the purge
-- policy forces. So the fact to record is "this folder's attempt was deleted, by
-- this account, on this paper", and an AFTER DELETE trigger is the only place
-- that can see it. One row per deleted attempt: `submission_id` is the folder,
-- `exam_id` is the paper (kept so a *supervisor assigned later* can still finish
-- a colleague's half-done reset), `granted_to` is who pressed the button (NULL
-- when the delete came from SQL with no JWT - the retention job, psql).
--
-- No foreign keys, on purpose: a cascade from `exams` would erase the grant when
-- a paper is deleted, and a cascade from `profiles` would erase it when an
-- account leaves - both are cases where the stills are still in the bucket.
create table if not exists public.snapshot_purge_grants (
  submission_id uuid primary key,
  exam_id       uuid not null,
  granted_to    uuid,
  granted_at    timestamptz not null default now()
);

comment on table public.snapshot_purge_grants is
  'One row per deleted exam_submissions row, written by the AFTER DELETE trigger below: which attempt folder disappeared, on which paper, and who deleted it. Read only by may_purge_snapshot(); it is what scopes the two snapshot purge policies to the paper the reset belonged to instead of to the staff tier at large.';

revoke all on table public.snapshot_purge_grants from anon, authenticated;
grant all on table public.snapshot_purge_grants to service_role;

-- RLS on with no policy at all: the table is readable through
-- `may_purge_snapshot()` (SECURITY DEFINER) and by the service role, and by
-- nobody else - not even an administrator, who has no screen that shows it.
alter table public.snapshot_purge_grants enable row level security;

create or replace function public.record_snapshot_purge_grant()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.snapshot_purge_grants (submission_id, exam_id, granted_to)
  values (old.id, old.exam_id, auth.uid())
  on conflict (submission_id) do update
    set exam_id    = excluded.exam_id,
        granted_to = excluded.granted_to,
        granted_at = now();
  return old;
end;
$$;

comment on function public.record_snapshot_purge_grant() is
  'AFTER DELETE trigger body on exam_submissions: records the folder, the paper and the account so may_purge_snapshot() can answer "may this caller finish this reset" after the attempt row is gone. Never raises - a failed bookkeeping row must not turn a completed reset into an error.';

revoke execute on function public.record_snapshot_purge_grant() from public, anon, authenticated;

drop trigger if exists exam_submissions_record_purge_grant on public.exam_submissions;
create trigger exam_submissions_record_purge_grant
  after delete on public.exam_submissions
  for each row execute function public.record_snapshot_purge_grant();


-- "May this caller finish the reset that emptied this folder?"
--
-- The account that deleted the attempt, or anybody who can reach the paper it
-- belonged to (its author, an administrator, the supervisor assigned to it - so
-- a reset half-finished by a colleague, or by a psql session with no JWT, can
-- still be completed by whoever is accountable for the paper now).
--
-- Shape-tested before the cast, like `snapshot_attempt_exists()`: `name` is free
-- text and a cast that raised on a stray object would abort a whole purge
-- statement instead of answering about that one object.
create or replace function public.may_purge_snapshot(p_object_name text)
returns boolean
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_folder text;
begin
  if p_object_name is null then
    return false;
  end if;

  v_folder := (storage.foldername(p_object_name))[1];

  if v_folder is null
     or v_folder !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  then
    return false;
  end if;

  return exists (
    select 1
    from public.snapshot_purge_grants g
    where g.submission_id = v_folder::uuid
      and (
        g.granted_to = auth.uid()
        or public.can_reach_exam(g.exam_id)
      )
  );
end;
$$;

comment on function public.may_purge_snapshot(text) is
  'True when the caller may purge the stills of this attempt folder: the account that deleted the attempt (snapshot_purge_grants.granted_to), or anybody who can reach the paper it belonged to. False for a folder no reset produced - a live attempt (snapshot_attempt_exists() also refuses those) and a folder left by the service role, which purges without RLS.';

revoke execute on function public.may_purge_snapshot(text) from public, anon;
grant execute on function public.may_purge_snapshot(text) to authenticated, service_role;

-- Both purge policies: the tier (`is_attempt_resetter()`), the fact (the folder
-- names no attempt), and now the owner of that fact. The third term is what
-- takes the *whole bucket* out of every lecturer's reach. The comment that
-- explains the first two, and the `snapshot_orphan_check.sql` hole that put the
-- definer in `snapshot_attempt_exists()`, is in section 6 of `schema.sql`.
drop policy if exists "Proctor snapshots supervisor purge" on storage.objects;
create policy "Proctor snapshots supervisor purge"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'proctor-snapshots'
    and public.is_attempt_resetter()
    and not public.snapshot_attempt_exists(name)
    and public.may_purge_snapshot(name)
  );

-- The companion a `DELETE ... WHERE` needs (Postgres only deletes rows the
-- statement may see), on the same three terms.
drop policy if exists "Proctor snapshots orphan read for purge" on storage.objects;
create policy "Proctor snapshots orphan read for purge"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'proctor-snapshots'
    and public.is_attempt_resetter()
    and not public.snapshot_attempt_exists(name)
    and public.may_purge_snapshot(name)
  );


-- =====================================================================
-- 11. THE AUTOMATIC SCORE  -  auto_graded_score(uuid)
-- =====================================================================
-- One number, computed from the answer key the caller cannot read, for an
-- attempt the caller may already see. That last clause was `is_staff()`: any
-- lecturer could call the RPC with any attempt id and read the automatic part of
-- a stranger's score. It is `can_reach_exam(s.exam_id)` now - and the two
-- internal callers are unaffected, because `submit_exam()` runs it for the
-- student whose `s.student_id = auth.uid()` and `grade_submission()` has already
-- refused everybody but the paper's author or its supervisors.
create or replace function public.auto_graded_score(p_submission_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(q.points), 0)
  from public.questions q
  join public.exam_submissions s on s.id = p_submission_id
  where q.exam_id = s.exam_id
    and (s.student_id = auth.uid() or public.can_reach_exam(s.exam_id))
    and (
      (
        q.question_type = 'multiple_choice'
        and s.answers -> q.id::text = to_jsonb(q.correct_option)
      )
      or
      (
        q.question_type in ('fill_in_the_blank', 'true_false')
        and coalesce(btrim(q.correct_text_answer), '') <> ''
        and lower(btrim(s.answers ->> q.id::text)) =
            lower(btrim(q.correct_text_answer))
      )
    );
$$;

comment on function public.auto_graded_score(uuid) is
  'Automatic part of an attempt''s score (multiple-choice, true/false and fill-in-the-blank answers), for the student who owns the attempt or a caller who can reach its paper. Marks awarded by hand live in question_grades.';


-- =====================================================================
-- 12. THE INDEX THE SCOPE READS
-- =====================================================================
-- `owns_exam()` and every policy above filter `exams.created_by`; the column had
-- no index, so each of those predicates was a sequential scan of the papers
-- table (once per candidate row on `profiles` and `exam_submissions`). The
-- supervisor half already had one through the assignment primary key.
create index if not exists idx_exams_created_by on public.exams(created_by);



-- =====================================================================
-- 13. VERIFY  -  refuse to leave a database that still has the leak
-- =====================================================================
-- Every statement above is idempotent, so this file can be re-run; this block
-- is what makes a *re-run* meaningful after somebody else's migration, a hand
-- edit in the dashboard or a half-applied file. It raises (and the whole file
-- rolls back with it) if:
--
--   * a SELECT policy on a paper-scoped table names no paper scope at all;
--   * any SELECT policy in `public` still answers on the staff tier alone -
--     `is_staff()` / `is_supervisor_only()` with no paper or person predicate
--     next to it, which is the exact shape of all seven leaks in the header;
--   * a still policy no longer asks the scope it must ask;
--   * `can_read_profile()` or `auto_graded_score()` still mentions `is_staff()`,
--     which would mean this file ran against a project where an older
--     definition won.
do $$
declare
  v_bad     text;
  v_table   text;
  v_scoped  constant text :=
    '(owns_exam|can_supervise_exam|can_reach_exam|can_read_profile)';
begin
  -- (1) a SELECT policy that can answer on the staff tier alone.
  select string_agg(format('%s.%s (%s)', schemaname, tablename, policyname), ', ')
    into v_bad
  from pg_policies
  where schemaname = 'public'
    and cmd in ('SELECT', 'ALL')
    and ('authenticated' = any (roles) or 'public' = any (roles))
    and coalesce(qual, '') ~ '(is_staff|is_supervisor_only)\('
    and coalesce(qual, '') !~ v_scoped
    -- An ownership test written inline (`e.created_by = auth.uid()`) is the
    -- author's arm, which is a scope; `questions_select_owner` is the one policy
    -- that spells it that way, and `schema.sql` says so next to it.
    and coalesce(qual, '') !~ 'created_by = auth\.uid\(\)';
  if v_bad is not null then
    raise exception 'VERIFY: a SELECT policy still answers on the staff tier alone: %', v_bad;
  end if;

  -- (2) every paper-scoped table must have at least one SELECT policy that asks
  -- the scope - a table whose only read policy was dropped would be silent here
  -- and open (or closed) by accident.
  foreach v_table in array array[
    'exams', 'exam_submissions', 'exam_allowed_students', 'question_grades',
    'proctoring_consents', 'questions', 'proctoring_logs', 'proctor_heartbeats',
    'session_reset_logs', 'attempt_review_logs', 'profiles'
  ] loop
    if not exists (
      select 1
      from pg_policies
      where schemaname = 'public'
        and tablename = v_table
        and cmd in ('SELECT', 'ALL')
        and coalesce(qual, '') ~ v_scoped
    ) then
      raise exception 'VERIFY: public.% has no SELECT policy that names a paper scope', v_table;
    end if;
  end loop;

  -- (3) the stills: read follows the attempt's paper, purge follows the grant.
  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname = 'Proctor snapshots read access'
      and coalesce(qual, '') ~ 'can_reach_exam'
  ) then
    raise exception 'VERIFY: "Proctor snapshots read access" does not ask can_reach_exam()';
  end if;

  select string_agg(policyname, ', ') into v_bad
  from pg_policies
  where schemaname = 'storage' and tablename = 'objects'
    and policyname in ('Proctor snapshots supervisor purge',
                       'Proctor snapshots orphan read for purge')
    and coalesce(qual, '') !~ 'may_purge_snapshot';
  if v_bad is not null then
    raise exception 'VERIFY: a snapshot purge policy does not ask may_purge_snapshot(): %', v_bad;
  end if;

  if (select count(*) from pg_policies
       where schemaname = 'storage' and tablename = 'objects'
         and policyname in ('Proctor snapshots supervisor purge',
                            'Proctor snapshots orphan read for purge')) <> 2 then
    raise exception 'VERIFY: a snapshot purge policy is missing';
  end if;

  -- (4) the bookkeeping the purge reads.
  if to_regclass('public.snapshot_purge_grants') is null then
    raise exception 'VERIFY: public.snapshot_purge_grants was not created';
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.exam_submissions'::regclass
      and tgname = 'exam_submissions_record_purge_grant'
      and not tgisinternal
  ) then
    raise exception 'VERIFY: the AFTER DELETE trigger on exam_submissions is missing';
  end if;

  -- (5) the two definitions this file rewrites must not still name the tier.
  if pg_get_functiondef('public.auto_graded_score(uuid)'::regprocedure) ~ 'is_staff' then
    raise exception 'VERIFY: auto_graded_score() still admits is_staff()';
  end if;

  if pg_get_functiondef('public.can_read_profile(uuid)'::regprocedure) !~ 'can_reach_exam' then
    raise exception 'VERIFY: can_read_profile() does not read can_reach_exam()';
  end if;

  raise notice 'VERIFY: lecturer isolation in place - reach follows the paper (author, assigned supervisor, administrator).';
end $$;

