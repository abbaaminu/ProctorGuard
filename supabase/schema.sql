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
--   * Two question shapes share `questions`: `question_type = 'multiple_choice'`
--     (options + index) and `'fill_in_the_blank'` (`correct_text_answer`, graded
--     case-insensitively after trimming). Answers are merged by
--     `merge_submission_answer` (choice) or `merge_submission_text_answer`
--     (text).
--   * Students cannot grade or close themselves with a direct UPDATE — the
--     RPCs `submit_exam` (grading, both shapes) and `register_violation`
--     (3-strike rule) are the only writers of status/score/submitted_at, and
--     both re-check that the caller owns the submission.
--   * Evidence is append-only for clients: `proctoring_logs` has no INSERT
--     policy, so register_violation() is the single write path. That RPC is
--     idempotent per `client_event_id`, which is what lets the app queue a
--     violation it could not deliver and replay it later without inventing a
--     second strike (see `client_timestamp` / `client_event_id` in section 5).
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
  created_at  timestamptz not null default now()
);

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
create table if not exists public.exams (
  id               uuid primary key default uuid_generate_v4(),
  title            text not null,
  created_by       uuid not null references public.profiles(id) on delete cascade,
  duration_minutes int not null check (duration_minutes > 0),
  is_published     boolean not null default false,
  created_at       timestamptz not null default now()
);

alter table public.exams enable row level security;

drop policy if exists "exams_select" on public.exams;
drop policy if exists "exams_insert_supervisor_only" on public.exams;
drop policy if exists "exams_update_owner" on public.exams;
drop policy if exists "exams_delete_owner" on public.exams;

create policy "exams_select"
  on public.exams for select
  to authenticated
  using (
    is_published = true
    or created_by = auth.uid()
    or public.is_staff()
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
  -- Two question shapes share this table:
  --   'multiple_choice'   -> `options` are the tap targets, `correct_option` the index
  --   'fill_in_the_blank' -> `options` is empty, `correct_text_answer` is graded
  --                          case-insensitively after trimming
  question_type       text not null default 'multiple_choice'
                        check (question_type in ('multiple_choice', 'fill_in_the_blank')),
  options             jsonb not null default '[]'::jsonb,
  correct_option      int,
  correct_text_answer text,
  points              numeric not null default 1,
  created_at          timestamptz not null default now(),
  -- Exactly one answer key, matching the question's type. Without this a row
  -- could carry both (graded twice by submit_exam) or neither (ungradeable).
  constraint questions_answer_key_shape check (
    (question_type = 'multiple_choice' and correct_option is not null)
    or
    (question_type = 'fill_in_the_blank'
      and coalesce(btrim(correct_text_answer), '') <> '')
  )
);

-- Migration for databases created before question types existed (`create table
-- if not exists` above is a no-op there). Every statement is idempotent.
alter table public.questions add column if not exists question_type text not null default 'multiple_choice';
alter table public.questions add column if not exists correct_text_answer text;
alter table public.questions alter column options set default '[]'::jsonb;
-- A fill-in-the-blank row has no option index, so this column cannot stay NOT NULL.
alter table public.questions alter column correct_option drop not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'questions_question_type_check') then
    alter table public.questions
      add constraint questions_question_type_check
      check (question_type in ('multiple_choice', 'fill_in_the_blank'));
  end if;

  if not exists (select 1 from pg_constraint where conname = 'questions_answer_key_shape') then
    alter table public.questions
      add constraint questions_answer_key_shape
      check (
        (question_type = 'multiple_choice' and correct_option is not null)
        or
        (question_type = 'fill_in_the_blank'
          and coalesce(btrim(correct_text_answer), '') <> '')
      );
  end if;
end $$;

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
      where e.id = exam_id and e.is_published = true
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
-- Same audience as the update policy above: admins and supervisors.
-- Students are deliberately left out. A student who could delete their own row
-- would be able to erase a graded attempt - and the evidence behind a
-- disqualification - and then simply start the exam again.
create policy "submissions_delete_supervisor"
  on public.exam_submissions for delete
  to authenticated
  using (public.is_exam_supervisor());

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

