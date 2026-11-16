-- =====================================================================
-- PREDICATE EXECUTE  -  run against a LOCAL `supabase start` database
-- =====================================================================
-- Run from the repo root with:
--
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres
--     -f supabase/tests/predicate_execute_check.sql
--
-- Prerequisites: `supabase start` is running, and `supabase db reset` has applied
-- `supabase/schema.sql` (which carries the nine `revoke execute ... from public,
-- anon` statements beside the predicates they harden) or
-- `supabase/migrations/20261113090000_predicate_execute_hardening.sql` on a project
-- that was installed before them.
--
-- WHAT IT PROVES
--   (a) `authenticated` still executes every predicate - and still gets the right
--       ANSWER from each. Four callers (admin, lecturer, supervisor, student) are
--       run through the seven in one go, because "the grant is back" and "the
--       predicate answers what it used to" are different failures: a revoked grant
--       raises 42501, while a body that drifted answers the wrong boolean for a
--       caller whose reads are now scoped by it.
--   (b) the policies that call them still return rows, which is the only path that
--       actually matters: a policy is evaluated with the *caller's* privileges, so
--       an administrator listing the roster proves `is_admin()` / `is_staff()` are
--       executable inside `profiles_select_own_or_staff`, and a student reading one
--       row proves the same for a caller who answers false.
--   (c) `service_role` - the key every Edge Function holds - still executes them.
--       The seven are called here; the two guards' bits are read in (d).
--       `admin-create-user` and `admin-update-profile` check roles with
--       `is_admin()`; a revoke that reached `service_role` would turn those into
--       42501 rather than a refusal with a reason.
--   (d) `anon` cannot execute any of them. The seven that can be called are called,
--       and each raises 42501; the two guards are trigger functions that cannot be
--       called directly at all (`0A000`), so their bit is read with
--       `has_function_privilege()` instead of by calling them. All nine are checked
--       that way as well, and for `authenticated` and `service_role`, so the ACL is
--       asserted rather than inferred from the calls.
--   (e) the anonymous keep-alive still works: `anon` holds SELECT on `profiles` and
--       reads zero rows - a `200 []`, not a `42501`. That is what
--       `.github/workflows/keep_alive.yml` pings for twice a day, and it is why the
--       hardening had to leave every table privilege alone.
--   (f) the two guards still fire as triggers, even though `anon` can no longer
--       execute them: a student's own `role` and `level` writes are refused with
--       42501, and an administrator's write to somebody else's `role` is allowed. The
--       revoke changed the ACL and nothing about the trigger.
--
-- HOW RLS IS APPLIED
--   Identical to `profile_labels_admin_check.sql`: `set local role authenticated`
--   plus a `request.jwt.claims` carrying the caller's uuid, then `reset role` and a
--   blank claims string before the next fixture write. The claims matter twice here:
--   they are what `auth.uid()` reads inside the predicates, and they are what makes
--   the two guards treat the caller as an ordinary account rather than as a
--   claims-less session (SQL editor, migration, fixture) that may write anything.
--
--   The whole file is wrapped in begin; ... rollback; - no data persists.
-- =====================================================================

begin;

-- Fixture helper: profiles.id references auth.users(id), which a plain insert
-- into public.profiles does not create. Rolled back with everything else.
create function public.tmp_fixture_auth_user() returns trigger
language plpgsql security definer set search_path = public as $f$
begin
  insert into auth.users (id, email) values (new.id, new.email) on conflict (id) do nothing;
  return new;
end $f$;
create trigger a_tmp_fixture_auth_user before insert on public.profiles
  for each row execute function public.tmp_fixture_auth_user();

