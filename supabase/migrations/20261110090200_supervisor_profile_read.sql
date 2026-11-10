-- =====================================================================
-- PROCTORGUARD - THE SUPERVISOR'S ROSTER READ, RE-INSTALLED
-- Re-creates `public.can_read_profile(uuid)` and the `profiles_select_own_or_staff`
-- policy on a project whose `20261109090000_supervisor_exam_assignments.sql` was
-- applied *before* the roster read was scoped, so a supervisor stops reading every
-- profile row in the institution.
--
-- WHY THIS FILE EXISTS
--   `7c7f286` narrowed every supervisor policy except one: the profiles read was
--   left at `id = auth.uid() or public.is_staff()`, so a supervisor still read
--   **every** profile row - full name, matriculation number, staff id, faculty,
--   department, level, photograph - assigned or not, sitting or not. `8e193ae`
--   closed that by adding `can_read_profile()` and re-writing the policy, but it
--   added them *to the migration that had already been applied*. Its VERIFY block
--   only runs when the file is run, so a project that ran `20261109090000` before
--   that commit was left with
--
--     * no `public.can_read_profile(uuid)` at all, and
--     * `profiles_select_own_or_staff` still `id = auth.uid() or is_staff()`,
--
--   and nothing told it so. `supabase/tests/supervisor_scope_check.sql` block (k)
--   is the check that catches it: every other read in that file is scoped by
--   `can_supervise_exam()`, so (a)-(j) pass, and then (k)v fails - "the supervisor
--   read a student on a paper they do not run" - because `is_staff()` answers for
--   them on every row of the table.
--
--   A file that has already been applied cannot fix a project that has already
--   applied it. This one is the upgrade path instead: the same function and the
--   same policy, in a file no project can have run yet.
--
-- WHAT CHANGES
--   1. `public.can_read_profile(uuid)` - created (or replaced) as its owner
--      (`security definer`, `stable`, pinned `search_path`), so the predicate can
--      read `exam_submissions`, `exam_allowed_students`, `exams` and
--      `supervisor_exam_assignments` on behalf of a caller who may read none of
--      them. It answers true for a student who
--        * has an attempt on a paper the caller is assigned to (the monitor's
--          roster - the only place a supervisor strictly needs a name);
--        * is on one of those papers' `exam_allowed_students` borrow list;
--        * is aimed at by a **labelled** assigned paper (faculty/department/level,
--          read with the same blank-label rule as `student_can_access_exam()`).
--      A paper that names no cohort is offered to everybody, so "aimed at" would
--      have meant "every student in the institution"; the cohort branch therefore
--      requires the paper to name something, and an untargeted paper reaches its
--      audience through the first two answers - which is what a console can render.
--   2. `profiles_select_own_or_staff` - dropped by name and re-created with the
--      supervisor arm asking `can_read_profile(id)`. An administrator and a
--      lecturer are not `is_supervisor_only()`, so their `is_staff()` roster read -
--      the admin console's account list, the marking queue's `_namesFor()` - is the
--      same sentence it always was.
--   3. The legacy read policy names are dropped: the `users_*` ones a pre-rename
--      project still carries, "Allow users to read own profile and staff to read all
--      users", which no revision of `supabase/schema.sql` ever created, and anything
--      else on the table that says the same thing under a name of its own. A leftover
--      permissive read policy is read as a *union* with the one above: it would leave
--      the roster just as wide, and nothing about the new policy would show it. So the
--      table is swept by **predicate**, not by label: a read policy that asks
--      `is_staff()` without `can_read_profile()` *is* the un-narrowed roster read
--      whatever it is called - the live project's is "Allow users to read own profile
--      and staff to read all", one word short of the name above, which is how a
--      by-name drop walked past it - and it is printed with its definition before it
--      goes. A read policy that is only `(auth.uid() = id)` is dropped as a duplicate
--      of the policy's own first arm. Anything the sweep cannot recognise stops the
--      file, named with its predicate, instead of being unioned with in silence.
--      (Same names, same reason, as `supabase/schema.sql` section 1.)
--
--   4. Two things a project can be missing without any policy looking wrong: row level
--      security itself (`alter table … enable`, a no-op where it is already on), and
--      `profiles_admin_all` asking `is_admin()`. A project whose table was created by
--      hand or by an early revision may have the first off, and a project whose copy of
--      the second asks `is_staff()` reads wide through the administrator's arm - both
--      hand the whole roster back to a supervisor whatever `profiles_select_own_or_staff`
--      says.
--
-- WHAT IT DOES NOT DO
--   * No change to `is_supervisor_only()`, `can_supervise_exam()`,
--     `student_can_access_exam()`, `is_staff()` or `supervisor_exam_assignments` -
--     the paper scope is `20261109090000`'s, and this file only answers the one
--     question that file left at the tier.
--   * No new table, column, grant or RPC, and no row is read or rewritten: two
--     definitions, an `enable` a project built from `schema.sql` already has, and a
--     hand-drop of names that should not be there.
--   * It does not narrow anybody but a supervisor. A student still reads their own
--     row (`id = auth.uid()`), which is what sign-in reads.
--   * It is not a backfill: an assignment made before this file runs keeps working,
--     because the predicate reads the table as it is.
--
-- PREREQUISITES
--   * `public.supervisor_exam_assignments`, `public.is_supervisor_only()`,
--     `public.is_staff()` and `public.profiles` - i.e.
--     `20261109090000_supervisor_exam_assignments.sql` (the VERIFY block below
--     raises by name if one of them is missing).
--   * Order: after `20261109090000`. Before or after
--     `20261110090100_snapshot_orphan_check.sql` does not matter - neither file
--     touches the other's objects, and nothing here re-creates a snapshot policy,
--     so this file does **not** have to be followed by a re-apply of `20261110090100`.
--
-- HOW TO APPLY
--   SQL Editor (paste the whole file, Run), or through the CLI:
--     supabase db query --linked -f supabase/migrations/20261110090200_supervisor_profile_read.sql
--   Then `supabase/tests/supervisor_scope_check.sql` block (k) passes.
--
-- VERIFY (by hand, before and after - the block at the end of this file raises if
-- the result is wrong, so this is for reading, not for passing):
--     -- 1. the helper: missing on a project that ran 20261109090000 before 8e193ae
--     select proname from pg_proc
--      where pronamespace = 'public'::regnamespace and proname = 'can_read_profile';
--     -- 2. the policy: must ask can_read_profile, not just is_staff()
--     select policyname, qual from pg_policies
--      where schemaname = 'public' and tablename = 'profiles' and cmd = 'SELECT';
--     -- 3. no leftover read policy a pre-rename project still carries
--     select policyname from pg_policies
--      where schemaname = 'public' and tablename = 'profiles'
--        and policyname in ('users_select_own_or_supervisor',
--                           'Users can view own profile',
--                           'Authenticated users can read profiles');
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. THE PREDICATE
-- ---------------------------------------------------------------------
-- "May this supervisor read *this person's* profile row?" - the per-person twin of
-- `can_supervise_exam()`. Character for character the function in
-- `supabase/schema.sql` section 1 and in `20261109090000` section 2; the three
-- copies are pinned against each other by
-- `mobile/test/schema_contract_test.dart`.
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

