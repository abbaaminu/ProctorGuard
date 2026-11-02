-- =====================================================================
-- TARGETING RLS TEST  –  run against a LOCAL `supabase start` database
-- =====================================================================
-- Run this file through `supabase db execute` (NOT the Supabase SQL editor
-- of a linked live project):
--
--   supabase db execute -f supabase/tests/targeting_check.sql
--
-- Prerequisites: schema.sql has been applied (via `supabase db reset`).
-- This script creates test accounts, tests, and cleans up after itself.
--
-- WHAT IT PROVES
--   1. A student with a NULL/blank faculty/department/level CANNOT see or
--      start a paper that names those fields.
--   2. The same student CAN see UNtargeted papers (all three NULL).
--   3. A student whose labels match CAN see and start the targeted paper.
--   4. The `exam_allowed_students` borrow list overrides the targeting
--      block for an otherwise-excluded student.
--   5. Whitespace-only labels behave the same as NULL via nullif(btrim()).
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

  -- -----------------------------------------------------------------
  -- 1.  set up accounts
  -- -----------------------------------------------------------------
  v_lecturer_id := gen_random_uuid();
  insert into public.profiles (id, role, email) values
    (v_lecturer_id, 'lecturer', 'lecturer@test.local');

  v_student_a := gen_random_uuid();
  insert into public.profiles (id, role, email, faculty, department, level)
    values (v_student_a, 'student', 'student.a@test.local',
            'Science', 'CS', '300');

  v_student_b := gen_random_uuid();
  insert into public.profiles (id, role, email, faculty, department, level)
    values (v_student_b, 'student', 'student.b@test.local',
            NULL, NULL, NULL);

  -- -----------------------------------------------------------------
  -- 2.  create exams
  -- -----------------------------------------------------------------
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

  -- -----------------------------------------------------------------
  -- 3.  TEST: Student A (labels match) sees targeted paper
  -- -----------------------------------------------------------------
  select count(*) into v_visible
    from public.exams e
    where e.id = v_exam_targeted
      and (
        exists (
          select 1 from public.profiles p
          where p.id = v_student_a
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
  if v_visible != 1 then
    raise exception 'FAIL 1: Student A cannot see targeted paper (got %)', v_visible;
  end if;

  -- -----------------------------------------------------------------
  -- 3b.  Student A sees untargeted paper too
  -- -----------------------------------------------------------------
  select count(*) into v_visible
    from public.exams e
    where e.id = v_exam_untargeted
      and (
        exists (
          select 1 from public.profiles p
          where p.id = v_student_a
            and (nullif(btrim(e.faculty), '') is null
                 or (nullif(btrim(p.faculty), '') is not null
                     and lower(btrim(p.faculty)) = lower(btrim(e.faculty))))
            and (nullif(btrim(e.department), '') is null
                 or (nullif(btrim(p.department), '') is not null
                     and lower(btrim(p.department)) = lower(btrim(e.department))))
            and (nullif(btrim(e.level), '') is null

  -- -----------------------------------------------------------------
  -- 4.  TEST: Student B (NULL labels) blocked from targeted, sees untargeted
  -- -----------------------------------------------------------------
  select count(*) into v_visible
    from public.exams e
    where e.id = v_exam_targeted
      and (
        exists (
          select 1 from public.profiles p
          where p.id = v_student_b
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
  if v_visible != 0 then
    raise exception 'FAIL 3a: Student B (NULL labels) sees targeted (got %)', v_visible;
  end if;

  select count(*) into v_visible
    from public.exams e
    where e.id = v_exam_untargeted
      and (
        exists (
          select 1 from public.profiles p
          where p.id = v_student_b
            and (nullif(btrim(e.faculty), '') is null
                 or (nullif(btrim(p.faculty), '') is not null
                     and lower(btrim(p.faculty)) = lower(btrim(e.faculty))))

  -- -----------------------------------------------------------------
  -- 5.  TEST: borrow list overrides targeting for excluded student
  -- -----------------------------------------------------------------
  insert into public.exam_allowed_students (exam_id, student_id, created_by)
    values (v_exam_targeted, v_student_b, v_lecturer_id);

  select count(*) into v_visible
    from public.exams e
    where e.id = v_exam_targeted
      and (
        (
          exists (
            select 1 from public.profiles p
            where p.id = v_student_b
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
        )
        or exists (
          select 1 from public.exam_allowed_students a
          where a.exam_id = e.id and a.student_id = v_student_b
        )
      );
  if v_visible != 1 then
    raise exception 'FAIL 4: Borrow list did not override targeting (got %)', v_visible;
  end if;

  -- -----------------------------------------------------------------
  -- 6.  TEST: whitespace-only labels treated as blank
  -- -----------------------------------------------------------------
  update public.profiles
    set faculty = '   ', department = '', level = ' '
    where id = v_student_b;

  select count(*) into v_visible
    from public.exams e
    where e.id = v_exam_targeted
      and (
        exists (
          select 1 from public.profiles p
          where p.id = v_student_b
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
  if v_visible != 0 then
    raise exception 'FAIL 5: Whitespace-only labels see targeted (got %)', v_visible;
  end if;
  raise notice 'PASS 5: Whitespace-only labels treated as blank.';

  -- -----------------------------------------------------------------
  -- 7.  clean up
  -- -----------------------------------------------------------------
  delete from public.exam_allowed_students
    where exam_id in (v_exam_targeted, v_exam_untargeted);
  delete from public.proctoring_logs
    where submission_id in (
      select id from public.exam_submissions
      where exam_id in (v_exam_targeted, v_exam_untargeted)
    );
  delete from public.exam_submissions
    where exam_id in (v_exam_targeted, v_exam_untargeted);
  delete from public.exams where id in (v_exam_targeted, v_exam_untargeted);
  delete from public.profiles
    where id in (v_lecturer_id, v_student_a, v_student_b);

  raise notice 'ALL TESTS PASSED.';
end;
$$;

commit;


  raise notice 'PASS 4: Borrow list overrides targeting.';

            and (nullif(btrim(e.department), '') is null
                 or (nullif(btrim(p.department), '') is not null
                     and lower(btrim(p.department)) = lower(btrim(e.department))))
            and (nullif(btrim(e.level), '') is null
                 or (nullif(btrim(p.level), '') is not null
                     and lower(btrim(p.level)) = lower(btrim(e.level))))
        )
      );
  if v_visible != 1 then
    raise exception 'FAIL 3b: Student B cannot see untargeted (got %)', v_visible;
  end if;
  raise notice 'PASS 3: Student B excluded from targeted, sees untargeted.';

                 or (nullif(btrim(p.level), '') is not null
                     and lower(btrim(p.level)) = lower(btrim(e.level))))
        )
      );
  if v_visible != 1 then
    raise exception 'FAIL 2: Student A cannot see untargeted paper (got %)', v_visible;
  end if;
  raise notice 'PASS 1+2: Student A sees both papers.';