-- Assertion helper: the seven predicates in one array, in the order the messages
-- name them. Created as postgres and run as the caller under test, so it is the
-- *caller's* EXECUTE bit that decides whether it can evaluate them - which is the
-- whole question this file asks. (A `security definer` helper would answer the
-- wrong question: it would test postgres's privileges.)
create function public.tmp_expect_predicates(p_expected boolean[], p_who text)
returns void
language plpgsql
set search_path = public
as $f$
declare
  v_actual boolean[] := array[
    public.is_staff(),
    public.is_admin(),
    public.is_exam_supervisor(),
    public.is_supervisor_only(),
    public.is_attempt_resetter(),
    public.owns_exam(current_setting('test.exam')::uuid),
    public.is_supervisor()
  ];
begin
  if v_actual is distinct from p_expected then
    raise exception 'FAIL (a): % answered % (is_staff, is_admin, is_exam_supervisor, is_supervisor_only, is_attempt_resetter, owns_exam, is_supervisor) - expected %',
      p_who, v_actual, p_expected;
  end if;
  raise notice 'PASS (a): % got % from the seven predicates', p_who, v_actual;
end $f$;
grant execute on function public.tmp_expect_predicates(boolean[], text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Fixtures (as postgres: no claims, RLS bypassed)
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := gen_random_uuid();
  v_lect  uuid := gen_random_uuid();
  v_sup   uuid := gen_random_uuid();
  v_stu   uuid := gen_random_uuid();
  v_exam  uuid := gen_random_uuid();  -- the paper v_lect wrote, for owns_exam()
begin
  insert into public.profiles (id, role, full_name, email)
    values
      (v_admin, 'admin',      'Admin',      'admin.pred@test.local'),
      (v_lect,  'lecturer',   'Lecturer',   'lecturer.pred@test.local'),
      (v_sup,   'supervisor', 'Supervisor', 'supervisor.pred@test.local'),
      (v_stu,   'student',    'Student',    'student.pred@test.local');

  insert into public.exams (id, title, created_by, duration_minutes, is_published)
    values (v_exam, 'Predicate ACL paper', v_lect, 60, true);

  perform set_config('test.admin', v_admin::text, false);
  perform set_config('test.lect',  v_lect::text,  false);
  perform set_config('test.sup',   v_sup::text,   false);
  perform set_config('test.stu',   v_stu::text,   false);
  perform set_config('test.exam',  v_exam::text,  false);
end $$;

-- =====================================================================
-- (a)  authenticated still executes them - and still gets the same answers
-- =====================================================================
-- The expected arrays are the seven predicates' bodies read back: is_staff() is
-- admin/lecturer/supervisor, is_admin() is admin only, is_exam_supervisor() is
-- admin or supervisor, is_supervisor_only() is supervisor exactly,
-- is_attempt_resetter() is admin/supervisor/lecturer, owns_exam() is
-- "exams.created_by = auth.uid()" (so only the lecturer, who wrote the fixture
-- paper), is_supervisor() delegates to is_staff().

set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "email": "admin.pred@test.local"}',
  current_setting('test.admin')), true);
select public.tmp_expect_predicates(
  array[true, true, true, false, true, false, true], 'an administrator');
reset role;
select set_config('request.jwt.claims', '', true);

set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "email": "lecturer.pred@test.local"}',
  current_setting('test.lect')), true);
select public.tmp_expect_predicates(
  array[true, false, false, false, true, true, true], 'a lecturer');
reset role;
select set_config('request.jwt.claims', '', true);

set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "email": "supervisor.pred@test.local"}',
  current_setting('test.sup')), true);
select public.tmp_expect_predicates(
  array[true, false, true, true, true, false, true], 'a supervisor');
reset role;
select set_config('request.jwt.claims', '', true);

set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "email": "student.pred@test.local"}',
  current_setting('test.stu')), true);
select public.tmp_expect_predicates(
  array[false, false, false, false, false, false, false], 'a student');
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (b)  the policies that call them still return rows
-- =====================================================================
-- (a) proved a direct call works. This proves the path the schema actually uses:
-- one arm of `profiles_select_own_or_staff` is `id = auth.uid()`, the second is
-- `is_admin()` and the third is `is_staff() and can_read_profile(id)`. An
-- administrator therefore sees all four fixture rows only if both predicates run,
-- and a student sees exactly one - their own - with `is_staff()` answering false
-- rather than raising.

set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "email": "admin.pred@test.local"}',
  current_setting('test.admin')), true);
do $$
declare
  v_seen integer;
begin
  select count(*) into v_seen
    from public.profiles
   where id in (current_setting('test.admin')::uuid,
                current_setting('test.lect')::uuid,
                current_setting('test.sup')::uuid,
                current_setting('test.stu')::uuid);
  if v_seen <> 4 then
    raise exception 'FAIL (b): an administrator read % of the 4 fixture rows through the roster policy', v_seen;
  end if;
  raise notice 'PASS (b): an administrator reads the roster through is_admin()/is_staff()';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "email": "student.pred@test.local"}',
  current_setting('test.stu')), true);
do $$
declare
  v_seen integer;
begin
  select count(*) into v_seen
    from public.profiles
   where id in (current_setting('test.admin')::uuid,
                current_setting('test.lect')::uuid,
                current_setting('test.sup')::uuid,
                current_setting('test.stu')::uuid);
  if v_seen <> 1 then
    raise exception 'FAIL (b): a student read % of the 4 fixture rows (expected their own only)', v_seen;
  end if;
  raise notice 'PASS (b): a student reads their own row and no other';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (c)  service_role - the Edge Function key - still executes all seven
-- =====================================================================
-- A `perform` is the assertion: if the grant were missing the statement would raise
-- 42501 before the notice printed.

set local role service_role;
do $$
begin
  perform public.is_staff();
  perform public.is_admin();
  perform public.is_exam_supervisor();
  perform public.is_supervisor_only();
  perform public.is_attempt_resetter();
  perform public.owns_exam(current_setting('test.exam')::uuid);
  perform public.is_supervisor();
  raise notice 'PASS (c): service_role executes the seven predicates';
end $$;
reset role;

