-- =====================================================================
-- SUPERVISOR SCOPE RLS TEST  -  run against a LOCAL `supabase start` database
-- =====================================================================
-- Run from the repo root with:
--
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres
--     -f supabase/tests/supervisor_scope_check.sql
--
-- Prerequisites: `supabase start` is running, and `supabase db reset` has applied
-- `supabase/schema.sql` (which carries section 2c/2d on a fresh install) or
-- `supabase/migrations/20261109090000_supervisor_exam_assignments.sql` on an
-- existing project.
--
-- HOW RLS IS APPLIED
--   Identical to `targeting_check.sql`, `weighted_strikes_check.sql`,
--   `proctoring_heartbeats_check.sql` and `proctoring_consents_check.sql`: each
--   block does `set local role authenticated`, sets a `request.jwt.claims` carrying
--   the caller's uuid, runs the check, then `reset role` and blanks the claims
--   before the next fixture write (the claims are transaction-local and would
--   otherwise still be set - and `guard_profile_labels()` refuses a label write from
--   any caller carrying them). The whole file is wrapped in begin; ... rollback; and
--   every fixture is written as `postgres`, so nothing persists.
--
-- WHAT IT PROVES
--   The supervisor scope (`20261109090000_supervisor_exam_assignments.sql`):
--   a supervisor reaches the papers an administrator assigned to them, an
--   administrator reaches every paper without a row, and **a lecturer keeps exactly
--   what they had** - every assertion that names the lecturer below is the shape
--   `lecturer_scoped_log_reads.sql` left behind.
--
--   (a) `can_supervise_exam()` is per paper: admin true everywhere with no row,
--       supervisor true only for the assigned paper, lecturer and student false,
--       and a NULL paper false even for an admin.
--   (b) the console list (`exams_select`): the supervisor is offered the assigned
--       paper and not the other; the lecturer and the admin still see both.
--   (c) the roster (`submissions_select_own_or_supervisor`): the supervisor reads
--       the assigned paper's attempts only; the lecturer still reads every attempt,
--       which is what makes their monitor work on any sitting.
--   (d) the incident feed (`logs_select_own_or_supervisor`): assigned paper only;
--       the lecturer keeps the feed of the paper they wrote, and the student their
--       own row.
--   (e) a still in the private bucket: readable for the assigned paper, refused for
--       the other one, and the owning student is unaffected.
--   (f) `resolve_flagged_attempt()`: refused on the unassigned paper, allowed on the
--       assigned one, the review row it writes is readable afterwards, and an
--       administrator needs no assignment.
--   (g) `submissions_delete_supervisor`: 0 rows deleted on the unassigned paper, 1
--       on the assigned one - the DELETE is scoped exactly like the reads.
--   (h) the SECURITY DEFINER readers: `proctoring_coverage()` and `submit_exam()`
--       refuse the unassigned paper's attempt (42501) and answer on the assigned one
--       - RLS never sees those calls, so the predicate inside them is the only gate.
--   (i) the assignment table itself: an administrator writes it in their own name, a
--       supervisor cannot write it at all, a non-supervisor account is refused by
--       `guard_supervisor_assignment()`, and an UPDATE changes nothing (there is no
--       update policy).
--   (j) demoting the supervisor to lecturer removes the reach on the instant the
--       role changes - `can_supervise_exam()` asks the role as well as the row - and
--       re-promoting restores the sittings it was trusted with.
--   (k) the roster read (`profiles_select_own_or_staff`): the supervisor reads the
--       name of every student on a paper they run - one who sat it, one on its
--       borrow list, one a labelled paper of theirs is aimed at - and, with no
--       assignment, exactly their own row. Another paper's student and another
--       member of staff stay unreadable, and the lecturer and the administrator keep
--       the whole roster.
begin;

-- =====================================================================
-- FIXTURES  (as `postgres`, so no policy applies)
-- =====================================================================
do $$
declare
  v_admin      uuid := gen_random_uuid();
  v_lecturer   uuid := gen_random_uuid();
  v_supervisor uuid := gen_random_uuid();  -- assigned to `v_mine`
  v_peer       uuid := gen_random_uuid();  -- a supervisor with no assignment
  v_s1         uuid := gen_random_uuid();  -- flagged attempt, assigned paper
  v_s2         uuid := gen_random_uuid();  -- flagged attempt, other paper
  v_s3         uuid := gen_random_uuid();  -- ongoing attempt, assigned paper
  v_s4         uuid := gen_random_uuid();  -- ongoing attempt, other paper
  v_mine       uuid := gen_random_uuid();  -- the paper the supervisor was given
  v_theirs     uuid := gen_random_uuid();  -- a paper they were not
  v_sub_mine   uuid := gen_random_uuid();
  v_sub_theirs uuid := gen_random_uuid();
  v_sub_open   uuid := gen_random_uuid();
  v_sub_open2  uuid := gen_random_uuid();
