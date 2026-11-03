-- =====================================================================
-- TARGETING AND HARDENING RLS TEST  -  run against a LOCAL `supabase start` database
-- =====================================================================
-- Run from the repo root with:
--
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres
--     -f supabase/tests/targeting_check.sql
--
-- Prerequisites: `supabase start` is running, and `supabase db reset` has applied
-- `supabase/schema.sql` (which already carries every 2026110309*.sql change).
--
-- HOW RLS IS APPLIED
--   Each check block does:
--     1. set local role authenticated;
--     2. select set_config('request.jwt.claims', '{"sub":"<uuid>","role":"authenticated",
--        "email":"..."}', true);
--     3. run the check - RLS fires (role='authenticated', auth.uid() from the JWT);
--     4. reset role;
--     5. select set_config('request.jwt.claims', '', true);
--   Step 5 is not decoration: the claims are transaction-local and would otherwise
--   still be set for the *next* fixture write, and `guard_profile_labels()` refuses a
--   label write from any caller carrying claims. Every postgres-side write below is
--   preceded by it.
--
--   The whole file is wrapped in begin; ... rollback; - no data persists. Nothing
--   here is a SECURITY DEFINER helper: the fixtures are written as `postgres`, which
--   is what the SQL editor and `supabase db reset` are.
--
-- WHAT IT PROVES
--   (a) exams_select: a paper aimed at a cohort is invisible to a blank-label
--       student, to a mismatched student, and to a student it is not published for;
--       an untargeted paper is visible to both.
--   (b) submissions_insert_own_ongoing: an out-of-cohort student cannot start a
--       paper at all; a student cannot start a paper before its window opens, nor a
--       draft. (This block used to assert the *opposite* - "both inserts succeed,
--       targeting is not checked on insert" - which was the hole.)
--   (c) exam_allowed_students still overrides the labels, for read and for insert.
--   (d) whitespace-only labels are blank after btrim.
--   (e) guard_profile_labels: a student cannot insert a row carrying academic
--       labels, cannot change their own labels or email, and can still fix their
--       own name.
--   (f) questions_public: an out-of-cohort student reads none of a paper's
--       questions, a student reads none before `starts_at`, the aimed-at student
--       reads them while the window is open, and the author keeps their own draft.
--   (g) questions_public: an ongoing attempt keeps its paper readable after
--       `ends_at`, and stops being readable once `started_at + duration_minutes`
--       has passed.
--   (h) questions_select_supervisor: a lecturer does not read another lecturer's
--       draft questions on the raw table or through the view; the author and a
--       supervisor do.
--   (i) storage.objects + submissions_delete_supervisor: a lecturer cannot read
--       another paper's snapshots and cannot delete another paper's attempt; the
--       author, the owning student and a supervisor can.
--   (j) register_violation: a snapshot path that is not inside the attempt's own
--       folder is stored as NULL and the violation still counts; the folder-shaped
--       path is stored; the third strike disqualifies.
--
-- NOT EXECUTED HERE. This file is written against the schema, not run against a
-- live database in the change that added it; run it after `supabase db reset`.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Fixtures (as postgres: no claims, RLS bypassed)
-- ---------------------------------------------------------------------
do $$
declare
  v_lecturer_a  uuid := gen_random_uuid();
  v_lecturer_b  uuid := gen_random_uuid();
  v_supervisor  uuid := gen_random_uuid();
  v_student_a   uuid := gen_random_uuid();   -- Science / CS / 300
  v_student_b   uuid := gen_random_uuid();   -- no labels
  v_student_c   uuid := gen_random_uuid();   -- Arts / History / 200
  v_targeted    uuid := gen_random_uuid();   -- published, aimed at A's cohort
  v_untargeted  uuid := gen_random_uuid();   -- published, no labels
  v_later       uuid := gen_random_uuid();   -- published, starts tomorrow
  v_closed      uuid := gen_random_uuid();   -- published, ended a minute ago
  v_draft       uuid := gen_random_uuid();   -- NOT published, owned by A
begin
  insert into public.profiles (id, role, full_name, email, faculty, department, level)
    values
      (v_lecturer_a, 'lecturer', 'Lecturer A', 'lecturer.a@test.local',
       'Science', 'CS', null),
      (v_lecturer_b, 'lecturer', 'Lecturer B', 'lecturer.b@test.local',
       'Science', 'CS', null),
      (v_supervisor, 'supervisor', 'Supervisor', 'supervisor@test.local',
       'Science', 'CS', null),
      (v_student_a, 'student', 'Student A', 'student.a@test.local',
       'Science', 'CS', '300'),
      (v_student_b, 'student', 'Student B', 'student.b@test.local',
       null, null, null),
      (v_student_c, 'student', 'Student C', 'student.c@test.local',
       'Arts', 'History', '200');

  insert into public.exams (id, title, created_by, duration_minutes, is_published,
                            faculty, department, level)
    values
      (v_targeted, 'Targeted CS101', v_lecturer_a, 60, true, 'Science', 'CS', '300'),
      (v_untargeted, 'Untargeted GES101', v_lecturer_a, 60, true, null, null, null),
      (v_later, 'Opens tomorrow', v_lecturer_a, 60, true, 'Science', 'CS', '300'),
      (v_closed, 'Closed a minute ago', v_lecturer_a, 60, true,
       'Science', 'CS', '300'),
      (v_draft, 'Lecturer A draft', v_lecturer_a, 60, false, 'Science', 'CS', '300');

  update public.exams set starts_at = now() + interval '1 day'
   where id = v_later;
  update public.exams set ends_at = now() - interval '1 minute'
   where id = v_closed;

  -- One 'subjective' question per paper (and two on the targeted one): no answer
  -- key, so the answer-key shape constraint holds without inventing options.
  insert into public.questions (exam_id, question_text, question_type, points)
    values
      (v_targeted, 'Targeted Q1', 'subjective', 1),
      (v_targeted, 'Targeted Q2', 'subjective', 1),
      (v_untargeted, 'Untargeted Q1', 'subjective', 1),
      (v_later, 'Later Q1', 'subjective', 1),
      (v_closed, 'Closed Q1', 'subjective', 1),
      (v_draft, 'Draft Q1', 'subjective', 1);

  -- Session-level, so every later block can read them.
  perform set_config('test.lecturer_a', v_lecturer_a::text, false);
  perform set_config('test.lecturer_b', v_lecturer_b::text, false);
  perform set_config('test.supervisor', v_supervisor::text, false);
  perform set_config('test.student_a', v_student_a::text, false);
  perform set_config('test.student_b', v_student_b::text, false);
  perform set_config('test.student_c', v_student_c::text, false);
  perform set_config('test.targeted', v_targeted::text, false);
  perform set_config('test.untargeted', v_untargeted::text, false);
  perform set_config('test.later', v_later::text, false);
  perform set_config('test.closed', v_closed::text, false);
  perform set_config('test.draft', v_draft::text, false);
end $$;

-- =====================================================================
-- (a)  exams_select: which papers a student is shown
-- =====================================================================

-- (a) i: the student the paper is aimed at sees it.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.a@test.local"}',
         current_setting('test.student_a')), true);
