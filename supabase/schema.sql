-- =====================================================================
-- PROCTOR — SUPABASE SCHEMA + ROW LEVEL SECURITY (PRODUCTION READY)
-- Single source of truth for the Flutter app at ../mobile.
-- Run in Supabase SQL editor. Assumes auth.users is Supabase Auth.
--
-- SECURITY MODEL (what the policies below deliberately enforce)
--   * `profiles.role` is the boundary every policy trusts, so it is write-once
--     for non-admins: self-service signup may only create role='student'
--     (profiles_insert_self_student) and a trigger blocks later role rewrites
--     unless the caller is an admin (guard_user_role_change). The four roles
--     live in the `user_role` enum: admin, lecturer, supervisor, student.
--   * Students never see answer keys: there is no student SELECT policy on
--     `questions`; they read the definer view `questions_public`, which carries
--     neither `correct_option` nor `correct_text_answer` and shows a row only to
--     four audiences (section 3): admins and supervisors, the paper's author, a
--     student the paper is aimed at **while its window is open**, or the owner of
--     an ongoing attempt until that attempt's deadline. On the raw table a
--     lecturer reads the papers they wrote and an admin/supervisor reads every
--     paper (`questions_select_supervisor`), so being employed is not a way into
--     somebody else's draft.
--   * Four question shapes share `questions`: `'multiple_choice'` (options + an
--     index), `'true_false'` (`correct_text_answer` is 'true' or 'false'),
--     `'fill_in_the_blank'` (`correct_text_answer`, graded case-insensitively
--     after trimming) and `'subjective'` (no answer key at all — an essay, marked
--     by hand). A choice answer is merged by `merge_submission_answer`; true/false
--     and fill-in-the-blank go through `merge_submission_text_answer`, which is
--     also what a true/false tap stores ('true' / 'false' as a JSON string).
--   * Students cannot grade or close themselves with a direct UPDATE — the
--     RPCs `submit_exam` (automatic grading) and `register_violation` (the
--     weighted escalation: 3 weighted points closes the attempt as
--     `flagged_for_review` for `resolve_flagged_attempt()`) are the only writers
--     of status/score/submitted_at, and both re-check that the caller owns the
--     submission. A subjective answer is
--     marked afterwards by the paper's owner through `grade_submission()`, which
--     records the marks in `question_grades` (section 8) and recomputes `score`
--     as automatic + awarded.
--   * Exams are *optionally* scheduled. `exams.starts_at` / `exams.ends_at` are
--     nullable; NULL on both (the default, and every paper authored before
--     scheduling existed) means the paper is offered as soon as it is published.
--     A window is enforced in two places and nowhere else:
--     `submissions_insert_own_ongoing` refuses an attempt row before `starts_at`
--     or after `ends_at`, and `attempt_deadline()` caps an attempt already in
--     progress by `ends_at` â€” the same function the two answer-merge RPCs and
--     `submit_exam()` read, so "how long have I got" has one answer (section 9).
--   * Evidence is append-only for clients: `proctoring_logs` has no INSERT
--     policy, so register_violation() is the single write path. That RPC is
--     idempotent per `client_event_id`, which is what lets the app queue a
--     violation it could not deliver and replay it later without inventing a
--     second strike (see `client_timestamp` / `client_event_id` in section 5).
--   * A reset is itself evidence. Clearing an attempt destroys it together with
--     its incident rows, so the call that does it also records what it
--     destroyed in `session_reset_logs` (section 7): append-only, with
--     `actor_id` defaulted from auth.uid() on the server, so the trail cannot be
--     edited away by the person who just used it.
-- =====================================================================

create extension if not exists "uuid-ossp";

-- ---------------------------------------------------------------------
-- 0a. DEFERRED FUNCTION-BODY CHECKING (before the first helper is created)
-- ---------------------------------------------------------------------
-- The helpers in section 1 are `language sql` predicates that name tables
-- created much later in this file (`profiles`, `exams`, `exam_allow_list`,
-- `exam_submissions`) - `is_staff()`, `owns_exam()`, `is_attempt_resetter()`,
-- `student_can_access_exam()`. With `check_function_bodies` on (the server
-- default) `create function` parses and *resolves* a SQL body at creation time,
-- so a fresh install would fail with `relation "public.profiles" does not exist`
-- before it ever reached section 2. That is also what makes this file re-runnable
-- in one pass on an empty database: the helper outlives the object it quotes and
-- the tables catch up below.
--
-- It only governs *creation-time* validation. Nothing is skipped at run time: a
-- SQL function still plans against the real tables, and a missing one is an error
-- the moment the function is called.
--
-- Session-scoped, so it needs no reset (the SQL editor ends it with the session).
-- The alternative - reordering the whole file so `profiles` and `exams` precede
-- every predicate - would leave the schema unreadable in the order it is
-- explained. This statement is the one line that buys that layout.
set check_function_bodies = off;
-- ---------------------------------------------------------------------
-- 0. API PRIVILEGES (before the first table exists)
-- ---------------------------------------------------------------------
-- PostgREST reaches `public` as `anon` / `authenticated` / `service_role`, and
-- a row security policy is only consulted once those roles hold the *ordinary*
-- privileges: USAGE on the schema, then SELECT/INSERT/UPDATE/DELETE on the
-- object. A database without them refuses every statement before RLS runs,
-- answering `401 {"code":"42501","message":"permission denied for schema
-- public"}` — which is what made the console report that no account could read
-- its profile, for every account, while sign-in itself kept succeeding. (The
-- symptom, and the copy to run against an already-deployed project, are in
-- supabase/migrations/grant_api_roles_public_schema.sql.)
--
-- It sits above the first `create table` so the ALTER DEFAULT PRIVILEGES apply
-- to everything this file goes on to create; the blanket grants are what cover
-- objects that already exist, since schema.sql is re-runnable.
--
-- Nothing here widens what a caller can *see*: the policies below remain the
-- only thing that decides rows, which is why `anon` still reads zero rows from
-- `profiles` (its one SELECT policy is `to authenticated`).
grant usage on schema public to postgres, anon, authenticated, service_role;

grant all privileges on all tables    in schema public to postgres, anon, authenticated, service_role;
grant all privileges on all sequences in schema public to postgres, anon, authenticated, service_role;
grant all privileges on all functions in schema public to postgres, anon, authenticated, service_role;

alter default privileges in schema public
  grant all privileges on tables to postgres, anon, authenticated, service_role;
alter default privileges in schema public
  grant all privileges on sequences to postgres, anon, authenticated, service_role;
alter default privileges in schema public
  grant all privileges on functions to postgres, anon, authenticated, service_role;



-- ---------------------------------------------------------------------
-- 1. PROFILES (profile table, 1:1 with auth.users)
-- ---------------------------------------------------------------------
-- The table is called `profiles` because that is what a row is: the account
-- itself lives in `auth.users`, and this row adds the role, the display name
-- and the e-mail that the app renders. (It used to be `public.users`, which
-- made `public.users` and `auth.users` easy to mix up in a query.)
--
-- FOUR ROLES, one enum:
--   admin       manages accounts: the mobile admin console, and the only role
--               that may create a profile row for somebody else or rewrite a
--               `role` after the fact.
--   lecturer    staff: reviews the attempt roster and analytics.
--   supervisor  staff: invigilates exams, monitors attempts and resets them.
--   student     sits exams.
-- `lecturer` and `supervisor` are the same tier for *reads* -- is_staff() --
-- while writes to other people's rows are admin-only, so a lecturer cannot
-- quietly promote an account to admin.
do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typname = 'user_role'
  ) then
    create type public.user_role as enum ('admin','lecturer','supervisor','student');
  end if;
end $$;

-- Upgrade path for a database created by an earlier revision of this file.
-- schema.sql stays re-runnable, so the `users` -> `profiles` and
-- `name` -> `full_name` renames have to live here too, not only in
-- supabase/migrations/add_user_roles_and_profiles.sql (which is the copy to run
-- against an already-deployed project, where it is the only file that runs).
do $$
begin
  if to_regclass('public.users') is not null
     and to_regclass('public.profiles') is null then
    alter table public.users rename to profiles;
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'profiles'
      and column_name = 'name'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'profiles'
      and column_name = 'full_name'
  ) then
    alter table public.profiles rename column name to full_name;
  end if;
end $$;

-- The previous revision stored `role` as text behind a two-value CHECK.
-- Convert the column to the enum in place: 'student' and 'supervisor' are valid
-- labels, so no row is lost, and the type carries the constraint from now on.
do $$
declare
  v_udt        text;
  v_constraint text;
begin
  if to_regclass('public.profiles') is null then
    return; -- fresh install: the CREATE TABLE below has not run yet
  end if;

  select c.udt_name into v_udt
  from information_schema.columns c
  where c.table_schema = 'public'
    and c.table_name = 'profiles'
    and c.column_name = 'role';

  if v_udt is null or v_udt = 'user_role' then
    return; -- no role column at all, or already the enum
  end if;

  for v_constraint in
    select con.conname
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace nsp on nsp.oid = rel.relnamespace
    where nsp.nspname = 'public'
      and rel.relname = 'profiles'
      and con.contype = 'c'
      and pg_get_constraintdef(con.oid) like '%role%'
  loop
    execute format('alter table public.profiles drop constraint %I', v_constraint);
  end loop;

  alter table public.profiles alter column role drop default;
  alter table public.profiles
    alter column role type public.user_role using role::text::public.user_role;
  alter table public.profiles alter column role set default 'student';
end $$;

create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  role        public.user_role not null default 'student',
  full_name   text not null,
  email       text not null unique,
  created_at  timestamptz not null default now(),
  -- Academic metadata: who this account belongs to inside the institution.
  --
  -- Free text rather than a `faculties` / `departments` pair of tables, because
  -- the values are *labels a policy compares*, not entities with their own
  -- lifecycle: nothing joins them, nothing cascades from them, and an
  -- administrator importing a roster writes them straight from a CSV. NULL means
  -- "not stated", and every scoped policy below reads NULL as *no narrowing* —
  -- an account whose faculty was never recorded keeps the access it had before
  -- the columns existed, so adding the metadata can never lock anybody out.
  --
  -- `level` is the catalogue's own spelling ('100' … '600'), so an exam aimed at
  -- '300' matches every profile row that says '300' — the app's
  -- `AcademicCatalog` is the one place those labels are written down.
  faculty     text,
  department  text,
  level       text,
  -- Identification numbers: the institution's own name for the person, as it is
  -- printed on the student ID card (`matric_number`) or the staff badge
  -- (`staff_id`). Optional in every sense — nullable, not unique, never compared
  -- by a policy — because they are *labels a human reads* and a roster import
  -- may not have the number for every row. A student's row carries
  -- `matric_number` and a staff row `staff_id`; either may be NULL, and neither
  -- is a key, so a repeated or missing cell can never fail an import wholesale.
  matric_number text,
  staff_id      text
);

-- The upgrade path for a project created before the academic metadata: the
-- `create table if not exists` above is a no-op there, so the columns are added
-- in place instead of being lost. `supabase/migrations/academic_targeting.sql`
-- carries the three label statements and
-- `supabase/migrations/profile_identity_numbers.sql` the two identity ones, and
-- the files must be kept in step.
alter table public.profiles add column if not exists faculty    text;
alter table public.profiles add column if not exists department text;
alter table public.profiles add column if not exists level      text;
alter table public.profiles add column if not exists matric_number text;
alter table public.profiles add column if not exists staff_id      text;

alter table public.profiles enable row level security;

-- Security Definer helpers: a policy on `profiles` can ask about the caller's
-- role without re-entering the policies on `profiles`, which would recurse
-- (policy -> select profiles -> policy -> ...). `set search_path` pins the
-- lookup so a hijacked search_path cannot swap the table underneath.
create or replace function public.is_staff()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('admin','lecturer','supervisor')
  );
$$;

-- Admin-only. Used by the profiles policies and by guard_user_role_change();
-- this is the tier the mobile admin console signs in as.
create or replace function public.is_admin()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

-- The *intervention* tier: who may write to somebody else's attempt row (a
-- status change or an after-the-fact re-grade) and who may read the incident
-- feed. Deliberately not the same question as "who may reset one" - see
-- is_attempt_resetter() below.
--
-- This is a *tier* question and only a tier question: "is this account an admin
-- or a supervisor". It says nothing about *which* paper, and since
-- `migrations/20261109090000_supervisor_exam_assignments.sql` no policy in this
-- file asks it any more - the per-paper question is `can_supervise_exam(exam_id)`
-- (§2c), because a supervisor is accountable for the sittings an administrator
-- assigned to them and an administrator is accountable for all of them. The
-- function stays defined for two reasons: the tier is still the right question for
-- *identity* actions (the Edge Functions name it), and a database that has not
-- re-run its older files still carries policies that call it - re-running this
-- file must not leave those undefined.
create or replace function public.is_exam_supervisor()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('admin', 'supervisor')
  );
$$;

-- role = 'supervisor' exactly - the one staff label whose reach the assignment
-- scope narrows.
--
-- Written as its own predicate rather than as `not is_admin() and not ...` at each
-- call site because the *compliment* is what the policies need to express: "staff,
-- except that a supervisor is limited to the papers they were assigned". An
-- administrator and a lecturer answer false here, which is exactly why the two of
-- them keep the reach they had on the day before this predicate existed. Stated
-- once, a policy cannot accidentally narrow a lecturer while trying to narrow a
-- supervisor.
create or replace function public.is_supervisor_only()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'supervisor'
  );
$$;

comment on function public.is_supervisor_only() is
  'True only for a supervisor account - the staff label whose reach supervisor_exam_assignments narrows. Admin and lecturer are false, which is what keeps their policies unchanged.';

-- The *reset* tier: who may clear a student's attempt and the evidence that
-- went with it.
--
-- Resetting is the one destructive staff action in the console - it deletes the
-- `exam_submissions` row (cascading to the answers and every `proctoring_logs`
-- incident row) and then purges the snapshot objects that belonged to it - so
-- the tier is wider than the read tier on purpose: the person most likely to
-- need it is the lecturer who wrote the paper. They are the one who discovers
-- the answer key was wrong, or that the wrong candidate was disqualified, and
-- they can already read every attempt through `is_staff()`; withholding the
-- repair from them while granting it to a supervisor who did not write the
-- question buys nothing. They do *not* join `is_exam_supervisor()`: nothing
-- here lets a lecturer rewrite a row in place, which is what that predicate
-- still guards.
--
-- The snapshot purge and the reset audit row ask this predicate - the two steps
-- that follow the delete and must keep working for the caller the delete has just
-- allowed. The delete itself is narrower by design:
-- `submissions_delete_supervisor` asks
-- `can_supervise_exam(exam_id) or owns_exam(exam_id)` - the supervisor of that
-- paper, or its author, because deleting an attempt is a repair of a paper you are
-- accountable for, while
-- `is_attempt_resetter()` (every lecturer) would let any lecturer delete any
-- attempt in the institution. `UserRole.canResetAttempts` in the Flutter app is
-- this list (admin, supervisor, lecturer), and the console gates the *control* per
-- row to the papers the lecturer owns; `mobile/test/schema_contract_test.dart`
-- reads this sentence back out of the file and fails if the two drift apart.
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

-- Does the caller own the paper a piece of evidence belongs to?
--
-- The read tier for *evidence* is deliberately narrower than the roster read.
-- `is_staff()` may see every attempt (`submissions_select_own_or_supervisor`) -
-- that is what makes a lecturer's monitor roster work on any sitting - but what
-- was recorded *inside* a sitting is a different question: the incident rows in
-- `proctoring_logs` and the reset audit rows in `session_reset_logs` name
-- students, timings and sometimes the member of staff who acted. A lecturer sees
-- those for the papers they wrote; the supervisors of a paper - an administrator,
-- or the supervisor assigned to it (`can_supervise_exam()`) - see them for that
-- paper.
--
-- Asked with the evidence row's own exam id - `proctoring_logs` reaches it
-- through `exam_submissions.exam_id`, `session_reset_logs` carries it as plain
-- evidence - so the two policies cannot disagree about what "owns" means.
-- `created_by` is the column the authoring console already scopes edits with
-- (`exams_update_owner`, `questions_*_author`).
--
-- SECURITY DEFINER for the same reason as the role predicates above: the policy
-- on `proctoring_logs` must not have to re-enter the policies on `exams` to
-- answer this, and `set search_path` pins the lookup so a hijacked path cannot
-- swap the table underneath. A policy that calls this may therefore be created on
-- a database where `exams` is not readable by the caller at all.
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

-- "May this student sit this paper?" - published, and aimed at the caller either
-- by the paper's faculty/department/level or by its borrow list.
--
-- Three places ask it and none of them can ask the others: `exams_select` (may I
-- see the paper?), `questions_public` (may I read its questions?) and
-- `submissions_insert_own_ongoing` (may I start it?). A policy on
-- `exam_submissions` and a definer *view* may not assume the caller can read
-- `exams`, `profiles` or `exam_allowed_students` without re-entering those tables'
-- policies - and for `exams`, re-entering `exams_select` itself. Named once here,
-- the strict rule (blank paper label = no narrowing, blank profile field = no
-- match, borrow list as its own OR branch) cannot drift between its three callers -
-- which is exactly how a student used to be unable to *see* a paper while still
-- being able to start it and read its questions.
--
-- No schedule window: "may this student ever sit this paper" and "is the window
-- open now" are different questions, and a window here would drop a closed paper
-- out of the student's own history. The callers that need the window ask for it
-- themselves (`submissions_insert_own_ongoing`, `questions_public`).
--
-- No `is_staff()` arm either: staff access does not depend on being aimed at, so
-- the callers OR in `is_exam_supervisor()` / `owns_exam()` on their own.
--
-- And no **supervisor**: `not public.is_supervisor_only()` in front of the EXISTS
-- below. The predicate asks about the caller's labels, and a profile with NULL
-- labels matches an untargeted paper - which is every staff profile, because the
-- admin console creates accounts with a role, a name and an email and nothing else.
-- So the student arm of `exams_select` used to offer an unassigned supervisor any
-- published untargeted paper, which they could then read the questions of and even
-- start. `20261103090100` left that arm role-neutral on purpose - a lecturer who is
-- also enrolled is "exactly the borrow-list case" - and that case survives: the
-- guard names the supervisor tier and nothing else, so a lecturer and an
-- administrator answer here exactly as they did, and a supervisor's reach stays
-- `can_supervise_exam(paper)` in the callers, where it belongs.
-- `20261110090000_supervisor_student_arm.sql` is the same statement for a project
-- that is already live.
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

-- Historical name, kept deliberately: a policy or RPC created by an *earlier*
-- revision of this file still calls it on a database that has not re-run this
-- file yet. It resolves to the staff tier, exactly as it did back when
-- 'supervisor' was the only staff role, so re-running this file can never
-- narrow anybody's access. New code calls is_staff() / is_admin().
create or replace function public.is_supervisor()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select public.is_staff();
$$;

-- Drop legacy policies to ensure a clean state. The `users_*` names are what a
-- pre-rename database still carries on this table, so they are dropped too.
drop policy if exists "users_select_own_or_supervisor" on public.profiles;
drop policy if exists "Users can view own profile" on public.profiles;
drop policy if exists "Authenticated users can read profiles" on public.profiles;
drop policy if exists "users_insert_self" on public.profiles;
drop policy if exists "users_insert_self_student" on public.profiles;
drop policy if exists "users_update_self" on public.profiles;
drop policy if exists "profiles_select_own_or_staff" on public.profiles;
drop policy if exists "profiles_insert_self_student" on public.profiles;
drop policy if exists "profiles_update_self" on public.profiles;
drop policy if exists "profiles_admin_all" on public.profiles;

