-- =====================================================================
-- MIGRATION: four-role accounts (public.user_role) + public.profiles
-- =====================================================================
-- Run ONCE, in the Supabase SQL editor, against a project that already has the
-- pre-change schema. `supabase/schema.sql` is the source of truth for a fresh
-- install and already contains everything below, so running this file on a
-- fresh project (or twice) is harmless: every step is guarded.
--
-- WHY
--   The account table knew two roles, 'student' and 'supervisor', as free text
--   behind a CHECK. There was nowhere to put the two roles the product now
--   needs: an `admin` (manages accounts, from the mobile admin dashboard) and a
--   `lecturer` (staff who write exams but are not invigilating). Text also meant
--   every new role needed the constraint rewritten, and a policy comparing a
--   string could not be type-checked.
--
-- WHAT IT DOES
--   1. creates the enum public.user_role = admin | lecturer | supervisor | student
--   2. renames public.users -> public.profiles, and its `name` -> `full_name`
--      (a row here is the profile of an auth.users account, and the old name
--      invited confusion with auth.users in queries)
--   3. converts `role` from text to public.user_role in place - no row is lost,
--      because 'student' and 'supervisor' are still valid labels
--   4. generalises is_supervisor() into is_staff() (admin|lecturer|supervisor)
--      and adds is_admin(); the old name stays as an alias so anything still
--      calling it keeps its behaviour
--   5. replaces the table's policies, adding the admin "manage every profile"
--      policy, and repoints the realtime publication at the new table name
--   6. makes guard_user_role_change() admin-only, while still letting the SQL
--      editor and the service_role key through (see the function for why)
--
-- AFTER RUNNING THIS, PROMOTE THE FIRST ADMIN. Nothing here does it for you: a
-- migration cannot know which account is yours, and no signed-in session is an
-- admin yet. From the SQL editor:
--
--   update public.profiles set role = 'admin' where email = 'you@example.com';
--   select id, role, full_name, email from public.profiles order by role, full_name;
--
-- That works from the SQL editor precisely because guard_user_role_change()
-- lets a session with no JWT through - otherwise the first admin could never be
-- created. After that, admins change roles through the mobile admin dashboard
-- (or the admin-create-user Edge Function) and the SQL editor is no longer
-- needed.
--
-- ROLLBACK is not scripted on purpose: the rename and the type change are
-- data-safe, but 'admin'/'lecturer' cannot be written back into the old
-- two-value CHECK. Renaming back (`alter table public.profiles rename to
-- users; alter table public.users rename column full_name to name;`) and
-- re-running the previous schema.sql restores the old shape for any data that
-- never used the new roles.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The enum
-- ---------------------------------------------------------------------
-- Postgres has no `create type if not exists`, hence the catalogue probe. Note
-- that the labels are added by CREATE TYPE rather than ALTER TYPE ... ADD VALUE:
-- a value added by ALTER in the same transaction cannot be used in it, and the
-- SQL editor sends this whole file as one transaction.
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

-- ---------------------------------------------------------------------
-- 2. users -> profiles, name -> full_name
-- ---------------------------------------------------------------------
-- A rename keeps the primary key, both foreign keys (exams.created_by,
-- exam_submissions.student_id), the RLS flag, the trigger and the realtime
-- publication attached: they all reference the table by OID, not by name.
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

-- ---------------------------------------------------------------------
-- 3. role: text -> public.user_role
-- ---------------------------------------------------------------------
-- The CHECK that spelled out ('student','supervisor') is dropped first: with
-- the enum in place the type *is* the constraint, and the old one would reject
-- 'admin'. `using role::text::public.user_role` is the explicit two-step cast
-- (text -> enum), so an unexpected value fails loudly here instead of being
-- silently coerced.
do $$
declare
  v_udt        text;
  v_constraint text;
begin
  if to_regclass('public.profiles') is null then
    return; -- fresh project: the CREATE TABLE below has not run yet
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
    raise notice 'dropped constraint % - the enum replaces it', v_constraint;
  end loop;

  alter table public.profiles alter column role drop default;
  alter table public.profiles
    alter column role type public.user_role using role::text::public.user_role;
  alter table public.profiles alter column role set default 'student';
end $$;