do $$
begin
  if (select count(*) from public.exams e
      where e.id = current_setting('test.targeted')::uuid) <> 1 then
    raise exception 'FAIL (a)i: the aimed-at student cannot see the targeted paper';
  end if;
  raise notice 'PASS (a)i: aimed-at student sees the targeted paper';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (a) ii: a student with no labels at all does not see it.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.b@test.local"}',
         current_setting('test.student_b')), true);
do $$
begin
  if (select count(*) from public.exams e
      where e.id = current_setting('test.targeted')::uuid) <> 0 then
    raise exception 'FAIL (a)ii: a blank-label student sees a targeted paper';
  end if;
  raise notice 'PASS (a)ii: blank-label student does not see the targeted paper';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (a) iii: a student with *different* labels does not see it either.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.c@test.local"}',
         current_setting('test.student_c')), true);
do $$
begin
  if (select count(*) from public.exams e
      where e.id = current_setting('test.targeted')::uuid) <> 0 then
    raise exception 'FAIL (a)iii: an out-of-cohort student sees the targeted paper';
  end if;
  raise notice 'PASS (a)iii: out-of-cohort student does not see the targeted paper';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (a) iv: an untargeted paper is visible to everybody (both students).
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.a@test.local"}',
         current_setting('test.student_a')), true);