begin
  insert into public.profiles (id, role, full_name, email) values
    (v_admin,      'admin',      'Admin',          'scope.admin@test.local'),
    (v_lecturer,   'lecturer',   'Lecturer',       'scope.lecturer@test.local'),
    (v_supervisor, 'supervisor', 'Assigned Sup',   'scope.supervisor@test.local'),
    (v_peer,       'supervisor', 'Unassigned Sup', 'scope.peer@test.local'),
    (v_s1,         'student',    'Student One',    'scope.s1@test.local'),
    (v_s2,         'student',    'Student Two',    'scope.s2@test.local'),
    (v_s3,         'student',    'Student Three',  'scope.s3@test.local'),
    (v_s4,         'student',    'Student Four',   'scope.s4@test.local');

  -- Two published papers, both written by the lecturer: the scope is about the
  -- *supervisor's* reach, and giving the lecturer both papers is what lets the
  -- "unchanged" assertions below compare the two roles on the same rows.
  insert into public.exams (id, title, created_by, duration_minutes, is_published) values
    (v_mine,   'Assigned sitting',   v_lecturer, 60, true),
    (v_theirs, 'Unassigned sitting', v_lecturer, 60, true);

  -- The one row the whole file turns on: the supervisor is assigned to `v_mine`.
  insert into public.supervisor_exam_assignments (exam_id, supervisor_id, assigned_by)
    values (v_mine, v_supervisor, v_admin);

  -- Two flagged attempts (for the review decision) and two running ones (for the
  -- delete and the hand-in), one of each per paper.
  insert into public.exam_submissions
    (id, student_id, exam_id, status, started_at, submitted_at) values
    (v_sub_mine,   v_s1, v_mine,   'flagged_for_review',
     now() - interval '40 minutes', now() - interval '5 minutes'),
    (v_sub_theirs, v_s2, v_theirs, 'flagged_for_review',
     now() - interval '40 minutes', now() - interval '5 minutes'),
    (v_sub_open,   v_s3, v_mine,   'ongoing', now() - interval '4 minutes', null),
    (v_sub_open2,  v_s4, v_theirs, 'ongoing', now() - interval '4 minutes', null);

  -- One incident per flagged attempt, so the feed has a row on each side.
  insert into public.proctoring_logs (submission_id, action_type) values
    (v_sub_mine,   'looking_away'),
    (v_sub_theirs, 'looking_away');

  -- One still per attempt folder, in the convention the bucket, the upload policy
  -- and the purge share (`<submission_id>/<action_type>_<epoch-ms>.jpg`).
  insert into storage.objects (bucket_id, name) values
    ('proctor-snapshots', v_sub_mine::text   || '/looking_away_1.jpg'),
    ('proctor-snapshots', v_sub_theirs::text || '/looking_away_1.jpg');

  perform set_config('test.admin',      v_admin::text, false);
  perform set_config('test.lecturer',   v_lecturer::text, false);
  perform set_config('test.supervisor', v_supervisor::text, false);
  perform set_config('test.peer',       v_peer::text, false);
  perform set_config('test.s1',         v_s1::text, false);
  perform set_config('test.s2',         v_s2::text, false);
  perform set_config('test.mine',       v_mine::text, false);
  perform set_config('test.theirs',     v_theirs::text, false);
  perform set_config('test.sub_mine',   v_sub_mine::text, false);
  perform set_config('test.sub_theirs', v_sub_theirs::text, false);
  perform set_config('test.sub_open',   v_sub_open::text, false);
  perform set_config('test.sub_open2',  v_sub_open2::text, false);
end $$;


-- =====================================================================
-- (a)  can_supervise_exam(): the per-paper question
-- =====================================================================
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.admin@test.local"}',
         current_setting('test.admin')), true);
do $$
declare
  v_mine   uuid := current_setting('test.mine')::uuid;
  v_theirs uuid := current_setting('test.theirs')::uuid;
