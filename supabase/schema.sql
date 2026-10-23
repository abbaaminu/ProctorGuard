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
--     `questions`; they read the definer view `questions_public` (published
--     exams only, neither `correct_option` nor `correct_text_answer`) while
--     staff (`is_staff()`) read the raw table.
--   * Four question shapes share `questions`: `'multiple_choice'` (options + an
--     index), `'true_false'` (`correct_text_answer` is 'true' or 'false'),
--     `'fill_in_the_blank'` (`correct_text_answer`, graded case-insensitively
--     after trimming) and `'subjective'` (no answer key at all — an essay, marked
--     by hand). A choice answer is merged by `merge_submission_answer`; true/false
--     and fill-in-the-blank go through `merge_submission_text_answer`, which is
--     also what a true/false tap stores ('true' / 'false' as a JSON string).
--   * Students cannot grade or close themselves with a direct UPDATE — the
--     RPCs `submit_exam` (automatic grading) and `register_violation`
--     (3-strike rule) are the only writers of status/score/submitted_at, and
--     both re-check that the caller owns the submission. A subjective answer is
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
  level       text
);

-- The upgrade path for a project created before the academic metadata: the
-- `create table if not exists` above is a no-op there, so the columns are added
-- in place instead of being lost. `supabase/migrations/academic_targeting.sql`
-- carries the same statements, and the two files must be kept in step.
alter table public.profiles add column if not exists faculty    text;
alter table public.profiles add column if not exists department text;
alter table public.profiles add column if not exists level      text;

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
-- Every policy the reset rides on asks this one predicate
-- (`submissions_delete_supervisor`, the `Proctor snapshots supervisor purge`
-- storage policy, and `session_reset_logs_insert_supervisor`), so the tier is
-- named once and the audit trail cannot end up disagreeing with the delete it
-- records. `UserRole.canResetAttempts` in the Flutter app is the same list
-- asked on the client; `mobile/test/schema_contract_test.dart` reads this
-- sentence back out of the file and fails if the two drift apart.
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
-- those for the papers they wrote; the intervention tier
-- (`is_exam_supervisor()`) sees them for every paper.
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

-- Read: your own row, or every row when you are staff — the staff roster,
-- the admin console's account list and live exam monitor both render
-- other people's names and roles. Deliberately NOT "any authenticated user": a
-- student must not be able to enumerate the roster of the whole institution.
create policy "profiles_select_own_or_staff"
  on public.profiles for select
  to authenticated
  using (id = auth.uid() or public.is_staff());

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
  using (student_id = auth.uid() or public.is_staff());

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