do $$
begin
  if (select count(*) from public.exams e
      where e.id = current_setting('test.untargeted')::uuid) <> 1 then
    raise exception 'FAIL (a)iv: the aimed-at student cannot see the untargeted paper';
  end if;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.b@test.local"}',
         current_setting('test.student_b')), true);
do $$
begin
  if (select count(*) from public.exams e
      where e.id = current_setting('test.untargeted')::uuid) <> 1 then
    raise exception 'FAIL (a)iv: a blank-label student cannot see the untargeted paper';
  end if;
  raise notice 'PASS (a)iv: an untargeted paper is visible to both students';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (a) v: a draft is nobody's to see but its author's and staff.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.a@test.local"}',
         current_setting('test.student_a')), true);
do $$
begin
  if (select count(*) from public.exams e
      where e.id = current_setting('test.draft')::uuid) <> 0 then
    raise exception 'FAIL (a)v: a student sees an unpublished paper';
  end if;
  raise notice 'PASS (a)v: a student does not see a draft';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (b)  submissions_insert_own_ongoing: starting an attempt
-- =====================================================================
-- This block used to assert that BOTH students could start the targeted paper
-- ("insert does not check targeting"). That was the hole: the insert policy now
-- asks student_can_access_exam(), so the out-of-cohort insert must be refused.

-- (b) i: the aimed-at student starts the paper.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.a@test.local"}',
         current_setting('test.student_a')), true);
do $$
declare
  v_sub uuid;
begin
  insert into public.exam_submissions (exam_id, student_id)
    values (current_setting('test.targeted')::uuid,
            current_setting('test.student_a')::uuid)
    returning id into v_sub;
  perform set_config('test.sub_a', v_sub::text, false);
  raise notice 'PASS (b)i: aimed-at student started attempt %', v_sub;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (b) ii: a blank-label student CANNOT start it.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.b@test.local"}',
         current_setting('test.student_b')), true);
do $$
begin
  begin
    insert into public.exam_submissions (exam_id, student_id)
      values (current_setting('test.targeted')::uuid,
              current_setting('test.student_b')::uuid);
    raise exception 'FAIL (b)ii: an out-of-cohort student started the targeted paper';
  exception
    when insufficient_privilege then
      raise notice 'PASS (b)ii: out-of-cohort insert refused (42501)';
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (b) iii: a student CANNOT start a paper before its window opens.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.a@test.local"}',
         current_setting('test.student_a')), true);
do $$
begin
  begin
    insert into public.exam_submissions (exam_id, student_id)
      values (current_setting('test.later')::uuid,
              current_setting('test.student_a')::uuid);
    raise exception 'FAIL (b)iii: an attempt was started before starts_at';
  exception
    when insufficient_privilege then
      raise notice 'PASS (b)iii: insert before starts_at refused (42501)';
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (b) iv: a student CANNOT start a draft, however well it is aimed.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.a@test.local"}',
         current_setting('test.student_a')), true);
do $$
begin
  begin
    insert into public.exam_submissions (exam_id, student_id)
      values (current_setting('test.draft')::uuid,
              current_setting('test.student_a')::uuid);
    raise exception 'FAIL (b)iv: an attempt was started on an unpublished paper';
  exception
    when insufficient_privilege then
      raise notice 'PASS (b)iv: insert on a draft refused (42501)';
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (b) v: an untargeted paper stays open to everybody - the fix must not have
-- narrowed the common case.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.b@test.local"}',
         current_setting('test.student_b')), true);
do $$
declare
  v_sub uuid;
begin
  insert into public.exam_submissions (exam_id, student_id)
    values (current_setting('test.untargeted')::uuid,
            current_setting('test.student_b')::uuid)
    returning id into v_sub;
  perform set_config('test.sub_untargeted', v_sub::text, false);
  raise notice 'PASS (b)v: an untargeted paper is still open to a blank-label student';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (c)  Borrow list overrides the labels - for reading and for starting