begin
  if not public.can_supervise_exam(v_mine)
     or not public.can_supervise_exam(v_theirs) then
    raise exception 'FAIL (a)i: an administrator needs no assignment to supervise a paper';
  end if;
  if public.can_supervise_exam(null) then
    raise exception 'FAIL (a)i: a null paper answered true for an administrator';
  end if;
  raise notice 'PASS (a)i: an administrator supervises every paper without a row';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.supervisor@test.local"}',
         current_setting('test.supervisor')), true);
do $$
begin
  if not public.can_supervise_exam(current_setting('test.mine')::uuid) then
    raise exception 'FAIL (a)ii: the assigned supervisor cannot supervise their own paper';
  end if;
  if public.can_supervise_exam(current_setting('test.theirs')::uuid) then
    raise exception 'FAIL (a)ii: a paper the supervisor was not assigned answered true';
  end if;
  if public.can_supervise_exam(null) then
    raise exception 'FAIL (a)ii: a null paper answered true for a supervisor';
  end if;
  raise notice 'PASS (a)ii: a supervisor supervises exactly the assigned paper';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- A lecturer is not in the scope at all: their reach is `owns_exam()`, which the
-- policies still carry. This predicate answering true for them would mean the author
-- arm had been folded into the wrong place.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.lecturer@test.local"}',
         current_setting('test.lecturer')), true);
do $$
begin
  if public.can_supervise_exam(current_setting('test.mine')::uuid)
     or public.can_supervise_exam(current_setting('test.theirs')::uuid) then
    raise exception 'FAIL (a)iii: a lecturer answered the supervisor predicate';
  end if;
  raise notice 'PASS (a)iii: a lecturer is out of the supervisor scope (owns_exam() covers them)';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.s1@test.local"}',
         current_setting('test.s1')), true);
do $$
begin
  if public.can_supervise_exam(current_setting('test.mine')::uuid) then
    raise exception 'FAIL (a)iv: a student answered the supervisor predicate';
  end if;
  raise notice 'PASS (a)iv: a student is out of the supervisor scope';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);


-- =====================================================================
-- (b)  exams_select: the console's list
-- =====================================================================
-- The supervisor console lists `publishedExamsProvider`, which is this policy. The
-- assigned paper is offered; the other one is not offered at all - which is what the
-- empty state on that console is for when there is no assignment either.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.supervisor@test.local"}',
         current_setting('test.supervisor')), true);
do $$
declare
  v_visible int;
begin
  select count(*) into v_visible
  from public.exams
  where id in (current_setting('test.mine')::uuid,
               current_setting('test.theirs')::uuid);

  if v_visible <> 1 then
    raise exception 'FAIL (b): a supervisor was offered % papers, expected 1', v_visible;
  end if;
  if not exists (select 1 from public.exams
                  where id = current_setting('test.mine')::uuid) then
    raise exception 'FAIL (b): the assigned paper is missing from the supervisor list';
  end if;
  raise notice 'PASS (b): a supervisor is offered the assigned paper only';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- The lecturer still sees both papers - the "exactly what they had" half.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.lecturer@test.local"}',
         current_setting('test.lecturer')), true);
do $$
declare
  v_visible int;
begin
  select count(*) into v_visible
  from public.exams
  where id in (current_setting('test.mine')::uuid,
               current_setting('test.theirs')::uuid);

  if v_visible <> 2 then
    raise exception 'FAIL (b)ii: a lecturer now sees % papers, expected both', v_visible;
  end if;
  raise notice 'PASS (b)ii: a lecturer still sees every paper';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (c)  the roster: submissions_select_own_or_supervisor
-- =====================================================================
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.supervisor@test.local"}',
         current_setting('test.supervisor')), true);
do $$
declare
  v_visible int;
begin
  select count(*) into v_visible
  from public.exam_submissions
  where exam_id in (current_setting('test.mine')::uuid,
                    current_setting('test.theirs')::uuid);

  if v_visible <> 2 then
    raise exception 'FAIL (c): a supervisor read % attempts, expected the 2 on the assigned paper', v_visible;
  end if;
  raise notice 'PASS (c): a supervisor reads the assigned paper''s roster only';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.lecturer@test.local"}',
         current_setting('test.lecturer')), true);
do $$
declare
  v_visible int;
