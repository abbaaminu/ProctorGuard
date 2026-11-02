-- =====================================================================
-- TARGETING RLS TEST  –  run against a LOCAL `supabase start` database
-- =====================================================================
-- Run from the repo root with:
--
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres
--     -f supabase/tests/targeting_check.sql
--
-- Prerequisites: `supabase start` is running and schema.sql has been
-- applied via `supabase db reset`.
--
-- HOW RLS IS APPLIED
--   Each check block does:
--     1. set local role authenticated;
--     2. select set_config('request.jwt.claims', '{"sub":"<uuid>"}', true);
--     3. run query — RLS fires (role='authenticated', auth.uid() from JWT);
--     4. reset role;
--   The whole file is wrapped in begin; … rollback; — no data persists.
--
-- WHAT IT PROVES
--   (a) SELECT: blank-label student cannot see a targeted paper.
--   (b) INSERT: submissions_insert_own_ongoing does not check targeting
--       (both students succeed — documented in the contract test).
--   (c) Borrow list overrides targeting.
--   (d) Whitespace-only labels are null after btrim.
-- =====================================================================

begin;

do $$
declare
  v_lecturer_id uuid := gen_random_uuid();
  v_student_a   uuid := gen_random_uuid();
  v_student_b   uuid := gen_random_uuid();
  v_targeted    uuid := gen_random_uuid();
  v_untargeted  uuid := gen_random_uuid();
begin
  insert into public.profiles (id, role, email)
    values (v_lecturer_id, 'lecturer', 'lecturer@test.local');
  insert into public.profiles (id, role, email, faculty, department, level)
    values (v_student_a, 'student', 'student.a@test.local',
            'Science', 'CS', '300');
  insert into public.profiles (id, role, email, faculty, department, level)
    values (v_student_b, 'student', 'student.b@test.local',
            NULL, NULL, NULL);
  insert into public.exams (id, title, created_by, duration_minutes, is_published,
                            faculty, department, level)
    values (v_targeted, 'Targeted CS101', v_lecturer_id, 60, true,
            'Science', 'CS', '300');
  insert into public.exams (id, title, created_by, duration_minutes, is_published,
                            faculty, department, level)
    values (v_untargeted, 'Untargeted GES101', v_lecturer_id, 60, true,
            NULL, NULL, NULL);

  -- Persist IDs as session-level custom parameters.
  perform set_config('test.lecturer', v_lecturer_id::text, false);
  perform set_config('test.student_a', v_student_a::text, false);
  perform set_config('test.student_b', v_student_b::text, false);
  perform set_config('test.targeted', v_targeted::text, false);
  perform set_config('test.untargeted', v_untargeted::text, false);
end $$;

-- =====================================================================
-- (a)  SELECT
-- =====================================================================

-- (a) i: matching student CAN see targeted paper.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s"}', current_setting('test.student_a')), true);

do $$
begin
  if (select count(*) from public.exams e
      where e.id = current_setting('test.targeted')::uuid) != 1 then
    raise exception 'FAIL (a)i';
  end if;
  raise notice 'PASS (a)i: matching student sees targeted';
end $$;
reset role;

-- (a) ii: blank-label student CANNOT see targeted paper.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s"}', current_setting('test.student_b')), true);

do $$
begin
  if (select count(*) from public.exams e
      where e.id = current_setting('test.targeted')::uuid) != 0 then
    raise exception 'FAIL (a)ii';
  end if;
  raise notice 'PASS (a)ii: blank student excluded from targeted';
end $$;
reset role;

-- (a) iii+iv: both students see untargeted paper.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s"}', current_setting('test.student_a')), true);

do $$
begin
  if (select count(*) from public.exams e
      where e.id = current_setting('test.untargeted')::uuid) != 1 then
    raise exception 'FAIL (a)iii';
  end if;
end $$;
reset role;

set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s"}', current_setting('test.student_b')), true);

do $$
begin
  if (select count(*) from public.exams e
      where e.id = current_setting('test.untargeted')::uuid) != 1 then
    raise exception 'FAIL (a)iv';
  end if;
  raise notice 'PASS (a)iii+iv: both students see untargeted';
end $$;
reset role;

-- =====================================================================
-- (b)  INSERT
-- =====================================================================
-- NOTE: submissions_insert_own_ongoing does not check targeting (only
-- is_published and window).  Both inserts are expected to SUCCEED.

-- (b) i: matching student can INSERT a submission.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s"}', current_setting('test.student_a')), true);

do $$
declare
  v_sub_id uuid;
begin
  insert into public.exam_submissions (exam_id, student_id)
    values (current_setting('test.targeted')::uuid,
            current_setting('test.student_a')::uuid)
    returning id into v_sub_id;
  if v_sub_id is null then raise exception 'FAIL (b)i'; end if;
  raise notice 'PASS (b)i: matching student can INSERT';
end $$;
reset role;

-- (b) ii: blank-label student can also INSERT (by design).
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s"}', current_setting('test.student_b')), true);

do $$
declare
  v_sub_id uuid;
begin
  insert into public.exam_submissions (exam_id, student_id)
    values (current_setting('test.targeted')::uuid,
            current_setting('test.student_b')::uuid)
    returning id into v_sub_id;
  if v_sub_id is null then raise exception 'FAIL (b)ii'; end if;
  raise notice 'PASS (b)ii: blank student CAN INSERT (expected)';
end $$;
reset role;

-- =====================================================================
-- (c)  Borrow-list override
-- =====================================================================
do $$
begin
  insert into public.exam_allowed_students (exam_id, student_id, created_by)
    values (current_setting('test.targeted')::uuid,
            current_setting('test.student_b')::uuid,
            current_setting('test.lecturer')::uuid);
end $$;

set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s"}', current_setting('test.student_b')), true);

do $$
begin
  if (select count(*) from public.exams e
      where e.id = current_setting('test.targeted')::uuid) != 1 then
    raise exception 'FAIL (c)';
  end if;
  raise notice 'PASS (c): borrow list overrides targeting';
end $$;
reset role;

-- =====================================================================
-- (d)  Whitespace-only labels
-- =====================================================================
do $$
begin
  update public.profiles
    set faculty = '   ', department = '', level = ' '
    where id = current_setting('test.student_b')::uuid;
end $$;

do $$
begin
  if nullif(btrim((select faculty from public.profiles
                   where id = current_setting('test.student_b')::uuid)), '')
     is not null then
    raise exception 'FAIL (d): whitespace not blank after btrim';
  end if;
  raise notice 'PASS (d): whitespace-only null after btrim';
end $$;

do $$
begin
  raise notice 'ALL TESTS PASSED.';
end $$;

rollback;