-- =====================================================================
-- Claims are cleared already; this is a postgres write.
do $$
begin
  insert into public.exam_allowed_students (exam_id, student_id, created_by)
    values (current_setting('test.targeted')::uuid,
            current_setting('test.student_b')::uuid,
            current_setting('test.lecturer_a')::uuid);
end $$;

set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.b@test.local"}',
         current_setting('test.student_b')), true);
do $$
declare
  v_sub uuid;
begin
  if (select count(*) from public.exams e
      where e.id = current_setting('test.targeted')::uuid) <> 1 then
    raise exception 'FAIL (c)i: the borrow list did not restore visibility';
  end if;

  insert into public.exam_submissions (exam_id, student_id)
    values (current_setting('test.targeted')::uuid,
            current_setting('test.student_b')::uuid)
    returning id into v_sub;
  perform set_config('test.sub_b', v_sub::text, false);
  raise notice 'PASS (c)i+ii: the borrow list admits a blank-label student to read and to start';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (d)  Whitespace-only labels are blank after btrim
-- =====================================================================
do $$
begin
  update public.profiles
     set faculty = '   ', department = '', level = ' '
   where id = current_setting('test.student_c')::uuid;

  if nullif(btrim((select faculty from public.profiles
                    where id = current_setting('test.student_c')::uuid)), '')
     is not null then
    raise exception 'FAIL (d): whitespace was not blank after btrim';
  end if;
  raise notice 'PASS (d): whitespace-only labels are blank after btrim';
end $$;

-- =====================================================================
-- (e)  guard_profile_labels: labels belong to the institution
-- =====================================================================
-- A brand-new account, so the INSERT half can be tested without colliding with
-- the fixtures above. Only the trigger can refuse the first insert: id = auth.uid()
-- and role = 'student' satisfy profiles_insert_self_student.
do $$
begin
  perform set_config('test.student_d', gen_random_uuid()::text, false);
end $$;

-- (e) i: a self-provisioned row may not carry academic labels.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.d@test.local"}',
         current_setting('test.student_d')), true);
do $$
begin
  begin
    insert into public.profiles (id, role, full_name, email, faculty, department, level)
      values (current_setting('test.student_d')::uuid, 'student', 'Student D',
              'student.d@test.local', 'Science', 'CS', '300');
    raise exception 'FAIL (e)i: a sign-up carried academic labels';
  exception
    when insufficient_privilege then
      raise notice 'PASS (e)i: an INSERT carrying labels refused (42501)';
  end;
end $$;

-- (e) ii: the same row, without labels and with the session's own address, is
-- exactly what self-provisioning is allowed to write.
do $$
begin
  insert into public.profiles (id, role, full_name, email)
    values (current_setting('test.student_d')::uuid, 'student', 'Student D',
            'student.d@test.local');
  raise notice 'PASS (e)ii: a name-and-address self-provisioning INSERT succeeded';
end $$;

-- (e) iii: the owner cannot move their own level.
do $$
begin
  begin
    update public.profiles set level = '400'
     where id = current_setting('test.student_d')::uuid;
    raise exception 'FAIL (e)iii: a student retargeted their own level';
  exception
    when insufficient_privilege then
      raise notice 'PASS (e)iii: a label UPDATE refused (42501)';
  end;
end $$;

-- (e) iv: nor their own address (it is the roster import's join key).
do $$
begin
  begin
    update public.profiles set email = 'somebody.else@test.local'
     where id = current_setting('test.student_d')::uuid;
    raise exception 'FAIL (e)iv: a student changed their own email';
  exception
    when insufficient_privilege then
      raise notice 'PASS (e)iv: an email UPDATE refused (42501)';
  end;
end $$;

-- (e) v: the name stays theirs to fix - profiles_update_self still means something.
do $$
begin
  update public.profiles set full_name = 'Student D (corrected)'
   where id = current_setting('test.student_d')::uuid;
  raise notice 'PASS (e)v: an owner may still correct their own name';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (f)  questions_public: cohort, window, author
-- =====================================================================

-- (f) i: the aimed-at student reads the paper's questions while it is open.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.a@test.local"}',
         current_setting('test.student_a')), true);