-- "May this supervisor read *this person's* profile row?" - the per-person twin of
-- `can_supervise_exam()` (§2d), and the reason a supervisor's monitor can print
-- "Aisha Bello" without a supervisor being able to enumerate the student body.
--
-- Three questions, in order:
--   * did this person *sit* a paper the caller runs - an `exam_submissions` row on
--     an assigned paper. This is the roster the monitor renders, and the only place
--     a supervisor strictly needs somebody's name;
--   * was this person *granted* one of those papers - an `exam_allowed_students`
--     row (§2b), the "may this person sit it" answer the console shows before an
--     attempt exists;
--   * is this person *aimed at* by one of those papers - the paper names at least
--     one of faculty/department/level and the student's row matches every label it
--     names (the same blank-label reading `student_can_access_exam()` uses). A paper
--     that names no cohort is offered to everybody, and "aimed at everybody" would
--     turn this branch into "every student in the institution" - so the branch
--     requires the paper to name something. An untargeted paper reaches its
--     audience through the two answers above, which is the audience a console can
--     actually display.
--
-- Not a staff question. Another member of staff's row - the paper's author
-- included - is not readable through this, and nothing a supervisor's screens
-- render comes from one: the roster prints students, the reset and review dialogs
-- name the student, and the author of a paper is a uuid the console never resolves.
--
-- SECURITY DEFINER for the reason every predicate here is: a policy on `profiles`
-- may not re-enter the policies on `profiles`, and this one reads
-- `supervisor_exam_assignments` (§2c), `exam_allowed_students` (§2b),
-- `exam_submissions` (§4) and `exams` - tables it has to answer for a caller who may
-- read none of them. It sits here, above the policy that calls it, and section 0a is
-- what lets it name tables created further down this file.
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
         join public.supervisor_exam_assignments a on a.exam_id = s.exam_id
         where s.student_id = p_profile_id
           and a.supervisor_id = auth.uid()
       )
       or exists (
         select 1
         from public.exam_allowed_students t
         join public.supervisor_exam_assignments a on a.exam_id = t.exam_id
         where t.student_id = p_profile_id
           and a.supervisor_id = auth.uid()
       )
       or exists (
         select 1
         from public.profiles p
         join public.supervisor_exam_assignments a on a.supervisor_id = auth.uid()
         join public.exams e on e.id = a.exam_id
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
  'Per-person scope for the profiles read: true for a student who sat, was granted or is aimed at a paper the caller is assigned to. The read policy asks it only of a supervisor - an administrator and a lecturer are not is_supervisor_only() - so it answers false for another member of staff by design.';

revoke execute on function public.can_read_profile(uuid) from public, anon;
grant execute on function public.can_read_profile(uuid) to authenticated, service_role;

-- Read: your own row; every row when you are staff - the staff roster, the admin
-- console's account list and live exam monitor all render other people's names and
-- roles. Deliberately NOT "any authenticated user": a student must not be able to
-- enumerate the roster of the whole institution.
--
-- The supervisor is the one staff role whose read is narrowed. Until
-- `20261109090000_supervisor_exam_assignments.sql` any supervisor read every
-- profile row by being `is_staff()` - every matriculation number, faculty,
-- department, level and photograph in the institution, with no assignment and no
-- sitting - because the tier read was the only question this policy asked.
-- `can_read_profile()` above is the per-person narrowing: the students who sat,
-- were granted, or are aimed at a paper the supervisor runs. An administrator and a
-- lecturer are not `is_supervisor_only()`, so their roster read is the sentence it
-- always was.
create policy "profiles_select_own_or_staff"
  on public.profiles for select
  to authenticated
  using (
    id = auth.uid()
    or (
      public.is_staff()
      and (not public.is_supervisor_only() or public.can_read_profile(id))
    )
  );

-- Self-service provisioning may only ever create a STUDENT row. Without the
-- role check, anyone who can sign up (public anon key) could insert
-- role='supervisor' for themselves — and every policy in this file trusts
-- `profiles.role`. Staff and admin rows are created out of band: by an admin
-- through the `admin-create-user` Edge Function, or by the SQL editor and the
-- service_role key, both of which bypass RLS.
create policy "profiles_insert_self_student"
  on public.profiles for insert
  to authenticated
  with check (id = auth.uid() and role = 'student');

-- Profile owners may correct their own name. `role` is protected by the trigger
-- below, because RLS cannot restrict *columns*.
create policy "profiles_update_self"
  on public.profiles for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- The admin tier: full row access for account management (provision a lecturer,
-- fix a misspelt name, promote a supervisor, clean up a duplicate). This is the
-- policy the admin console relies on, and the one that lets it list
-- every account.
--
-- One caveat worth knowing before using the DELETE half: deleting a profile row
-- does not delete the auth account, because `auth.users` is owned by Supabase
-- Auth. Removing an account for good means calling Auth's admin API (or, from
-- the Supabase Dashboard Authentication tab); the row here is only the profile.
create policy "profiles_admin_all"
  on public.profiles for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- `role` is the security boundary the whole schema is built on, so it cannot be
-- rewritten through a self-update. Admins are the one role that may do it -- that
-- is what the admin console exists for -- and `profiles_admin_all` above is
-- the matching RLS half of the same rule.
--
-- Two sessions have to stay able to change a role or a project could never be
-- bootstrapped: the SQL editor / migrations, which carry no JWT at all, and the
-- service_role key, which is what an Edge Function holds. Neither bypasses a
-- trigger, so both are recognised explicitly below: `request.jwt.claims` is set
-- by PostgREST for real API traffic only, and its `role` claim reads
-- 'service_role' when the request was signed with the service key. A request
-- from a signed-in user always lands in the is_admin() branch, so this escape
-- hatch is not reachable with an anon or a user token.
create or replace function public.guard_user_role_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_claims text := nullif(current_setting('request.jwt.claims', true), '');
begin
  if new.role is distinct from old.role
     and v_claims is not null
     and coalesce(v_claims::jsonb ->> 'role', '') <> 'service_role'
     and not public.is_admin() then
    raise exception 'profiles.role is immutable for non-admins'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists users_guard_role_change on public.profiles;
drop trigger if exists profiles_guard_role_change on public.profiles;
create trigger profiles_guard_role_change
  before update on public.profiles
  for each row execute function public.guard_user_role_change();

-- The same argument as `role`, for the other columns a policy trusts.
--
-- `profiles_update_self` and `profiles_insert_self_student` above are *row*
-- policies, and RLS cannot restrict columns, so an account could rewrite its own
-- `faculty` / `department` / `level` and retarget itself: `exams_select`,
-- `student_can_access_exam()` and `questions_public` all compare those columns
-- against the reader's own row, so aiming a paper is pointless if the target can
-- move. `matric_number` / `staff_id` are the identity a human reads on the roster
-- and in every export taken from it, and `email` is the address the row was
-- provisioned with - the join key a roster import matches, and the login address
-- in `auth.users`.
--
-- For a caller that arrives with JWT claims whose `role` claim is not
-- 'service_role' and who is not an admin: on INSERT the three labels and the two
-- identity numbers must be NULL, and `lower(email)` must equal the JWT's `email`
-- claim (a self-provisioned row is a name and an address, not an academic
-- identity); on UPDATE those five columns and `email` are immutable. `full_name`
-- stays editable, since `profiles_update_self` says owners may correct their name
-- and no policy compares it.
--
-- The escape hatches are `guard_user_role_change()`'s, for the same reason - a
-- project could not be bootstrapped without them: no claims at all (SQL editor,
-- `supabase db reset`, `seed.sql`, the fixtures in `supabase/tests/`) or the
-- service_role key (the admin Edge Functions and roster imports).
create or replace function public.guard_profile_labels()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  -- Null for anything that did not arrive through PostgREST: a migration, the SQL
  -- editor, `supabase db reset`, a fixture in `supabase/tests/`.
  v_claims      text := nullif(current_setting('request.jwt.claims', true), '');
  v_claim_role  text := '';
  v_claim_email text;
begin
  if v_claims is null then
    return new;
  end if;

  begin
    v_claim_role  := coalesce(v_claims::jsonb ->> 'role', '');
    v_claim_email :=
      nullif(lower(btrim(coalesce(v_claims::jsonb ->> 'email', ''))), '');
  exception
    when others then
      -- A malformed claim is not a privilege: fall through as an ordinary caller.
      v_claim_role  := '';
      v_claim_email := null;
  end;

  if v_claim_role = 'service_role' or public.is_admin() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.faculty          is not null
       or new.department    is not null
       or new.level         is not null
       or new.matric_number is not null
       or new.staff_id      is not null then
      raise exception 'academic labels and identity numbers are set by the institution, not at sign-up'
        using errcode = '42501',
              hint = 'leave faculty, department, level, matric_number and staff_id null; an administrator records them from the roster';
    end if;

    if v_claim_email is null
       or lower(btrim(new.email)) <> v_claim_email then
      raise exception 'profiles.email must be the address of the authenticated account'
        using errcode = '42501',
              hint = 'insert the row for the address you signed in with; an administrator can correct it later';
    end if;

    return new;
  end if;

  if new.faculty          is distinct from old.faculty
     or new.department    is distinct from old.department
     or new.level         is distinct from old.level
     or new.matric_number is distinct from old.matric_number
     or new.staff_id      is distinct from old.staff_id
     or new.email         is distinct from old.email then
    raise exception 'profile labels are set by the institution, not by the account'
      using errcode = '42501',
            hint = 'ask an administrator to correct faculty, department, level, matric_number, staff_id or email';
  end if;

  return new;
end;
$$;

comment on function public.guard_profile_labels() is
  'Refuses a self-service write to the profile labels a policy compares or a human reads: on INSERT the academic labels and identity numbers must be null and the email must be the session''s own; on UPDATE those five columns and email are immutable. Administrators, service_role and claims-less sessions (SQL editor, migrations) may write them.';

drop trigger if exists users_guard_labels on public.profiles;
drop trigger if exists profiles_guard_labels on public.profiles;
create trigger profiles_guard_labels
  before insert or update on public.profiles
  for each row execute function public.guard_profile_labels();

-- ---------------------------------------------------------------------
-- 2. EXAMS
-- ---------------------------------------------------------------------
-- `starts_at` / `ends_at` are the *optional* scheduling window, and NULL on
-- both is the default and the common case:
--   * both NULL  -> an unscheduled paper: offered to students as soon as it is
--                   published, exactly as every paper behaved before scheduling
--                   existed;
--   * starts_at  -> the paper is not offered before that instant;
--   * ends_at    -> the paper closes then. No new attempt may be created after
--                   it (`submissions_insert_own_ongoing`), and it *caps* the
--                   effective deadline of an attempt still in progress, through
--                   `attempt_deadline()` - so a hard close is a hard close.
-- timestamptz, so a window means one instant everywhere the app runs; the
-- console sends UTC and the clients render it in the student's own zone.
create table if not exists public.exams (
  id               uuid primary key default uuid_generate_v4(),
  title            text not null,
  created_by       uuid not null references public.profiles(id) on delete cascade,
  duration_minutes int not null check (duration_minutes > 0),
  is_published     boolean not null default false,
  shuffle_questions boolean not null default false,
  starts_at        timestamptz,
  ends_at          timestamptz,
  created_at       timestamptz not null default now(),
  -- Who the paper is *for*. Each column is an optional narrowing and NULL means
  -- "anybody": a paper with all three NULL is the institution-wide paper every
  -- publication was before targeting existed. The predicate that reads them is
  -- `exams_select`, and it compares each column against the reader's own
  -- `profiles` row — with the same NULL-means-no-narrowing reading, so a student
  -- whose faculty was never recorded is not excluded by a targeted paper.
  faculty          text,
  department       text,
  level            text
);

-- The upgrade path for a project created before scheduling: the
-- `create table if not exists` above is a no-op there, so the two columns are
-- added in place instead of being lost. `supabase/migrations/
-- optional_exam_scheduling.sql` carries the same statements, and the two files
-- must be kept in step.
alter table public.exams add column if not exists starts_at timestamptz;
alter table public.exams add column if not exists ends_at   timestamptz;

-- The same upgrade path for the academic targeting columns added with the
-- profiles metadata above; `supabase/migrations/academic_targeting.sql` carries
-- these statements too.
alter table public.exams add column if not exists faculty    text;
alter table public.exams add column if not exists department text;
alter table public.exams add column if not exists level      text;
alter table public.exams add column if not exists shuffle_questions boolean not null default false;

-- `drop constraint if exists` + `add constraint`, like the shape rules in
-- section 3: the name may already exist on a live project, and an
-- `if not exists` guard would silently keep the old definition.
alter table public.exams drop constraint if exists exams_window_ordered;
alter table public.exams
  add constraint exams_window_ordered
  check (starts_at is null or ends_at is null or ends_at > starts_at);

comment on column public.exams.starts_at is
  'When the paper is first offered to students. NULL = an unscheduled paper, offered as soon as it is published.';
comment on column public.exams.ends_at is
  'When the paper closes: no new attempt may be created, and an attempt still in progress is capped by this instant (see attempt_deadline()). NULL = no hard close.';

alter table public.exams enable row level security;

-- ---------------------------------------------------------------------
-- 2c. SUPERVISOR EXAM ASSIGNMENTS (which sitting a supervisor may run)
-- ---------------------------------------------------------------------
-- `is_exam_supervisor()` says *what* an account is (admin or supervisor). This
-- table answers the question the policies actually needed: **which** paper is this
-- supervisor accountable for. One row per (paper, supervisor).
--
-- Why a table rather than `exams.supervisor_id`: a sitting is run by whoever is
-- free that morning, a department has more than one invigilator, and the same
-- person is routinely on two papers in a week. A single column would be a lie the
-- first week it was used, and the second invigilator would need a second column.
--
-- Why the row carries `assigned_by`: "who put this person on this paper" is part
-- of the record - the same reason `session_reset_logs.actor_id` exists. It
-- defaults to `auth.uid()` and the insert policy re-checks it, so it is the
-- database's answer rather than a client's claim, and the Flutter console
-- deliberately never sends the column.
--
-- Both foreign keys cascade. An assignment to a paper or an account that no longer
-- exists grants nothing, and keeping the row would only make the admin screen
-- claim a grant that does not exist.
--
-- Deliberately NOT backfilled by the migration that introduces it: guessing "this
-- existing supervisor keeps all 400 papers" would recreate exactly the hole the
-- table closes. A supervisor with no row sees an empty console that says so.
create table if not exists public.supervisor_exam_assignments (
  exam_id       uuid not null references public.exams(id) on delete cascade,
  supervisor_id uuid not null references public.profiles(id) on delete cascade,
  assigned_by   uuid not null default auth.uid(),
  assigned_at   timestamptz not null default now(),
  -- One row per pair: assigning the same supervisor twice is a no-op rather than a
  -- second grant an unassign would have to guess between.
  primary key (exam_id, supervisor_id)
);

comment on table public.supervisor_exam_assignments is
  'Which supervisor may run which paper. Read by can_supervise_exam(), written only by an administrator. No row = no reach: a supervisor sees, reads and intervenes in exactly the papers listed here.';

-- The primary key already serves "who runs this paper" (its `exam_id` prefix);
-- this index serves the supervisor's own console ("which papers are mine") and the
-- cascade when an account is deleted.
create index if not exists idx_supervisor_assignments_supervisor
  on public.supervisor_exam_assignments(supervisor_id);

-- Nothing but a supervisor account may be assigned. `can_supervise_exam()` asks
-- the role as well as the row, so this is not the guard that makes the scope hold -
-- it is the guard that keeps the *table* honest, so the admin screen cannot record
-- a grant that will never do anything and a later reader cannot mistake it for one.
-- SECURITY DEFINER like the role predicates above: the check must not depend on
-- whether the caller may read the account's `profiles` row.
create or replace function public.guard_supervisor_assignment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role public.user_role;
begin
  select p.role into v_role
  from public.profiles p
  where p.id = new.supervisor_id;

  if v_role is null then
    raise exception 'supervisor assignment: no account with id %', new.supervisor_id
      using errcode = '23503';
  end if;

  if v_role <> 'supervisor' then
    raise exception 'supervisor assignment: % is a %, and only a supervisor account may be assigned to a paper',
      new.supervisor_id, v_role
      using errcode = '23514';
  end if;

  return new;
end $$;

comment on function public.guard_supervisor_assignment() is
  'Refuses a supervisor_exam_assignments row whose supervisor_id is not a supervisor account. can_supervise_exam() asks the role too, so this keeps the table honest rather than carrying the scope.';

drop trigger if exists guard_supervisor_assignment on public.supervisor_exam_assignments;
create trigger guard_supervisor_assignment
  before insert or update on public.supervisor_exam_assignments
  for each row execute function public.guard_supervisor_assignment();

alter table public.supervisor_exam_assignments enable row level security;

drop policy if exists "supervisor_assignments_select_own_or_admin" on public.supervisor_exam_assignments;
drop policy if exists "supervisor_assignments_insert_admin" on public.supervisor_exam_assignments;
drop policy if exists "supervisor_assignments_delete_admin" on public.supervisor_exam_assignments;

-- Read: the supervisor the row names, and administrators (who assign them). A
-- lecturer reads nothing here: their reach comes from `owns_exam()`, and who else
-- was put on a paper is the administrator's business.
create policy "supervisor_assignments_select_own_or_admin"
  on public.supervisor_exam_assignments for select
  to authenticated
  using (supervisor_id = auth.uid() or public.is_admin());

-- Write: administrators only, and only in their own name.
create policy "supervisor_assignments_insert_admin"
  on public.supervisor_exam_assignments for insert
  to authenticated
  with check (public.is_admin() and assigned_by = auth.uid());

-- Unassigning is a DELETE of the pair. There is deliberately NO update policy: the
-- row is a fact ("this person runs this paper"), and changing either half of it is
-- a different assignment, not an edit.
create policy "supervisor_assignments_delete_admin"
  on public.supervisor_exam_assignments for delete
  to authenticated
  using (public.is_admin());

revoke all on table public.supervisor_exam_assignments from anon;
revoke update, truncate on table public.supervisor_exam_assignments from authenticated;
grant select, insert, delete on table public.supervisor_exam_assignments to authenticated;
grant all on table public.supervisor_exam_assignments to service_role;

