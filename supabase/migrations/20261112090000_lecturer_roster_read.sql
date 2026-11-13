-- =====================================================================
-- PROCTORGUARD - THE LECTURER'S ROSTER READ, RE-INSTALLED
-- Re-creates `public.can_reach_exam(uuid)`, `public.can_read_profile(uuid)` and the
-- `profiles_select_own_or_staff` policy on a project whose
-- `20261111090100_lecturer_isolation.sql` was never applied, so a lecturer stops
-- reading every profile row in the institution.
--
-- WHY THIS FILE EXISTS
--   `20261111090100_lecturer_isolation.sql` is the file that narrows a lecturer's
--   reads to the papers they wrote. It makes two edits, and they only work
--   together: it widened `can_read_profile()` from "a paper assigned to me" to "a
--   paper I can reach" (`can_reach_exam()`), and it narrowed the roster policy from
--
--     id = auth.uid()
--     or (is_staff() and (not is_supervisor_only() or can_read_profile(id)))
--
--   to
--
--     id = auth.uid()
--     or is_admin()
--     or (is_staff() and can_read_profile(id)).
--
--   A project that never ran that file still carries *both* old halves - the
--   `20261110090200_supervisor_profile_read.sql` state - and block (k)viii of
--   `supabase/tests/supervisor_scope_check.sql` is what says so: a lecturer answers
--   `is_staff()`, is not `is_supervisor_only()`, and so the third arm is true for
--   every row of the table. The lecturer reads a colleague's account, and the block
--   raises "a lecturer read a colleague's profile row" - the roster leak, caught by
--   the check written for it.
--
--   The half-installed shape fails the other way and is worth naming, because a
--   half-fix looks like progress: a project that installed the narrowed *policy*
--   but kept the supervisor-era *function* reads nothing for a lecturer at all -
--   `can_read_profile()` still joins `supervisor_exam_assignments`, a lecturer has
--   no assignment, so the marking queue's names vanish and (k)viii reports 0 of the
--   4 students. Both shapes are cured here, which is why the function and the
--   policy are installed together, from one file.
--
--   A file that has already been applied cannot fix a project that has already
--   applied it, and `20261111090100` is in that position on such a project. This
--   one is the upgrade path for the roster read: the same three objects, in a file
--   no project can have run yet. On a project that *has* run that file it is a
--   no-op - every statement is a `create or replace`, a `drop` + `create` or an
--   `enable`.
--
-- WHAT CHANGES
--   1. `public.can_reach_exam(uuid)` - created (or replaced) as its owner
--      (`security definer`, `stable`, pinned `search_path`), so the predicate can
--      read `exams` and `supervisor_exam_assignments` on behalf of a caller whose
--      own policies would otherwise recurse. It is one sentence: the paper's
--      author (`owns_exam()`), an administrator, or the supervisor the
--      administrator assigned to it (`can_supervise_exam()`).
--   2. `public.can_read_profile(uuid)` - the same three questions as the
--      supervisor-era body (did this person sit, was this person granted, is this
--      person aimed at, a paper the caller runs), with "a paper the caller runs"
--      asked as `can_reach_exam()`. That single edit is what lets a lecturer's own
--      students - and only theirs - resolve to a name.
--   3. `profiles_select_own_or_staff` - dropped by name and re-created as your own
--      row, every row for an administrator (`is_admin()` is written out, because an
--      administrator must keep the roster even on a project with no papers at
--      all), and for the rest of the staff tier the rows `can_read_profile()`
--      answers yes about. The "everybody except a supervisor" arm is gone: the
--      compliment was the leak.
--   4. `profiles_admin_all` - re-created to the shape `supabase/schema.sql` has
--      (`for all`, `is_admin()`), because a copy that asks `is_staff()` matches a
--      supervisor too and hands the whole roster back through the administrator's
--      arm.
--
-- WHAT IT DOES NOT DO
--   * It does not install the other nine lecturer-level reads - papers, questions,
--     attempts, hand marks, the incident feed, snapshots, the two deletes and the
--     purge grants. Those are `20261111090100_lecturer_isolation.sql`'s, and a
--     project that is missing this file is missing them too: run that file as well.
--     VERIFY prints a NOTICE naming it if the attempt read still looks tier-wide,
--     rather than reporting success on a project that is only half narrowed.
--   * It does not drop a read policy it cannot recognise. One that asks
--     `is_staff()` without `can_read_profile()` is a different matter - that is the
--     old roster read under a name of its own, and it is a union with the policy
--     below, so this file stops and names it instead of guessing.
--   * It backfills nothing and moves no row. `profiles` is read more narrowly from
--     the moment the file commits; nothing about a profile row itself changes.
--
-- PREREQUISITES
--   The tables and predicates every other staff policy in the schema already reads:
--   `public.exam_submissions`, `public.exam_allowed_students`,
--   `public.supervisor_exam_assignments`, `public.is_staff()`,
--   `public.is_admin()`, `public.owns_exam(uuid)` and
--   `public.can_supervise_exam(uuid)`. If one is missing, VERIFY says which and
--   stops before the grants would have failed, rather than midway through a body.
-- =====================================================================


