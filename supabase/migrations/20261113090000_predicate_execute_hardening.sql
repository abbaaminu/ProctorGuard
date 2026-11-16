-- =====================================================================
-- PROCTORGUARD - THE NINE PREDICATES STOP BEING AN ANONYMOUS API
-- =====================================================================
-- Revokes EXECUTE on the predicates the policies are written in, and on the two
-- profile guards, from PUBLIC and `anon`, and leaves it with `authenticated` and
-- `service_role`.
--
-- WHY THIS FILE EXISTS
--   Section 0 of `supabase/schema.sql` grants `all privileges on all functions in
--   schema public` to `postgres, anon, authenticated, service_role`, and the same
--   ALTER DEFAULT PRIVILEGES for every function created after that. The grant is
--   deliberate: a row security policy is evaluated with the *caller's* privileges,
--   so `authenticated` has to be able to execute the helpers a policy calls - take
--   that away and every staff read answers `42501` instead of a row. But a blanket
--   grant also hands the anonymous key EXECUTE on every helper in the file, and for
--   the nine below that is a privilege nobody needs.
--
--   They are the *terms* the policies are written in, not an API. Every policy in
--   `supabase/schema.sql` is `to authenticated` (43 of them, and not one carries a
--   `TO public` or `TO anon` clause), so no anonymous request can reach a policy
--   that calls one of these and no anonymous read loses an answer when the grant
--   goes. What the grant did buy was a callable endpoint:
--   `POST /rest/v1/rpc/is_staff` with the anonymous key executed a SECURITY DEFINER
--   function that reads `profiles` on the caller's behalf. It answered `false`,
--   because `auth.uid()` is null when nothing is signed in - so this is not a leak
--   that was used, it is a surface that should not exist, and the smallest fix for
--   it is to take the EXECUTE bit away. The same argument covers the two guards: a
--   trigger function is invoked by the table's trigger and needs no EXECUTE from the
--   role that fires the statement, so `guard_user_role_change()` and
--   `guard_profile_labels()` were callable by `anon` for no reason at all.
--
-- WHY IT CANNOT BREAK THE ANONYMOUS KEEP-ALIVE
--   `.github/workflows/keep_alive.yml` pings `/rest/v1/profiles?select=id&limit=1`
--   with the anonymous key twice a day and treats any status but `200` as a failed
--   run. That read is answered by *row security*, and `anon` has no policy on
--   `profiles`, so it comes back `200 []`. No predicate is consulted on the way -
--   which is exactly why the audit behind this file had to be done before writing
--   it: a policy that applied to `anon` and called one of the nine would have turned
--   that empty list into a `42501`. There is no such policy. This file also revokes
--   no table privilege, and VERIFY fails if `anon` has lost SELECT on `profiles`,
--   because losing it would break the ping just as thoroughly.
--
-- WHAT CHANGES  (nine revokes, nine grants, nothing else)
--   1. The seven predicates the policies are written in: `is_staff()`,
--      `is_admin()`, `is_exam_supervisor()`, `is_supervisor_only()`,
--      `is_attempt_resetter()`, `owns_exam(uuid)` and `is_supervisor()`.
--   2. The two BEFORE triggers on `profiles`: `guard_user_role_change()` and
--      `guard_profile_labels()`. Revoking them changes nothing about a profile
--      write - the trigger still fires, as the table owner - and closes a question
--      ("may this role execute the guard?") whose answer was yes and should be no.
--
-- WHAT IT DOES NOT DO
--   * It does not revoke any table, view, sequence, schema or storage privilege.
--   * It does not create, drop or replace a policy, a view, a table or a function
--     body. Every object it names already exists; the only thing written is its ACL.
--   * It does not revoke anything from `authenticated` or `service_role`. Both keep
--     EXECUTE, which is what the policies need and what the admin Edge Functions
--     check roles with - VERIFY raises if either has lost it.
--   * It cannot make a *future* helper anon-proof. Section 0's ALTER DEFAULT
--     PRIVILEGES still grants EXECUTE on every function created after this file, so
--     a new predicate needs its own `revoke` beside its definition (and its line in
--     `supabase/tests/predicate_execute_check.sql`). This file fixes the nine that
--     exist; it is not a policy for the tenth.
--
-- PREREQUISITES
--   The nine functions, and the three roles `anon`, `authenticated` and
--   `service_role`. Section 0 checks all twelve before the first revoke, so a
--   project that predates one of them - `20261103090000_guard_profile_labels.sql`,
--   say - stops with one sentence naming what is missing, instead of failing half
--   way through section 1 with `42883`.
--
-- IT IS RE-RUNNABLE
--   `revoke` and `grant` are both idempotent, and `create or replace function`
--   preserves a function's ACL, so re-running this file (or a later re-run of
--   `schema.sql`) leaves the same bits set. A `drop function` followed by a create
--   would not: that starts again from the default ACL, which is why VERIFY checks
--   the grantee list rather than trusting that this file has ever been run.
-- =====================================================================