-- ---------------------------------------------------------------------
-- 2d. "MAY THIS ACCOUNT SUPERVISE *THIS* PAPER?"
-- ---------------------------------------------------------------------
-- The per-paper question every policy below now asks where it used to ask the tier
-- question. Three sentences, in this order:
--   * an administrator may supervise any paper - they assign the supervisors and
--     are accountable for the deployment, so scoping them would leave nobody able
--     to open a monitor on a paper whose invigilator resigned;
--   * a supervisor may supervise the papers `supervisor_exam_assignments` names -
--     the practice the table records;
--   * everybody else (a lecturer, a student, an account with no profile row) may
--     not. `p_exam_id` null answers false: a consent record that is not aimed at a
--     paper (`exam_id IS NULL`) is nobody's to supervise.
--
-- The role is asked here *and* by the guard on the table, on purpose: a supervisor
-- demoted to lecturer keeps their rows, and this predicate stops answering true on
-- the instant the role changed rather than when somebody remembers to clear up the
-- assignments. Re-promoting them restores the sittings they were trusted with,
-- which is the outcome a department wants.
--
-- `can_read_profile()` in section 1 is the same question asked about a *person*
-- rather than a paper - "may this supervisor read this student's profile row" - and
-- it is the other half of the scope: this predicate decides which sittings a
-- supervisor can open, and that one decides whose names the console can print
-- inside them.
--
-- SECURITY DEFINER with `set search_path`, exactly like `owns_exam()`: a policy
-- that calls it must not re-enter the policies on `supervisor_exam_assignments` (or
-- on `profiles`) to answer, and it must work for a caller who may read neither.
create or replace function public.can_supervise_exam(p_exam_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select p_exam_id is not null
     and (
       exists (
         select 1 from public.profiles
         where id = auth.uid() and role = 'admin'
       )
       or exists (
         select 1
         from public.profiles p
         join public.supervisor_exam_assignments a on a.supervisor_id = p.id
         where p.id = auth.uid()
           and p.role = 'supervisor'
           and a.exam_id = p_exam_id
       )
     );
$$;

comment on function public.can_supervise_exam(uuid) is
  'True when the caller may supervise this paper: an administrator, or a supervisor assigned to it in supervisor_exam_assignments. False for a supervisor with no assignment, for a lecturer (who reaches their own papers through owns_exam()) and for a null paper.';

revoke execute on function public.can_supervise_exam(uuid) from public, anon;
grant execute on function public.can_supervise_exam(uuid) to authenticated, service_role;

revoke execute on function public.guard_supervisor_assignment() from public, anon;
grant execute on function public.guard_supervisor_assignment() to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2b. BORROWED-COURSE ACCESS
-- ---------------------------------------------------------------------
-- A paper is aimed at a cohort by the three columns above, but a cohort is not
-- the whole audience: a student from another department may be taking the
-- course (a service course, a minor, a carry-over), and the lecturer knows who
-- before the sitting does. This table is that exception list — one row per
-- (paper, student) pair, added by the paper's author and read by the student it
-- names. `exams_select` is the policy that consumes it.
--
-- A table rather than an `exams.extra_student_ids uuid[]` column: each row is a
-- foreign key, so deleting the student's profile or the paper removes the
-- exception with it (a uuid[] would leave a dangling id behind), and the
-- author's add/remove is a plain PostgREST write that the policies below scope.
create table if not exists public.exam_allowed_students (
  exam_id    uuid not null references public.exams(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  -- Who granted the exception. Audit only: no policy reads it, and an account
  -- deleted afterwards must not take the exception with it, so it is
  -- `on delete set null` rather than a cascade.
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (exam_id, student_id)
);

alter table public.exam_allowed_students enable row level security;

drop policy if exists "exam_allowed_students_select" on public.exam_allowed_students;
drop policy if exists "exam_allowed_students_insert_owner" on public.exam_allowed_students;
drop policy if exists "exam_allowed_students_delete_owner" on public.exam_allowed_students;

-- Read: the student the row names, or any member of staff (the console lists a
-- paper's exceptions next to the paper). A student must not be able to see who
-- else was granted one — that is somebody else's business.
create policy "exam_allowed_students_select"
  on public.exam_allowed_students for select
  to authenticated
  using (
    student_id = auth.uid()
    or (
      public.is_staff()
      and (not public.is_supervisor_only() or public.can_supervise_exam(exam_id))
    )
  );

-- Write: only the paper's author. `owns_exam()` is SECURITY DEFINER, so this
-- check does not re-enter `exams_select` — which is the policy that reads this
-- very table, and would otherwise recurse.
create policy "exam_allowed_students_insert_owner"
  on public.exam_allowed_students for insert
  to authenticated
  with check (public.owns_exam(exam_id));

create policy "exam_allowed_students_delete_owner"
  on public.exam_allowed_students for delete
  to authenticated
  using (public.owns_exam(exam_id));

drop policy if exists "exams_select" on public.exams;
drop policy if exists "exams_insert_supervisor_only" on public.exams;
drop policy if exists "exams_update_owner" on public.exams;
drop policy if exists "exams_delete_owner" on public.exams;

-- Read: staff see their papers, published or not - an invigilator opens a sitting
-- in the department they were assigned to, and the console's monitor list depends
-- on it; the author always sees their own drafts.
--
-- Who "their papers" means, exactly: an administrator and a lecturer see every
-- paper (unchanged - the lecturer's monitor and the authoring console lean on it),
-- while a **supervisor** sees the papers an administrator assigned to them
-- (`can_supervise_exam()`, section 2d). That is what makes the supervisor console's
-- list the sittings they are responsible for instead of the whole institution's,
-- and it is the read half of the scope the other policies enforce: hiding the row
-- here means an unassigned paper's title, schedule and roster are not even offered.
--
-- Students see a **published** paper only when it is aimed at them:
--     every column the paper names must match their own `profiles` row. A paper
--     whose label is effectively empty (NULL or whitespace-only via
--     `nullif(btrim(...))`) is untargeted and stays visible to everybody. A
--     student with a NULL or whitespace-only label is **not** matched by a paper
--     that names that field, so incomplete or blank profiles lose access to
--     targeted papers they do not belong to.
--   * or they were explicitly allowed to borrow it (`exam_allowed_students`,
--     section 2b), which is how a service-course student sees a paper aimed at
--     another department.
--
-- The exception list is read through its own policies above, which let the
-- student see exactly the rows that name them, so this EXISTS needs no definer
-- helper and cannot recurse.
--
-- The third arm is a *student's* arm: `student_can_access_exam()` answers false for
-- a supervisor (`not is_supervisor_only()`), so an unassigned paper is not offered
-- to that console by it - the first arm is the supervisor's, and it names the
-- assignment. Without that term a supervisor's blank profile matched every
-- untargeted paper, which is the leak `20261110090000` closes.
create policy "exams_select"
  on public.exams for select
  to authenticated
  using (
    (
      public.is_staff()
      and (not public.is_supervisor_only() or public.can_supervise_exam(id))
    )
    or created_by = auth.uid()
    or public.student_can_access_exam(id)
  );

create policy "exams_insert_supervisor_only"
  on public.exams for insert
  to authenticated
  with check (
    created_by = auth.uid()
    and public.is_staff()
  );

create policy "exams_update_owner"
  on public.exams for update
  to authenticated
  using (created_by = auth.uid() and public.is_staff());

create policy "exams_delete_owner"
  on public.exams for delete
  to authenticated
  using (created_by = auth.uid() and public.is_staff());

-- ---------------------------------------------------------------------
-- 3. QUESTIONS
-- ---------------------------------------------------------------------
create table if not exists public.questions (
  id                  uuid primary key default uuid_generate_v4(),
  exam_id             uuid not null references public.exams(id) on delete cascade,
  question_text       text not null,
  -- Four question shapes share this table:
  --   'multiple_choice'   -> `options` are the tap targets, `correct_option` the index
  --   'true_false'        -> `options` is empty, `correct_text_answer` is 'true' or 'false'
  --   'fill_in_the_blank' -> `options` is empty, `correct_text_answer` is graded
  --                          case-insensitively after trimming
  --   'subjective'        -> neither key: an essay, marked by hand afterwards
  question_type       text not null default 'multiple_choice'
                        check (question_type in ('multiple_choice', 'true_false',
                                                 'fill_in_the_blank', 'subjective')),
  options             jsonb not null default '[]'::jsonb,
  correct_option      int,
  correct_text_answer text,
  points              numeric not null default 1,
  created_at          timestamptz not null default now(),
  -- Exactly one answer key, matching the question's type. Without this a row
  -- could carry both (graded twice by submit_exam) or neither (ungradeable).
  -- 'subjective' is the deliberate exception: the absence of a key is the shape.
  constraint questions_answer_key_shape check (
    (question_type = 'multiple_choice' and correct_option is not null)
    or
    (question_type = 'true_false'
      and lower(btrim(coalesce(correct_text_answer, ''))) in ('true', 'false'))
    or
    (question_type = 'fill_in_the_blank'
      and coalesce(btrim(correct_text_answer), '') <> '')
    or
    question_type = 'subjective'
  )
);

-- Migration for databases created before question types existed (`create table
-- if not exists` above is a no-op there). Every statement is idempotent.
alter table public.questions add column if not exists question_type text not null default 'multiple_choice';
alter table public.questions add column if not exists correct_text_answer text;
alter table public.questions alter column options set default '[]'::jsonb;
-- A fill-in-the-blank row has no option index, so this column cannot stay NOT NULL.
alter table public.questions alter column correct_option drop not null;

-- Both shape rules are dropped by name and re-created rather than guarded with
-- `if not exists`. This revision widened `question_type` from two values to four,
-- and an `if not exists` guard would have left a live database holding the old
-- two-value check - refusing to *store* a true/false or subjective question being
-- authored in the console against a table that otherwise looks correct. Dropping
-- first is still re-runnable, which is what a file applied twice needs.
alter table public.questions
  drop constraint if exists questions_question_type_check;
alter table public.questions
  add constraint questions_question_type_check
  check (question_type in ('multiple_choice', 'true_false',
                           'fill_in_the_blank', 'subjective'));

alter table public.questions
  drop constraint if exists questions_answer_key_shape;
alter table public.questions
  add constraint questions_answer_key_shape
  check (
    (question_type = 'multiple_choice' and correct_option is not null)
    or
    (question_type = 'true_false'
      and lower(btrim(coalesce(correct_text_answer, ''))) in ('true', 'false'))
    or
    (question_type = 'fill_in_the_blank'
      and coalesce(btrim(correct_text_answer), '') <> '')
    or
    question_type = 'subjective'
  );

-- `points` is what `submit_exam()` sums into `score`, so a zero-or-negative
-- weight would let a paper mark itself down. The column has never had a floor;
-- this is it. (Same drop-then-add shape as above: re-runnable, and it fails
-- loudly at migration time if a database really does hold a negative weight,
-- which is a row worth seeing rather than a rule worth skipping.)
alter table public.questions drop constraint if exists questions_points_non_negative;
alter table public.questions
  add constraint questions_points_non_negative check (points >= 0);

alter table public.questions enable row level security;

drop policy if exists "questions_select_owner" on public.questions;
drop policy if exists "questions_select_supervisor" on public.questions;
drop policy if exists "questions_select_student_published" on public.questions;
drop policy if exists "questions_write_owner" on public.questions;
drop policy if exists "questions_update_owner" on public.questions;
drop policy if exists "questions_delete_owner" on public.questions;

-- Two SELECT paths, and the difference between them is the point of this pair:
-- the author reads their own paper's questions, and an admin or supervisor reads
-- every paper's. The second used to be `is_staff()` - i.e. every lecturer - so any
-- lecturer could read any paper's questions, a colleague's unpublished draft
-- included. `owns_exam()` is the same ownership question asked from the row's
-- `exam_id`, so this policy and the owner policy below cannot disagree about who
-- wrote what.
create policy "questions_select_owner"
  on public.questions for select
  to authenticated
  using (
    exists (
      select 1 from public.exams e
      where e.id = exam_id and e.created_by = auth.uid()
    )
    and public.is_staff()
  );

create policy "questions_select_supervisor"
  on public.questions for select
  to authenticated
  using (
    public.can_supervise_exam(exam_id)
    or public.owns_exam(exam_id)
  );

-- NOTE: there is deliberately NO student SELECT policy on this table, and that
-- is the whole point of the view further down. A policy that lets students read
-- their exam's rows also hands them `correct_option` — i.e. the answer key.
-- Students read public.questions_public instead, which cannot expose it.

create policy "questions_write_owner"
  on public.questions for insert
  to authenticated
  with check (
    exists (
      select 1 from public.exams e
      where e.id = exam_id and e.created_by = auth.uid()
    )
    and public.is_staff()
  );

create policy "questions_update_owner"
  on public.questions for update
  to authenticated
  using (
    exists (
      select 1 from public.exams e
      where e.id = exam_id and e.created_by = auth.uid()
    )
    and public.is_staff()
  );

create policy "questions_delete_owner"
  on public.questions for delete
  to authenticated
  using (
    exists (
      select 1 from public.exams e
      where e.id = exam_id and e.created_by = auth.uid()
    )
    and public.is_staff()
  );

-- The student-safe feed (`questions_public`) is created at the END of section 4,
-- not here, because it LEFT JOINs `exam_submissions` (§4) on the caller's own
-- attempt: a view body is resolved when it is created, so this file cannot define
-- it before the table it joins exists. The whole design note moved with it -
-- the four audiences, the definer view, and the `anon` revoke.

-- ---------------------------------------------------------------------
-- 3b. PROCTORING CONSENTS (the notice accepted before an attempt exists)
-- ---------------------------------------------------------------------
-- Placed here, in front of section 4, for one reason: the attempt policy in §4
-- asks `student_has_consent()`, and a policy's expression is resolved when the
-- policy is created - so the table and the function have to exist first. (Same
-- argument that puts `student_can_access_exam()` in §1.) An existing project
-- gets the identical objects from
-- `supabase/migrations/20261106090000_proctoring_consents.sql`, which also
-- carries the full design note; what follows is the short version.
--
-- What was missing: consent was a claim the client made by *starting*. Nothing
-- recorded what wording a student was shown, when, or whether they were shown
-- anything at all - for a system that turns a camera on somebody and keeps a
-- photograph of their face when a rule is broken, that is not a record. Here it
-- becomes one: a row per (student, paper, notice version), written before the
-- attempt exists, immutable afterwards.
--
-- The server owns "which version is current" (`proctoring_consent_config`); the
-- app owns the text and carries the matching version string
-- (`ProctorConsentConfig` in the Flutter app). A build showing older wording can
-- still record what it showed - `record_consent()` stores it and answers
-- `is_current = false` - but it cannot satisfy the policy, so the student is
-- told to update rather than being refused at the insert with no explanation.
create table if not exists public.proctoring_consent_config (
  id              smallint primary key default 1,
  current_version text not null
                  check (length(btrim(current_version)) between 1 and 64),
  updated_at      timestamptz not null default now(),
  constraint proctoring_consent_config_single_row check (id = 1)
);

insert into public.proctoring_consent_config (id, current_version)
values (1, '2026-11-v1')
on conflict (id) do nothing;

comment on table public.proctoring_consent_config is
  'The proctoring consent notice version a student must have accepted before an attempt can be created. One row. Read by current_proctor_consent_version() / student_has_consent(); set current_version here when the wording changes, and ship an app build whose ProctorConsentConfig.version matches it.';

comment on column public.proctoring_consent_config.current_version is
  'The notice version in force. A consent row only satisfies student_has_consent() when consent_version equals this, so a stale acceptance does not carry over to new wording.';

alter table public.proctoring_consent_config enable row level security;

-- Readable by any signed-in caller; writable through the API by nobody (no
-- write policy, and no grant past `select`). `postgres` and `service_role`
-- bypass this, which is where a version is meant to be changed.
revoke all on table public.proctoring_consent_config from anon, authenticated;
grant select on table public.proctoring_consent_config to authenticated;
grant all on table public.proctoring_consent_config to service_role;

drop policy if exists "consent_config_read_all" on public.proctoring_consent_config;
create policy "consent_config_read_all"
  on public.proctoring_consent_config for select
  to authenticated
  using (true);

create or replace function public.current_proctor_consent_version()
returns text
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select c.current_version
    from public.proctoring_consent_config c
   where c.id = 1;
$$;

comment on function public.current_proctor_consent_version() is
  'The proctoring consent notice version currently in force, or NULL when none is configured (which makes every student_has_consent() call false - fail-closed, never "no notice required").';

revoke execute on function public.current_proctor_consent_version() from public, anon;
grant execute on function public.current_proctor_consent_version()
  to authenticated, service_role;


-- The acceptances themselves.
--
-- `exam_id` is nullable - NULL is "a general acceptance covering every paper" -
-- and carries no foreign key, because this is evidence of what a person agreed
-- to and a cascade from `exams` would let deleting a paper erase the acceptance
-- given to sit it (the same argument `attempt_review_logs` and
-- `session_reset_logs` make). `student_id` does cascade, from `profiles`: an
-- account deletion is the one path that should take the record with it.
create table if not exists public.proctoring_consents (
  id              uuid primary key default uuid_generate_v4(),
  student_id      uuid not null references public.profiles(id) on delete cascade,
  exam_id         uuid,
  consent_version text not null
                  check (length(btrim(consent_version)) between 1 and 64),
  accepted_at     timestamptz not null default now(),
  user_agent      text
);

comment on table public.proctoring_consents is
  'One row per acceptance of the proctoring consent notice: which version, for which paper (NULL = every paper), by whom, when, from what client. Written only by record_consent(); no update or delete path exists for an API caller.';

comment on column public.proctoring_consents.exam_id is
  'The paper this acceptance covers, or NULL for a general acceptance covering every paper. No foreign key: the record of consent outlives the paper it was given for.';

comment on column public.proctoring_consents.consent_version is
  'The notice version the client reported displaying. Only a row matching proctoring_consent_config.current_version satisfies student_has_consent().';

comment on column public.proctoring_consents.user_agent is
  'The transport User-Agent captured by record_consent(). Evidence of what client accepted, not a validated value: nothing branches on it.';

-- Two partial unique indexes, not one constraint: `exam_id` is nullable and
-- NULLs are distinct in a unique index, so a single constraint would let a
-- student accumulate any number of "general" rows and `record_consent()` would
-- quietly stop being idempotent there.
create unique index if not exists proctoring_consents_exam_version_key
  on public.proctoring_consents (student_id, exam_id, consent_version)
  where exam_id is not null;

create unique index if not exists proctoring_consents_general_version_key
  on public.proctoring_consents (student_id, consent_version)
  where exam_id is null;

create index if not exists proctoring_consents_student_accepted_idx
  on public.proctoring_consents (student_id, accepted_at desc);

alter table public.proctoring_consents enable row level security;

drop policy if exists "consents_insert_own" on public.proctoring_consents;
drop policy if exists "consents_select_own_or_supervisor" on public.proctoring_consents;

-- Accepting is the student's own act in their own name.
create policy "consents_insert_own"
  on public.proctoring_consents for insert
  to authenticated
  with check (student_id = auth.uid());

-- Read: your own acceptances, or the supervisor of the paper it names (admin and
-- the assigned supervisor - `can_supervise_exam()`, section 2d). Deliberately not
-- `is_staff()`: a lecturer reads the evidence of a sitting; "did this person agree,
-- and to what wording?" is a supervisory question.
--
-- A general acceptance (`exam_id IS NULL`) is readable by its subject only. There is
-- no paper to be assigned to, so no supervisor is accountable for it - and the row
-- says when a person agreed to a notice, which is not a sitting's evidence.
--
-- And again the control is an absence - no UPDATE policy, no DELETE policy, and
-- `select, insert` as the only grants (the schema's default privileges hand every
-- new table `all` to `authenticated`, so UPDATE/DELETE/TRUNCATE are revoked
-- explicitly: `truncate` ignores RLS, which is why it is named). A consent record
-- its subject can rewrite or remove is not a record.
create policy "consents_select_own_or_supervisor"
  on public.proctoring_consents for select
  to authenticated
  using (
    student_id = auth.uid()
    or (exam_id is not null and public.can_supervise_exam(exam_id))
  );

revoke all on table public.proctoring_consents from anon;
revoke update, delete, truncate on table public.proctoring_consents from authenticated;
grant select, insert on table public.proctoring_consents to authenticated;
grant all on table public.proctoring_consents to service_role;

-- "Has this student accepted the current notice, for this paper or generally?"
-- SECURITY DEFINER with an explicit ownership term, like
-- `student_can_access_exam()`: the answer must not shift if the read policy above
-- is ever tightened.
create or replace function public.student_has_consent(p_exam_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.proctoring_consents c
     where c.student_id = auth.uid()
       and c.consent_version = public.current_proctor_consent_version()
       and (c.exam_id is null or c.exam_id = p_exam_id)
  );
$$;

comment on function public.student_has_consent(uuid) is
  'True when the caller has accepted the proctoring consent notice currently in force, either for this paper or as a general acceptance (exam_id NULL). False when no notice version is configured - fail-closed by design. Asked by submissions_insert_own_ongoing; it grants nothing else.';

revoke execute on function public.student_has_consent(uuid) from public, anon;
grant execute on function public.student_has_consent(uuid) to authenticated, service_role;


-- ---------------------------------------------------------------------
-- 4. EXAM SUBMISSIONS
-- ---------------------------------------------------------------------
create table if not exists public.exam_submissions (
  id            uuid primary key default uuid_generate_v4(),
  student_id    uuid not null references public.profiles(id) on delete cascade,
  exam_id       uuid not null references public.exams(id) on delete cascade,
  answers       jsonb not null default '{}'::jsonb,
  status        text not null default 'ongoing'
                check (status in ('ongoing','flagged_for_review','submitted','disqualified')),
  score         numeric,
  started_at    timestamptz not null default now(),
  submitted_at  timestamptz,
  -- When this attempt's proctoring client last reported for duty (section 5b).
  -- NULL means *nothing has ever checked in* - which is a different statement from
  -- "checked in and saw nothing", and the whole reason this column exists.
  last_heartbeat_at timestamptz,
  unique (student_id, exam_id)
);

-- The list above only applies to a database that does not have the table yet:
-- `create table if not exists` cannot widen a constraint that already exists. This
-- is the same refresh as
-- ../supabase/migrations/20261104090100_weighted_strikes_and_flagged_review.sql,
-- repeated here so re-running this single file also upgrades an older
-- installation.
--
-- `flagged_for_review` is the weighted-threshold state: the sitting is closed (no
-- more answers, no more snapshots) but nothing has been decided - a supervisor
-- calls `resolve_flagged_attempt()` to disqualify it or restore it to 'submitted'
-- for marking. It sits between 'ongoing' and the two final states on purpose; no
-- function may treat it as either of them without saying so.
--
-- Dropped by *definition* and added NOT VALID + VALIDATE for the same reasons as
-- the action_type refresh in section 5: re-runnable, no rewrite of the table, and
-- an unknown existing status surfaces as a validation error that names the row
-- instead of being silently rewritten.
do $$
declare
  v_constraint text;
begin
  for v_constraint in
    select con.conname
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join pg_namespace nsp on nsp.oid = rel.relnamespace
     where nsp.nspname = 'public'
       and rel.relname = 'exam_submissions'
       and con.contype = 'c'
       and pg_get_constraintdef(con.oid) like '%status%'
  loop
    execute format('alter table public.exam_submissions drop constraint %I', v_constraint);
  end loop;
end $$;

alter table public.exam_submissions
  add constraint exam_submissions_status_check
  check (status in ('ongoing', 'flagged_for_review', 'submitted', 'disqualified'))
  not valid;

alter table public.exam_submissions
  validate constraint exam_submissions_status_check;

-- Added for databases created before the heartbeat existed; a no-op on a fresh
-- install, where the CREATE TABLE above already carries it.
--
-- Nothing else reads or writes it: `record_heartbeat()` (bottom of this file) is
-- the single writer, and it is what lets a supervisor tell an attempt that was
-- watched and clean apart from one nobody was watching at all. The denormalised
-- copy exists so the live grid can answer "is this client still there" from the
-- row it already streams, without a join per attempt.
alter table public.exam_submissions
  add column if not exists last_heartbeat_at timestamptz;


alter table public.exam_submissions enable row level security;

drop policy if exists "submissions_select_own_or_supervisor" on public.exam_submissions;
drop policy if exists "submissions_insert_own" on public.exam_submissions;
drop policy if exists "submissions_insert_own_ongoing" on public.exam_submissions;
drop policy if exists "submissions_update_own_ongoing" on public.exam_submissions;
drop policy if exists "submissions_update_supervisor" on public.exam_submissions;
drop policy if exists "submissions_delete_supervisor" on public.exam_submissions;

-- Read: your own attempt, or any attempt of a paper you may supervise. The console
-- roster/audit and the mobile live monitor both need the wide read, and
-- `exams_select` already grants it for the exam rows themselves.
--
-- "Any attempt" is admin-anywhere, lecturer-anywhere (unchanged: a lecturer may
-- watch any sitting - `lecturer_scoped_log_reads.sql`'s "what it does not change"),
-- and supervisor-only-on-assigned-papers (`can_supervise_exam()`, section 2d). The
-- roster is the one table where the scope is visible as an *absence* rather than a
-- refusal: an unassigned paper's attempts are not streamed to the console at all, so
-- the monitor cannot be opened on a sitting nobody asked this account to run.
create policy "submissions_select_own_or_supervisor"
  on public.exam_submissions for select
  to authenticated
  using (
    student_id = auth.uid()
    or (
      public.is_staff()
      and (not public.is_supervisor_only() or public.can_supervise_exam(exam_id))
    )
  );

-- A start row can only ever be a fresh attempt: the student's own id, ongoing
-- status, empty answers, no score or submit time, and the database's start
-- timestamp on a published exam. Otherwise a client could preseed answers or
-- choose a future start time to bypass the server-enforced deadline.
--
-- "Is it this student's paper?" is asked here too, through
-- `student_can_access_exam(exam_id)` - the same predicate `exams_select` and the
-- question feed use. Without it, hiding a paper from the list was cosmetic: a
-- patched client could POST an attempt on any published paper and then read its
-- questions, and an attempt is the row every other row (answers, logs, snapshots,
-- the roster card) hangs from. Publication moved inside that predicate, so
-- `is_published` is no longer repeated below - one statement of "published" per
-- insert instead of two that could drift apart.
--
-- The window is asked here too, and this is the *only* server-side check on it:
-- hiding a tile in the portal is courtesy, so a patched client gets no attempt
-- row before `starts_at` or after `ends_at`. Both bounds are optional, so both
-- tests are written as "NULL, or inside it" - an unscheduled paper (the common
-- case, and every paper authored before scheduling existed) passes unchanged.
--
-- "Has this student accepted the proctoring notice?" is the third question, and
-- §3b is why it exists: `student_has_consent(exam_id)` is true for a general
-- acceptance (a row with `exam_id IS NULL`) or for one naming this paper, and
-- only for the notice version currently in force. It is asked *here* rather than
-- folded into `student_can_access_exam()` because that predicate also answers
-- `exams_select` and `questions_public` - a student must be able to read the
-- paper before they can decide whether to accept the notice for it.
create policy "submissions_insert_own_ongoing"
  on public.exam_submissions for insert
  to authenticated
  with check (
    student_id = auth.uid()
    and status = 'ongoing'
    and score is null
    and answers = '{}'::jsonb
    and submitted_at is null
    and started_at = now()
    and public.student_can_access_exam(exam_id)
    and public.student_has_consent(exam_id)
    and exists (
      select 1 from public.exams e
      where e.id = exam_id
        and (e.starts_at is null or now() >= e.starts_at)
        and (e.ends_at  is null or now() <= e.ends_at)
    )
  );


-- There is deliberately NO student UPDATE policy: status, score and
-- submitted_at are written by submit_exam() and register_violation(), both
-- SECURITY DEFINER, so a patched client cannot grade itself. Only admins and
-- supervisors can directly intervene; lecturers review attempts.
create policy "submissions_update_supervisor"
  on public.exam_submissions for update
  to authenticated
  using (public.can_supervise_exam(exam_id))
  with check (public.can_supervise_exam(exam_id));

-- Resetting one attempt (the staff app's "Reset attempt" control)
-- is a DELETE of this row: the score, the stored answers, the roster card and -
-- through the `on delete cascade` on proctoring_logs.submission_id - the
-- incident log are all cleared together. The child table needs no twin policy:
-- referential actions run outside row security, so this one policy is what lets
-- the evidence go with the attempt.
--
-- The reset tier - wider than the update policy above by exactly one role. It is
-- `can_supervise_exam(exam_id) or owns_exam(exam_id)`: the supervisor of that paper
-- - an administrator, or the supervisor assigned to it - can clear any attempt on
-- it, and the lecturer who wrote *this* paper can clear an attempt on it -
-- which is the repair the control exists for (the wrong answer key, the mis-aimed
-- disqualification). It used to be `is_attempt_resetter()`, which is every
-- lecturer, so any lecturer could delete any student's attempt on any paper in the
-- institution, cascading away its incident rows - the destructive half of the
-- review's finding (c).
-- Students are deliberately left out. A student who could delete their own row
-- would be able to erase a graded attempt - and the evidence behind a
-- disqualification - and then simply start the exam again.
--
-- The purge of the snapshots and the audit row of §7 keep the wider
-- `is_attempt_resetter()` tier on purpose: a delete this policy refuses removes
-- zero rows, and the console reads that zero and stops *before* purging or
-- auditing (`resetSubmission()` checks `.delete().select()`). Making that
-- sequence atomic is the reset RPC proposed in `supabase/RESET_ATTEMPT_RPC_PROPOSAL.md`,
-- not something a policy can do.
create policy "submissions_delete_supervisor"
  on public.exam_submissions for delete
  to authenticated
  using (
    public.can_supervise_exam(exam_id)
    or public.owns_exam(exam_id)
  );

-- A closed attempt stops being editable.
--
-- The policies above stop every *client* path (students have no UPDATE policy,
-- a supervisor writes through RLS), but nothing stopped the two SECURITY DEFINER
-- merge RPCs from writing to a row that had already been graded: a queued answer
-- replayed after `submit_exam()` - which is exactly what the app's offline queue
-- does on the next connection - landed a key in the `answers` jsonb of a closed
-- attempt, silently changing what a re-grade would read. The guard is keyed on
-- the status the row *already* has, so it holds for every caller that can reach
-- the row: the RPCs (definer, so RLS never sees them), the console's supervisor
-- update, and anything added later.
--
-- What stays writable on a closed row is deliberate: `score` and `submitted_at`
-- are how a supervisor re-grades, and `status` may still move between the closed
-- states ('submitted' <-> 'disqualified', and 'flagged_for_review' -> either of
-- them through `resolve_flagged_attempt()`) so an after-the-fact disqualification
-- counts and a mistaken one can be undone. Reopening one
-- ('ongoing' again) is not a repair - it would hand a student a live session over
-- an attempt whose answers were already recorded; the supported way to let
-- somebody retake an exam is "Reset attempt", which deletes the row.
create or replace function public.guard_submission_immutability()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  -- Null for anything that did not arrive through PostgREST (a migration, the
  -- SQL editor, a trigger from a background job).
  v_claims text := nullif(current_setting('request.jwt.claims', true), '');
begin
  -- The escape hatch the rest of this file gives the Edge Functions: their
  -- client signs with the service key, which is what `admin-delete-user` and the
  -- cleanup scripts use. Same rule as guard_user_role_change above - a request
  -- signed by a user or the anon key never carries this claim.
  if v_claims is not null
     and coalesce(v_claims::jsonb ->> 'role', '') = 'service_role' then
    return new;
  end if;

  if old.status <> 'ongoing' then
    if new.answers is distinct from old.answers then
      raise exception 'the answers of a closed attempt are immutable'
        using errcode = '42501';
    end if;

    if new.status = 'ongoing' then
      raise exception 'a closed attempt cannot be reopened'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists submissions_guard_immutability on public.exam_submissions;
create trigger submissions_guard_immutability
  before update on public.exam_submissions
  for each row execute function public.guard_submission_immutability();

-- ---------------------------------------------------------------------
-- 4a. THE STUDENT QUESTION FEED (questions_public)
-- ---------------------------------------------------------------------
-- Placed HERE, after `exam_submissions`, because the view joins it. It used to
-- sit at the end of section 3, above the table it reads: a view body is resolved
-- when the view is created, so on a fresh install that ordering was only survivable
-- because the CREATE happened to name a relation nobody had made yet - the kind of
-- defect that stays invisible until the file is replayed from scratch or the order
-- is trusted by somebody reading it. Section 3's comments point here.
--
-- Student-safe view: strips both answer keys (`correct_option` and
-- `correct_text_answer`) so students never receive them, and returns one row per
-- *audience* instead of every published row:
--   1. the supervisor of the paper - an administrator, or the supervisor assigned to
--      it (`can_supervise_exam(e.id)`);
--   2. the paper's author (`e.created_by = auth.uid()`), who authored these rows;
--   3. a student the paper is aimed at, **while its window is open** -
--      `student_can_access_exam(e.id)` plus `starts_at` / `ends_at`;
--   4. the owner of an `'ongoing'` attempt on it, until that attempt's deadline
--      (`started_at + duration_minutes`).
-- `e.is_published = true` alone - which is what this was - meant a student who
-- could not even *see* the paper in their list could read its questions by
-- guessing its id (exam ids travel in links, exports and the console UI), and a
-- paper not yet open could be read the moment it was published.
--
-- The `LEFT JOIN` follows `exam_submissions` on the caller's own attempt, and it
-- cannot duplicate the feed: that table is `unique (student_id, exam_id)` (this
-- section), so it contributes at most one row per question.
--
-- `security_invoker` is turned OFF on purpose. With invoker semantics the view
-- runs under the caller's own policies, which would require exactly the student
-- SELECT policy on `questions` that leaks the answer keys. As a definer view
-- owned by the owner of the schema it reads the base table directly (RLS is not
-- applied to a table's owner) and exposes one fixed column set, filtered to the
-- audiences above.
--
-- DROP + CREATE rather than `create or replace`: Postgres refuses to reorder or
-- re-type the columns of an existing view, and `question_type` has to sit with
-- the rest of the question shape. The view has no dependants, and the grant is
-- re-applied below.
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
  where public.can_supervise_exam(e.id)
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

-- ... and now take the reader the view was never meant for out of it.
--
-- That grant is not what keeps the public key away: section 0's blanket
-- `grant all privileges on all tables` runs on *every* install of this file -
-- including a re-run over a database where this view already exists - and the
-- `alter default privileges` beside it re-applies the same privileges to
-- anything created later, so `anon` holds SELECT on this view (and on
-- `questions`, the table holding the answer keys) unless it is revoked here,
-- after both objects exist. A revoke, not a missing grant, is what makes the
-- reach deterministic no matter which order this file is applied in.
--
-- Both revokes stay BELOW the create for the same reason the view itself moved
-- below `exam_submissions`: a revoke can only name an object that exists, and
-- section 0's default privileges are what put the grant there in the first place.
--
-- Nothing in the app needs the feed with the anonymous key: every read of
-- it happens after sign-in (the student's own `questions_public` query runs with
-- their session, and staff access to `questions` uses their session), and the only anonymous
-- consumer was `.github/workflows/keep_alive.yml`, which pinged this view to
-- prove the schema was reachable - i.e. exactly the reach being removed here. It
-- pings `profiles` now, which answers 200 `[]` for `anon` because no policy
-- grants it a row: the schema proves itself without the answer key's table being
-- reachable at all.
revoke all on public.questions_public from anon;
revoke all on public.questions        from anon;

-- ---------------------------------------------------------------------
-- 5. PROCTORING LOGS
-- ---------------------------------------------------------------------
create table if not exists public.proctoring_logs (
  id             uuid primary key default uuid_generate_v4(),
  submission_id  uuid not null references public.exam_submissions(id) on delete cascade,
  action_type    text not null check (
                   action_type in (
                     -- Camera / session signals
                     'looking_away','multiple_faces','no_face','app_minimized','audio_noise',
                     -- Browser exam lockdown (copy/paste, right-click, devtools)
                     'copy_paste_attempt','right_click_blocked','devtools_detected',
                     -- Device integrity (second display, virtual camera)
                     'secondary_display_detected','virtual_camera_detected',
                     -- Inactivity
                     'idle_afk'
                   )
                 ),
  timestamp      timestamptz not null default now(),
  -- The evidence still for this incident: the *bucket-relative object path*
  -- inside the private `proctor-snapshots` bucket
  -- (`<submission_id>/<action_type>_<epoch-ms>.jpg`, see section 6), not a URL.
  -- A URL would either have to be public - anyone holding it could view a
  -- student's face, forever - or signed and dead long before an appeal. The
  -- reader mints a short-lived URL from this path when it actually shows the
  -- still (`createSignedUrl`, bounded by the bucket's RLS policy).
  -- Rows written before the bucket went private hold a public URL here; readers
  -- normalise both shapes (mobile: `SupabaseService.snapshotObjectPath`).
  snapshot_url   text
);

-- The list above only applies to a database that does not have the table yet:
-- `create table if not exists` cannot widen a constraint that already exists.
-- This is the same refresh as
-- ../supabase/migrations/update_proctoring_action_types.sql, repeated here so
-- re-running this single file also upgrades an older installation (the mobile
-- app refuses to log a violation whose action_type the server would reject) -
-- keep the two lists, and `ViolationType` in ../mobile, in step.
--
-- The drop is by *definition* and the add is NOT VALID + VALIDATE, so this is
-- safe to re-run and safe on a table that already holds rows: no rewrite, and a
-- pre-existing unknown action_type surfaces as a validation error instead of
-- being silently rewritten.
do $$
declare
  v_constraint text;
begin
  for v_constraint in
    select con.conname
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join pg_namespace nsp on nsp.oid = rel.relnamespace
     where nsp.nspname = 'public'
       and rel.relname = 'proctoring_logs'
       and con.contype = 'c'
       and pg_get_constraintdef(con.oid) like '%action_type%'
  loop
    execute format('alter table public.proctoring_logs drop constraint %I', v_constraint);
  end loop;
end $$;

alter table public.proctoring_logs
  add constraint proctoring_logs_action_type_check
  check (
    action_type in (
      'looking_away','multiple_faces','no_face','app_minimized','audio_noise',
      'copy_paste_attempt','right_click_blocked','devtools_detected',
      'secondary_display_detected','virtual_camera_detected','idle_afk'
    )
  ) not valid;

alter table public.proctoring_logs
  validate constraint proctoring_logs_action_type_check;

-- Two columns the offline retry needs, added for databases created before them.
--
--   * `client_timestamp` is *when the violation happened on the student's device*.
--     `timestamp` stays the server's receipt time on purpose: it is the column the
--     supervisor console orders by, and it cannot be moved by a wrong device clock.
--     Recording both is what makes a late delivery (a violation taken while the
--     exam app was offline) distinguishable from a late detection.
--   * `client_event_id` is the idempotency key `register_violation` deduplicates
--     on. Without it, replaying a call whose response was lost would append a
--     second row - and so a second strike - for the same event.
--
-- The unique index is partial because the column is null for rows written by a
-- client that predates the offline queue (and for direct SQL by a supervisor).
alter table public.proctoring_logs add column if not exists client_timestamp timestamptz;
alter table public.proctoring_logs add column if not exists client_event_id uuid;

create unique index if not exists idx_logs_client_event_id
  on public.proctoring_logs(client_event_id)
  where client_event_id is not null;

alter table public.proctoring_logs enable row level security;

drop policy if exists "logs_select_own_or_supervisor" on public.proctoring_logs;
drop policy if exists "logs_insert_own_ongoing" on public.proctoring_logs;

-- Read: your own attempt; the incident feed of any sitting you may supervise -
-- every sitting for an administrator, the assigned ones for a supervisor
-- (`can_supervise_exam()`, section 2d); and - for the lecturer who wrote the paper -
-- the incidents recorded on their own exam.
--
-- The third arm is what makes a lecturer's monitor show violations instead of an
-- empty feed, and it is scoped by `owns_exam()` rather than by the staff tier on
-- purpose: a lecturer may read every attempt (the roster), but not the evidence
-- gathered on somebody else's paper. A student still reads only their own rows.
-- The ownership test rides on the same subquery as the student one, so the
-- attempt row is fetched once either way.
create policy "logs_select_own_or_supervisor"
  on public.proctoring_logs for select
  to authenticated
  using (
    exists (
      select 1 from public.exam_submissions s
      where s.id = submission_id
        and (
          s.student_id = auth.uid()
          or public.owns_exam(s.exam_id)
          or public.can_supervise_exam(s.exam_id)
        )
    )
  );

-- There is deliberately NO insert policy. `register_violation()` is the single
-- write path for evidence: it re-checks that the caller owns the submission,
-- inserts the row and applies the weighted-strike rule in one transaction. Letting
-- clients insert here as well would give them a second, unguarded way to write
-- proctoring evidence (and to pad somebody's strike count).

-- ---------------------------------------------------------------------
-- 5a. VIOLATION WEIGHTS (how much each signal counts)
-- ---------------------------------------------------------------------
-- The escalation in `register_violation()` (bottom of this file) used to count
-- rows: three of anything at all closed the attempt. That made three right-clicks
-- the same evidence as three sustained second-face sightings. The distinction is
-- already in the vocabulary `proctoring_logs_action_type_check` carries, so it
-- lives in this table now rather than in a hard-coded `3`: an institution retunes
-- a type with one UPDATE (README, "Tuning the violation weights") and the stored
-- logs are never rewritten to match the new policy.
--
--   * `weight`          points added to the attempt's disqualification score.
--   * `counts_toward_dq` whether the type may contribute at all - `false` keeps a
--                       signal as evidence for a human, out of the automatic rule.
--   * No row for a type  is scored as (1, counted) by `register_violation()`: a
--                       type the constraint accepts can never be a free pass.
--
-- `looking_away` and `audio_noise` were seeded at 0 / not counted and are counted
-- now (1 point each): a candidate reading a second screen and a candidate talking
-- the answers through with somebody in the room are exactly the two signals a
-- camera-and-microphone proctor is good at, and neither used to move the score.
-- `migrations/20261108090000_looking_away_and_noise_count.sql` is the upgrade for
-- a project that already carries the old values; re-running this file cannot undo
-- a tuned weight (see the `on conflict` note below), so that migration is the way
-- those two rows change on a live database.
--
-- The upgrade migrations are `migrations/20261104090000_violation_weights.sql`
-- and `migrations/20261108090000_looking_away_and_noise_count.sql`; keep the seed
-- below in step with them and with `ViolationType` in the mobile app
-- (`schema_contract_test.dart` fails if either drifts).
create table if not exists public.violation_weights (
  action_type      text primary key,
  weight           int not null check (weight >= 0),
  counts_toward_dq boolean not null
);

comment on table public.violation_weights is
  'How much each proctoring_logs.action_type counts towards automatic disqualification. Read by register_violation(); a missing row is scored as (1, counted) so a new action type can never be a free pass.';

-- `do nothing` on conflict: re-running this file must not reset a weight an
-- operator tuned with UPDATE.
insert into public.violation_weights (action_type, weight, counts_toward_dq) values
  -- Hard: one point each, so three reach the threshold - exactly the signals the
  -- old row count was meant to protect.
  ('multiple_faces',               1, true),
  ('no_face',                      1, true),
  ('app_minimized',                1, true),
  ('devtools_detected',            1, true),
  ('secondary_display_detected',   1, true),
  ('virtual_camera_detected',      1, true),
  -- Counted since 20261108090000: a sustained glance off screen and a room that
  -- stays above its own floor. Both are client-side rules with their own
  -- 2-second windows (`proctoring_thresholds.dart`, `AudioNoiseDetector`), so one
  -- cough or one glance-and-return is not a point.
  ('looking_away',                 1, true),
  ('audio_noise',                  1, true),
  -- Soft: stored, shown to a supervisor, never automatically fatal.
  ('copy_paste_attempt',           0, false),
  ('right_click_blocked',          0, false),
  ('idle_afk',                     0, false)
on conflict (action_type) do nothing;

alter table public.violation_weights enable row level security;

drop policy if exists "violation_weights_select_authenticated" on public.violation_weights;
drop policy if exists "violation_weights_insert_admin" on public.violation_weights;
drop policy if exists "violation_weights_update_admin" on public.violation_weights;
drop policy if exists "violation_weights_delete_admin" on public.violation_weights;

create policy "violation_weights_select_authenticated"
  on public.violation_weights for select
  to authenticated
  using (true);

create policy "violation_weights_insert_admin"
  on public.violation_weights for insert
  to authenticated
  with check (public.is_admin());

create policy "violation_weights_update_admin"
  on public.violation_weights for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

create policy "violation_weights_delete_admin"
  on public.violation_weights for delete
  to authenticated
  using (public.is_admin());

grant select, insert, update, delete on public.violation_weights to authenticated;
revoke all on public.violation_weights from anon;

-- ---------------------------------------------------------------------
-- 5b. PROCTORING HEARTBEATS (was the client running?)
-- ---------------------------------------------------------------------
-- Every other piece of proctoring evidence is a *negative*: no violations
-- recorded. That silence has two completely different causes, and until now the
-- database could not tell them apart -
--
--   * the client was running, watched the camera, and saw nothing, or
--   * the client was never running (closed tab, killed app, blocked script,
--     wifi dropped, JS error before the first frame).
--
-- An empty `proctoring_logs` feed reads as "clean sitting" in both cases. This
-- table is the positive signal that makes the difference visible: the client
-- says "still here, camera streaming, monitoring active" every few seconds, and
-- a gap in that series is a fact a human can act on ("this student's proctoring
-- stopped at 14:22, look at it") rather than a silent assumption.
--
-- What a heartbeat is NOT, and this is the honest limit of the whole feature:
--
--   * It proves an authenticated client *claimed* to be running. A tampered or
--     scripted client can send beats while doing nothing, exactly as it can send
--     fabricated violation photos. Heartbeats raise the cost of the trivial
--     attack (close the app and get a clean record) - they do not attest to
--     application integrity. Platform attestation (Play Integrity / App Attest)
--     is listed as future work in the README.
--   * A gap is not misconduct. Network loss, a stolen laptop and a genuinely
--     broken webcam all look identical from here, so a gap only ever produces a
--     *flag for a human* (`proctoring_coverage()` below never disqualifies).
--   * `received_at` is the server clock; `client_time` is what the device said.
--     A beat replayed from the offline queue therefore arrives with a `client_time`
--     in the past - it still proves the client is *alive now*, not that it was
--     being honest earlier. Coverage prefers `received_at` for exactly that
--     reason.
--
-- Growth: one row per client per ~15s is ~240 rows/hour/student. That is fine
-- for a sitting and too much to keep for a year, which is why it has its own
-- retention policy (`retention_policy.sql`, `proctor_heartbeats`).
create table if not exists public.proctor_heartbeats (
  id             uuid primary key default uuid_generate_v4(),
  submission_id  uuid not null references public.exam_submissions(id) on delete cascade,
  -- Server clock. The only timestamp a supervisor should trust; see the note
  -- above about replayed beats.
  received_at    timestamptz not null default now(),
  -- Device clock at the moment the beat was produced. NULL for a live beat from
  -- a build that does not send it. Kept for diagnostics ("the gap is real" vs
  -- "the phone's clock jumped"), never used for the gap arithmetic.
  client_time    timestamptz,
  -- Did the camera have a live track at that moment? A beat with camera_ok=false
  -- is the "proctoring is running but blind" case - the one an empty log feed
  -- used to hide completely.
  camera_ok      boolean not null default true,
  -- Is the monitor as a whole (detector loop, foreground app) up? false covers
  -- "app backgrounded", "detector paused", "session ended early".
  monitoring_ok  boolean not null default true,
  app_version    text,
  -- Set by the offline queue so a retried beat is stored once. Same idea as
  -- `proctoring_logs.client_event_id`.
  client_event_id uuid
);

-- One row per queued beat, however many times the retry replays it.
create unique index if not exists idx_heartbeats_client_event_id
  on public.proctor_heartbeats(client_event_id)
  where client_event_id is not null;

comment on table public.proctor_heartbeats is
  'Proctoring client liveness beats. Answers "was anything watching?", which an empty proctoring_logs feed cannot. Proves a client claimed to be running - never that it was doing its job (no application attestation).';
comment on column public.proctor_heartbeats.received_at is
  'Server clock at insert. The only timestamp coverage trusts: a beat replayed from the offline queue has a client_time in the past.';
comment on column public.proctor_heartbeats.camera_ok is
  'Whether the camera had a live track when the beat was produced. false is the "monitor running but blind" case an empty log feed used to hide.';
comment on column public.proctor_heartbeats.monitoring_ok is
  'Whether the monitor as a whole (detector loop, foreground app) was up. false covers backgrounded, paused or ended early.';
comment on column public.proctor_heartbeats.client_event_id is
  'Idempotency key for the offline queue: record_heartbeat() stores one row per beat however many times it is replayed.';
comment on column public.exam_submissions.last_heartbeat_at is
  'Server time of the last accepted proctoring heartbeat (record_heartbeat()). NULL = the client never reported, which is not evidence of a clean sitting.';

alter table public.proctor_heartbeats enable row level security;

drop policy if exists "heartbeats_select_own_or_supervisor" on public.proctor_heartbeats;

-- Read: the same audience as the evidence itself - the student whose attempt it
-- is, the lecturer who wrote the paper, and the intervention tier. Anything
-- broader turns the table into a presence tracker for the whole institution.
create policy "heartbeats_select_own_or_supervisor"
  on public.proctor_heartbeats for select
  to authenticated
  using (
    exists (
      select 1 from public.exam_submissions s
      where s.id = submission_id
        and (
          s.student_id = auth.uid()
          or public.owns_exam(s.exam_id)
          or public.can_supervise_exam(s.exam_id)
        )
    )
  );

-- Again, deliberately NO insert/update/delete policy. `record_heartbeat()` is
-- the only writer: it re-checks ownership and the attempt's status, rate-limits
-- the caller and stamps `exam_submissions.last_heartbeat_at` in the same
-- transaction. A client-insertable heartbeat table would let a tampered client
-- backfill a tidy series of beats it never sent - the one thing this table is
-- supposed to make hard.
grant select on public.proctor_heartbeats to authenticated;
revoke all on public.proctor_heartbeats from anon;

-- ---------------------------------------------------------------------
-- 6. STORAGE BUCKET (Proctoring Violation Snapshots)

-- ---------------------------------------------------------------------
-- Path convention written by the mobile app (core/services/supabase_service.dart):
--   <submission_id>/<action_type>_<epoch-ms>.jpg
-- so the first folder is always the submission the snapshot belongs to.
--
-- The bucket is PRIVATE. A snapshot is a photograph of a student's face, and a
-- public bucket served every one of them to anybody who had (or guessed, or was
-- forwarded) the URL - from a log export, a screenshot of the console, a shared
-- link - with no expiry and no way to revoke it short of deleting the object.
-- Private means Storage serves nothing from here without a signature:
--   * the app stores the bucket-relative *path* on `proctoring_logs.snapshot_url`
--     and mints a short-lived URL when it (or the console) actually shows the
--     still: `storage.from('proctor-snapshots').createSignedUrl(path, 600)`;
--   * the signature is minted under the caller's own JWT, so the read policy
--     below still decides who may create one - the owning student, or staff;
--   * a leaked URL now dies within minutes, and the object behind it stays
--     protected even while the URL lives.
-- `public = false` on an existing installation is the migration: re-running this
-- block flips the bucket in place, because the file limits and mime types are set
-- with `on conflict do update` below.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('proctor-snapshots', 'proctor-snapshots', false, 5242880, array['image/jpeg', 'image/png'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Proctor snapshots read access" on storage.objects;
drop policy if exists "Proctor snapshots upload access" on storage.objects;
drop policy if exists "Proctor snapshots upload own ongoing session" on storage.objects;
drop policy if exists "Proctor snapshots supervisor purge" on storage.objects;

-- Read (and therefore sign): the student the submission belongs to, the
-- intervention tier, or the author of the paper the attempt is against. With the
-- bucket private this is not a convenience any more - it is the only thing that
-- lets anybody read a still at all, because Storage refuses both the object and
-- the signature without it (signing is a SELECT under the hood).
--
-- It ended in `or public.is_staff()`, which is everybody employed: any lecturer
-- could sign a ten-minute URL to a photograph of any student in any sitting. The
-- evidence tier is narrower than the roster tier for the same reason
-- `proctoring_logs` is (`owns_exam()`), except that here the evidence is a face.
-- The supervisor arm used to sit *outside* the EXISTS so the intervention tier
-- could still read an object whose folder no longer resolves to a submission - the
-- state between deleting an attempt and purging its stills. It is inside now,
-- because the question "may this account supervise it" needs the paper the folder
-- resolves to; the orphaned window is covered by the purge policies below, which
-- ask `is_attempt_resetter()` (the tier that is allowed to delete an attempt at
-- all) and only match once `snapshot_attempt_exists()` says the folder names no
-- attempt at all.
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
          or public.owns_exam(s.exam_id)
          or public.can_supervise_exam(s.exam_id)
        )
    )
  );

-- Upload: a student may only write into the folder of their OWN submission, and
-- only while it is still 'ongoing' — the storage twin of the ownership check
-- inside register_violation(), which is the only writer of `proctoring_logs`.
create policy "Proctor snapshots upload own ongoing session"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'proctor-snapshots'
    and exists (
      select 1 from public.exam_submissions s
      where s.id::text = (storage.foldername(name))[1]
        and s.student_id = auth.uid()
        and s.status = 'ongoing'
    )
  );

-- Does this object's folder name an attempt? Asked as the OWNER, never as the
-- caller, and that is the whole point: a policy expression is evaluated with the
-- caller's privileges, so the two purge policies below cannot ask this themselves
-- without the answer changing with who is asking.
-- `submissions_select_own_or_supervisor` shows a supervisor only the attempts of
-- the papers assigned to them, so an inline `not exists (select 1 from
-- public.exam_submissions ...)` inside a policy reads a *scope* - 0 rows for a
-- paper they were not given - and not a fact. That made a live attempt's folder
-- look orphaned, and its stills readable and purgable, to exactly the account that
-- can neither read that attempt nor delete it
-- (`migrations/20261110090100_snapshot_orphan_check.sql` is this fix applied to an
-- existing project). A definer function is what `owns_exam()`,
-- `can_supervise_exam()` and `can_read_profile()` already are in this file, for the
-- same reason: the question is about a row the caller may not read.
--
-- `stable`, so it is answered once per candidate object inside one DELETE and sees
-- the table as of that statement - the snapshot in which a reset's earlier
-- `delete from exam_submissions` has already happened. The first path segment is
-- shape-tested before the `::uuid` cast because `storage.objects.name` is free
-- text: a cast that raised on a stray object would abort a whole purge statement
-- (22P02) instead of answering about that one object. It is compared as a uuid
-- rather than as text so one folder spelled another way still names its attempt,
-- which is the fail-closed direction (kept, not purged).
create or replace function public.snapshot_attempt_exists(p_object_name text)
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
    select 1 from public.exam_submissions s where s.id = v_folder::uuid
  );
end;
$$;

-- Called by the two policies below (as `authenticated`) and by nothing else: not a
-- client API, so it is not reachable from PostgREST even though the policies are.
revoke execute on function public.snapshot_attempt_exists(text) from public, anon;
grant execute on function public.snapshot_attempt_exists(text) to authenticated, service_role;


-- No update policy: a stored snapshot is never rewritten.
--
-- Delete is one deliberate exception, and it exists for exactly one action - the
-- staff app's "Reset attempt". That action deletes the submission row first (the
-- DELETE that `submissions_delete_supervisor` authorizes, whose cascade takes
-- the log rows with it) and then drops the stills those rows pointed at: a reset
-- that left a student's images behind in Storage would not be a reset.
--
-- The `not exists` arm is what makes that ORDER the rule rather than a habit of
-- the client. An object is purgeable only once its folder no longer resolves to a
-- submission - exactly the state `DashboardRepositoryImpl.resetSubmission()`
-- creates before it calls `storage.remove()` (it reads the paths, deletes the row
-- and only then purges). Two holes close with it:
--   * a plain lecturer account (`is_attempt_resetter()` names every lecturer) could
--     otherwise delete the stills of *any* sitting in the institution while that
--     sitting was still running - the evidence gone, the attempt untouched, no
--     audit row anywhere, because no attempt row was ever deleted;
--   * the reset tier could purge evidence of an attempt it could not delete
--     (`submissions_delete_supervisor` asks `can_supervise_exam(exam_id)` or the
--     author),
--     so the destructive half of a reset was reachable without the repair half.
--
-- Without `is_attempt_resetter()` the orphan arm would be a hole rather than a
-- guard - any signed-in account could delete the orphaned stills of a finished
-- reset - so both terms stay. And unlike the read/upload policies above this one
-- cannot be anchored to the submission folder: its whole purpose is the window
-- in which that folder resolves to nothing.
--
-- The subquery is NOT evaluated under the caller's own permissions - it is
-- `public.snapshot_attempt_exists()` above, a definer function, and that is a fix
-- rather than a flourish. It read as staff when it was written, because
-- `submissions_select_own_or_supervisor` then handed every staff member every
-- attempt; since `20261109090000` the same sentence is evaluated under the caller's
-- scope instead, which turns a supervisor's unassigned paper into an "orphan" and
-- hands them a signed URL to - and a DELETE over - the stills of an attempt they may
-- not even read. The tier (`is_attempt_resetter()`) and the question ("does this
-- folder name no attempt") are the ones this file has always meant; the definer is
-- what keeps the answer about the folder rather than about the reader.
create policy "Proctor snapshots supervisor purge"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'proctor-snapshots'
    and public.is_attempt_resetter()
    and not public.snapshot_attempt_exists(name)
  );


-- A DELETE that has a WHERE clause (which is what `storage.remove()` issues) must
-- also pass the table's SELECT policies: Postgres only lets a statement delete rows
-- it is allowed to see. The read policy above admits a lecturer only through an
-- attempt row, and the purge runs exactly when that row is gone, so without this
-- companion the purge matched 0 rows for a lecturer and left the stills behind.
-- Same predicate as the purge policy, on SELECT; it exposes only already-orphaned
-- objects, to the tier that is about to delete them.
--
-- It is also the policy the "unassigned supervisor reads another paper's stills"
-- hole was *read* through: with the orphan test evaluated under the caller's RLS,
-- a paper they were not assigned showed no attempt, so this policy matched and the
-- console could sign a URL for the stills of an attempt it could not open - or see
-- at all. `snapshot_attempt_exists()` answers about the folder rather than about
-- the reader, so "orphaned" means what it says whoever is asking.
drop policy if exists "Proctor snapshots orphan read for purge" on storage.objects;
create policy "Proctor snapshots orphan read for purge"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'proctor-snapshots'
    and public.is_attempt_resetter()
    and not public.snapshot_attempt_exists(name)
  );

-- ---------------------------------------------------------------------
-- 7. SESSION RESET LOGS (the audit trail behind "Reset attempt")
-- ---------------------------------------------------------------------
-- A supervisor's reset deletes the attempt *and* the incident rows, which makes
-- it the one destructive staff action in the console: proctoring evidence
-- disappears with it. This table is what keeps that from being invisible.
--
-- `DashboardRepositoryImpl.resetSubmission()` is the writer: it deletes the
-- attempt first, purges the snapshot objects next, and then inserts one row here
-- describing what it destroyed. It never throws on the last step - the attempt
-- is already gone by then, so reporting a failure would invite a retry against
-- an attempt that no longer exists. The console shows a failed write as a caveat
-- on an otherwise successful reset instead
-- (`SubmissionResetResult.auditWarning` in the Flutter app).
--
-- `actor_id` is the point of the table: it defaults to auth.uid() and the insert
-- policy re-checks `actor_id = auth.uid()`, so *who* cleared an attempt is the
-- database's answer rather than the client's claim. The Flutter repository
-- deliberately never sends the column.
--
-- No foreign keys, on purpose. `submission_id` names the attempt this row
-- describes, and that row was just deleted by the very action being recorded: a
-- reference would either refuse every insert, or - with `on delete set null` -
-- blank out the id that ties the record to the attempt it replaced. `student_id`
-- and `exam_id` are kept as plain uuid evidence for the same reason, so an
-- account or exam removed later cannot take its audit trail with it.
-- (`exam_submissions` cascades still take the attempt, its answers and its
-- `proctoring_logs` rows; this table sits outside that cascade by design.)
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

-- Fresh installs get the table from here; a project that already ran an earlier
-- revision of this file gets it from
-- supabase/migrations/session_reset_logs.sql, which carries the same DDL.
alter table public.session_reset_logs enable row level security;

drop policy if exists "session_reset_logs_select_staff" on public.session_reset_logs;
drop policy if exists "session_reset_logs_insert_supervisor" on public.session_reset_logs;

-- Read: the intervention tier sees every reset; the paper's own lecturer sees the
-- resets recorded against the exams they wrote (`owns_exam()` on the exam id the
-- row carries as plain evidence). Students get no rows: the record names the
-- member of staff who ran the reset.
--
-- Deliberately narrower than `is_staff()`. The tier that may read every *attempt*
-- is not the tier that may read every *reset*: a reset row names another
-- teacher's student, their exam and the actor who cleared it, which is exactly
-- the "unrelated system log" a shared staff read would expose. A lecturer who is
-- missing an attempt on their own paper still sees the row that explains why.
create policy "session_reset_logs_select_staff"
  on public.session_reset_logs for select
  to authenticated
  using (public.can_supervise_exam(exam_id) or public.owns_exam(exam_id));

-- Write: exactly the tier that may delete an attempt in the first place - the
-- supervisor of the paper or its author, in the caller's own name. It used to be
-- `is_attempt_resetter()` (every lecturer), which was wider than the DELETE the row
-- describes: a lecturer could record a reset of an attempt on somebody else's paper
-- that the DELETE policy had just refused, and a supervisor could record one for a
-- paper they are not assigned to. The insert can only ever follow a successful
-- delete, so this narrows nothing that ever worked.
create policy "session_reset_logs_insert_supervisor"
  on public.session_reset_logs for insert
  to authenticated
  with check (
    (public.can_supervise_exam(exam_id) or public.owns_exam(exam_id))
    and actor_id = auth.uid()
  );

-- There is deliberately NO update policy and NO delete policy. A record its own
-- author can rewrite or remove is not a record; if one is ever wrong, the
-- correction is another row (or SQL by the project owner), never an edit.

-- ---------------------------------------------------------------------
-- 7a. ATTEMPT REVIEW LOGS (the audit trail behind "resolve")
-- ---------------------------------------------------------------------
-- `register_violation()` no longer disqualifies on its own: at the weighted
-- threshold it closes the sitting as `flagged_for_review` and a person decides.
-- This table is the record of that decision - who, when, which way, and on what
-- grounds - which is exactly what an appeal turns on. One row per call, written by
-- `resolve_flagged_attempt()` (bottom of this file) and by nothing else.
--
-- No foreign keys, for the same reason `session_reset_logs` has none: the attempt
-- this row describes can be deleted afterwards by "Reset attempt", and a reference
-- would either refuse the insert or - with `on delete set null` - blank out the id
-- that ties the record to the attempt it is about. `student_id` and `exam_id` stay
-- as plain uuid evidence, so a deleted exam cannot take its review trail with it.
create table if not exists public.attempt_review_logs (
  id            uuid primary key default uuid_generate_v4(),
  submission_id uuid not null,
  student_id    uuid not null,
  exam_id       uuid not null,
  from_status   text not null,
  to_status     text not null,
  decision      text not null check (decision in ('disqualify', 'clear')),
  note          text,
  actor_id      uuid not null default auth.uid(),
  created_at    timestamptz not null default now()
);

comment on table public.attempt_review_logs is
  'One row per resolve_flagged_attempt() call: who decided what about an attempt that reached the weighted threshold, with their note. Read-only to clients.';

alter table public.attempt_review_logs enable row level security;

drop policy if exists "attempt_review_logs_select_staff" on public.attempt_review_logs;

-- Read: the intervention tier sees every review; the lecturer who wrote the paper
-- sees the reviews of their own sitting. Students get no rows - the record names
-- the member of staff who made the call. Same reach as `session_reset_logs`, and
-- for the same reason: a shared staff read would expose another teacher's student
-- and another teacher's decision.
create policy "attempt_review_logs_select_staff"
  on public.attempt_review_logs for select
  to authenticated
  using (public.can_supervise_exam(exam_id) or public.owns_exam(exam_id));

-- No insert policy, and no update or delete one. The row is written inside
-- `resolve_flagged_attempt()`, a SECURITY DEFINER function that has already
-- checked the caller's tier, so `actor_id = auth.uid()` is the database's answer
-- rather than a client's claim.
grant select on public.attempt_review_logs to authenticated;
revoke insert, update, delete on public.attempt_review_logs from authenticated;
revoke all on public.attempt_review_logs from anon;

-- ---------------------------------------------------------------------
-- 8. QUESTION GRADES (the marks a person awarded, not the RPC)
-- ---------------------------------------------------------------------
-- `submit_exam()` grades the questions whose answer key it holds. A subjective
-- answer has none: the mark is a judgement, so it is recorded here, one row per
-- marked answer, by the paper's owner through `grade_submission()` (bottom of
-- this file), which also folds the award into `exam_submissions.score`.
--
-- Why a table instead of a key inside `exam_submissions.answers`:
-- `guard_submission_immutability` freezes `answers` the moment an attempt closes,
-- and that is exactly right - a re-mark must read the words the student actually
-- submitted. A mark is the *grader's* input, so it gets its own row rather than a
-- rewrite of the student's evidence. It also keeps the two write paths apart:
-- answers are written by the student while the attempt is open, marks by the
-- lecturer after it closed.
--
-- `on delete cascade` from both parents, on purpose: "Reset attempt" or a deleted
-- question has to take its marks with it, or `score` would keep counting marks for
-- a question that no longer exists. (`session_reset_logs` deliberately sits
-- outside that cascade - the trail of a reset is not part of what it destroyed.)
create table if not exists public.question_grades (
  id            uuid primary key default uuid_generate_v4(),
  submission_id uuid not null references public.exam_submissions(id) on delete cascade,
  question_id   uuid not null references public.questions(id) on delete cascade,
  awarded       numeric not null check (awarded >= 0),
  feedback      text,
  graded_by     uuid not null default auth.uid(),
  graded_at     timestamptz not null default now(),
  -- One mark per answer: re-marking is an UPDATE of this row (the RPC upserts),
  -- never a second opinion that `score` would then count twice.
  unique (submission_id, question_id)
);

alter table public.question_grades enable row level security;

drop policy if exists "question_grades_select_staff" on public.question_grades;

-- Read: the staff tier, like the attempts and their incident rows - the lecturer
-- marking a paper and the supervisor answering an appeal see the same marks.
-- Students read no rows here: their total is on their own
-- `exam_submissions.score`, which `submissions_select_own_or_supervisor` already
-- lets them read.
create policy "question_grades_select_staff"
  on public.question_grades for select
  to authenticated
  using (
    public.is_staff()
    and (
      not public.is_supervisor_only()
      or exists (
        select 1 from public.exam_submissions s
        where s.id = submission_id and public.can_supervise_exam(s.exam_id)
      )
    )
  );

-- There is deliberately NO insert and NO update policy, the shape
-- `proctoring_logs` uses: `grade_submission()` is SECURITY DEFINER and re-checks
-- that the caller owns the paper, so it is the single write path. A lecturer who
-- could insert these rows directly could also award marks on an exam they do not
-- own - and could do it for a question they never read.
--
-- No delete policy either: a mark is corrected by re-marking, which the unique
-- constraint above turns into an update of the same row.

-- ---------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------
create index if not exists idx_questions_exam_id on public.questions(exam_id);
create index if not exists idx_submissions_exam_id on public.exam_submissions(exam_id);
create index if not exists idx_submissions_student_id on public.exam_submissions(student_id);
-- Roster queries and staff analytics filter an exam by status,
-- so the composite pays for itself as soon as an exam has a few hundred rows.
create index if not exists idx_submissions_exam_status on public.exam_submissions(exam_id, status);
create index if not exists idx_logs_submission_id on public.proctoring_logs(submission_id);
create index if not exists idx_logs_timestamp on public.proctoring_logs(timestamp desc);
-- Heartbeats are read as a time series for one attempt (the coverage function
-- walks them in `received_at` order) and pruned by age (retention), so the
-- composite serves the read and `idx_heartbeats_received_at` the prune.
create index if not exists idx_heartbeats_submission_received
  on public.proctor_heartbeats(submission_id, received_at);
create index if not exists idx_heartbeats_received_at
  on public.proctor_heartbeats(received_at);
-- The audit trail is read newest-first, and per exam when an appeal asks "what
-- was cleared during this sitting".
create index if not exists idx_session_reset_logs_created_at on public.session_reset_logs(created_at desc);
create index if not exists idx_session_reset_logs_exam_id on public.session_reset_logs(exam_id);
-- Per-answer marks are read by attempt (the unique (submission_id, question_id)
-- above already serves that prefix); this walks the other way, for "which papers
-- still owe marks on this question" and for the cascade when one is deleted.
create index if not exists idx_question_grades_question_id on public.question_grades(question_id);
-- `exam_allowed_students` is keyed (exam_id, student_id), so listing a paper's
-- exceptions is already covered by the primary key's prefix; this walks the other
-- way, for the student's side of `exams_select` ("is this paper on my list?") and
-- for the cascade when a profile is deleted.
create index if not exists idx_exam_allowed_students_student
  on public.exam_allowed_students(student_id);
-- A student's papers are filtered by their own cohort, which is a lookup of
-- `profiles` by primary key; this serves the other direction, where the console's
-- roster asks "who is in this department and level?".
create index if not exists idx_profiles_department_level
  on public.profiles(department, level);

-- ---------------------------------------------------------------------
-- Realtime setup
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'proctoring_logs') then
    alter publication supabase_realtime add table public.proctoring_logs;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'exam_submissions') then
    alter publication supabase_realtime add table public.exam_submissions;
  end if;
  -- Profile rows so the console's id -> name map can refresh itself (the
  -- supervisor roster/incident feed renders names, see mobile/lib/features/dashboard/
  -- src/hooks/useAccountNames.ts). RLS still applies to the stream.
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'profiles') then
    alter publication supabase_realtime add table public.profiles;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Server-side weighted escalation (RPC)