create policy "logs_select_own_or_supervisor"
  on public.proctoring_logs for select
  to authenticated
  using (
    exists (
      select 1 from public.exam_submissions s
      where s.id = submission_id and s.student_id = auth.uid()
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
-- The bucket is public so the supervisor app can render the snapshot URL;
-- anyone holding a URL can fetch that snapshot, so treat it as
-- unguessable rather than secret. The policies below still scope uploads to
-- the owning student. Everything here is idempotent - safe to re-run.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('proctor-snapshots', 'proctor-snapshots', true, 5242880, array['image/jpeg', 'image/png'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Proctor snapshots read access" on storage.objects;
drop policy if exists "Proctor snapshots upload access" on storage.objects;
drop policy if exists "Proctor snapshots upload own ongoing session" on storage.objects;
drop policy if exists "Proctor snapshots supervisor purge" on storage.objects;

-- Read: the student who owns the submission, or any supervisor (public buckets
-- already serve /object/public/... without a policy; this covers list()/download()
-- through the SDKs). Supervisor-wide on purpose, to match
-- submissions_select_own_or_supervisor.
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
-- reset that left a student's images in a public bucket would not be a reset.
--
-- This policy is therefore necessarily broader than the two above - it cannot be
-- anchored to the submission folder, because by this point that folder no longer
-- resolves to a submission row. Supervisor-only is no wider than the delete
-- policy it serves (a supervisor can already delete any attempt, log rows
-- included), and it is what keeps the console from leaving orphaned blobs
-- behind: deleting the `storage.objects` rows without the Storage API would do
-- precisely that.
create policy "Proctor snapshots supervisor purge"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'proctor-snapshots'
    and public.is_exam_supervisor()
  );

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
-- keeps working. The 2-argument overload is dropped explicitly: leaving it in
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
        and clock_timestamp() < s.started_at
          + make_interval(mins => e.duration_minutes)
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
  v_submitted_at timestamptz;
  v_score   numeric;
begin
  if auth.uid() is null then
    raise exception 'authentication is required to submit an exam'
      using errcode = '42501';
  end if;

  select s.student_id, s.exam_id, s.status, s.started_at, e.duration_minutes
    into v_student, v_exam, v_status, v_started_at, v_duration_minutes
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
  -- deadline. Record the deadline as the effective submit time for late closes.
  v_submitted_at := least(
    clock_timestamp(),
    v_started_at + make_interval(mins => v_duration_minutes)
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
  -- right, and it has to cover both question shapes:
  --   * multiple choice: the stored jsonb number equals `correct_option`
  --   * fill in the blank: the stored jsonb string matches `correct_text_answer`
  --     case-insensitively after trimming, so "  http " counts for "HTTP"
  -- An unanswered question stores nothing, so `->>` is NULL and the comparison
  -- is NULL (never true) - it simply does not score.
  select coalesce(sum(q.points), 0)
    into v_score
  from public.questions q
  join public.exam_submissions s on s.id = p_submission_id
  where q.exam_id = v_exam
    and (
      (
        q.question_type = 'multiple_choice'
        and s.answers -> q.id::text = to_jsonb(q.correct_option)
      )
      or
      (
        q.question_type = 'fill_in_the_blank'
        and coalesce(btrim(q.correct_text_answer), '') <> ''
        and lower(btrim(s.answers ->> q.id::text)) =
            lower(btrim(q.correct_text_answer))
      )
    );

  update public.exam_submissions
  set status = 'submitted', submitted_at = v_submitted_at, score = v_score
  where id = p_submission_id;

  return query select 'submitted'::text, v_score;
end;
$$;

comment on function public.submit_exam(uuid, boolean) is
  'Closes and grades a student''s own attempt; late answer writes are rejected and an expired attempt is graded from saved answers. Idempotent.';

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
        and clock_timestamp() < s.started_at
          + make_interval(mins => e.duration_minutes)
    );

  if not found then
    raise exception 'submission is not active or its exam deadline has passed'
      using errcode = '55000';
  end if;
end;
$$;
revoke execute on function public.merge_submission_text_answer(uuid, uuid, text) from public, anon;
grant execute on function public.merge_submission_text_answer(uuid, uuid, text) to authenticated, service_role;