-- ---------------------------------------------------------------------
-- 2. THE POLICY
-- ---------------------------------------------------------------------
-- RLS first: without it the table is read as if no policy existed, and a project whose
-- `profiles` table was created by hand - or by an early revision of `schema.sql` that
-- ran before the `alter table` below - has every policy in this file consulted by
-- nobody. `enable` is a no-op on a project that already has it, so this is safe on both.
alter table public.profiles enable row level security;

-- The verdict set drops a policy by name and re-creates it; so does this. The
-- `users_*` names are the pre-rename ones, and "Allow users to read own profile and
-- staff to read all users" is a name no revision of `supabase/schema.sql` ever used:
-- a hand-made policy from the dashboard, carrying the same
-- `id = auth.uid() or is_staff()` the roster read used to be. A project built from a
-- file older than the rename still carries whichever of them it has, and a second
-- permissive SELECT policy is a union with this one: it would keep the roster exactly
-- as wide as it was, and the new predicate would never be asked.
--
-- The names below are dropped blindly, because a project that has one must lose it
-- whatever state it is in - but they are not enough, and the live run of this file is
-- the proof: the hand-made policy there is called
-- "Allow users to read own profile and staff to read all", one word short of the name
-- above, so the by-name drop walked straight past it and the verify block stopped the
-- file. The sweep after them is what actually clears the table, and it reads
-- predicates rather than labels.
drop policy if exists "Allow users to read own profile and staff to read all users" on public.profiles;
drop policy if exists "users_select_own_or_supervisor" on public.profiles;
drop policy if exists "Users can view own profile" on public.profiles;
drop policy if exists "Users can read own profile" on public.profiles;
drop policy if exists "Authenticated users can read profiles" on public.profiles;
drop policy if exists "profiles_select_own_or_staff" on public.profiles;