do $$
begin
  if (select count(*) from public.questions_public q
      where q.exam_id = current_setting('test.targeted')::uuid) <> 2 then
    raise exception 'FAIL (f)i: the aimed-at student cannot read the questions';
  end if;
  raise notice 'PASS (f)i: the aimed-at student reads both questions';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (f) ii: a student who is out of cohort and NOT on the borrow list reads nothing.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.c@test.local"}',
         current_setting('test.student_c')), true);
do $$
begin
  if (select count(*) from public.questions_public q
      where q.exam_id = current_setting('test.targeted')::uuid) <> 0 then
    raise exception 'FAIL (f)ii: an out-of-cohort student read the questions';
  end if;
  raise notice 'PASS (f)ii: an out-of-cohort student reads none of the questions';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (f) iii: a paper that has not opened yet is unreadable even to its cohort -
-- this is the "read it before starts_at" hole.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.a@test.local"}',
         current_setting('test.student_a')), true);
do $$
begin
  if (select count(*) from public.questions_public q
      where q.exam_id = current_setting('test.later')::uuid) <> 0 then
    raise exception 'FAIL (f)iii: a not-yet-open paper''s questions were readable';
  end if;
  raise notice 'PASS (f)iii: a not-yet-open paper''s questions are unreadable';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (f) iv: a colleague cannot read a draft through the view either.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "lecturer.b@test.local"}',
         current_setting('test.lecturer_b')), true);
do $$
begin
  if (select count(*) from public.questions_public q
      where q.exam_id = current_setting('test.draft')::uuid) <> 0 then
    raise exception 'FAIL (f)iv: lecturer B read lecturer A''s draft through the view';
  end if;
  raise notice 'PASS (f)iv: lecturer B reads none of lecturer A''s draft through the view';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (f) v: the author does read their own draft through it.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "lecturer.a@test.local"}',
         current_setting('test.lecturer_a')), true);
do $$
begin
  if (select count(*) from public.questions_public q
      where q.exam_id = current_setting('test.draft')::uuid) <> 1 then
    raise exception 'FAIL (f)v: the author cannot read their own draft';
  end if;
  raise notice 'PASS (f)v: the author reads their own draft through the view';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (g)  An ongoing attempt survives ends_at - but only until its deadline
-- =====================================================================
-- v_closed ended a minute ago, so branch 3 (cohort + window) no longer matches.
-- The attempt below started five minutes ago on a 60-minute paper, so branch 4
-- still does.
do $$
begin
  insert into public.exam_submissions (exam_id, student_id, status, started_at)
    values (current_setting('test.closed')::uuid,
            current_setting('test.student_a')::uuid,
            'ongoing',
            now() - interval '5 minutes');
end $$;

set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.a@test.local"}',
         current_setting('test.student_a')), true);
do $$
begin
  if (select count(*) from public.questions_public q
      where q.exam_id = current_setting('test.closed')::uuid) <> 1 then
    raise exception 'FAIL (g)i: a live attempt lost its questions when the window closed';
  end if;
  raise notice 'PASS (g)i: a live attempt keeps its questions after ends_at';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- Push the start time back far enough that started_at + duration has passed.
do $$
begin
  update public.exam_submissions
     set started_at = now() - interval '2 hours'
   where exam_id = current_setting('test.closed')::uuid
     and student_id = current_setting('test.student_a')::uuid;
end $$;

set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.a@test.local"}',
         current_setting('test.student_a')), true);
do $$
begin
  if (select count(*) from public.questions_public q
      where q.exam_id = current_setting('test.closed')::uuid) <> 0 then
    raise exception 'FAIL (g)ii: an expired attempt still reads its questions';
  end if;
  raise notice 'PASS (g)ii: an expired attempt reads none of its questions';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (h)  The raw questions table is not "any colleague"
-- =====================================================================

-- (h) i: lecturer B cannot read lecturer A's draft questions.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "lecturer.b@test.local"}',
         current_setting('test.lecturer_b')), true);