-- =====================================================================
-- 1. THE PAPER SCOPE  -  can_reach_exam()
-- =====================================================================
-- The definition `20261111090100_lecturer_isolation.sql` writes and
-- `supabase/schema.sql` carries, and `mobile/test/schema_contract_test.dart` fails
-- the build if the copies drift apart. It is restated here rather than depended on
-- because on the project this file exists for it does not exist at all.
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
-- The same three questions as the supervisor-era body - did this person sit, was
-- this person granted, is this person aimed at, a paper the caller runs - with
-- "a paper the caller runs" asked as `can_reach_exam()` instead of "a paper
-- assigned to me". That is the only edit, and it is what makes the policy in
-- section 3 work for a lecturer: a lecturer has no `supervisor_exam_assignments`
-- row, so the old body answered false for every student of theirs and the marking
-- queue printed uuids.
--
-- The "aimed at" branch keeps its shape and its reasoning: only the papers this
-- caller can reach are joined, a paper that names no cohort is skipped ("aimed at
-- everybody" would be the whole student body), and a student whose own label is
-- blank is not matched by a paper that names that field.
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

revoke execute on function public.can_read_profile(uuid) from public, anon;
grant execute on function public.can_read_profile(uuid) to authenticated, service_role;


-- =====================================================================
-- 3. THE ROSTER  -  profiles_select_own_or_staff
-- =====================================================================
-- RLS first: without it the table is read as if no policy existed, and a project
-- whose `profiles` table was created by hand - or by an early revision of
-- `schema.sql` - would consult none of the below. `enable` is a no-op on a project
-- that already has it, so this is safe on both.
alter table public.profiles enable row level security;

-- Your own row; every row for an administrator; and for everybody else on the
-- staff tier, the rows section 2 answers yes about. The third arm used to read
-- `is_staff() and (not is_supervisor_only() or can_read_profile(id))`, i.e.
-- "everybody except a supervisor", which is how a lecturer kept the whole roster
-- after `20261109090000` - the compliment was the leak. It is now the same
-- per-person question for both staff roles, and `is_admin()` is written out
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

-- The administrator's read is `is_admin()`, never `is_staff()`. A project whose copy
-- of this policy asks `is_staff()` matches every account of the intervention tier -
-- a supervisor included - so it is a second permissive read policy and the
-- narrowing above never applies. Re-created to the shape `supabase/schema.sql` has
-- (`for all`, admins only).
drop policy if exists "profiles_admin_all" on public.profiles;
create policy "profiles_admin_all"
  on public.profiles for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());


-- =====================================================================
-- 4. VERIFY
-- =====================================================================
-- Raises rather than reporting success on a project where the roster read did not
-- land. Every statement above is a `create or replace`, a `drop` + `create` or an
-- `enable`, so a half-applied file - or one run against a project missing the
-- tables the predicate reads - would otherwise look clean, and the leak it leaves
-- behind is silent: a lecturer reading every matriculation number in the
-- institution. Block (k)viii of `supabase/tests/supervisor_scope_check.sql` asks
-- the same question with fixtures, against a running project; this block is the
-- one that answers when the file is applied.
do $$
declare
  v_src        text;
  v_qual       text;
  v_extra      text;
  v_admin_qual text;
  v_admin_src  text;
  v_attempt    text;