-- ---------------------------------------------------------------------
-- One log row is one piece of evidence, and evidence is not the same as a strike.
-- `public.violation_weights` (section 5a) says how much each `action_type` counts:
-- eight signals weigh 1 - the six identity-breaking ones plus `looking_away` and
-- `audio_noise` - and three weigh 0. Three weighted points close the sitting as
-- `flagged_for_review` - the student is told a
-- supervisor will review it - and `resolve_flagged_attempt()` (below) is the human
-- decision. The rule used to be `count(*) >= 3` and `status = 'disqualified'`,
-- which made three right-clicks equal to three second faces and left no record of
-- who ended an attempt.
--
-- p_snapshot_url is optional, so a client that only knows the violation type
-- keeps working. Its value is the *object path* inside the private
-- `proctor-snapshots` bucket (section 6), not a URL - see the column comment on
-- `proctoring_logs.snapshot_url`. The 2-argument overload is dropped explicitly:
-- leaving it in
-- place would make `register_violation(uuid, text)` ambiguous ("function
-- register_violation(uuid, text) is not unique") now that a defaulted
-- 3-argument version exists.

--
-- The path is the one string the student's device chooses and the database stores
-- verbatim, so it is checked before it is stored: it must match
-- `^<p_submission_id>/<action_type>_<epoch-ms>\.(jpg|png)$` - the exact name
-- `SupabaseService.snapshotPath()` mints, inside this attempt's own folder,
-- which is the convention section 6 and the reset purge both assume.
-- Anything else - another submission's folder, a path outside the bucket, a full
-- URL, a folder-shaped name this app never minted - is stored as NULL and the
-- violation still counts. Storing NULL rather than
-- raising is deliberate: a malformed path must not buy a strike back, and the
-- incident is the fact while the photograph is the optional attachment. Without
-- this, a forged path is both evidence poisoning (an incident that points at
-- somebody else's still) and a delete-by-proxy (the next legitimate reset removes
-- the objects those paths name).
drop function if exists public.register_violation(uuid, text);

-- The pre-offline-queue signature. Adding the two new *defaulted* parameters below
-- would otherwise leave two candidates for a 3-argument named call and Postgres
-- answers that with "function register_violation(...) is not unique", so the old
-- shape is dropped before the new one is created.
drop function if exists public.register_violation(uuid, text, text);

-- The five-argument shape is dropped as well, and not for ambiguity: it gains a
-- third output column (`flagged`), and `create or replace` refuses to change a
-- function's return type ("cannot change return type of existing function"). Its
-- grants are re-applied at the end of this block.
drop function if exists public.register_violation(uuid, text, text, timestamptz, uuid);

create or replace function public.register_violation(
  p_submission_id    uuid,
  p_action_type      text,
  p_snapshot_url     text default null,
  p_client_timestamp timestamptz default null,
  p_client_event_id  uuid default null
)
returns table(warning_count int, disqualified boolean, flagged boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  -- The bar, in weighted points. Three, because every seeded hard type weighs 1:
  -- "any three hard signals" is the rule this replaces for the signals that
  -- deserve it, and a soft type at weight 0 can never reach it alone. This is the
  -- one number to change if an institution wants a stricter or looser ceiling -
  -- changing a *type's* contribution does not need a migration at all (README,
  -- "Tuning the violation weights").
  c_flag_threshold constant int := 3;

  v_count  int;
  v_status text;
  v_snapshot_path text;
  v_weighted int;
begin

  if auth.uid() is null then
    raise exception 'authentication is required to register a violation'
      using errcode = '42501';
  end if;

  -- SECURITY DEFINER is required here (a student may neither insert into
  -- proctoring_logs nor update exam_submissions), which is exactly why the
  -- function has to re-check who is asking: without this guard any signed-in
  -- account could disqualify a classmate by calling the RPC with their
  -- submission id.
  select s.status
    into v_status
  from public.exam_submissions s
  where s.id = p_submission_id
    and s.student_id = auth.uid()
  for update;

  if v_status is null then
    raise exception 'submission % does not belong to the caller', p_submission_id
      using errcode = '42501';
  end if;

  -- Frames that arrive after the attempt closed (submitted, under review, or
  -- already disqualified) must not append more evidence or resurrect the session:
  -- report the final state instead of raising, so a late callback is harmless.
  -- `flagged` is read from the stored status, so a client that missed the ruling
  -- still learns the attempt is under review.
  if v_status <> 'ongoing' then
    select count(*) into v_count
    from public.proctoring_logs
    where submission_id = p_submission_id;
    return query select v_count, (v_status = 'disqualified'),
                        (v_status = 'flagged_for_review');
    return;
  end if;

  -- `on conflict` + the unique index on client_event_id is what makes the
  -- client's offline retry safe: the same event replayed inserts nothing, and the
  -- strike count below is read from the table, so a retry can never turn one
  -- violation into two strikes. A client that reuses an id on purpose only
  -- suppresses its own strike - and a client that controls the app can skip
  -- calling this at all, so the idempotency key costs the rule nothing.
  --
  -- Only THIS attempt's own snapshot object is stored, and only in the exact
  -- shape `SupabaseService.snapshotPath()` mints:
  --     <p_submission_id>/<action_type>_<epoch-ms>.(jpg|png)
  -- `[a-z_]+` is the action_type vocabulary (every member is lowercase ASCII and
  -- underscores), `[0-9]+` is the epoch-millisecond stamp, and the two extensions
  -- are the only mime types the bucket accepts (section 6). Everything else is
  -- stored as NULL, because each rejected shape is a hole of its own:
  --   * another submission's folder - evidence poisoning (an incident of *this*
  --     sitting that shows somebody else's face, on which an appeal is judged) and
  --     a delete-by-proxy (a reset reads these paths back and removes the objects
  --     they name);
  --   * a path outside the bucket, a full URL (the shape a build that predates the
  --     private bucket wrote), a traversal such as `<own id>/../../other` - none of
  --     them addresses a still of this attempt;
  --   * a folder-shaped name this app never minted (`<own id>/evidence.jpg`,
  --     `<own id>/nested/x.jpg`, `<own id>/x_1.gif`) - what a patched client would
  --     send to park an arbitrary object where a reviewer believes a snapshot of
  --     this student is.
  -- A `~` on NULL yields NULL, which takes the `else` arm, so a missing path stays
  -- missing. Storing NULL rather than raising is deliberate: a malformed path must
  -- not buy a strike back - the incident is the fact, the photograph is the
  -- optional attachment.
  v_snapshot_path := case
    when p_snapshot_url ~ ('^' || p_submission_id::text || '/[a-z_]+_[0-9]+\.(jpg|png)$')
      then p_snapshot_url
    else null
  end;

  insert into public.proctoring_logs (
    submission_id, action_type, snapshot_url, client_timestamp, client_event_id
  )
  values (
    p_submission_id,
    p_action_type,
    v_snapshot_path,
    coalesce(p_client_timestamp, now()),
    p_client_event_id
  )
  on conflict (client_event_id) where client_event_id is not null do nothing;

  select count(*) into v_count
  from public.proctoring_logs
  where submission_id = p_submission_id;

  -- The weighted score for the whole attempt, recomputed from the stored rows -
  -- never an increment. A replayed `client_event_id` inserts nothing, a retried
  -- delivery inserts nothing, and a queue replayed twice must arrive at exactly the
  -- same number as the evidence actually held.
  --
  -- `left join` + coalesce is the fail-closed shape: a row whose action_type has no
  -- weight yet scores one point, so widening the check constraint (section 5) can
  -- never hand out a free signal. `counts_toward_dq` gates the point, so a soft
  -- type contributes 0 even if somebody later gives it a weight.
  select coalesce(sum(
           case
             when coalesce(w.counts_toward_dq, true) then coalesce(w.weight, 1)
             else 0
           end
         ), 0)::int
    into v_weighted
  from public.proctoring_logs l
  left join public.violation_weights w on w.action_type = l.action_type
  where l.submission_id = p_submission_id;

  if v_weighted >= c_flag_threshold then
    -- The sitting stops, but nobody has decided anything: `flagged_for_review`
    -- means "a person must look at this", and `resolve_flagged_attempt()` below is
    -- that person. `submitted_at` is written once - a replayed call keeps the
    -- original close time - and `score` is cleared because marking does not start
    -- until the review ends.
    update public.exam_submissions
       set status = 'flagged_for_review',
           submitted_at = coalesce(submitted_at, now()),
           score = null
     where id = p_submission_id
       and status = 'ongoing';
    return query select v_count, false, true;
    return;
  end if;

  return query select v_count, false, false;
end;
$$;
revoke execute on function public.register_violation(uuid, text, text, timestamptz, uuid) from public, anon;
grant execute on function public.register_violation(uuid, text, text, timestamptz, uuid) to authenticated, service_role;

comment on function public.register_violation(uuid, text, text, timestamptz, uuid) is
  'The single write path for proctoring evidence: ownership-checked, idempotent per client_event_id, and weighted - only types whose violation_weights row counts_toward_dq add points. At 3 weighted points the attempt becomes flagged_for_review for resolve_flagged_attempt() instead of being disqualified automatically.';

-- ---------------------------------------------------------------------
-- Recording a consent acceptance (RPC)
-- ---------------------------------------------------------------------
-- The write half of §3b, and the only writer of `proctoring_consents`. It is an
-- RPC rather than a plain PostgREST insert for three reasons the table cannot
-- express on its own:
--
--   * `student_id` is `auth.uid()`, never a body field - the ownership is stated
--     once, in the server;
--   * `user_agent` comes from the *transport* headers
--     (`request.headers` -> `user-agent`), so it is the server's record of what
--     client asked rather than the client's account of itself. That setting only
--     exists behind PostgREST, hence the wrapped read: a direct psql call has no
--     headers and the column is evidence, not a condition;
--   * `is_current` answers a question the client cannot answer for itself: is the
--     version I just displayed the one in force? `false` means this build shipped
--     older wording, and the consent screen says so ("update the app") instead of
--     letting the student accept text the institution has replaced and then be
--     refused at the insert with no explanation.
--
-- Idempotent: a retry after a lost response returns the row that already exists
-- (the two partial unique indexes in §3b are what make that a no-op rather than a
-- duplicate or a unique-violation the student cannot act on). The version is
-- stored verbatim - a server that "corrected" it would be writing a claim nobody
-- made - and an exam-scoped acceptance is only accepted for a paper the student
-- may sit, so a random uuid cannot be used to fill the table.
create or replace function public.record_consent(
  p_exam_id uuid default null,
  p_version text default null
)
returns table (
  consent_id      uuid,
  consent_version text,
  accepted_at     timestamptz,
  is_current      boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_student    uuid := auth.uid();
  v_version    text;
  v_user_agent text;
  v_id         uuid;
  v_accepted   timestamptz;
begin
  if v_student is null then
    raise exception 'Sign in before accepting the proctoring notice.'
      using errcode = '28000';
  end if;

  v_version := nullif(btrim(coalesce(p_version, '')), '');
  if v_version is null then
    raise exception 'The consent notice version is required.'
      using errcode = '22023';
  end if;
  if length(v_version) > 64 then
    raise exception 'The consent notice version is longer than 64 characters.'
      using errcode = '22023';
  end if;

  -- "May this student sit this paper at all?" is the same predicate the attempt
  -- policy asks, so an acceptance can never be stored for a paper the student has
  -- no access to. A general acceptance (no paper) skips the question.
  if p_exam_id is not null and not public.student_can_access_exam(p_exam_id) then
    raise exception 'That paper is not offered to you, so there is nothing to accept for it.'
      using errcode = '42501';
  end if;

  -- The transport's header, when there is one. Wrapped because
  -- `request.headers` is a PostgREST setting that a direct psql session does not
  -- have, and its absence must not fail an acceptance: this column is evidence,
  -- not a condition.
  begin
    v_user_agent := nullif(btrim(coalesce(
      (current_setting('request.headers', true)::jsonb) ->> 'user-agent', '')), '');
  exception
    when others then
      v_user_agent := null;
  end;

  -- The table is aliased and every name in the RETURNING list is qualified: the
  -- OUT parameters above are named `consent_id`, `consent_version`,
  -- `accepted_at` and `is_current`, and PL/pgSQL resolves a bare column name
  -- against its variables first - an unqualified `accepted_at` here raises
  -- 42702 ("column reference "accepted_at" is ambiguous") the first time the RPC
  -- runs, which is why it is spelled `c.accepted_at`.
  insert into public.proctoring_consents as c (
    student_id, exam_id, consent_version, user_agent
  )
  values (
    v_student, p_exam_id, v_version, v_user_agent
  )
  -- No conflict target on purpose: the two partial unique indexes above split on
  -- `exam_id is null`, and "swallow whichever one this row hit" is exactly the
  -- intent - either shape is already stored, once.
  on conflict do nothing
  returning c.id, c.accepted_at into v_id, v_accepted;

  if v_id is null then
    select c.id, c.accepted_at into v_id, v_accepted
      from public.proctoring_consents c
     where c.student_id = v_student
       and c.consent_version = v_version
       and c.exam_id is not distinct from p_exam_id
     order by c.accepted_at
     limit 1;
  end if;

  return query
    select v_id, v_version, v_accepted,
           v_version = public.current_proctor_consent_version();
end;
$$;

comment on function public.record_consent(uuid, text) is
  'Records the caller''s acceptance of the proctoring consent notice for one paper (or generally, when p_exam_id is NULL). Stores the version the client says it displayed plus the transport User-Agent, is idempotent, and reports is_current = false when the version sent is not the one in force. The only writer of public.proctoring_consents.';

revoke execute on function public.record_consent(uuid, text) from public, anon;
grant execute on function public.record_consent(uuid, text) to authenticated, service_role;


-- ---------------------------------------------------------------------
-- The proctoring heartbeat (RPC)
-- ---------------------------------------------------------------------
-- The complement of `register_violation()`: that RPC records what the client
-- *saw*, this one records that the client was *there to see it*. Without it an
-- empty `proctoring_logs` feed means either "watched and clean" or "nobody was
-- watching", and a supervisor has no way to tell which - see section 5b for the
-- full argument and for what a heartbeat cannot prove.
--
-- Shape of the contract, chosen so a client can stay simple and a server can
-- still be strict:
--
--   * ownership and status are re-checked here, never trusted from the request;
--   * one row per beat, deduplicated on `client_event_id` so the offline queue
--     can replay a batch of beats without inflating the series;
--   * a beat arriving inside the rate-limit window is answered, not raised: the
--     client retries on a timer and must not have to special-case "you are too
--     early", which is never the student's fault;
--   * the same transaction stamps `exam_submissions.last_heartbeat_at`, so the
--     live grid can ask "is this client still here" from the row it already
--     streams.
--
-- A throttled or duplicated beat still means the client is alive *right now*, so
-- `last_heartbeat_at` is refreshed for all three outcomes. Only the insert is
-- skipped - the series must not be padded by retries.
create or replace function public.record_heartbeat(
  p_submission_id   uuid,
  p_camera_ok       boolean     default true,
  p_monitoring_ok   boolean     default true,
  p_app_version     text        default null,
  p_client_time     timestamptz default null,
  p_client_event_id uuid        default null
)
returns table (
  -- 'recorded' | 'duplicate' | 'throttled'. Not an error for the last two: the
  -- client's job is to keep the beat going, not to negotiate about one.
  outcome     text,
  recorded_at timestamptz,
  beat_count  int
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  -- The client beats every 15s (mobile: ProctoringHeartbeatService). The window is
  -- deliberately *shorter* than that so an honest client is never throttled by
  -- jitter, while a script hammering the RPC still cannot write a thousand rows a
  -- second.
  c_min_interval constant interval := interval '8 seconds';
  v_now   timestamptz := now();
  v_sub   public.exam_submissions;
  v_last  timestamptz;
  v_first timestamptz;
  v_count int;
begin


  if auth.uid() is null then
    raise exception 'record_heartbeat: sign in before reporting a heartbeat'
      using errcode = '28000';
  end if;

  -- `for update` serialises two beats that arrive together, so the rate-limit
  -- read below cannot be raced into writing two rows inside one window.
  select * into v_sub
  from public.exam_submissions s
  where s.id = p_submission_id
  for update;

  if not found then
    raise exception 'record_heartbeat: no attempt with id %', p_submission_id
      using errcode = 'P0002';
  end if;

  if v_sub.student_id <> auth.uid() then
    raise exception 'record_heartbeat: attempt % belongs to another student', p_submission_id
      using errcode = '42501';
  end if;

  -- A closed attempt cannot report for duty. Accepting these would let an ended
  -- (or flagged) sitting keep its coverage looking healthy after the fact.
  if v_sub.status <> 'ongoing' then
    raise exception 'record_heartbeat: attempt % is %, not ongoing', p_submission_id, v_sub.status
      using errcode = '22023';
  end if;

  select count(*) into v_count
  from public.proctor_heartbeats h
  where h.submission_id = p_submission_id;

  -- Idempotency first: a replay of a beat that is already stored is not "too
  -- early", it is already done.
  if p_client_event_id is not null then
    select h.received_at into v_last
    from public.proctor_heartbeats h
    where h.client_event_id = p_client_event_id;

    if v_last is not null then
      -- Still refresh liveness: the client is talking to us *now*, whatever the
      -- beat it replayed was about.
      update public.exam_submissions
         set last_heartbeat_at = v_now
       where id = p_submission_id;
      return query select 'duplicate'::text, v_last, v_count;
      return;
    end if;
  end if;

  select max(h.received_at) into v_last
  from public.proctor_heartbeats h
  where h.submission_id = p_submission_id;

  if v_last is not null and v_last > v_now - c_min_interval then
    update public.exam_submissions
       set last_heartbeat_at = v_now
     where id = p_submission_id;
    return query select 'throttled'::text, v_last, v_count;
    return;
  end if;

  insert into public.proctor_heartbeats (
    submission_id, received_at, client_time, camera_ok, monitoring_ok,
    app_version, client_event_id
  )
  values (
    p_submission_id,
    v_now,
    p_client_time,
    coalesce(p_camera_ok, true),
    coalesce(p_monitoring_ok, true),
    p_app_version,
    p_client_event_id
  )
  on conflict (client_event_id) where client_event_id is not null do nothing
  returning received_at into v_first;

  update public.exam_submissions
     set last_heartbeat_at = v_now
   where id = p_submission_id;

  -- The insert may have been swallowed by the unique index if two deliveries of
  -- the same beat raced; either way the attempt is alive and the series holds one
  -- row, so both answers are honest.
  -- `count(*)` is bigint and `beat_count` is int: a RETURN QUERY is checked
  -- against the declared row type exactly (no assignment cast, unlike
  -- `select ... into`), so the cast is what keeps the RPC from failing with
  -- "Returned type bigint does not match expected type integer in column 3".
  return query select
    case when v_first is null then 'duplicate' else 'recorded' end,
    coalesce(v_first, v_now),
    (select count(*)::integer from public.proctor_heartbeats h
      where h.submission_id = p_submission_id);
end;
$$;
revoke execute on function public.record_heartbeat(uuid, boolean, boolean, text, timestamptz, uuid) from public, anon;
grant execute on function public.record_heartbeat(uuid, boolean, boolean, text, timestamptz, uuid) to authenticated, service_role;

comment on function public.record_heartbeat(uuid, boolean, boolean, text, timestamptz, uuid) is
  'The single write path for proctoring heartbeats: ownership- and status-checked, idempotent per client_event_id, rate-limited to one stored beat per 8s, and the only writer of exam_submissions.last_heartbeat_at. Proves a client was running, never that it was doing its job.';

-- ---------------------------------------------------------------------
-- Coverage: what the heartbeat series can and cannot say (RPC)
-- ---------------------------------------------------------------------
-- Answers "was this attempt actually watched?" with numbers a supervisor can
-- check, and a `risk_flag` that means *look at this*, never *punish this*:
--
--   * `beats = 0`                  nothing ever checked in;
--   * `longest_gap_seconds > 60`   proctoring stopped for a while;
--   * `camera_down_beats > 0`      the monitor was up with no camera behind it;
--   * `coverage_ratio < 0.5`       most of the expected beats never arrived.
--
-- The grace window exists because every attempt blinks for the first minute: the
-- client boots, asks for the camera, waits for the detector model. Flagging that
-- would turn the report into noise. And no branch here touches
-- `exam_submissions.status`: coverage informs a human, it does not act.
create or replace function public.proctoring_coverage(p_submission_id uuid)
returns table (
  submission_id         uuid,
  student_id            uuid,
  exam_id               uuid,
  status                text,
  started_at            timestamptz,
  ended_at              timestamptz,
  beats                 int,
  expected_beats        int,
  coverage_ratio        numeric,
  first_beat_at         timestamptz,
  last_beat_at          timestamptz,
  longest_gap_seconds   int,
  silent_seconds        int,
  camera_down_beats     int,
  monitoring_down_beats int,
  risk_flag             boolean,
  reason                text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  -- The cadence the client is expected to keep (mobile ProctoringHeartbeatService).
  -- Expected beats are derived from the attempt's own length, so a 20-minute
  -- sitting is not judged against a 2-hour one.
  c_expected_interval constant numeric  := 15;
  -- Anything longer than this between two beats is a gap worth a human's time.
  c_gap_threshold     constant int      := 60;
  -- No verdict of any kind for the first stretch of an attempt.
  c_grace             constant interval := interval '90 seconds';

  v_sub      public.exam_submissions;
  v_now      timestamptz := now();
  v_end      timestamptz;
  v_window   numeric;
  v_beats    int;
  v_expected int;
  v_ratio    numeric;
  v_first    timestamptz;
  v_last     timestamptz;
  v_gap      int;
  v_head     int;
  v_tail     int;
  v_camera   int;
  v_monitor  int;
  v_silent   int;
  v_flag     boolean := false;
  v_reasons  text[]  := '{}';
begin
  select * into v_sub
  from public.exam_submissions s
  where s.id = p_submission_id;

  if not found then
    raise exception 'proctoring_coverage: no attempt with id %', p_submission_id
      using errcode = 'P0002';
  end if;

  -- SECURITY DEFINER, so the visibility rule the RLS policy on
  -- `proctor_heartbeats` would have applied has to be spelled out here. Same
  -- three audiences as `logs_select_own_or_supervisor`.
  if not (
    v_sub.student_id = auth.uid()
    or public.owns_exam(v_sub.exam_id)
    or public.can_supervise_exam(v_sub.exam_id)
  ) then
    raise exception 'proctoring_coverage: attempt % is not yours to read', p_submission_id
      using errcode = '42501';
  end if;

  v_end := coalesce(v_sub.submitted_at, v_now);

  select count(*),
         min(h.received_at),
         max(h.received_at),
         count(*) filter (where not h.camera_ok),
         count(*) filter (where not h.monitoring_ok)
    into v_beats, v_first, v_last, v_camera, v_monitor
  from public.proctor_heartbeats h
  where h.submission_id = p_submission_id;

  -- Longest silence *between* stored beats, then the two ends: the head gap
  -- (attempt started, nothing checked in yet) and the tail (client went quiet
  -- before the attempt closed). All three are the same fact - a stretch with no
  -- evidence of a running monitor - so the report keeps the largest.
  select coalesce(max(g.seconds), 0) into v_gap
  from (
    select extract(epoch from (h.received_at
             - lag(h.received_at) over (order by h.received_at)))::int as seconds
    from public.proctor_heartbeats h
    where h.submission_id = p_submission_id
  ) g
  where g.seconds is not null;

  v_head := greatest(0, extract(epoch from (coalesce(v_first, v_end) - v_sub.started_at))::int);
  v_tail := greatest(0, extract(epoch from (v_end - coalesce(v_last, v_sub.started_at)))::int);
  v_gap  := greatest(v_gap, v_head, v_tail);

  v_window   := greatest(0, extract(epoch from (v_end - v_sub.started_at)));
  v_expected := floor(v_window / c_expected_interval)::int + 1;
  v_ratio    := round(v_beats::numeric / greatest(v_expected, 1), 3);

  -- Silence *now* only means something while the attempt is live; a closed
  -- attempt's silence is already in the tail gap above.
  v_silent := case
    when v_sub.status = 'ongoing'
      then greatest(0, extract(epoch from (v_now - coalesce(v_last, v_sub.started_at)))::int)
    else 0
  end;

  if v_sub.status = 'ongoing' and v_now - v_sub.started_at < c_grace then
    -- Too early to say anything: reported as a row (so a console can still show
    -- "0 beats so far") but never as a gap.
    v_reasons := array_append(v_reasons, 'attempt just started - too early to judge');
  else
    if v_beats = 0 then
      v_flag := true;
      v_reasons := array_append(v_reasons,
        'the proctoring client never checked in - no evidence of monitoring for this attempt');
    end if;
    if v_gap > c_gap_threshold then
      v_flag := true;
      v_reasons := array_append(v_reasons,
        format('proctoring went quiet for %ss (longest, including the ends)', v_gap));
    end if;
    if v_camera > 0 then
      v_flag := true;
      v_reasons := array_append(v_reasons,
        format('the camera was not streaming on %s heartbeat(s)', v_camera));
    end if;
    if v_ratio < 0.5 then
      v_flag := true;
      v_reasons := array_append(v_reasons,
        format('only %s of ~%s expected heartbeats arrived', v_beats, v_expected));
    end if;
    if v_monitor > 0 and v_camera = 0 then
      -- Recorded, never flagged on its own: a beat with monitoring_ok = false and
      -- the camera up is the client admitting it was backgrounded, which the gap
      -- rules above will usually have caught anyway.
      v_reasons := array_append(v_reasons,
        format('%s heartbeat(s) reported monitoring inactive', v_monitor));
    end if;
    if v_flag then
      v_reasons := array_append(v_reasons,
        'flag for human review only - a gap can be a dropped network or a broken webcam; coverage never disqualifies an attempt');
    elsif v_reasons = '{}' then
      v_reasons := array_append(v_reasons,
        format('%s heartbeats, largest gap %ss - proctoring was running throughout', v_beats, v_gap));
    end if;
  end if;

  return query select
    v_sub.id, v_sub.student_id, v_sub.exam_id, v_sub.status,
    v_sub.started_at,
    case when v_sub.submitted_at is null then null else v_end end,
    v_beats, v_expected, v_ratio, v_first, v_last,
    v_gap, v_silent, v_camera, v_monitor, v_flag,
    array_to_string(v_reasons, '; ');
end;
$$;
revoke execute on function public.proctoring_coverage(uuid) from public, anon;
grant execute on function public.proctoring_coverage(uuid) to authenticated, service_role;

comment on function public.proctoring_coverage(uuid) is
  'Per-attempt heartbeat coverage: beats received vs expected, longest gap, silent time and camera-down beats, plus a risk_flag that marks the attempt for human review. Never changes exam_submissions.status - a gap can be a network drop, so coverage informs, it does not disqualify.';

-- Every attempt in one sitting, for the supervisor who is about to decide
-- something: one call, no joins. Visibility is filtered *before* the lateral call
-- so a student asking about their exam gets their own row instead of an exception
-- for a classmate's.
create or replace function public.proctoring_coverage_for_exam(p_exam_id uuid)
returns setof record
language sql
security invoker
set search_path = public, pg_temp
as $$
  select c.*
  from public.exam_submissions s
  cross join lateral public.proctoring_coverage(s.id) c
  where s.exam_id = p_exam_id
    and (
      s.student_id = auth.uid()
      or public.owns_exam(s.exam_id)
      or public.can_supervise_exam(s.exam_id)
    )
  order by c.risk_flag desc, c.last_beat_at nulls first;
$$;
revoke execute on function public.proctoring_coverage_for_exam(uuid) from public, anon;
grant execute on function public.proctoring_coverage_for_exam(uuid) to authenticated, service_role;

comment on function public.proctoring_coverage_for_exam(uuid) is
  'proctoring_coverage() for every attempt in one exam, risk-flagged rows first. Returns setof record, so callers must name the columns: select * from proctoring_coverage_for_exam(...) as c(submission_id uuid, student_id uuid, exam_id uuid, status text, started_at timestamptz, ended_at timestamptz, beats int, expected_beats int, coverage_ratio numeric, first_beat_at timestamptz, last_beat_at timestamptz, longest_gap_seconds int, silent_seconds int, camera_down_beats int, monitoring_down_beats int, risk_flag boolean, reason text).';

-- ---------------------------------------------------------------------
-- The human decision behind the weighted threshold (RPC)
-- ---------------------------------------------------------------------
-- The only way out of `flagged_for_review`, and the only writer of
-- `attempt_review_logs` (section 7a). A server that stops an attempt on a weighted
-- score and then leaves it stopped forever would be worse than the 3-strike rule it
-- replaces: the student would have no outcome and the paper would never be marked.
--
-- WHO MAY CALL IT: the tier that may already delete an attempt on this paper -
-- `can_supervise_exam(v_exam)` (an administrator, or the supervisor assigned to the
-- paper) anywhere and `owns_exam(exam_id)` for
-- the lecturer who wrote it. A lecturer on somebody else's paper is refused, and so
-- is the student: the account under review does not get a vote.
--
-- 'disqualify' -> status 'disqualified', score cleared.
-- 'clear'      -> status 'submitted', score recomputed from the automatic key -
--                 the gradable state. Subjective marks arrive afterwards through
--                 `grade_submission()`, which refuses a flagged attempt precisely so
--                 a mark cannot be awarded on a sitting that then stops counting.
--
-- Idempotent: an attempt that is no longer flagged returns the status it already
-- holds and writes no second audit row, so a lost response can be retried. An
-- 'ongoing' attempt raises - there is nothing to review yet, and closing a live
-- sitting silently would be a reset by another name.
create or replace function public.resolve_flagged_attempt(
  p_submission_id uuid,
  p_decision      text,
  p_note          text default null
)
returns table(new_status text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status  text;
  v_student uuid;
  v_exam    uuid;
  v_to      text;
  v_score   numeric;
begin
  if auth.uid() is null then
    raise exception 'authentication is required to resolve a flagged attempt'
      using errcode = '42501';
  end if;

  if p_decision is null or p_decision not in ('disqualify', 'clear') then
    raise exception 'a review decision must be ''disqualify'' or ''clear'' (got %)',
      coalesce(p_decision, 'null')
      using errcode = '22023';
  end if;

  -- Locked for the duration: two supervisors pressing "Disqualify" and "Clear" in
  -- the same second must produce one decision and one audit row, not two that
  -- disagree.
  select s.status, s.student_id, s.exam_id
    into v_status, v_student, v_exam
  from public.exam_submissions s
  where s.id = p_submission_id
  for update;

  if v_status is null then
    raise exception 'submission % does not exist', p_submission_id
      using errcode = 'P0002';
  end if;

  -- The tier check runs BEFORE the status check on purpose: whether an attempt is
  -- flagged is not something an unauthorised caller should learn from an error
  -- message, and the refusal has to be identical for every attempt they may not
  -- touch.
  if not (public.can_supervise_exam(v_exam) or public.owns_exam(v_exam)) then
    raise exception 'only a supervisor, or the lecturer who wrote this paper, may resolve a flagged attempt'
      using errcode = '42501';
  end if;

  if v_status = 'ongoing' then
    raise exception 'submission % is still in progress: there is nothing to review', p_submission_id
      using errcode = '55000';
  end if;

  if v_status <> 'flagged_for_review' then
    -- Already decided (or never flagged): report the stored outcome and write
    -- nothing, so a client that lost the response can replay the call without a
    -- second audit row appearing.
    return query select v_status;
    return;
  end if;

  if p_decision = 'disqualify' then
    v_to := 'disqualified';
    v_score := null;
  else
    v_to := 'submitted';
    -- The automatic part of the mark, exactly as submit_exam() computes it, so
    -- "clear" lands the attempt in the state a normal hand-in would.
    v_score := public.auto_graded_score(p_submission_id);
  end if;

  update public.exam_submissions
     set status = v_to,
         score = v_score,
         submitted_at = coalesce(submitted_at, now())
   where id = p_submission_id;

  insert into public.attempt_review_logs (
    submission_id, student_id, exam_id, from_status, to_status, decision, note
  )
  values (
    p_submission_id,
    v_student,
    v_exam,
    v_status,
    v_to,
    p_decision,
    -- Capped like every other free-text field here, and blank becomes NULL so "no
    -- note" has one shape.
    nullif(btrim(left(coalesce(p_note, ''), 2000)), '')
  );

  return query select v_to;
end;
$$;

comment on function public.resolve_flagged_attempt(uuid, text, text) is
  'The human decision behind flagged_for_review: disqualify or clear an attempt that reached the weighted threshold, supervisor-only (or the paper''s author), and the only writer of attempt_review_logs. Idempotent; refuses an ongoing attempt.';

revoke execute on function public.resolve_flagged_attempt(uuid, text, text) from public, anon;
grant execute on function public.resolve_flagged_attempt(uuid, text, text) to authenticated, service_role;



-- ---------------------------------------------------------------------
-- The single home of "how long has this attempt got?"
-- ---------------------------------------------------------------------
-- `started_at` + the paper's `duration_minutes`, *capped* by the paper's own
-- `ends_at` when it has one. Both RPCs below and `submit_exam()` ask this one
-- function, so the deadline an answer is measured against and the deadline the
-- close records can never disagree - the same reason `auto_graded_score()` owns
-- the grading rule.
--
-- IMMUTABLE, and deliberately not SECURITY DEFINER: it reads no table, so there
-- is nothing for RLS to filter and nothing to leak. `coalesce(..., 'infinity')`
-- is what keeps an unscheduled paper (ends_at NULL) behaving exactly as it did
-- before the columns existed.
create or replace function public.attempt_deadline(
  p_started_at       timestamptz,
  p_duration_minutes int,
  p_ends_at          timestamptz
)
returns timestamptz
language sql
immutable
as $$
  select least(
    p_started_at + make_interval(mins => p_duration_minutes),
    coalesce(p_ends_at, 'infinity'::timestamptz)
  );
$$;

comment on function public.attempt_deadline(timestamptz, int, timestamptz) is
  'The effective deadline of an attempt: started_at + duration_minutes, capped by the exam window''s ends_at (NULL ends_at = no cap).';

revoke execute on function public.attempt_deadline(timestamptz, int, timestamptz) from public, anon;
grant execute on function public.attempt_deadline(timestamptz, int, timestamptz) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Race-safe partial-answer merge (RPC)
-- ---------------------------------------------------------------------
create or replace function public.merge_submission_answer(
  p_submission_id uuid,
  p_question_id uuid,
  p_selected_option int
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication is required to save an exam answer'
      using errcode = '42501';
  end if;

  update public.exam_submissions as s
  set answers = jsonb_set(
        coalesce(s.answers, '{}'::jsonb),
        array[p_question_id::text],
        to_jsonb(p_selected_option),
        true
      )
  where s.id = p_submission_id
    and s.student_id = auth.uid()
    and s.status = 'ongoing'
    and exists (
      select 1
      from public.exams e
      where e.id = s.exam_id
        -- The paper's own close is a hard close: an answer that arrives after
        -- `ends_at` is refused even while the attempt's duration has time left.
        and clock_timestamp() < public.attempt_deadline(
          s.started_at, e.duration_minutes, e.ends_at
        )
    );

  if not found then
    raise exception 'submission is not active or its exam deadline has passed'
      using errcode = '55000';
  end if;
end;
$$;
revoke execute on function public.merge_submission_answer(uuid, uuid, int) from public, anon;
grant execute on function public.merge_submission_answer(uuid, uuid, int) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Server-side grading + close (RPC)
-- ---------------------------------------------------------------------
-- The only way a student can close their own attempt, and the only writer of
-- `score`. Grading is a sum of `questions.points` over the questions whose
-- `correct_option` matches the stored answer, so the answer key never leaves
-- the database and a patched client cannot award itself points
-- (there is no student UPDATE policy on exam_submissions any more).
--
-- Idempotent by design: closing an attempt that is already closed returns its
-- final state instead of raising, so an offline client replaying the call after
-- a reconnect is safe. `p_disqualified => true` is the client-side redundancy
-- path for a disqualification the server has already applied via
-- register_violation(); it never grades.
--
-- The deadline it records is `attempt_deadline()`: the attempt's own duration,
-- capped by the paper's `ends_at` when the paper has a window, so a paper that
-- closes at 17:00 does not hand an attempt started at 16:50 a full hour.
create or replace function public.submit_exam(
  p_submission_id uuid,
  p_disqualified  boolean default false
)
returns table(result_status text, final_score numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student uuid;
  v_exam    uuid;
  v_status  text;
  v_started_at timestamptz;
  v_duration_minutes int;
  v_ends_at timestamptz;
  v_submitted_at timestamptz;
  v_score   numeric;
begin
  if auth.uid() is null then
    raise exception 'authentication is required to submit an exam'
      using errcode = '42501';
  end if;

  select s.student_id, s.exam_id, s.status, s.started_at,
         e.duration_minutes, e.ends_at
    into v_student, v_exam, v_status, v_started_at,
         v_duration_minutes, v_ends_at
  from public.exam_submissions s
  join public.exams e on e.id = s.exam_id
  where s.id = p_submission_id
  for update of s;

  if v_student is null then
    raise exception 'submission % does not exist', p_submission_id
      using errcode = 'P0002';
  end if;

  if v_student <> auth.uid() and not public.can_supervise_exam(v_exam) then
    raise exception 'submission % does not belong to the caller', p_submission_id
      using errcode = '42501';
  end if;

  -- Already closed: report the stored outcome (retry-safe).
  if v_status <> 'ongoing' then
    return query
      select s.status, s.score
      from public.exam_submissions s
      where s.id = p_submission_id;
    return;
  end if;

  -- Expired attempts are closed and graded from answers saved before the
  -- deadline. Record the deadline as the effective submit time for late closes:
  -- `attempt_deadline()` is the attempt's own duration capped by the paper's
  -- close, so a late arrival inside a scheduled window records the window's end.
  v_submitted_at := least(
    clock_timestamp(),
    public.attempt_deadline(v_started_at, v_duration_minutes, v_ends_at)
  );

  -- A disqualified attempt is never graded: a score would imply it counts.
  if p_disqualified then
    update public.exam_submissions
    set status = 'disqualified', submitted_at = now(), score = null
    where id = p_submission_id;

    return query select 'disqualified'::text, null::numeric;
    return;
  end if;

  -- Grading is a sum of `questions.points` over the questions the student got
  -- right, and it has to cover every automatically graded shape:
  --   * multiple choice: the stored jsonb number equals `correct_option`
  --   * true/false and fill in the blank: the stored jsonb string matches
  --     `correct_text_answer` case-insensitively after trimming, so "  http "
  --     counts for "HTTP" and "TRUE" counts for "true"
  -- A 'subjective' row never matches: it has no key, and its marks arrive later
  -- through `grade_submission()` after a person read it. An unanswered question
  -- stores nothing, so `->>` is NULL and the comparison is NULL (never true) - it
  -- simply does not score.
  --
  -- The sum itself lives in `auto_graded_score()` so this close and a later
  -- `grade_submission()` cannot drift apart about which answers count.
  v_score := public.auto_graded_score(p_submission_id);

  update public.exam_submissions
  set status = 'submitted', submitted_at = v_submitted_at, score = v_score
  where id = p_submission_id;

  return query select 'submitted'::text, v_score;
end;
$$;

comment on function public.submit_exam(uuid, boolean) is
  'Closes and grades a student''s own attempt; late answer writes are rejected and an expired attempt is graded from saved answers. The deadline is started_at + duration_minutes, capped by the exam window''s ends_at. Idempotent.';

revoke execute on function public.submit_exam(uuid, boolean) from public, anon;
grant execute on function public.submit_exam(uuid, boolean) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Race-safe free-text answer merge (RPC)
-- ---------------------------------------------------------------------
-- The fill-in-the-blank twin of merge_submission_answer(): it stores a JSON
-- *string* under the question id instead of an option index, with the same
-- ownership + `ongoing` guard. Used by the Flutter exam screen, and the only
-- way a text answer reaches the row (students have no UPDATE policy on
-- exam_submissions).
--
-- The value is capped at 2000 characters: a patched client must not be able to
-- park an unbounded blob in the answers jsonb of a row a supervisor will later
-- read.
create or replace function public.merge_submission_text_answer(
  p_submission_id uuid,
  p_question_id   uuid,
  p_answer        text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication is required to save an exam answer'
      using errcode = '42501';
  end if;

  update public.exam_submissions as s
  set answers = jsonb_set(
        coalesce(s.answers, '{}'::jsonb),
        array[p_question_id::text],
        to_jsonb(left(coalesce(p_answer, ''), 2000)),
        true
      )
  where s.id = p_submission_id
    and s.student_id = auth.uid()
    and s.status = 'ongoing'
    and exists (
      select 1
      from public.exams e
      where e.id = s.exam_id
        -- Same deadline as the option merge: whichever comes first, the
        -- attempt's duration or the paper's close.
        and clock_timestamp() < public.attempt_deadline(
          s.started_at, e.duration_minutes, e.ends_at
        )
    );

  if not found then
    raise exception 'submission is not active or its exam deadline has passed'
      using errcode = '55000';
  end if;
end;
$$;
revoke execute on function public.merge_submission_text_answer(uuid, uuid, text) from public, anon;
grant execute on function public.merge_submission_text_answer(uuid, uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Automatic score of an attempt (RPC helper)
-- ---------------------------------------------------------------------
-- The single home of the automatic grading predicate: `submit_exam()` calls it
-- when an attempt closes, and `grade_submission()` calls it again to recompute
-- that same part after a subjective answer is marked. Two copies of "which
-- answers count" is how a re-mark silently disagrees with the close before it.
--
-- SECURITY DEFINER because the caller's own policies would hide the answer key:
-- `questions` has no student SELECT policy, so under invoker semantics every
-- attempt would grade 0. It returns one number - never the key it read - and it
-- answers only for an attempt the caller may already see.
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
    and (s.student_id = auth.uid() or public.is_staff())
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
  'Automatic part of an attempt''s score (multiple-choice, true/false and fill-in-the-blank answers). Marks awarded by hand live in question_grades.';

revoke execute on function public.auto_graded_score(uuid) from public, anon;
grant execute on function public.auto_graded_score(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Marking the subjective answers (RPC)
-- ---------------------------------------------------------------------
-- The only writer of `question_grades`, and the only writer of a `score` a
-- person influenced. `p_grades` is a JSON object keyed by question id, the same
-- shape as `answers`:
--
--   { "<question uuid>": { "awarded": 7.5, "feedback": "Good structure." } }
--
-- Only the paper's owner (or an administrator) may call it, only for a
-- *subjective* question of that paper, only for an attempt that has already been
-- handed in, and never for more than the question is worth - the four ways a
-- marking slip turns into somebody's wrong final mark. Everything else is
-- refused with a status the app turns into prose.
--
-- Idempotent by construction: the marks are upserted and `score` is recomputed
-- from the answers rather than incremented, so replaying the call after a dropped
-- connection leaves the attempt exactly as it was, and a second read of the same
-- essay is a correction of the same row rather than a second award.
create or replace function public.grade_submission(
  p_submission_id uuid,
  p_grades        jsonb
)
returns table(final_score numeric, graded_answers int, ungraded_answers int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exam    uuid;
  v_status  text;
  v_owner   uuid;
  v_entry   record;
  v_awarded numeric;
  v_points  numeric;
  v_graded  int;
  v_open    int;
  v_score   numeric;
begin
  if auth.uid() is null then
    raise exception 'authentication is required to grade an attempt'
      using errcode = '42501';
  end if;

  if p_grades is null or jsonb_typeof(p_grades) <> 'object' then
    raise exception 'the marks must be a json object keyed by question id'
      using errcode = '22023';
  end if;

  select s.exam_id, s.status, e.created_by
    into v_exam, v_status, v_owner
  from public.exam_submissions s
  join public.exams e on e.id = s.exam_id
  where s.id = p_submission_id
  for update of s;

  if v_exam is null then
    raise exception 'submission % does not exist', p_submission_id
      using errcode = 'P0002';
  end if;

  -- The academic owner, not the wider invigilation tier: a supervisor may clear
  -- an attempt, but the mark on somebody's paper is the lecturer's call. An
  -- administrator is the deliberate exception - the role that can already
  -- intervene in a submission directly.
  if v_owner <> auth.uid() and not public.is_admin() then
    raise exception 'only the exam owner may grade its answers'
      using errcode = '42501';
  end if;

  -- An open attempt has not been handed in, so its answers can still change and
  -- there is nothing final to mark yet.
  if v_status = 'ongoing' then
    raise exception 'submission % is still in progress', p_submission_id
      using errcode = '55000';
  end if;

  -- A disqualified attempt is never graded: a score would imply it counts.
  if v_status = 'disqualified' then
    raise exception 'submission % was disqualified and is not graded',
      p_submission_id
      using errcode = '55000';
  end if;

  -- The weighted-threshold state: an attempt under review has no outcome yet, and a
  -- mark entered now would be a mark on a sitting that may stop counting.
  -- `resolve_flagged_attempt()` either disqualifies it or restores it to
  -- 'submitted', after which this function grades it normally.
  if v_status = 'flagged_for_review' then
    raise exception 'submission % is under review and is not graded until it is resolved',
      p_submission_id
      using errcode = '55000';
  end if;

  for v_entry in
    select key as question_id, value as mark from jsonb_each(p_grades)
  loop
    select q.points into v_points
    from public.questions q
    where q.id = v_entry.question_id::uuid
      and q.exam_id = v_exam
      and q.question_type = 'subjective';

    if v_points is null then
      raise exception 'question % is not a subjective question of this exam',
        v_entry.question_id
        using errcode = '22023';
    end if;

    -- `is distinct from` rather than `<>`: a missing `awarded` key has a NULL
    -- type, and NULL silently passes a plain inequality - the NULL mark would
    -- then be refused by the column with a raw NOT NULL error instead of this
    -- sentence.
    if jsonb_typeof(v_entry.mark) is distinct from 'object'
       or jsonb_typeof(v_entry.mark -> 'awarded') is distinct from 'number' then
      raise exception 'question % needs a numeric "awarded" mark',
        v_entry.question_id
        using errcode = '22023';
    end if;

    v_awarded := (v_entry.mark ->> 'awarded')::numeric;

    if v_awarded < 0 or v_awarded > v_points then
      raise exception 'marks for question % must be between 0 and %',
        v_entry.question_id, v_points
        using errcode = '22023';
    end if;

    insert into public.question_grades
      (submission_id, question_id, awarded, feedback, graded_by)
    values (
      p_submission_id,
      v_entry.question_id::uuid,
      v_awarded,
      -- Capped like `merge_submission_text_answer`: a feedback box must not be
      -- able to park an unbounded blob on a row a report will read. An empty box
      -- is stored as NULL rather than as "", so "no remark" has one shape.
      nullif(left(coalesce(v_entry.mark ->> 'feedback', ''), 2000), ''),
      auth.uid()
    )
    on conflict (submission_id, question_id) do update
      set awarded   = excluded.awarded,
          feedback  = excluded.feedback,
          graded_by = excluded.graded_by,
          graded_at = now();
  end loop;

  -- What the console reports back: how much of this paper is marked, and what the
  -- attempt is worth so far. Both are counted from the rows rather than from the
  -- request, so a caller that sent three marks learns the same numbers the
  -- attempt holds.
  select count(*) filter (where g.id is not null)
    into v_graded
  from public.questions q
  left join public.question_grades g
    on g.question_id = q.id and g.submission_id = p_submission_id
  where q.exam_id = v_exam
    and q.question_type = 'subjective';

  select count(*)
    into v_open
  from public.questions q
  where q.exam_id = v_exam
    and q.question_type = 'subjective'
    and not exists (
      select 1 from public.question_grades g
      where g.submission_id = p_submission_id and g.question_id = q.id
    );

  -- `score` is rewritten from scratch - automatic marks plus what was awarded -
  -- which is what makes a re-mark a correction, and why a partially marked
  -- attempt already carries a meaningful total. `guard_submission_immutability`
  -- allows this write to a closed row (score is exactly what a re-mark may
  -- change) while still refusing any change to `answers`.
  select public.auto_graded_score(p_submission_id)
       + coalesce(sum(g.awarded), 0)
    into v_score
  from public.question_grades g
  where g.submission_id = p_submission_id;

  update public.exam_submissions
  set score = v_score
  where id = p_submission_id;

  return query select v_score, v_graded, v_open;
end;
$$;

comment on function public.grade_submission(uuid, jsonb) is
  'Marks an attempt''s subjective answers (paper owner or admin only): upserts one question_grades row per answer and recomputes score as automatic + awarded. Idempotent.';

revoke execute on function public.grade_submission(uuid, jsonb) from public, anon;
grant execute on function public.grade_submission(uuid, jsonb) to authenticated, service_role;