begin
  select count(*) into v_visible
  from public.exam_submissions
  where exam_id in (current_setting('test.mine')::uuid,
                    current_setting('test.theirs')::uuid);

  if v_visible <> 4 then
    raise exception 'FAIL (c)ii: a lecturer now reads % attempts, expected all 4', v_visible;
  end if;
  raise notice 'PASS (c)ii: a lecturer still reads every attempt (unchanged)';
end $$;
reset role;

-- =====================================================================
-- (d)  the incident feed: logs_select_own_or_supervisor
-- =====================================================================
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.supervisor@test.local"}',
         current_setting('test.supervisor')), true);
do $$
declare
  v_visible int;
begin
  select count(*) into v_visible
  from public.proctoring_logs
  where submission_id in (current_setting('test.sub_mine')::uuid,
                          current_setting('test.sub_theirs')::uuid);

  if v_visible <> 1 then
    raise exception 'FAIL (d): a supervisor read % incidents, expected the assigned paper''s one', v_visible;
  end if;
  raise notice 'PASS (d): a supervisor reads the assigned paper''s incidents only';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- The lecturer keeps the feed of the paper they wrote (`owns_exam()`), which is what
-- this file must not disturb.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.lecturer@test.local"}',
         current_setting('test.lecturer')), true);
do $$
declare
  v_visible int;
begin
  select count(*) into v_visible
  from public.proctoring_logs
  where submission_id in (current_setting('test.sub_mine')::uuid,
                          current_setting('test.sub_theirs')::uuid);

  if v_visible <> 2 then
    raise exception 'FAIL (d)ii: a lecturer now reads % incidents, expected both', v_visible;
  end if;
  raise notice 'PASS (d)ii: a lecturer still reads their own paper''s incidents';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (e)  a still in the private bucket
-- =====================================================================
-- The read policy now resolves the folder to the attempt and asks
-- `can_supervise_exam()`; the orphaned window after a delete is the purge policy's,
-- proven in `targeting_check.sql` (i)viii-ix.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.supervisor@test.local"}',
         current_setting('test.supervisor')), true);
do $$
declare
  v_mine   int;
  v_theirs int;
begin
  select count(*) into v_mine
  from storage.objects
  where bucket_id = 'proctor-snapshots'
    and name like current_setting('test.sub_mine') || '/%';

  select count(*) into v_theirs
  from storage.objects
  where bucket_id = 'proctor-snapshots'
    and name like current_setting('test.sub_theirs') || '/%';

  if v_mine <> 1 then
    raise exception 'FAIL (e): the supervisor cannot read the assigned paper''s still (%)', v_mine;
  end if;
  if v_theirs <> 0 then
    raise exception 'FAIL (e): the supervisor read % still(s) of an unassigned paper', v_theirs;
  end if;
  raise notice 'PASS (e): a still follows the paper it belongs to';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (f)  the review decision: resolve_flagged_attempt()
-- =====================================================================
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.supervisor@test.local"}',
         current_setting('test.supervisor')), true);
do $$
declare
  r record;
begin
  begin
    perform public.resolve_flagged_attempt(
      current_setting('test.sub_theirs')::uuid, 'disqualify', 'not mine');
    raise exception 'FAIL (f): a supervisor resolved an attempt on an unassigned paper';
  exception when insufficient_privilege then
    raise notice 'PASS (f): an unassigned paper''s attempt cannot be resolved';
  end;

  select * into r from public.resolve_flagged_attempt(
    current_setting('test.sub_mine')::uuid, 'disqualify', 'held the assigned sitting');
  if r.new_status <> 'disqualified' then
    raise exception 'FAIL (f)ii: the assigned paper''s attempt came back as %', r.new_status;
  end if;

  -- ...and the audit row it just wrote is readable, because it carries the exam id
  -- this supervisor is assigned to.
  if (select count(*) from public.attempt_review_logs
       where exam_id = current_setting('test.mine')::uuid) <> 1 then
    raise exception 'FAIL (f)iii: the supervisor cannot read the review row it wrote';
  end if;
  raise notice 'PASS (f)ii-iii: the assigned paper''s attempt is resolved, and audited';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- An administrator needs no assignment for either paper.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.admin@test.local"}',
         current_setting('test.admin')), true);
do $$
declare
  r record;
begin
  select * into r from public.resolve_flagged_attempt(
    current_setting('test.sub_theirs')::uuid, 'clear', 'administrator reviewed it');
  if r.new_status <> 'submitted' then
    raise exception 'FAIL (f)iv: an administrator''s clear produced %', r.new_status;
  end if;
  raise notice 'PASS (f)iv: an administrator resolves any paper without an assignment';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);