begin
  -- The three tables the predicate reads and the predicates it is written in
  -- terms of. Naming them here is what turns "wrong order" into one red sentence
  -- instead of a 42P01 half way through a grant.
  if to_regclass('public.exam_submissions') is null then
    raise exception 'FAIL: public.exam_submissions is missing - can_read_profile() cannot answer "did this person sit a paper of mine"';
  end if;
  if to_regclass('public.exam_allowed_students') is null then
    raise exception 'FAIL: public.exam_allowed_students is missing - can_read_profile() cannot answer "was this person granted a paper of mine"';
  end if;
  if to_regclass('public.supervisor_exam_assignments') is null then
    raise exception 'FAIL: public.supervisor_exam_assignments is missing - can_supervise_exam(), which can_reach_exam() asks, cannot answer';
  end if;
  if to_regprocedure('public.owns_exam(uuid)') is null then
    raise exception 'FAIL: owns_exam() is missing - the author arm of can_reach_exam() cannot be built without it';
  end if;
  if to_regprocedure('public.can_supervise_exam(uuid)') is null then
    raise exception 'FAIL: can_supervise_exam() is missing - the administrator and assigned-supervisor arm of can_reach_exam() cannot be built without it';
  end if;
  if to_regprocedure('public.is_staff()') is null
     or to_regprocedure('public.is_admin()') is null then
    raise exception 'FAIL: is_staff() or is_admin() is missing - the roster policy is written in terms of both';
  end if;

  -- A policy nobody consults is not a narrowing: with RLS off, the table reads as
  -- if every policy were `using (true)`, and the roster is as wide as it ever was.
  if not coalesce(
    (select c.relrowsecurity from pg_class c where c.oid = 'public.profiles'::regclass),
    false
  ) then
    raise exception 'FAIL: row level security is off on public.profiles - no policy on it is consulted, and every row is readable by everybody';
  end if;

  -- The paper scope itself, as the server holds it. `owns_exam()` and
  -- `can_supervise_exam()` are the two arms, and a body missing either answers
  -- false for the author or for the assigned supervisor - which is a different
  -- bug than the one this file exists for, and a silent one.
  select p.prosrc into v_src
  from pg_proc p
  where p.oid = to_regprocedure('public.can_reach_exam(uuid)');

  if v_src is null then
    raise exception 'FAIL: public.can_reach_exam(uuid) does not exist after this file created it';
  end if;
  if v_src not like '%owns_exam%' then
    raise exception 'FAIL: can_reach_exam() does not ask owns_exam() - the author of a paper would not reach it';
  end if;
  if v_src not like '%can_supervise_exam%' then
    raise exception 'FAIL: can_reach_exam() does not ask can_supervise_exam() - an administrator and an assigned supervisor would not reach the paper';
  end if;

  -- The person scope: every arm has to ask the paper scope, and none may join
  -- `supervisor_exam_assignments` directly any more - that was the supervisor-only
  -- body, and keeping it would answer false for a lecturer's own students.
  select p.prosrc into v_src
  from pg_proc p
  where p.oid = to_regprocedure('public.can_read_profile(uuid)');

  if v_src is null then
    raise exception 'FAIL: public.can_read_profile(uuid) does not exist after this file replaced it';
  end if;
  if v_src like '%supervisor_exam_assignments%' then
    raise exception 'FAIL: can_read_profile() still joins supervisor_exam_assignments - a lecturer has no assignment row, so the answer is false for every student of theirs';
  end if;
  if v_src not like '%exam_submissions%'
     or v_src not like '%exam_allowed_students%'
     or v_src not like '%can_reach_exam%' then
    raise exception 'FAIL: can_read_profile() is missing one of its arms - it must ask whether the person sat, was granted, or is aimed at a paper the caller can reach';
  end if;
  if (length(v_src) - length(replace(v_src, 'can_reach_exam', ''))) / length('can_reach_exam') < 3 then
    raise exception 'FAIL: can_read_profile() asks can_reach_exam() fewer than three times - one of its three arms is still asking something else';
  end if;

  -- The roster policy, as the server holds it: a permissive SELECT policy for
  -- `authenticated` whose qualifier asks `can_read_profile()` and never
  -- `is_supervisor_only()`. That last condition is the whole bug - `not
  -- is_supervisor_only()` is true for every lecturer, so it matches every row.
  select pg_get_expr(p.polqual, p.polrelid) into v_qual
  from pg_policy p
  where p.polrelid = 'public.profiles'::regclass
    and p.polname = 'profiles_select_own_or_staff';

  if v_qual is null then
    raise exception 'FAIL: profiles_select_own_or_staff is missing from public.profiles after this file created it';
  end if;
  if v_qual not like '%can_read_profile%' or v_qual not like '%is_admin%' then
    raise exception 'FAIL: profiles_select_own_or_staff does not ask both is_admin() and can_read_profile() - got: %', v_qual;
  end if;
  if v_qual like '%is_supervisor_only%' then
    raise exception 'FAIL: profiles_select_own_or_staff still carries the not is_supervisor_only() arm - that is the roster leak: it is true for every lecturer, so every row matches. Got: %', v_qual;
  end if;

  -- ... and it has to be a *permissive* SELECT policy that `authenticated` is
  -- subject to. A restrictive one would subtract from the other policies instead
  -- of granting, and one granted to another role would never be consulted.
  if not exists (
    select 1
    from pg_policy p
    where p.polrelid = 'public.profiles'::regclass
      and p.polname = 'profiles_select_own_or_staff'
      and p.polpermissive
      and p.polcmd = 'r'
      and (0 = any (p.polroles) or 'authenticated'::regrole::oid = any (p.polroles))
  ) then
    raise exception 'FAIL: profiles_select_own_or_staff is not a permissive SELECT policy for authenticated - as written it grants nothing (or subtracts)';
  end if;

  -- The administrator's policy must not be a second permissive read for the staff
  -- tier. `is_staff()` there re-opens the whole roster for every lecturer and
  -- supervisor, and the narrowing above then has no effect at all.
  select pg_get_expr(p.polqual, p.polrelid),
         pg_get_expr(p.polwithcheck, p.polrelid)
    into v_admin_qual, v_admin_src
  from pg_policy p
  where p.polrelid = 'public.profiles'::regclass
    and p.polname = 'profiles_admin_all';

  if v_admin_qual is null and v_admin_src is null then
    raise exception 'FAIL: profiles_admin_all is missing from public.profiles - an administrator could not read the account list';
  end if;
  if coalesce(v_admin_qual, '') like '%is_staff%'
     or coalesce(v_admin_src, '') like '%is_staff%' then
    raise exception 'FAIL: profiles_admin_all asks is_staff() instead of is_admin() - it matches a supervisor and a lecturer, and hands the whole roster back through the administrator arm';
  end if;
  if coalesce(v_admin_qual, '') not like '%is_admin%' then
    raise exception 'FAIL: profiles_admin_all does not ask is_admin() - got: %', coalesce(v_admin_qual, '<null>');
  end if;

  -- A third read policy that asks the tier and not the per-person question is the
  -- old roster read under a name of its own. It is a union with the policy above,
  -- so it defeats the narrowing just as thoroughly, and it is not this file's to
  -- drop: name it and stop, rather than leave a leak that the file looks like it
  -- closed.
  select string_agg(p.polname, ', ' order by p.polname) into v_extra
  from pg_policy p
  where p.polrelid = 'public.profiles'::regclass
    and p.polpermissive
    and p.polcmd in ('r', '*')
    and p.polname <> 'profiles_select_own_or_staff'
    and coalesce(pg_get_expr(p.polqual, p.polrelid), '') like '%is_staff%'
    and coalesce(pg_get_expr(p.polqual, p.polrelid), '') not like '%can_read_profile%'
    and coalesce(pg_get_expr(p.polqual, p.polrelid), '') not like '%is_admin%';

  if v_extra is not null then
    raise exception 'FAIL: another permissive read policy on public.profiles still asks is_staff() without can_read_profile(): %. Drop or narrow it - it is a union with profiles_select_own_or_staff, so the roster stays readable.', v_extra;
  end if;

  -- This file narrowed the roster; the isolation file narrowed nine other reads.
  -- A project missing that file is missing all ten, so say so once, by name, on
  -- the policies that carry the loudest data (`answers`, `score`, marks, the
  -- acceptances) instead of reporting a clean run on a project that is only a
  -- tenth narrower.
  select string_agg(t.tbl || '.' || p.polname, ', ' order by p.polname) into v_attempt
  from (values ('public.exam_submissions'),
               ('public.exam_allowed_students'),
               ('public.question_grades'),
               ('public.proctoring_consents')) as t(tbl)
  join pg_policy p on p.polrelid = to_regclass(t.tbl)
  where p.polcmd in ('r', '*')
    and coalesce(pg_get_expr(p.polqual, p.polrelid), '') like '%is_staff%'
    and coalesce(pg_get_expr(p.polqual, p.polrelid), '') not like '%can_reach_exam%';

  if v_attempt is not null then
    raise notice 'NOTICE: % still read by is_staff() alone. This project is also missing the rest of 20261111090100_lecturer_isolation.sql (papers, questions, attempts, hand marks, the incident feed, snapshots). This file narrowed the profile roster only - run that file too.', v_attempt;
  end if;

  raise notice 'OK: the lecturer roster read is installed - can_reach_exam(), can_read_profile() and profiles_select_own_or_staff';
end $$;