-- =====================================================================
-- 0. PREREQUISITES
-- =====================================================================
-- `revoke execute on function` answers 42883 on a project that never installed the
-- predicate, and it answers it on the first one - half way through section 1, with
-- the earlier revokes already applied inside the transaction. This block reads the
-- catalogue and says everything that is missing in one sentence. It writes nothing.
do $$
declare
  v_missing text;
begin
  if not exists (select 1 from pg_roles where rolname = 'anon')
     or not exists (select 1 from pg_roles where rolname = 'authenticated')
     or not exists (select 1 from pg_roles where rolname = 'service_role') then
    raise exception 'FAIL: this project has no anon/authenticated/service_role role - PostgREST cannot reach schema public at all (see section 0 of supabase/schema.sql)';
  end if;

  select string_agg(f.name, ', ' order by f.name) into v_missing
    from unnest(array[
      'public.is_staff()',
      'public.is_admin()',
      'public.is_exam_supervisor()',
      'public.is_supervisor_only()',
      'public.is_attempt_resetter()',
      'public.owns_exam(uuid)',
      'public.is_supervisor()',
      'public.guard_user_role_change()',
      'public.guard_profile_labels()'
    ]) as f(name)
   where to_regprocedure(f.name) is null;

  if v_missing is not null then
    raise exception 'FAIL: % % missing on this project, so there is no EXECUTE to revoke - apply the migration that installs % first',
      v_missing,
      case when position(',' in v_missing) > 0 then 'are' else 'is' end,
      case when position(',' in v_missing) > 0 then 'them' else 'it' end;
  end if;

  raise notice 'PASS: the nine predicates and the three roles are present';
end $$;


-- =====================================================================
-- 1. THE PREDICATES  -  authenticated and service_role, and nobody else
-- =====================================================================
-- One pair per function, in the order section 1 of `supabase/schema.sql` defines
-- them. `grant ... to authenticated, service_role` is written out even though both
-- already hold the privilege from section 0: the statement is the record of what
-- this file means the ACL to be, and it is what makes the file safe to run on a
-- project where an earlier hand-edit revoked one of them.

revoke execute on function public.is_staff() from public, anon;
grant execute on function public.is_staff() to authenticated, service_role;

revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated, service_role;

revoke execute on function public.is_exam_supervisor() from public, anon;
grant execute on function public.is_exam_supervisor() to authenticated, service_role;

revoke execute on function public.is_supervisor_only() from public, anon;
grant execute on function public.is_supervisor_only() to authenticated, service_role;

revoke execute on function public.is_attempt_resetter() from public, anon;
grant execute on function public.is_attempt_resetter() to authenticated, service_role;

revoke execute on function public.owns_exam(uuid) from public, anon;
grant execute on function public.owns_exam(uuid) to authenticated, service_role;