-- Everything else on the table, judged by its predicate.
--
--   * `(auth.uid() = id)` and nothing else is the account's own row, which
--     `profiles_select_own_or_staff` already grants: a duplicate of one arm of it,
--     dropped so the table carries one read policy instead of two that say the same
--     thing.
--   * A predicate that asks `is_staff()` and *not* `can_read_profile()` **is** the
--     un-narrowed roster read, under whatever label it was given. That is the
--     hand-made policy on the live project, and the reason block (k)v of
--     `supabase/tests/supervisor_scope_check.sql` stayed red after every other check
--     passed. It goes, and its definition is printed first: the operator is entitled
--     to see what left the table.
--   * `using (true)` is the dashboard's default "Enable read access for all users" -
--     a read of every row by every caller, which no revision of `schema.sql` ever had
--     on this table. It goes too.
--   * A read policy that *does* mention `can_read_profile()` but under a name of its
--     own is somebody's half-fix: the policy created below says the same thing in the
--     shape `schema.sql` and `20261109090000` agree on, and two read policies where
--     one will do is how the roster went wide in the first place. It goes too.
--   * Anything else is not a shape this file can read, so it is *not* dropped: it is
--     named with its predicate and the file stops. A policy somebody wrote on purpose
--     is theirs to decide about, and the message is where to decide it.
--
-- The own-row, `true` and `can_read_profile()` cases are taken only on a SELECT policy:
-- the same predicate on an `ALL` policy is somebody's write path, and deleting a write
-- policy is not this file's job. The `is_staff()` case is dropped whatever its `cmd`,
-- because a `FOR ALL` there is the roster read *and* a staff-wide write; its notice says
-- that its write half went with it, and `profiles_admin_all` below plus the self-update
-- policies are the write path.
do $$
declare
  r        record;
  v_squash text;
  v_left   text := '';
begin
  for r in
    select policyname, cmd, coalesce(qual, 'true') as qual
    from pg_policies
    where schemaname = 'public'
      and tablename = 'profiles'
      and cmd in ('SELECT', 'ALL')
      and policyname not in ('profiles_select_own_or_staff', 'profiles_admin_all')
    order by policyname
  loop
    -- Parentheses and layout carry no meaning in a predicate comparison, so
    -- `(auth.uid() = id)`, `id = auth.uid()` and `((auth.uid() = id))` read the same.
    v_squash := lower(regexp_replace(r.qual, '[\s()]', '', 'g'));

    if v_squash in ('id=auth.uid', 'auth.uid=id') and r.cmd = 'SELECT' then
      execute format('drop policy %I on public.profiles', r.policyname);
      raise notice 'dropping a duplicate own-row profiles read policy (%): profiles_select_own_or_staff already grants id = auth.uid()', r.policyname;
    elsif v_squash = 'true' and r.cmd = 'SELECT' then
      execute format('drop policy %I on public.profiles', r.policyname);
      raise notice 'dropping a read-everything profiles policy (%): every caller read every row, and the narrowed roster read replaces it', r.policyname;
    elsif v_squash like '%is_staff%' and v_squash not like '%can_read_profile%' then
      execute format('drop policy %I on public.profiles', r.policyname);
      raise notice 'dropping a hand-made profiles read policy (% [%] using %)%. profiles_select_own_or_staff replaces it',
        r.policyname, r.cmd, r.qual,
        case when r.cmd = 'SELECT' then ''
             else ' Its write half goes with it: profiles_admin_all below and the self-update policies are the write path' end;
    elsif v_squash like '%can_read_profile%' and r.cmd = 'SELECT' then
      -- A half-fix: somebody edited the policy in place and did mention the narrow
      -- read, but under a name of their own, so the canonical policy below would be a
      -- second read policy beside it. Whatever it says, the one created next says the
      -- same thing in the shape `schema.sql` and the scope file agree on.
      execute format('drop policy %I on public.profiles', r.policyname);
      raise notice 'dropping a hand-modified profiles read policy (% using %) in favour of profiles_select_own_or_staff', r.policyname, r.qual;
    else
      v_left := v_left || format('%s [%s] using %s; ', r.policyname, r.cmd, r.qual);
    end if;
  end loop;

  if v_left <> '' then
    raise exception 'FAIL: public.profiles has another read policy (%): drop it by hand - it is neither the account''s own row nor an is_staff() roster read this file can recognise', rtrim(v_left);
  end if;