-- Read: staff see every paper, published or not — an invigilator opens a sitting
-- in any department, and the console's monitor roster depends on it; the author
-- always sees their own drafts.
--
-- Students see a **published** paper only when it is aimed at them:
--   * every column the paper names must match their own `profiles` row, and a
--     NULL on either side means "not narrowed" — so an untargeted paper (all
--     three NULL, every paper that existed before targeting) stays visible to
--     everybody, and a student whose faculty was never recorded is not excluded
--     from their own department's papers;
--   * or they were explicitly allowed to borrow it (`exam_allowed_students`,
--     section 2b), which is how a service-course student sees a paper aimed at
--     another department.
--
-- The exception list is read through its own policies above, which let the
-- student see exactly the rows that name them, so this EXISTS needs no definer
-- helper and cannot recurse.
create policy "exams_select"
  on public.exams for select
  to authenticated
  using (
    public.is_staff()
    or created_by = auth.uid()
    or (
      is_published = true
      and (
        exists (
          select 1
          from public.profiles p
          where p.id = auth.uid()
            and (exams.faculty    is null or p.faculty is null
                 or lower(p.faculty)    = lower(exams.faculty))
            and (exams.department is null or p.department is null
                 or lower(p.department) = lower(exams.department))
            and (exams.level      is null or p.level is null
                 or p.level = exams.level)
        )
        or exists (
          select 1
          from public.exam_allowed_students a
          where a.exam_id = exams.id and a.student_id = auth.uid()
        )
      )
    )
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

-- Owner-scoped first, then staff-wide (the same shape as exams_select): staff
-- access to an exam's full question set is separate from the student-safe view.
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
  using (public.is_staff());

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

-- Student-safe view: strips both answer keys (`correct_option` and
-- `correct_text_answer`) so students never receive them, and returns published
-- exams only.
--
-- `security_invoker` is turned OFF on purpose. With invoker semantics the view
-- runs under the caller's own policies, which would require exactly the student
-- SELECT policy on `questions` that leaks the answer keys. As a definer view
-- owned by owner of the schema it reads the base table directly (RLS is not
-- applied to a table's owner) and exposes one fixed column set, filtered to
-- published exams.
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
  where e.is_published = true;

alter view public.questions_public set (security_invoker = false);

comment on view public.questions_public is
  'Student-facing question feed: published exams only, neither answer key.';

grant select on public.questions_public to authenticated;

-- ... and now take the reader the view was never meant for out of it.
--
-- That grant is not what keeps the public key away: §0's blanket
-- `grant all privileges on all tables` runs on *every* install of this file -
-- including a re-run over a database where this view already exists - and the
-- `alter default privileges` beside it re-applies the same privileges to
-- anything created later, so `anon` holds SELECT on this view (and on
-- `questions`, the table holding the answer keys) unless it is revoked here,
-- after both objects exist. A revoke, not a missing grant, is what makes the
-- reach deterministic no matter which order this file is applied in.
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
-- 4. EXAM SUBMISSIONS
-- ---------------------------------------------------------------------
create table if not exists public.exam_submissions (
  id            uuid primary key default uuid_generate_v4(),
  student_id    uuid not null references public.profiles(id) on delete cascade,
  exam_id       uuid not null references public.exams(id) on delete cascade,
  answers       jsonb not null default '{}'::jsonb,
  status        text not null default 'ongoing'
                check (status in ('ongoing','submitted','disqualified')),
  score         numeric,
  started_at    timestamptz not null default now(),
  submitted_at  timestamptz,
  unique (student_id, exam_id)
);

alter table public.exam_submissions enable row level security;

drop policy if exists "submissions_select_own_or_supervisor" on public.exam_submissions;
drop policy if exists "submissions_insert_own" on public.exam_submissions;
drop policy if exists "submissions_insert_own_ongoing" on public.exam_submissions;
drop policy if exists "submissions_update_own_ongoing" on public.exam_submissions;
drop policy if exists "submissions_update_supervisor" on public.exam_submissions;
drop policy if exists "submissions_delete_supervisor" on public.exam_submissions;

-- Read: your own attempt, or any attempt when you are a supervisor. The console
-- roster/audit and the mobile live monitor both need the wide read, and
-- `exams_select` already grants it for the exam rows themselves.
create policy "submissions_select_own_or_supervisor"
  on public.exam_submissions for select
  to authenticated
  using (student_id = auth.uid() or public.is_staff());

-- A start row can only ever be a fresh attempt: the student's own id, ongoing
-- status, empty answers, no score or submit time, and the database's start
-- timestamp on a published exam. Otherwise a client could preseed answers or
-- choose a future start time to bypass the server-enforced deadline.
--
-- The window is asked here too, and this is the *only* server-side check on it:
-- hiding a tile in the portal is courtesy, so a patched client gets no attempt
-- row before `starts_at` or after `ends_at`. Both bounds are optional, so both
-- tests are written as "NULL, or inside it" - an unscheduled paper (the common
-- case, and every paper authored before scheduling existed) passes unchanged.
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
    and exists (
      select 1 from public.exams e
      where e.id = exam_id
        and e.is_published = true
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
  using (public.is_exam_supervisor())
  with check (public.is_exam_supervisor());

-- Resetting one attempt (the staff app's "Reset attempt" control)
-- is a DELETE of this row: the score, the stored answers, the roster card and -
-- through the `on delete cascade` on proctoring_logs.submission_id - the
-- incident log are all cleared together. The child table needs no twin policy:
-- referential actions run outside row security, so this one policy is what lets
-- the evidence go with the attempt.
--
-- The reset tier - wider than the update policy above by exactly one role. It is
-- `is_attempt_resetter()` rather than `is_exam_supervisor()` for that reason: the
-- lecturer who wrote the paper can clear an attempt, and a student cannot.
-- Students are deliberately left out. A student who could delete their own row
-- would be able to erase a graded attempt - and the evidence behind a
-- disqualification - and then simply start the exam again.
create policy "submissions_delete_supervisor"
  on public.exam_submissions for delete
  to authenticated
  using (public.is_attempt_resetter());

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
-- are how a supervisor re-grades, and `status` may still move between the two
-- closed states ('submitted' <-> 'disqualified') so an after-the-fact
-- disqualification counts and a mistaken one can be undone. Reopening one
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

-- Read: your own attempt; the incident feed of *any* sitting for the
-- intervention tier; and - for the lecturer who wrote the paper - the incidents
-- recorded on their own exam.
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
        and (s.student_id = auth.uid() or public.owns_exam(s.exam_id))
    )
    or public.is_exam_supervisor()
  );

-- There is deliberately NO insert policy. `register_violation()` is the single
-- write path for evidence: it re-checks that the caller owns the submission,
-- inserts the row and applies the 3-strike rule in one transaction. Letting
-- clients insert here as well would give them a second, unguarded way to write
-- proctoring evidence (and to pad somebody's strike count).

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

-- Read: the student who owns the submission, or any member of staff. With the
-- bucket private this is not a convenience any more - it is the only thing that
-- lets anybody read a still at all, because Storage refuses both the object and
-- the signature without it (signing is a SELECT under the hood). Supervisor-wide
-- on purpose, to match submissions_select_own_or_supervisor.
create policy "Proctor snapshots read access"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'proctor-snapshots'
    and (
      exists (
        select 1 from public.exam_submissions s
        where s.id::text = (storage.foldername(name))[1]
          and s.student_id = auth.uid()
      )
      or public.is_staff()
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

-- No update policy: a stored snapshot is never rewritten.
--
-- Delete is one deliberate exception, and it exists for exactly one action - the
-- staff app's "Reset attempt". That action deletes the submission row first (the
-- DELETE that `submissions_delete_supervisor` authorizes, whose cascade takes
-- the log rows with it) and then has to drop the stills those rows pointed at: a
-- reset that left a student's images behind in Storage would not be a reset.
--
-- This policy is therefore necessarily broader than the two above - it cannot be
-- anchored to the submission folder, because by this point that folder no longer
-- resolves to a submission row. The reset tier is no wider than the delete
-- policy it serves (whoever `is_attempt_resetter()` names can already delete any
-- attempt, log rows included), and it is what keeps the console from leaving
-- orphaned blobs behind: deleting the `storage.objects` rows without the Storage
-- API would do precisely that.
create policy "Proctor snapshots supervisor purge"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'proctor-snapshots'
    and public.is_attempt_resetter()
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
  using (public.is_exam_supervisor() or public.owns_exam(exam_id));

-- Write: exactly the tier that may delete an attempt in the first place
-- (`is_attempt_resetter()` is what `submissions_delete_supervisor` and the
-- snapshot-purge policy use), and only in the caller's own name.
create policy "session_reset_logs_insert_supervisor"
  on public.session_reset_logs for insert
  to authenticated
  with check (public.is_attempt_resetter() and actor_id = auth.uid());

-- There is deliberately NO update policy and NO delete policy. A record its own
-- author can rewrite or remove is not a record; if one is ever wrong, the
-- correction is another row (or SQL by the project owner), never an edit.

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
  using (public.is_staff());

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
-- Server-side 3-strike escalation (RPC)
-- ---------------------------------------------------------------------
-- p_snapshot_url is optional, so a client that only knows the violation type
-- keeps working. Its value is the *object path* inside the private
-- `proctor-snapshots` bucket (section 6), not a URL - see the column comment on
-- `proctoring_logs.snapshot_url`. The 2-argument overload is dropped explicitly:
-- leaving it in
-- place would make `register_violation(uuid, text)` ambiguous ("function
-- register_violation(uuid, text) is not unique") now that a defaulted
-- 3-argument version exists.
drop function if exists public.register_violation(uuid, text);

-- The pre-offline-queue signature. Adding the two new *defaulted* parameters below
-- would otherwise leave two candidates for a 3-argument named call and Postgres
-- answers that with "function register_violation(...) is not unique", so the old
-- shape is dropped before the new one is created.
drop function if exists public.register_violation(uuid, text, text);

create or replace function public.register_violation(
  p_submission_id    uuid,
  p_action_type      text,
  p_snapshot_url     text default null,
  p_client_timestamp timestamptz default null,
  p_client_event_id  uuid default null
)
returns table(warning_count int, disqualified boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count  int;
  v_status text;
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

  -- Frames that arrive after the attempt closed (submitted, or already at
  -- strike 3) must not append more evidence or resurrect the session: report
  -- the final state instead of raising, so a late callback is harmless.
  if v_status <> 'ongoing' then
    select count(*) into v_count
    from public.proctoring_logs
    where submission_id = p_submission_id;
    return query select v_count, (v_status = 'disqualified');
    return;
  end if;

  -- `on conflict` + the unique index on client_event_id is what makes the
  -- client's offline retry safe: the same event replayed inserts nothing, and the
  -- strike count below is read from the table, so a retry can never turn one
  -- violation into two strikes. A client that reuses an id on purpose only
  -- suppresses its own strike - and a client that controls the app can skip
  -- calling this at all, so the idempotency key costs the rule nothing.
  insert into public.proctoring_logs (
    submission_id, action_type, snapshot_url, client_timestamp, client_event_id
  )
  values (
    p_submission_id,
    p_action_type,
    p_snapshot_url,
    coalesce(p_client_timestamp, now()),
    p_client_event_id
  )
  on conflict (client_event_id) where client_event_id is not null do nothing;

  select count(*) into v_count
  from public.proctoring_logs
  where submission_id = p_submission_id;

  if v_count >= 3 then
    update public.exam_submissions
    set status = 'disqualified', submitted_at = now(), score = null
    where id = p_submission_id and status = 'ongoing';
    return query select v_count, true;
  else
    return query select v_count, false;
  end if;
end;
$$;
revoke execute on function public.register_violation(uuid, text, text, timestamptz, uuid) from public, anon;
grant execute on function public.register_violation(uuid, text, text, timestamptz, uuid) to authenticated, service_role;

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

  if v_student <> auth.uid() and not public.is_exam_supervisor() then
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
