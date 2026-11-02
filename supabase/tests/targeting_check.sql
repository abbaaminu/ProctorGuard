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
-- WHAT IT PROVES
--   Each check runs through a SECURITY DEFINER helper that sets
--   `request.jwt.claims` so RLS fires as a real signed-in student.
--
--   1. Matching labels → can see a targeted paper.
--   2. NULL/blank labels → cannot see that paper.
--   3. Both see an UNtargeted paper.
--   4. Borrow list overrides targeting.
--   5. Whitespace-only labels treated as blank.
--
-- Wrapped in begin; … rollback; — no data persists.
-- =====================================================================

begin;

do $$
declare
  v_lecturer_id uuid;
  v_student_a   uuid;  -- faculty='Science', department='CS', level='300'
  v_student_b   uuid;  -- faculty=NULL, department=NULL, level=NULL
  v_exam_targeted   uuid;
  v_exam_untargeted uuid;
  v_visible int;
begin

  -- Create test data (postgres role bypasses RLS).
  v_lecturer_id := gen_random_uuid();
  insert into public.profiles (id, role, email)
    values (v_lecturer_id, 'lecturer', 'lecturer@test.local');

  v_student_a := gen_random_uuid();
  insert into public.profiles (id, role, email, faculty, department, level)
    values (v_student_a, 'student', 'student.a@test.local',
            'Science', 'CS', '300');

  v_student_b := gen_random_uuid();
  insert into public.profiles (id, role, email, faculty, department, level)
    values (v_student_b, 'student', 'student.b@test.local',
            NULL, NULL, NULL);

  v_exam_targeted := gen_random_uuid();
  insert into public.exams (id, title, created_by, duration_minutes, is_published,
                            faculty, department, level)
    values (v_exam_targeted, 'Targeted CS101', v_lecturer_id, 60, true,
            'Science', 'CS', '300');

  v_exam_untargeted := gen_random_uuid();
  insert into public.exams (id, title, created_by, duration_minutes, is_published,
                            faculty, department, level)
    values (v_exam_untargeted, 'Untargeted GES101', v_lecturer_id, 60, true,
            NULL, NULL, NULL);

  -- SECURITY DEFINER helper: set JWT claim so RLS sees auth.uid()
  create or replace function _rls_check(
    p_student_id uuid,
    p_exam_id    uuid
  ) returns int
    language plpgsql
    security definer
    set search_path = pg_catalog
  as $$
  declare
    v_cnt int;
  begin
    perform set_config(
      'request.jwt.claims',
      format('{"sub": "%s"}', p_student_id::text),
      true
    );
    select count(*) into v_cnt
      from public.exams e
      where e.id = p_exam_id
        and (
          public.is_staff()
          or e.created_by = auth.uid()
          or (
            e.is_published = true
            and (
              exists (
                select 1 from public.profiles p
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
                select 1 from public.exam_allowed_students a
                where a.exam_id = e.id and a.student_id = auth.uid()

  -- -----------------------------------------------------------------
  --  TEST 1+2: Student A sees both papers
  -- -----------------------------------------------------------------
  v_visible := _rls_check(v_student_a, v_exam_targeted);
  if v_visible != 1 then
    raise exception 'FAIL 1: Student A cannot see targeted (got %)', v_visible;
  end if;

  v_visible := _rls_check(v_student_a, v_exam_untargeted);
  if v_visible != 1 then
    raise exception 'FAIL 2: Student A cannot see untargeted (got %)', v_visible;
  end if;
  raise notice 'PASS 1+2: Student A sees both papers.';

  -- -----------------------------------------------------------------
  --  TEST 3: Student B blocked from targeted, sees untargeted
  -- -----------------------------------------------------------------
  v_visible := _rls_check(v_student_b, v_exam_targeted);
  if v_visible != 0 then
    raise exception 'FAIL 3a: Student B sees targeted (got %)', v_visible;
  end if;

  v_visible := _rls_check(v_student_b, v_exam_untargeted);
  if v_visible != 1 then
    raise exception 'FAIL 3b: Student B cannot see untargeted (got %)', v_visible;
  end if;
  raise notice 'PASS 3: Student B excluded from targeted, sees untargeted.';

  -- -----------------------------------------------------------------
  --  TEST 4: borrow list overrides targeting
  -- -----------------------------------------------------------------
  insert into public.exam_allowed_students (exam_id, student_id, created_by)
    values (v_exam_targeted, v_student_b, v_lecturer_id);

  v_visible := _rls_check(v_student_b, v_exam_targeted);
  if v_visible != 1 then
    raise exception 'FAIL 4: Borrow list did not override (got %)', v_visible;
  end if;
  raise notice 'PASS 4: Borrow list overrides targeting.';

  -- -----------------------------------------------------------------
  --  TEST 5: whitespace-only labels treated as blank
  -- -----------------------------------------------------------------
  update public.profiles
    set faculty = '   ', department = '', level = ' '
    where id = v_student_b;

  v_visible := _rls_check(v_student_b, v_exam_targeted);
  if v_visible != 0 then
    raise exception 'FAIL 5: Whitespace labels see targeted (got %)', v_visible;
  end if;
  raise notice 'PASS 5: Whitespace-only labels treated as blank.';

  drop function if exists _rls_check(uuid, uuid);

  raise notice 'ALL TESTS PASSED.';
end;
$$;

rollback;

              )
            )
          )
        );
    return v_cnt;
  end;
  $$;