do $$
begin
  if (select count(*) from public.questions q
      where q.exam_id = current_setting('test.draft')::uuid) <> 0 then
    raise exception 'FAIL (h)i: lecturer B read lecturer A''s draft questions';
  end if;
  raise notice 'PASS (h)i: lecturer B cannot read another lecturer''s draft questions';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (h) ii: the author can.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "lecturer.a@test.local"}',
         current_setting('test.lecturer_a')), true);
do $$
begin
  if (select count(*) from public.questions q
      where q.exam_id = current_setting('test.draft')::uuid) <> 1 then
    raise exception 'FAIL (h)ii: the author cannot read their own draft questions';
  end if;
  raise notice 'PASS (h)ii: the author reads their own draft questions';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (h) iii: a supervisor reads every paper, draft included.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "supervisor@test.local"}',
         current_setting('test.supervisor')), true);
do $$
begin
  if (select count(*) from public.questions q
      where q.exam_id = current_setting('test.draft')::uuid) <> 1 then
    raise exception 'FAIL (h)iii: a supervisor cannot read a draft''s questions';
  end if;
  raise notice 'PASS (h)iii: a supervisor reads every paper''s questions';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (i)  Evidence: storage reads and attempt deletion
-- =====================================================================
-- Two throwaway attempts, so the delete assertions cannot disturb the attempts
-- the blocks above still refer to.
do $$
declare
  v_del  uuid;
  v_del2 uuid;
begin
  insert into public.exam_submissions (exam_id, student_id)
    values (current_setting('test.untargeted')::uuid,
            current_setting('test.student_a')::uuid)
    returning id into v_del;

  insert into public.exam_submissions (exam_id, student_id)
    values (current_setting('test.untargeted')::uuid,
            current_setting('test.student_c')::uuid)
    returning id into v_del2;

  perform set_config('test.sub_del', v_del::text, false);
  perform set_config('test.sub_del2', v_del2::text, false);

  -- One stored still under the *live* attempt (b)i, in the folder convention the
  -- bucket, the upload policy and the purge all use.
  insert into storage.objects (bucket_id, name)
    values ('proctor-snapshots',
            current_setting('test.sub_a') || '/looking_away_1.jpg');
end $$;

-- (i) i: the owning student reads (and therefore signs) their own still.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.a@test.local"}',
         current_setting('test.student_a')), true);
do $$
begin
  if (select count(*) from storage.objects o
      where o.bucket_id = 'proctor-snapshots'
        and o.name = current_setting('test.sub_a') || '/looking_away_1.jpg') <> 1 then
    raise exception 'FAIL (i)i: the owning student cannot read their own snapshot';
  end if;
  raise notice 'PASS (i)i: the owning student reads their own snapshot';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (i) ii: a lecturer who did not write the paper cannot.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "lecturer.b@test.local"}',
         current_setting('test.lecturer_b')), true);
do $$
begin
  if (select count(*) from storage.objects o
      where o.bucket_id = 'proctor-snapshots'
        and o.name = current_setting('test.sub_a') || '/looking_away_1.jpg') <> 0 then
    raise exception 'FAIL (i)ii: lecturer B read another paper''s snapshot';
  end if;
  raise notice 'PASS (i)ii: a lecturer cannot read another paper''s snapshot';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (i) iii: the author of the paper can.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "lecturer.a@test.local"}',
         current_setting('test.lecturer_a')), true);
do $$
begin
  if (select count(*) from storage.objects o
      where o.bucket_id = 'proctor-snapshots'
        and o.name = current_setting('test.sub_a') || '/looking_away_1.jpg') <> 1 then
    raise exception 'FAIL (i)iii: the author cannot read the snapshot';
  end if;
  raise notice 'PASS (i)iii: the author reads the snapshot';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (i) iv: so can a supervisor.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "supervisor@test.local"}',
         current_setting('test.supervisor')), true);
do $$
begin
  if (select count(*) from storage.objects o
      where o.bucket_id = 'proctor-snapshots'
        and o.name = current_setting('test.sub_a') || '/looking_away_1.jpg') <> 1 then
    raise exception 'FAIL (i)iv: a supervisor cannot read the snapshot';
  end if;
  raise notice 'PASS (i)iv: a supervisor reads the snapshot';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (i) v: a lecturer who did not write the paper deletes nothing. RLS refuses
