-- =====================================================================
-- PROFILE LABELS: WHO MAY CORRECT THEM  -  run against a LOCAL `supabase start`
-- =====================================================================
-- Run from the repo root with:
--
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres
--     -f supabase/tests/profile_labels_admin_check.sql
--
-- Prerequisites: `supabase start` is running, and `supabase db reset` has applied
-- `supabase/schema.sql` (which carries the `guard_profile_labels()` trigger and
-- the `profiles_*` policies) and
-- `supabase/migrations/academic_targeting.sql` (the three label columns and
-- `exams_select`'s use of them).
--
-- WHAT IT PROVES
--   `targeting_check.sql` (e) proves the *refusal*: a student cannot write their
--   own labels, which is why a roster imported with the wrong level locks that
--   student out of every targeted paper. This file proves the way back out.
--
--   (a) an administrator may set the labels of a blank-label student — through
--       both RLS (`profiles_admin_all`) and `guard_profile_labels()` — and that
--       student then sees the targeted paper they could not see a moment before.
--   (b) the same for a *wrong* label: a level imported as "300 level" is invisible
--       to a paper aimed at `'300'`, because `exams_select` compares `level` with
--       equality. Correcting the spelling is what unlocks the paper — this is the
--       corpus delicti of the whole feature.
--   (c) clearing a label hides the paper again, so (a) was the columns at work
--       and not an artefact of the fixtures.
--   (d) `service_role` — what an Edge Function holds, `admin-update-profile`
--       included — may write the labels without an `admin` row of its own, and an
--       administrator may record an identity number (the matric number) at the
--       same time.
--   (e) none of that loosens the gate: a student still cannot move their own
--       level, nor write their own matric number.
--   (f) a lecturer is not an administrator here either: as a non-admin staff
--       caller the same UPDATE reaches no row at all, which is the RLS half of
--       the tier rule rather than the trigger's refusal.
--
-- HOW RLS IS APPLIED
--   Identical to `targeting_check.sql`: `set local role authenticated` plus a
--   `request.jwt.claims` carrying the caller's uuid, then `reset role` and a blank
--   claims string before the next fixture write — `guard_profile_labels()` refuses
--   a label write from any caller who arrives with claims, and the claims are
--   transaction-local, so leaving them set would poison the next block.
--
--   The whole file is wrapped in begin; ... rollback; — no data persists.
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

-- ---------------------------------------------------------------------
-- Fixtures (as postgres: no claims, RLS bypassed)
-- ---------------------------------------------------------------------
do $$
declare
  v_admin     uuid := gen_random_uuid();   -- (a)-(d) the tier that may correct
  v_lecturer  uuid := gen_random_uuid();   -- (f) staff, but not an administrator
  v_blank     uuid := gen_random_uuid();   -- (a) no labels at all
  v_wrong     uuid := gen_random_uuid();   -- (b) level imported as '300 level'
  v_exam      uuid := gen_random_uuid();   -- published, aimed at Science/CS/300
begin
  insert into public.profiles (id, role, full_name, email, faculty, department, level)
    values
      (v_admin, 'admin', 'Ada Admin', 'admin.labels@test.local',
       null, null, null),
      (v_lecturer, 'lecturer', 'Musa Lecturer', 'lecturer.labels@test.local',
       'Science', 'Computer Science', null),
      (v_blank, 'student', 'Blank Labels', 'blank.labels@test.local',
       null, null, null),
      -- The shape a real import produces: the level cell says "300 level", and
      -- `level` is compared with equality, so the paper below is invisible.
      (v_wrong, 'student', 'Wrong Labels', 'wrong.labels@test.local',
       'Science', 'Computer Science', '300 level');

  insert into public.exams (id, title, created_by, duration_minutes, is_published,
                            faculty, department, level)
    values
      (v_exam, 'Targeted CSC301', v_lecturer, 60, true,
       'Science', 'Computer Science', '300');

  -- Session-level, so every later block can read them.
  perform set_config('test.admin', v_admin::text, false);
  perform set_config('test.lecturer', v_lecturer::text, false);
  perform set_config('test.blank', v_blank::text, false);
  perform set_config('test.wrong', v_wrong::text, false);
  perform set_config('test.exam', v_exam::text, false);
end $$;

-- =====================================================================
-- (a)  an administrator labels a blank-label student
-- =====================================================================

-- (a) i: before the correction the paper is invisible — the lockout itself.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "blank.labels@test.local"}',
         current_setting('test.blank')), true);
