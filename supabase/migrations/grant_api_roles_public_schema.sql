-- =====================================================================
-- MIGRATION: give the Data API its privileges on schema `public` back
-- =====================================================================
-- Run ONCE, in the Supabase SQL editor, against the deployed project.
-- Idempotent — `grant` and `alter default privileges` both are — so running
-- it twice, or on a project that never had the problem, changes nothing.
-- The same statements are in `supabase/schema.sql` §0, which is where a fresh
-- install picks them up.
--
-- WHY
--   PostgREST answers a request by connecting as `authenticator` and then
--   SET ROLE-ing to `anon` (no JWT) or `authenticated` (valid JWT). Row Level
--   Security is consulted *after* that, so the role needs the ordinary Postgres
--   privileges first: USAGE on the schema, then SELECT/INSERT/UPDATE/DELETE on
--   the object. A database whose `public` schema carries none of them answers
--   every request with
--
--     HTTP 401  {"code":"42501","message":"permission denied for schema public"}
--
--   which is not a policy hiding a row (that is HTTP 200 and an empty array)
--   but the statement being refused before row security runs. Both apps then
--   fail in a way that reads like an account problem: sign-in *succeeds*,
--   because GoTrue authenticates over its own `supabase_auth_admin` connection
--   and never touches `public`, and the first read after it fails — so the
--   supervisor console said "This account is not allowed to read its profile.
--   Ask an administrator to check your access." for every account, accounts
--   whose `profiles` row was there all along included. `seed.sql` was not the
--   fault either: its rows were written by the SQL editor as `postgres`, which
--   owns the schema and is not subject to these grants.
--
--   None of this widens what a caller can *see*. The policies stay the only
--   thing that decides rows: `profiles` still has exactly one SELECT policy and
--   it is `to authenticated` (`id = auth.uid() or public.is_staff()`), so the
--   `anon` role reads zero rows from it before and after. `service_role` is in
--   the list because it is what the Edge Functions use and what the platform's
--   own bootstrap grants; it is documented to bypass RLS.
--
-- WHAT IT DOES
--   1. USAGE on schema public for the API roles
--   2. all privileges on everything already in it: tables, views
--      (`questions_public` included — its `grant select ... to authenticated`
--      was powerless without the schema USAGE), sequences and functions
--   3. the matching ALTER DEFAULT PRIVILEGES, so an object created later
--      inherits the same grants instead of becoming unreachable the moment it
--      is created. `schema.sql` is re-runnable and re-creates functions and
--      policies on every run, so this is not hypothetical. Those defaults
--      apply to objects created by the role that runs this file (`postgres`
--      from the SQL editor), which is who creates them here; an object created
--      by a different role needs its own `alter default privileges ... for
--      role <that role>`.
--
-- AFTER RUNNING THIS, CHECK THE STAFF ROW ITSELF. The grants only unblock the
-- read; a staff login still needs a `profiles` row carrying a staff role:
--
--   select id, role, full_name, email from public.profiles order by role, full_name;
--   select id, email, email_confirmed_at from auth.users where email = 'supervisor@proctor.test';
--
-- An empty first result is a different fault with a different fix: the account
-- authenticates but has no profile. Nothing in either app can create a staff
-- row — `profiles_insert_self_student` only ever accepts role='student' from a
-- client — so it has to be inserted here, or through the `admin-create-user`
-- Edge Function, which is also the only way to invite a staff login.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The schema
-- ---------------------------------------------------------------------
grant usage on schema public to postgres, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. Everything already in it
-- ---------------------------------------------------------------------
grant all privileges on all tables    in schema public to postgres, anon, authenticated, service_role;
grant all privileges on all sequences in schema public to postgres, anon, authenticated, service_role;
grant all privileges on all functions in schema public to postgres, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. ... and everything created later
-- ---------------------------------------------------------------------
alter default privileges in schema public
  grant all privileges on tables to postgres, anon, authenticated, service_role;
alter default privileges in schema public
  grant all privileges on sequences to postgres, anon, authenticated, service_role;
alter default privileges in schema public
  grant all privileges on functions to postgres, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------
-- The probe that produced the 401 above needs no session at all: the anon key
-- is enough to prove the schema is reachable again, and it answers 200 `[]`
-- once the grants are in place.
--
--   curl -i "https://<project-ref>.supabase.co/rest/v1/profiles?select=id&limit=1" -H "apikey: <anon-key>" -H "Authorization: Bearer <anon-key>"
--
-- ...or, from PowerShell:
--
--   Invoke-WebRequest -Uri "https://<project-ref>.supabase.co/rest/v1/profiles?select=id&limit=1" -Headers @{ apikey = "<anon-key>"; Authorization = "Bearer <anon-key>" } | Select-Object StatusCode, Content
--
-- An empty array is the *correct* answer there: `anon` has no policy on
-- `profiles`, so zero rows is RLS doing its job, not a query being refused. A
-- staff session then reads its own row and the console signs in normally.