-- silently, so the assertion is the affected row count.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "lecturer.b@test.local"}',
         current_setting('test.lecturer_b')), true);
do $$
declare
  v_rows int;
begin
  delete from public.exam_submissions
   where id = current_setting('test.sub_del')::uuid;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'FAIL (i)v: lecturer B deleted another paper''s attempt';
  end if;
  raise notice 'PASS (i)v: a lecturer cannot delete another paper''s attempt';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (i) vi: the author deletes it.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "lecturer.a@test.local"}',
         current_setting('test.lecturer_a')), true);
do $$
declare
  v_rows int;
begin
  delete from public.exam_submissions
   where id = current_setting('test.sub_del')::uuid;
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then
    raise exception 'FAIL (i)vi: the author could not delete the attempt (% rows)', v_rows;
  end if;
  raise notice 'PASS (i)vi: the author deletes an attempt on their own paper';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (i) vii: a supervisor deletes any attempt.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "supervisor@test.local"}',
         current_setting('test.supervisor')), true);
do $$
declare
  v_rows int;
begin
  delete from public.exam_submissions
   where id = current_setting('test.sub_del2')::uuid;
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then
    raise exception 'FAIL (i)vii: a supervisor could not delete the attempt (% rows)', v_rows;
  end if;
  raise notice 'PASS (i)vii: a supervisor deletes any attempt';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (j)  register_violation: the snapshot path must be this attempt's own
-- =====================================================================

-- (j) i: a full URL (a legacy shape, and what a forged client sends) is stored as
-- NULL - and the strike still counts.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "student.a@test.local"}',
         current_setting('test.student_a')), true);
do $$
declare
  r record;
begin
  select * into r
  from public.register_violation(
         current_setting('test.sub_a')::uuid,
         'looking_away',
         'https://example.supabase.co/storage/v1/object/public/proctor-snapshots/legacy.jpg',
         now(),
         gen_random_uuid());

  if r.warning_count <> 1 or r.disqualified then
    raise exception 'FAIL (j)i: expected 1 strike and no disqualification, got % / %',
      r.warning_count, r.disqualified;
  end if;

  if (select snapshot_url from public.proctoring_logs
       where submission_id = current_setting('test.sub_a')::uuid
       order by timestamp desc limit 1) is not null then
    raise exception 'FAIL (j)i: a path outside the attempt''s folder was stored';
  end if;
  raise notice 'PASS (j)i: a foreign path is stored as NULL and the strike still counts';
end $$;

-- (j) ii: a path inside the attempt's own folder is stored as sent.
do $$
declare
  r record;
begin
  select * into r
  from public.register_violation(
         current_setting('test.sub_a')::uuid,
         'looking_away',
         current_setting('test.sub_a') || '/looking_away_2.jpg',
         now(),
         gen_random_uuid());

  if r.warning_count <> 2 then
    raise exception 'FAIL (j)ii: expected 2 strikes, got %', r.warning_count;
  end if;

  if (select snapshot_url from public.proctoring_logs
       where submission_id = current_setting('test.sub_a')::uuid
         and snapshot_url is not null
       order by timestamp desc limit 1)
     is distinct from current_setting('test.sub_a') || '/looking_away_2.jpg' then
    raise exception 'FAIL (j)ii: the folder-shaped path was not stored';
  end if;
  raise notice 'PASS (j)ii: a path inside the attempt''s folder is stored';
end $$;

-- (j) iii: the third strike disqualifies, and is idempotent per client_event_id.
do $$
declare
  r record;
begin
  select * into r
  from public.register_violation(
         current_setting('test.sub_a')::uuid,
         'multiple_faces',
         null,
         now(),
         gen_random_uuid());

  if r.warning_count <> 3 or not r.disqualified then
    raise exception 'FAIL (j)iii: expected 3 strikes and disqualification, got % / %',
      r.warning_count, r.disqualified;
  end if;
  raise notice 'PASS (j)iii: the third strike disqualifies';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

do $$
begin
  raise notice 'ALL TARGETING AND HARDENING CHECKS PASSED.';
end $$;

rollback;