do $$
begin
  if (select count(*) from public.exams e
      where e.id = current_setting('test.exam')::uuid) <> 0 then
    raise exception 'FAIL (a)i: a blank-label student already sees the targeted paper';
  end if;
  raise notice 'PASS (a)i: a blank-label student cannot see the targeted paper';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (a) ii: the administrator writes all three labels. This passes only if *both*
-- halves allow it: `profiles_admin_all` (the row) and `guard_profile_labels()`
-- (the columns).
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "admin.labels@test.local"}',
         current_setting('test.admin')), true);
do $$
declare
  v_rows integer;
begin
  update public.profiles
     set faculty = 'Science', department = 'Computer Science', level = '300'
   where id = current_setting('test.blank')::uuid;
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then
    raise exception 'FAIL (a)ii: the administrator''s label UPDATE touched % rows', v_rows;
  end if;
  raise notice 'PASS (a)ii: an administrator sets the labels of a blank-label student';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (a) iii: and the paper opens for that student — the point of the correction.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "blank.labels@test.local"}',
         current_setting('test.blank')), true);
do $$
begin
  if (select count(*) from public.exams e
      where e.id = current_setting('test.exam')::uuid) <> 1 then
    raise exception 'FAIL (a)iii: the newly labelled student still cannot see the paper';
  end if;
  raise notice 'PASS (a)iii: the corrected student now sees the targeted paper';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (b)  a wrong label, corrected: '300 level' is not '300'
-- =====================================================================
-- `level` is the one column `exams_select` compares with `=`, so an imported
-- "300 level" is a lockout that looks like data. This is the case the console's
-- "correct the labels" dialog and the corrections CSV exist for.

-- (b) i: the mislabelled student is locked out.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "wrong.labels@test.local"}',
         current_setting('test.wrong')), true);
do $$
begin
  if (select count(*) from public.exams e
      where e.id = current_setting('test.exam')::uuid) <> 0 then
    raise exception 'FAIL (b)i: "300 level" reached a paper aimed at ''300''';
  end if;
  raise notice 'PASS (b)i: a level spelled "300 level" sees no paper aimed at ''300''';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (b) ii: the administrator corrects the spelling.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "admin.labels@test.local"}',
         current_setting('test.admin')), true);
do $$
declare
  v_level text;
begin
  update public.profiles set level = '300'
   where id = current_setting('test.wrong')::uuid;
  select level into v_level from public.profiles
   where id = current_setting('test.wrong')::uuid;
  if v_level is distinct from '300' then
    raise exception 'FAIL (b)ii: the level is % after the correction', v_level;
  end if;
  raise notice 'PASS (b)ii: an administrator corrects "300 level" to "300"';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (b) iii: and the paper opens.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "wrong.labels@test.local"}',
         current_setting('test.wrong')), true);
do $$
begin
  if (select count(*) from public.exams e
      where e.id = current_setting('test.exam')::uuid) <> 1 then
    raise exception 'FAIL (b)iii: the corrected level still cannot see the paper';
  end if;
  raise notice 'PASS (b)iii: the corrected level now sees the targeted paper';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);


-- =====================================================================
-- (c)  clearing a label hides the paper again
-- =====================================================================
-- The negative control for (a): if the paper stayed visible after the label was
-- removed, (a)iii would have been proving nothing about the columns.

-- (c) i: the administrator clears the student's level (NULL = "not recorded").
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "admin.labels@test.local"}',
         current_setting('test.admin')), true);
do $$
begin
  update public.profiles set level = null
   where id = current_setting('test.blank')::uuid;
  raise notice 'PASS (c)i: an administrator clears a label';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (c) ii: the paper is gone from that student's list again.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "blank.labels@test.local"}',
         current_setting('test.blank')), true);
do $$
begin
  if (select count(*) from public.exams e
      where e.id = current_setting('test.exam')::uuid) <> 0 then
    raise exception 'FAIL (c)ii: a cleared level still sees the targeted paper';
  end if;
  raise notice 'PASS (c)ii: a cleared label hides the paper again';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (d)  service_role, and the identity number