revoke execute on function public.is_supervisor() from public, anon;
grant execute on function public.is_supervisor() to authenticated, service_role;


-- =====================================================================
-- 2. THE TWO PROFILE GUARDS
-- =====================================================================
-- `guard_user_role_change()` and `guard_profile_labels()` are trigger functions on
-- `profiles`. Nobody - not `authenticated`, not `service_role` - calls them as
-- functions: the triggers fire them as the table owner, so the ACL decides nothing
-- about who may write a profile row. That is the point of revoking the anonymous
-- bit: the only thing a direct call could ever have produced is the error telling
-- the caller that a trigger function cannot be called directly, and the grant had
-- no business existing. `authenticated` and `service_role` keep EXECUTE so that the
-- ACL of the two guards matches the seven predicates above - one rule, nine lines,
-- no exception for a reviewer to remember.

revoke execute on function public.guard_user_role_change() from public, anon;
grant execute on function public.guard_user_role_change() to authenticated, service_role;

revoke execute on function public.guard_profile_labels() from public, anon;
grant execute on function public.guard_profile_labels() to authenticated, service_role;


-- =====================================================================
-- 3. VERIFY
-- =====================================================================
-- Reads the ACLs back instead of reporting success because the file ran. A revoke
-- that matched nothing is silent, and so is a project where somebody re-created a
-- predicate with `drop function` - that resets the ACL to the default, which grants
-- EXECUTE to PUBLIC again. Every failure below is one sentence naming the function
-- and saying what it means for the reader.
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
  v_name    text;
  v_oid     oid;
  v_public  boolean;
begin
  foreach v_name in array v_functions loop
    v_oid := to_regprocedure(v_name);
    if v_oid is null then
      raise exception 'FAIL: % does not exist on this project, so there is no EXECUTE to revoke - apply the migration that installs it first', v_name;
    end if;

    -- PUBLIC is grantee 0 in an aclitem. This is the check that notices a
    -- `drop function` + re-create, which would quietly restore the default grant
    -- that this file exists to remove.
    select exists (
      select 1
      from pg_proc p
      cross join lateral aclexplode(
        coalesce(p.proacl, acldefault('f', p.proowner))
      ) a
      where p.oid = v_oid
        and a.grantee = 0
        and a.privilege_type = 'EXECUTE'
    ) into v_public;

    if v_public then
      raise exception 'FAIL: % is still executable by PUBLIC - the default ACL is in place (was the function dropped and re-created after this file ran?)', v_name;
    end if;

    if has_function_privilege('anon', v_oid, 'EXECUTE') then
      raise exception 'FAIL: anon can still execute %', v_name;
    end if;

    if not has_function_privilege('authenticated', v_oid, 'EXECUTE') then
      raise exception 'FAIL: authenticated cannot execute % - every policy written in terms of it answers 42501 instead of a row, and the console reads nothing', v_name;
    end if;

    if not has_function_privilege('service_role', v_oid, 'EXECUTE') then
      raise exception 'FAIL: service_role cannot execute % - the admin Edge Functions check a caller''s role with it', v_name;
    end if;
  end loop;

  -- The keep-alive half. `anon` reaches `profiles` through row security, so it
  -- needs the ordinary SELECT privilege even though no policy gives it a row.
  -- Losing it answers `42501` to the ping in `.github/workflows/keep_alive.yml`
  -- instead of the empty list that proves the database is awake.
  if not has_schema_privilege('anon', 'public', 'USAGE') then
    raise exception 'FAIL: anon lost USAGE on schema public - every anonymous read answers 42501 now, the keep-alive ping included';
  end if;
  if not has_table_privilege('anon', 'public.profiles', 'SELECT') then
    raise exception 'FAIL: anon lost SELECT on public.profiles - the keep-alive ping needs a 200, and an empty list is not a permission error';
  end if;

  raise notice 'PASS: the nine predicates are executable by authenticated and service_role only, and anon still reads an empty profiles list';
end $$;