-- ---------------------------------------------------------------------
-- 4. The table (fresh installs only) and the role helpers
-- ---------------------------------------------------------------------
-- `create table if not exists` is the safety net for a project that never ran
-- schema.sql; after the rename above it is a no-op, and the IF NOT EXISTS means
-- the existing rows, defaults and constraints are left exactly as they are.
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  role        public.user_role not null default 'student',
  full_name   text not null,
  email       text not null unique,
  created_at  timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- security definer so a policy on `profiles` can ask about the caller's role
-- without re-entering the policies on `profiles` (which would recurse), and
-- `set search_path` so a hijacked path cannot swap the table underneath.
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

-- The name every pre-change policy and RPC calls. It keeps working, and keeps
-- meaning "the staff tier", so nothing that still calls it narrows or widens
-- its access when this migration lands. New code calls is_staff()/is_admin().
create or replace function public.is_supervisor()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select public.is_staff();
$$;

-- ---------------------------------------------------------------------
-- 5. Policies: the four-role set, including admin account management
-- ---------------------------------------------------------------------
-- Dropped by name rather than "drop every policy on profiles": the users_* names
-- are what the pre-rename table carries right now, and each one is recreated
-- below under the name the new schema.sql uses. Nothing is ever left with no
-- policy at all, because a table with RLS enabled and no policy returns no rows
-- to anyone (which would look like an outage rather than a security change).
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

-- Own row, or every row for staff. Unchanged in effect: is_staff() covers
-- 'supervisor' plus the two roles that did not exist before.
create policy "profiles_select_own_or_staff"
  on public.profiles for select
  to authenticated
  using (id = auth.uid() or public.is_staff());

-- Self-service signup may still only create a student row, whoever the caller
-- is: this is what stops a public signup from writing its own role.
create policy "profiles_insert_self_student"
  on public.profiles for insert
  to authenticated
  with check (id = auth.uid() and role = 'student');

-- Owners keep editing their own name; `role` is held by the trigger below.
create policy "profiles_update_self"
  on public.profiles for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- The new one: admins manage every profile (the mobile admin dashboard lists
-- accounts with this, and the admin-create-user Edge Function writes the row
-- for a new lecturer/supervisor through it). Deleting a row here does not delete
-- the auth account - use Supabase Auth's admin API for that.
create policy "profiles_admin_all"
  on public.profiles for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ---------------------------------------------------------------------
-- 6. Role changes become admin-only
-- ---------------------------------------------------------------------
-- Two exemptions keep a project bootstrappable and are worth reading twice:
--   * a session with no JWT at all (the SQL editor, a migration) - there would
--     otherwise be no way to appoint the first admin; and
--   * the service_role key, which is what an Edge Function holds: PostgREST
--     sets `request.jwt.claims` for API traffic, and the claim reads
--     'service_role' when that key signed the request.
-- A request from a signed-in user always has other claims, so it can only ever
-- take the is_admin() branch.
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
-- 7. Realtime
-- ---------------------------------------------------------------------
-- The rename kept the publication membership, but the dashboard subscribes by
-- table *name* (`postgres_changes` on `profiles`), so the entry has to exist
-- under the new one. The `exception` guard covers a project where the
-- supabase_realtime publication was never created.
do $$
begin
  begin
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and tablename = 'profiles'
    ) then
      alter publication supabase_realtime add table public.profiles;
    end if;
  exception when undefined_object then
    raise notice 'no supabase_realtime publication here - skipping (fine for a self-hosted setup)';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------
do $$
declare
  v_roles text;
  v_admins int;
begin
  select string_agg(e.enumlabel, ', ' order by e.enumsortorder)
    into v_roles
  from pg_enum e
  join pg_type t on t.oid = e.enumtypid
  join pg_namespace n on n.oid = t.typnamespace
  where n.nspname = 'public' and t.typname = 'user_role';

  select count(*) into v_admins from public.profiles where role = 'admin';

  raise notice 'public.user_role = %', coalesce(v_roles, '<missing>');
  raise notice '% account(s) hold the admin role', v_admins;

  if v_admins = 0 then
    raise notice 'No admin yet. Run: update public.profiles set role = ''admin'' where email = ''you@example.com'';';
  end if;
end $$;