-- =====================================================================

-- (d) i: `service_role` may write the labels without an admin row of its own.
--
-- Run as `postgres` with the claim a service-key request carries. A superuser
-- bypasses RLS, so what is under test here is the *trigger* arm alone —
-- `guard_profile_labels()` returns early for `role = 'service_role'`. That is
-- exactly the arm `admin-update-profile` and the roster import rely on: they hold
-- the service key, and their PostgREST session is not an administrator.
select set_config('request.jwt.claims', '{"role": "service_role"}', true);
do $$
declare
  v_level text;
begin
  update public.profiles set level = '300'
   where id = current_setting('test.wrong')::uuid;
  select level into v_level from public.profiles
   where id = current_setting('test.wrong')::uuid;
  if v_level is distinct from '300' then
    raise exception 'FAIL (d)i: service_role could not set a label (%)', v_level;
  end if;
  raise notice 'PASS (d)i: service_role writes labels without an admin row';
end $$;
select set_config('request.jwt.claims', '', true);


-- (d) ii: an administrator records the matric number, the identity a human reads
-- on the roster — the same statement `admin-update-profile` sends.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "admin.labels@test.local"}',
         current_setting('test.admin')), true);
do $$
declare
  v_matric text;
begin
  update public.profiles set matric_number = 'CSC/2021/041'
   where id = current_setting('test.wrong')::uuid;
  select matric_number into v_matric from public.profiles
   where id = current_setting('test.wrong')::uuid;
  if v_matric is distinct from 'CSC/2021/041' then
    raise exception 'FAIL (d)ii: the matric number is % after the correction', v_matric;
  end if;
  raise notice 'PASS (d)ii: an administrator records a matric number';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (e)  the gate is unchanged: a student may not correct their own row
-- =====================================================================
-- `targeting_check.sql` (e) proves this for a freshly self-provisioned row; here
-- it is an *existing, labelled* student — the row the console edits.

-- (e) i: the owner cannot move their own level.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "wrong.labels@test.local"}',
         current_setting('test.wrong')), true);
do $$
begin
  begin
    update public.profiles set level = '400'
     where id = current_setting('test.wrong')::uuid;
    raise exception 'FAIL (e)i: a student retargeted their own level';
  exception
    when insufficient_privilege then
      raise notice 'PASS (e)i: a label UPDATE refused (42501)';
  end;
end $$;

-- (e) ii: nor write their own matric number.
do $$
begin
  begin
    update public.profiles set matric_number = 'CSC/2021/042'
     where id = current_setting('test.wrong')::uuid;
    raise exception 'FAIL (e)ii: a student rewrote their own matric number';
  exception
    when insufficient_privilege then
      raise notice 'PASS (e)ii: an identity UPDATE refused (42501)';
  end;
end $$;

-- (e) iii: nor slip a label through beside a permitted column — the whole
-- statement is refused, not just the protected one.
do $$
begin
  begin
    update public.profiles set full_name = 'Wrong Labels (fixed)', level = '400'
     where id = current_setting('test.wrong')::uuid;
    raise exception 'FAIL (e)iii: a mixed UPDATE slipped a label through';
  exception
    when insufficient_privilege then
      raise notice 'PASS (e)iii: a mixed UPDATE refused entirely (42501)';
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (f)  a lecturer is staff, not an administrator
-- =====================================================================
-- `profiles_select_own_or_staff` lets a lecturer *read* the roster, so
-- `profiles_admin_all` is the difference — and it shows up as "no row matched"
-- rather than a refusal, because `using (is_admin())` filters the row out before
-- the trigger is ever reached.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "lecturer.labels@test.local"}',
         current_setting('test.lecturer')), true);
do $$
declare
  v_rows integer;
begin
  update public.profiles set level = '400'
   where id = current_setting('test.wrong')::uuid;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'FAIL (f): a lecturer''s label UPDATE touched % rows', v_rows;
  end if;
  raise notice 'PASS (f): a lecturer''s label UPDATE reaches no row';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

do $$
begin
  raise notice 'ALL PROFILE LABEL PERMISSION CHECKS PASSED.';
end $$;

rollback;