-- =====================================================================
-- (g)  the delete: submissions_delete_supervisor
-- =====================================================================
-- The DELETE is the destructive half of "Reset attempt", so it is scoped exactly
-- like the reads: 0 rows on a paper this account was not given (the console reads
-- that zero and stops before purging or auditing), 1 on the paper it runs.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.supervisor@test.local"}',
         current_setting('test.supervisor')), true);
do $$
declare
  v_deleted int;
begin
  delete from public.exam_submissions
   where id = current_setting('test.sub_theirs')::uuid;
  get diagnostics v_deleted = row_count;
  if v_deleted <> 0 then
    raise exception 'FAIL (g): a supervisor deleted % attempt(s) on an unassigned paper', v_deleted;
  end if;
  raise notice 'PASS (g): an unassigned paper''s attempt is not deletable';

  delete from public.exam_submissions
   where id = current_setting('test.sub_open')::uuid;
  get diagnostics v_deleted = row_count;
  if v_deleted <> 1 then
    raise exception 'FAIL (g)ii: the assigned paper''s attempt deleted % rows, expected 1', v_deleted;
  end if;
  raise notice 'PASS (g)ii: the assigned paper''s attempt is deletable';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (h)  the SECURITY DEFINER RPCs: RLS never sees these calls
-- =====================================================================
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.supervisor@test.local"}',
         current_setting('test.supervisor')), true);
do $$
declare
  v_rows int;
  r      record;
begin
  begin
    perform 1 from public.proctoring_coverage(current_setting('test.sub_theirs')::uuid);
    raise exception 'FAIL (h): coverage of an unassigned attempt was served';
  exception when insufficient_privilege then
    raise notice 'PASS (h): coverage of an unassigned attempt is refused';
  end;

  select count(*) into v_rows
  from public.proctoring_coverage(current_setting('test.sub_mine')::uuid);
  if v_rows <> 1 then
    raise exception 'FAIL (h)ii: coverage of the assigned attempt returned % rows', v_rows;
  end if;
  raise notice 'PASS (h)ii: coverage of the assigned attempt is served';

  begin
    perform 1 from public.submit_exam(current_setting('test.sub_open2')::uuid, false);
    raise exception 'FAIL (h)iii: submit_exam closed an unassigned paper''s attempt';
  exception when insufficient_privilege then
    raise notice 'PASS (h)iii: a hand-in is refused on an unassigned paper';
  end;

  -- The assigned paper's attempt is closed already (disqualified in (f)), so the
  -- RPC answers with the stored outcome rather than raising: what this proves is
  -- that the tier check let the call through.
  select * into r from public.submit_exam(current_setting('test.sub_mine')::uuid, false);
  if r.result_status <> 'disqualified' then
    raise exception 'FAIL (h)iv: the assigned attempt answered %', r.result_status;
  end if;
  raise notice 'PASS (h)iv: a hand-in on the assigned paper is allowed';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (i)  the assignment table itself
-- =====================================================================
-- A supervisor cannot grant themselves a paper (this is the whole point of the
-- table), an administrator writes it in their own name, and `assigned_by` is the
-- database's answer rather than a client's claim.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.supervisor@test.local"}',
         current_setting('test.supervisor')), true);
do $$
begin
  begin
    insert into public.supervisor_exam_assignments (exam_id, supervisor_id, assigned_by)
      values (current_setting('test.theirs')::uuid,
              current_setting('test.supervisor')::uuid,
              current_setting('test.supervisor')::uuid);
    raise exception 'FAIL (i): a supervisor assigned themselves a paper';
  exception when insufficient_privilege then
    raise notice 'PASS (i): a supervisor cannot write the assignment table';
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.admin@test.local"}',
         current_setting('test.admin')), true);
do $$
declare
  v_rows  int;
  v_after int;