-- =====================================================================
-- (d)  anon cannot execute any of the nine
-- =====================================================================
-- The ACL first, for all nine: the two guards are trigger functions and cannot be
-- called directly at all (`0A000` - "trigger functions can only be called as
-- triggers"), so `has_function_privilege()` is the only way to ask about their bit,
-- and asking it of `authenticated` and `service_role` in the same loop is what makes
-- this block fail if the revoke went one role too far.

set local role anon;
do $$
declare
  v_functions text[] := array[
    'public.is_staff()',
    'public.is_admin()',
    'public.is_exam_supervisor()',
    'public.is_supervisor_only()',
    'public.is_attempt_resetter()',
    'public.owns_exam(uuid)',
    'public.is_supervisor()',
    'public.guard_user_role_change()',
    'public.guard_profile_labels()'
  ];
  v_name text;
  v_oid  oid;
begin
  foreach v_name in array v_functions loop
    v_oid := to_regprocedure(v_name);
    if v_oid is null then
      raise exception 'FAIL (d): % does not exist - the ACL cannot be checked', v_name;
    end if;
    if has_function_privilege('anon', v_oid, 'EXECUTE') then
      raise exception 'FAIL (d): anon holds EXECUTE on %', v_name;
    end if;
    if not has_function_privilege('authenticated', v_oid, 'EXECUTE') then
      raise exception 'FAIL (d): authenticated lost EXECUTE on % - every policy written in terms of it answers 42501', v_name;
    end if;
    if not has_function_privilege('service_role', v_oid, 'EXECUTE') then
      raise exception 'FAIL (d): service_role lost EXECUTE on % - the admin Edge Functions check roles with it', v_name;
    end if;
  end loop;
  raise notice 'PASS (d): the nine are executable by authenticated and service_role, and by nobody else';
end $$;

-- Then the seven that can be called: each one has to be refused, with 42501.
do $$
declare
  v_calls text[] := array[
    'public.is_staff()',
    'public.is_admin()',
    'public.is_exam_supervisor()',
    'public.is_supervisor_only()',
    'public.is_attempt_resetter()',
    format('public.owns_exam(%L)', current_setting('test.exam')),
    'public.is_supervisor()'
  ];
  v_call text;
begin
  foreach v_call in array v_calls loop
    begin
      execute 'select ' || v_call;
      raise exception 'FAIL (d): anon executed %', v_call;
    exception
      when insufficient_privilege then
        raise notice 'PASS (d): anon cannot execute % (42501)', v_call;
    end;
  end loop;
end $$;

-- =====================================================================
-- (e)  the anonymous keep-alive still works
-- =====================================================================
-- The ping in `.github/workflows/keep_alive.yml` is
-- `/rest/v1/profiles?select=id&limit=1` with the anonymous key, and it treats
-- anything but `200` as a failed run - so `200 []` is the contract. It holds only
-- while `anon` keeps SELECT on the table and no policy offers it a row. The
-- hardening revoked function privileges only; this is the block that says so, asked
-- from the anonymous side.

do $$
declare
  v_seen integer;
begin
  if not has_table_privilege('anon', 'public.profiles', 'SELECT') then
    raise exception 'FAIL (e): anon lost SELECT on public.profiles - the keep-alive ping would answer 42501 instead of an empty list';
  end if;

  select count(*) into v_seen from public.profiles;
  if v_seen <> 0 then
    raise exception 'FAIL (e): anon read % profile rows - a policy that applies to anon came back', v_seen;
  end if;

  raise notice 'PASS (e): anon still reads profiles, and the answer is an empty list';
end $$;
reset role;

-- =====================================================================
-- (f)  the two guards still fire as triggers
-- =====================================================================
-- `anon` cannot execute them any more, and `authenticated` still can - but neither of
-- those is what a profile write uses. The triggers fire the functions as the table
-- owner, so the proof is a write: refused for the account itself, allowed for an
-- administrator, exactly as before the revoke.

set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "email": "student.pred@test.local"}',
  current_setting('test.stu')), true);
do $$
begin
  begin
    update public.profiles set role = 'admin'
     where id = current_setting('test.stu')::uuid;
    raise exception 'FAIL (f): a student promoted themselves';
  exception
    when insufficient_privilege then
      raise notice 'PASS (f): a student''s role change is still refused by guard_user_role_change() (42501)';
  end;

  begin
    update public.profiles set level = '400'
     where id = current_setting('test.stu')::uuid;
    raise exception 'FAIL (f): a student rewrote their own level';
  exception
    when insufficient_privilege then
      raise notice 'PASS (f): a student''s label change is still refused by guard_profile_labels() (42501)';
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "email": "admin.pred@test.local"}',
  current_setting('test.admin')), true);
do $$
declare
  v_rows integer;
begin
  update public.profiles set role = 'lecturer'
   where id = current_setting('test.stu')::uuid;
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then
    raise exception 'FAIL (f): an administrator''s role change touched % rows', v_rows;
  end if;
  raise notice 'PASS (f): an administrator moves a role, so the guard still allows what it allowed';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

do $$
begin
  raise notice 'ALL PREDICATE EXECUTE CHECKS PASSED.';
end $$;

rollback;