end $$;

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

-- The administrator's read is `is_admin()`, never `is_staff()`. A project whose copy of
-- this policy asks `is_staff()` matches every account of the intervention tier - a
-- supervisor included - so it is a second permissive read policy and the narrowing
-- above never applies. Re-created to the shape `supabase/schema.sql` has (`for all`,
-- admins only), so the roster read is the only thing a supervisor can match.
drop policy if exists "profiles_admin_all" on public.profiles;
create policy "profiles_admin_all"
  on public.profiles for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ---------------------------------------------------------------------
-- 3. VERIFY
-- ---------------------------------------------------------------------
-- Raises rather than reporting success on a project where the roster read did not
-- land. Every statement above is a `create or replace`, a `drop` + `create` or an
-- `enable`, so a half-applied file - or one run against a project that is missing the
-- assignment table - would otherwise look clean, and the leak it leaves behind is
-- silent: a supervisor reading every matriculation number in the institution.
do $$
declare
  v_src        text;
  v_qual       text;
  v_extra      text;
  v_admin_qual text;
  v_admin_src  text;
  v_roles      text;
begin
  -- The three objects the predicate is written against. Naming them here is what
  -- turns "wrong order" into one red sentence instead of a 42P01 in the middle of
  -- the file.
  if to_regclass('public.supervisor_exam_assignments') is null then
    raise exception 'FAIL: public.supervisor_exam_assignments is missing - apply 20261109090000_supervisor_exam_assignments.sql first';
  end if;
  if to_regprocedure('public.is_supervisor_only()') is null then
    raise exception 'FAIL: is_supervisor_only() is missing - apply 20261109090000_supervisor_exam_assignments.sql first';
  end if;
  if to_regprocedure('public.is_staff()') is null then
    raise exception 'FAIL: is_staff() is missing - the profiles read policy cannot be rebuilt without it';
  end if;

  -- A policy nobody consults is not a narrowing: with RLS off, the table reads as if
  -- every policy were `using (true)`, and the supervisor roster is as wide as it ever
  -- was. The `alter table … enable` above is what makes the rest of this matter.
  if not coalesce(
    (select c.relrowsecurity from pg_class c where c.oid = 'public.profiles'::regclass),
    false
  ) then
    raise exception 'FAIL: row level security is off on public.profiles - no policy on it is consulted, and every row is readable by everybody';
  end if;

  -- The role predicate the narrowed read is written in terms of. A body that does not
  -- name the role it is meant to test answers for somebody else, and the policy above
  -- becomes a formality: `not is_supervisor_only()` would be true for the supervisor
  -- too, and `can_read_profile()` would never be asked.
  select p.prosrc into v_roles
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = 'is_supervisor_only'
    and p.pronargs = 0;

  if v_roles is not null and v_roles not like '%supervisor%' then
    raise exception 'FAIL: is_supervisor_only() does not test for the supervisor role - the read above would skip can_read_profile() for the very tier it is written for';
  end if;

  -- `is_admin()` likewise: `profiles_admin_all` is rebuilt as `is_admin()`, so a body
  -- that answers for the whole staff tier instead would put every row back in range -
  -- for a supervisor, through the administrator's arm.
  select p.prosrc into v_admin_src
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = 'is_admin'
    and p.pronargs = 0;

  if v_admin_src is null then
    raise exception 'FAIL: is_admin() is missing - profiles_admin_all is written in terms of it';
  end if;
  if v_admin_src not like '%''admin''%' then
    raise exception 'FAIL: is_admin() does not test for the admin role - profiles_admin_all would match a supervisor';
  end if;

  select p.prosrc into v_src
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = 'can_read_profile'
    and p.pronargs = 1;

  if v_src is null then
    raise exception 'FAIL: public.can_read_profile(uuid) does not exist';
  end if;

  -- The three answers, and the cohort guard that keeps an untargeted paper from
  -- standing in for "everybody in the institution".
  if v_src not like '%public.exam_submissions%' then
    raise exception 'FAIL: can_read_profile() lost the sitting arm';
  end if;
  if v_src not like '%public.exam_allowed_students%' then
    raise exception 'FAIL: can_read_profile() lost the borrow-list arm';
  end if;
  if v_src not like '%or nullif(btrim(e.level), '''') is not null%' then
    raise exception 'FAIL: can_read_profile() lost the cohort guard - an untargeted paper would read every student';
  end if;
  if v_src not like '%p.role = ''student''%' then
    raise exception 'FAIL: can_read_profile() answers for somebody other than a student';
  end if;

  -- The policy itself, as the server will evaluate it - not as this file spells it.
  select qual into v_qual
  from pg_policies
  where schemaname = 'public'
    and tablename = 'profiles'
    and policyname = 'profiles_select_own_or_staff';

  if v_qual is null then
    raise exception 'FAIL: profiles_select_own_or_staff does not exist - a profiles table with RLS and no read policy returns no rows to anybody';
  end if;
  if v_qual not like '%can_read_profile%' then
    raise exception 'FAIL: profiles_select_own_or_staff still reads every row for a supervisor';
  end if;
  if v_qual not like '%is_supervisor_only%' then
    raise exception 'FAIL: profiles_select_own_or_staff does not ask whether the caller is a supervisor';
  end if;
  if v_qual not like '%id = auth.uid()%' then
    raise exception 'FAIL: profiles_select_own_or_staff no longer lets an account read its own row';
  end if;

  -- The other permissive policy on the table, re-created above as `is_admin()`. A
  -- project that still has `using (is_staff())` there hands the whole roster back to a
  -- supervisor through the administrator's arm, and the narrowing above never applies.
  select qual into v_admin_qual
  from pg_policies
  where schemaname = 'public'
    and tablename = 'profiles'
    and policyname = 'profiles_admin_all';

  if v_admin_qual is null then
    raise exception 'FAIL: profiles_admin_all is missing - the administrator console reads and writes profile rows through it';
  end if;
  if v_admin_qual not like '%is_admin%' then
    raise exception 'FAIL: profiles_admin_all asks % - a policy that matches is_staff() matches a supervisor too, and a supervisor reads every row through it', v_admin_qual;
  end if;

  -- A second permissive read policy is a union with the one above, so the roster
  -- stays exactly as wide as it was. Only these two names belong on the table: the
  -- scoped read and the administrator's `profiles_admin_all`. Anything else is named
  -- with the predicate it carries, because a leftover
  -- `using (id = auth.uid() or is_staff())` is the old read under another name and
  -- goes, while a policy somebody wrote on purpose is theirs to decide about - and
  -- the message is where to decide it.
  select string_agg(
           policyname || ' [' || cmd || '] using ' || coalesce(qual, '-')
             || coalesce(' check ' || with_check, ''),
           '; ' order by policyname
         )
    into v_extra
  from pg_policies
  where schemaname = 'public'
    and tablename = 'profiles'
    and cmd in ('SELECT', 'ALL')
    and policyname not in ('profiles_select_own_or_staff', 'profiles_admin_all');

  if v_extra is not null then
    raise exception 'FAIL: public.profiles has another read policy (%): drop it, or the supervisor roster read is a union with it', v_extra;
  end if;

  raise notice 'supervisor roster read installed: profiles_select_own_or_staff asks can_read_profile() for the supervisor tier, and an administrator and a lecturer read exactly what they did';
end $$;