begin
  -- The row the console writes: no `assigned_by` in the payload, so the column
  -- defaults to the caller. An assignment for a second supervisor on the other paper.
  insert into public.supervisor_exam_assignments (exam_id, supervisor_id)
    values (current_setting('test.theirs')::uuid, current_setting('test.peer')::uuid);

  select count(*) into v_rows
  from public.supervisor_exam_assignments
  where exam_id = current_setting('test.theirs')::uuid;
  if v_rows <> 1 then
    raise exception 'FAIL (i)ii: the administrator''s insert left % rows', v_rows;
  end if;

  -- A non-supervisor account is refused by the guard, not silently accepted into a
  -- grant that could never do anything.
  begin
    insert into public.supervisor_exam_assignments (exam_id, supervisor_id)
      values (current_setting('test.mine')::uuid, current_setting('test.s2')::uuid);
    raise exception 'FAIL (i)iii: a student was assigned a paper';
  exception when check_violation then
    raise notice 'PASS (i)iii: only a supervisor account may be assigned';
  end;

  -- No UPDATE policy: the row is a fact, and re-aiming it is a different assignment.
  update public.supervisor_exam_assignments
     set assigned_at = now()
   where supervisor_id = current_setting('test.peer')::uuid;
  get diagnostics v_after = row_count;
  if v_after <> 0 then
    raise exception 'FAIL (i)iv: % assignment row(s) were updated', v_after;
  end if;
  raise notice 'PASS (i)iv: an assignment cannot be rewritten in place';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (j)  the role is asked as well as the row
-- =====================================================================
-- A supervisor demoted to lecturer keeps their assignment rows (nothing deletes
-- them), and must lose the reach on that instant rather than when somebody clears up.
do $$
begin
  update public.profiles
     set role = 'lecturer'
   where id = current_setting('test.supervisor')::uuid;
end $$;

set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.supervisor@test.local"}',
         current_setting('test.supervisor')), true);
do $$
begin
  if public.can_supervise_exam(current_setting('test.mine')::uuid) then
    raise exception 'FAIL (j): a demoted account kept the supervisor reach';
  end if;
  raise notice 'PASS (j): demoting the account removes the reach immediately';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- ...and re-promoting restores the sittings it was trusted with.
do $$
begin
  update public.profiles
     set role = 'supervisor'
   where id = current_setting('test.supervisor')::uuid;
end $$;

set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.supervisor@test.local"}',
         current_setting('test.supervisor')), true);
do $$
begin
  if not public.can_supervise_exam(current_setting('test.mine')::uuid) then
    raise exception 'FAIL (j)ii: re-promoting did not restore the assignment';
  end if;
  raise notice 'PASS (j)ii: re-promoting restores the committed sittings';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (k)  the roster read: profiles_select_own_or_staff
-- =====================================================================
-- The one supervisor arm that asked no per-paper question at all, and the widest
-- hole in the set: `is_staff()` let any supervisor read *every* profile row in the
-- institution - name, matriculation number, faculty, department, level, photograph -
-- assigned or not, sitting or not. The supervisor console's names come from exactly
-- this read (`accountNamesProvider` in supervisor_dashboard_page.dart), so the
-- narrowing has to be proved against the rows that console can render.
--
-- Fixtures on top of the ones above: a labelled paper assigned to the same
-- supervisor, a student that paper is aimed at (no attempt), and a student on the
-- assigned paper's borrow list (no attempt).
do $$
declare
  v_targeted uuid := gen_random_uuid();
  v_borrower uuid := gen_random_uuid();
  v_lab      uuid := gen_random_uuid();
begin
  insert into public.profiles (id, role, full_name, email, faculty, department, level) values
    (v_targeted, 'student', 'Student Five', 'scope.s5@test.local', 'Science', 'Physics', '300'),
    (v_borrower, 'student', 'Student Six',  'scope.s6@test.local', null, null, null);

  insert into public.exams (id, title, created_by, duration_minutes, is_published,
                            faculty, department, level) values
    (v_lab, 'Labelled sitting', current_setting('test.lecturer')::uuid, 60, true,
     'Science', 'Physics', '300');

  insert into public.supervisor_exam_assignments (exam_id, supervisor_id, assigned_by) values
    (v_lab, current_setting('test.supervisor')::uuid, current_setting('test.admin')::uuid);

  -- A borrow-list row on the *unlabelled* assigned paper: the other way onto a paper.
  insert into public.exam_allowed_students (exam_id, student_id, created_by) values
    (current_setting('test.mine')::uuid, v_borrower, current_setting('test.admin')::uuid);

  perform set_config('test.targeted', v_targeted::text, false);
  perform set_config('test.borrower', v_borrower::text, false);
end $$;

set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.supervisor@test.local"}',
         current_setting('test.supervisor')), true);
do $$
begin
  -- The monitor's roster: a name for every student with an attempt on a paper this
  -- supervisor runs. Without this the grid prints "Student <uuid>" instead.
  if (select full_name from public.profiles
       where id = current_setting('test.s1')::uuid) is null then
    raise exception 'FAIL (k): the supervisor cannot read a student who sat their paper';
  end if;

  -- A student granted the paper, and a student a labelled paper is aimed at: both
  -- can appear in a roster before an attempt exists.
  if (select full_name from public.profiles
       where id = current_setting('test.borrower')::uuid) is null then
    raise exception 'FAIL (k)ii: the supervisor cannot read a student granted their paper';
  end if;
  if (select full_name from public.profiles
       where id = current_setting('test.targeted')::uuid) is null then
    raise exception 'FAIL (k)iii: the supervisor cannot read a student their labelled paper is aimed at';
  end if;

  -- Always their own row - the role gate reads it to route the console.
  if (select full_name from public.profiles
       where id = current_setting('test.supervisor')::uuid) is null then
    raise exception 'FAIL (k)iv: the supervisor cannot read their own row';
  end if;

  -- ...and nobody else. `test.mine` names no cohort, so an unlabelled paper must not
  -- stand in for "aimed at everybody in the institution".
  if exists (select 1 from public.profiles
              where id = current_setting('test.s2')::uuid) then
    raise exception 'FAIL (k)v: the supervisor read a student on a paper they do not run';
  end if;
  if exists (select 1 from public.profiles
              where id in (current_setting('test.lecturer')::uuid,
                           current_setting('test.admin')::uuid)) then
    raise exception 'FAIL (k)vi: the supervisor read a colleague''s profile row';
  end if;

  raise notice 'PASS (k): the supervisor reads the students on the papers they run, and only those';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- A supervisor with no assignment at all reads exactly one row: their own.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.peer@test.local"}',
         current_setting('test.peer')), true);
do $$
declare
  v_visible int;
begin
  -- Their own row is readable...
  if not exists (select 1 from public.profiles where id = auth.uid()) then
    raise exception 'FAIL (k)vii: a supervisor with no assignment cannot read their own row';
  end if;

  -- ...and nothing else is. Counted as "rows other than mine" rather than "exactly
  -- one row in the table": the total is 1 only on a database nobody has used, and a
  -- live project has as many profile rows as it has - so the question asked is the one
  -- this check is about, whether any *other* row got through.
  select count(*) into v_visible
  from public.profiles
  where id <> auth.uid();

  if v_visible <> 0 then
    raise exception 'FAIL (k)vii: a supervisor with no assignment read % other profile row(s)', v_visible;
  end if;
  raise notice 'PASS (k)vii: a supervisor with no assignment sees only their own row';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);


-- ...and the two roles that were never narrowed keep the whole roster. This is the
-- "unchanged" half, and it is the read the marking queue (`_namesFor()` in
-- question_authoring_repository_impl.dart) and the admin console go through.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.lecturer@test.local"}',
         current_setting('test.lecturer')), true);
do $$
declare
  v_visible int;
begin
  select count(*) into v_visible
  from public.profiles
  where id in (current_setting('test.s1')::uuid,
               current_setting('test.s2')::uuid,
               current_setting('test.peer')::uuid,
               current_setting('test.admin')::uuid,
               current_setting('test.borrower')::uuid,
               current_setting('test.targeted')::uuid);

  if v_visible <> 6 then
    raise exception 'FAIL (k)viii: a lecturer reads % of the 6 other rows, expected all of them', v_visible;
  end if;
  raise notice 'PASS (k)viii: a lecturer keeps the whole roster (unchanged)';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "scope.admin@test.local"}',
         current_setting('test.admin')), true);
do $$
declare
  v_visible int;
begin
  select count(*) into v_visible
  from public.profiles
  where id in (current_setting('test.s1')::uuid,
               current_setting('test.s2')::uuid,
               current_setting('test.peer')::uuid,
               current_setting('test.lecturer')::uuid,
               current_setting('test.borrower')::uuid,
               current_setting('test.targeted')::uuid);

  if v_visible <> 6 then
    raise exception 'FAIL (k)ix: an administrator reads % of the 6 other rows, expected all of them', v_visible;
  end if;
  raise notice 'PASS (k)ix: an administrator keeps the whole roster (no assignment needed)';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);


-- Nothing here persists: every fixture above is rolled back.
rollback;

select set_config('request.jwt.claims', '', true);
