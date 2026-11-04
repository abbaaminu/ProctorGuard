-- =====================================================================
-- WEIGHTED STRIKES TEST  -  run against a LOCAL `supabase start` database
-- =====================================================================
-- Run from the repo root with:
--
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres
--     -f supabase/tests/weighted_strikes_check.sql
--
-- Prerequisites: `supabase start` is running, and `supabase db reset` has applied
-- `supabase/schema.sql` (which already carries both 2026110409*.sql changes), or
-- those two migrations have been applied by hand.
--
-- WHAT IT PROVES
--   (a) `violation_weights` has a row for every `action_type`
--       `proctoring_logs_action_type_check` allows - the vocabulary is read out of
--       the constraint itself, so a new type added there without a weight fails
--       here rather than silently scoring as hard.
--   (b) three SOFT signals do not flag: they are stored as evidence, the count
--       rises, and the attempt stays 'ongoing'.
--   (c) three HARD signals flag: the attempt becomes 'flagged_for_review', the
--       sitting is closed (`submitted_at`), and no score is written.
--   (d) a MIXED history flags only when the counted signals reach three: two hard
--       plus a pile of soft is still 'ongoing', and the third hard one flags it.
--   (e) replaying one `client_event_id` adds nothing: the row count, the reported
--       `warning_count` and the weighted decision are all unchanged, so a retry
--       after a lost response can never cross the threshold twice.
--   (f) `resolve_flagged_attempt` is supervisor-only: the student cannot call it,
--       the lecturer who did not write the paper cannot call it, the author and a
--       supervisor can - and the decision writes exactly one `attempt_review_logs`
--       row, which a replay does not duplicate.
--   (g) `grade_submission` refuses an attempt under review.
--
-- HOW RLS IS APPLIED
--   Identical to `targeting_check.sql`: `set local role authenticated` plus a
--   `request.jwt.claims` carrying the caller's uuid, then `reset role` and a blank
--   claims string before the next fixture write (`guard_profile_labels()` refuses a
--   label write from a caller holding claims).
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

-- ---------------------------------------------------------------------
-- Fixtures (as postgres: no claims, RLS bypassed)
-- ---------------------------------------------------------------------
do $$
declare
  v_lecturer_a uuid := gen_random_uuid();   -- wrote the paper
  v_lecturer_b uuid := gen_random_uuid();   -- did not
  v_supervisor uuid := gen_random_uuid();
  v_soft       uuid := gen_random_uuid();   -- (b) three soft signals
  v_hard       uuid := gen_random_uuid();   -- (c) three hard signals
  v_mixed      uuid := gen_random_uuid();   -- (d) two hard + soft, then a third hard
  v_replay     uuid := gen_random_uuid();   -- (e) the same event twice
  v_review     uuid := gen_random_uuid();   -- (f)/(g) resolved, then graded
  v_exam       uuid := gen_random_uuid();
begin
  insert into public.profiles (id, role, full_name, email, faculty, department, level)
    values
      (v_lecturer_a, 'lecturer',   'Lecturer A', 'lecturer.a@test.local', 'Science', 'CS', null),
      (v_lecturer_b, 'lecturer',   'Lecturer B', 'lecturer.b@test.local', 'Science', 'CS', null),
      (v_supervisor, 'supervisor', 'Supervisor', 'supervisor@test.local', 'Science', 'CS', null),
      (v_soft,       'student',    'Student Soft',   'soft@test.local',   null, null, null),
      (v_hard,       'student',    'Student Hard',   'hard@test.local',   null, null, null),
      (v_mixed,      'student',    'Student Mixed',  'mixed@test.local',  null, null, null),
      (v_replay,     'student',    'Student Replay', 'replay@test.local', null, null, null),
      (v_review,     'student',    'Student Review', 'review@test.local', null, null, null);

  -- One untargeted, published paper: these checks are about the escalation rule,
  -- not about who may sit what (targeting_check.sql owns that).
  insert into public.exams (id, title, created_by, duration_minutes, is_published)
    values (v_exam, 'Weighted strikes paper', v_lecturer_a, 60, true);

  insert into public.questions (exam_id, question_text, question_type, points)
    values (v_exam, 'Q1', 'subjective', 1);

  -- One 'ongoing' attempt per student. Written as postgres, so no policy applies;
  -- 'ongoing' is the state register_violation() accepts.
  insert into public.exam_submissions (student_id, exam_id, status)
    values
      (v_soft,   v_exam, 'ongoing'),
      (v_hard,   v_exam, 'ongoing'),
      (v_mixed,  v_exam, 'ongoing'),
      (v_replay, v_exam, 'ongoing'),
      (v_review, v_exam, 'ongoing');

  perform set_config('test.lecturer_a', v_lecturer_a::text, false);
  perform set_config('test.lecturer_b', v_lecturer_b::text, false);
  perform set_config('test.supervisor', v_supervisor::text, false);
  perform set_config('test.soft',   v_soft::text, false);
  perform set_config('test.hard',   v_hard::text, false);
  perform set_config('test.mixed',  v_mixed::text, false);
  perform set_config('test.replay', v_replay::text, false);
  perform set_config('test.review', v_review::text, false);
  perform set_config('test.exam',   v_exam::text, false);

  perform set_config('test.sub_soft',
    (select id::text from public.exam_submissions where student_id = v_soft), false);
  perform set_config('test.sub_hard',
    (select id::text from public.exam_submissions where student_id = v_hard), false);
  perform set_config('test.sub_mixed',
    (select id::text from public.exam_submissions where student_id = v_mixed), false);
  perform set_config('test.sub_replay',
    (select id::text from public.exam_submissions where student_id = v_replay), false);
  perform set_config('test.sub_review',
    (select id::text from public.exam_submissions where student_id = v_review), false);
end $$;

-- =====================================================================
-- (a)  Every allowed action_type has a weight
-- =====================================================================
-- The vocabulary is read out of the live CHECK constraint, not copied: a type
-- added there without a `violation_weights` row would still score (as hard, fail
-- closed), but nobody would have decided that - which is the situation this check
-- exists to catch.
do $$
declare
  v_missing text;
  v_count   int;
begin
  with def as (
    select pg_get_constraintdef(oid) as d
    from pg_constraint
    where conrelid = 'public.proctoring_logs'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) like '%action_type%'
  ), listed as (
    select distinct (regexp_matches(d, '''([a-z_]+)''', 'g'))[1] as action_type
    from def
  )
  select coalesce(string_agg(l.action_type, ', ' order by l.action_type), '')
    into v_missing
  from listed l
  where not exists (
    select 1 from public.violation_weights w where w.action_type = l.action_type
  );

  if v_missing <> '' then
    raise exception 'FAIL (a): no violation_weights row for: %', v_missing;
  end if;

  select count(*) into v_count from public.violation_weights;
  if v_count <> 11 then
    raise exception 'FAIL (a): expected 11 weighted action types, found %', v_count;
  end if;
  raise notice 'PASS (a): every allowed action_type has a weight';
end $$;

-- =====================================================================
-- (b)  Three (in fact five) SOFT signals do not flag
-- =====================================================================
-- The evidence is still stored - every one of these rows is in proctoring_logs -
-- and the student is still warned; what must not happen is the attempt ending.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "soft@test.local"}',
         current_setting('test.soft')), true);
do $$
declare
  v_sub uuid := current_setting('test.sub_soft')::uuid;
  r     record;
begin
  select * into r from public.register_violation(v_sub, 'right_click_blocked', null, now(), gen_random_uuid());
  select * into r from public.register_violation(v_sub, 'copy_paste_attempt',  null, now(), gen_random_uuid());
  select * into r from public.register_violation(v_sub, 'looking_away',       null, now(), gen_random_uuid());

  if r.disqualified or r.flagged then
    raise exception 'FAIL (b): three soft signals ended the attempt (count %, disqualified %, flagged %)',
      r.warning_count, r.disqualified, r.flagged;
  end if;

  -- The remaining two soft types, to prove "every soft type" rather than "the
  -- first three". Five rows, still nothing.
  select * into r from public.register_violation(v_sub, 'audio_noise', null, now(), gen_random_uuid());
  select * into r from public.register_violation(v_sub, 'idle_afk',    null, now(), gen_random_uuid());

  if r.disqualified or r.flagged then
    raise exception 'FAIL (b): five soft signals ended the attempt';
  end if;
  if r.warning_count <> 5 then
    raise exception 'FAIL (b): expected 5 stored rows, RPC reported %', r.warning_count;
  end if;
  raise notice 'PASS (b): five soft signals stored, attempt still ongoing';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

do $$
begin
  if (select status from public.exam_submissions
       where id = current_setting('test.sub_soft')::uuid) <> 'ongoing' then
    raise exception 'FAIL (b): a soft-only attempt is not ongoing';
  end if;
  if (select count(*) from public.proctoring_logs
       where submission_id = current_setting('test.sub_soft')::uuid) <> 5 then
    raise exception 'FAIL (b): soft evidence was not stored';
  end if;
  raise notice 'PASS (b): all five soft signals are on the record';
end $$;

-- =====================================================================
-- (c)  Three HARD signals flag the attempt
-- =====================================================================
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "hard@test.local"}',
         current_setting('test.hard')), true);
do $$
declare
  v_sub uuid := current_setting('test.sub_hard')::uuid;
  r     record;
begin
  select * into r from public.register_violation(v_sub, 'multiple_faces', null, now(), gen_random_uuid());
  if r.flagged or r.disqualified then
    raise exception 'FAIL (c): one hard signal ended the attempt';
  end if;

  select * into r from public.register_violation(v_sub, 'no_face', null, now(), gen_random_uuid());
  if r.flagged or r.disqualified then
    raise exception 'FAIL (c): two hard signals ended the attempt';
  end if;

  select * into r from public.register_violation(v_sub, 'app_minimized', null, now(), gen_random_uuid());
  if not r.flagged then
    raise exception 'FAIL (c): three hard signals did not flag the attempt';
  end if;
  if r.disqualified then
    raise exception 'FAIL (c): the threshold disqualified the attempt instead of flagging it';
  end if;
  if r.warning_count <> 3 then
    raise exception 'FAIL (c): expected 3 stored rows, RPC reported %', r.warning_count;
  end if;
  raise notice 'PASS (c): three hard signals flag the attempt';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

do $$
declare
  v_sub public.exam_submissions;
begin
  select * into v_sub from public.exam_submissions
   where id = current_setting('test.sub_hard')::uuid;

  if v_sub.status <> 'flagged_for_review' then
    raise exception 'FAIL (c): status is %, expected flagged_for_review', v_sub.status;
  end if;
  -- The sitting is over and nothing is marked: a score here would imply a decision
  -- nobody has made.
  if v_sub.submitted_at is null then
    raise exception 'FAIL (c): a flagged attempt was left open (submitted_at is null)';
  end if;
  if v_sub.score is not null then
    raise exception 'FAIL (c): a flagged attempt carries a score (%)', v_sub.score;
  end if;
  raise notice 'PASS (c): the flagged attempt is closed and unmarked';
end $$;

-- =====================================================================
-- (d)  Mixed: only the counted signals add up
-- =====================================================================
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "mixed@test.local"}',
         current_setting('test.mixed')), true);
do $$
declare
  v_sub uuid := current_setting('test.sub_mixed')::uuid;
  r     record;
begin
  -- This is the shape the old rule got wrong: three incidents, one of them hard,
  -- and the two soft ones must not push it over.
  select * into r from public.register_violation(v_sub, 'multiple_faces',      null, now(), gen_random_uuid());
  select * into r from public.register_violation(v_sub, 'copy_paste_attempt',  null, now(), gen_random_uuid());
  select * into r from public.register_violation(v_sub, 'right_click_blocked', null, now(), gen_random_uuid());

  if r.flagged or r.disqualified then
    raise exception 'FAIL (d): one hard + two soft flagged the attempt (three rows, one point)';
  end if;
  if r.warning_count <> 3 then
    raise exception 'FAIL (d): expected 3 rows, RPC reported %', r.warning_count;
  end if;

  -- A fourth row, still only two weighted points: "four incidents" is not the rule.
  select * into r from public.register_violation(v_sub, 'no_face', null, now(), gen_random_uuid());
  if r.flagged or r.disqualified then
    raise exception 'FAIL (d): two hard + two soft flagged the attempt';
  end if;

  -- The third counted signal is the one that matters.
  select * into r from public.register_violation(v_sub, 'secondary_display_detected', null, now(), gen_random_uuid());
  if not r.flagged then
    raise exception 'FAIL (d): the third counted signal did not flag the attempt';
  end if;
  raise notice 'PASS (d): the flag follows the weighted score, not the row count';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (e)  Replaying one client_event_id adds nothing
-- =====================================================================
-- This is what makes the offline queue safe: the retry carries the id minted when
-- the event was seen, so a request whose response was lost inserts the row once.
-- The weighted score is recomputed from the rows, so it cannot double either.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "replay@test.local"}',
         current_setting('test.replay')), true);
do $$
declare
  v_sub   uuid := current_setting('test.sub_replay')::uuid;
  v_event uuid := gen_random_uuid();
  r       record;
begin
  -- The same soft event delivered twice.
  select * into r from public.register_violation(v_sub, 'right_click_blocked', null, now(), v_event);
  if r.warning_count <> 1 then
    raise exception 'FAIL (e): the first delivery reported % rows, expected 1', r.warning_count;
  end if;
  select * into r from public.register_violation(v_sub, 'right_click_blocked', null, now(), v_event);
  if r.warning_count <> 1 then
    raise exception 'FAIL (e): a replayed event became a second row (count %)', r.warning_count;
  end if;

  -- Two counted signals, then the third - which is also the id that gets replayed.
  select * into r from public.register_violation(v_sub, 'no_face', null, now(), gen_random_uuid());
  select * into r from public.register_violation(v_sub, 'multiple_faces', null, now(), gen_random_uuid());
  if r.flagged then
    raise exception 'FAIL (e): the attempt flagged at two weighted points';
  end if;

  v_event := gen_random_uuid();
  select * into r from public.register_violation(v_sub, 'devtools_detected', null, now(), v_event);
  if not r.flagged or r.warning_count <> 4 then
    raise exception 'FAIL (e): the third counted signal did not flag (count %, flagged %)',
      r.warning_count, r.flagged;
  end if;

  -- The replay of *that* event, after the attempt closed: no row, no second ending.
  select * into r from public.register_violation(v_sub, 'devtools_detected', null, now(), v_event);
  if r.warning_count <> 4 or not r.flagged then
    raise exception 'FAIL (e): replaying the flagging event changed the ruling (count %, flagged %)',
      r.warning_count, r.flagged;
  end if;
  raise notice 'PASS (e): a replayed client_event_id adds no row and no second flag';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

do $$
begin
  if (select count(*) from public.proctoring_logs
       where submission_id = current_setting('test.sub_replay')::uuid) <> 4 then
    raise exception 'FAIL (e): expected 4 stored rows after the replays';
  end if;
  raise notice 'PASS (e): four rows on the record, two deliveries of one of them';
end $$;

-- =====================================================================
-- (f)  The review decision is supervisor-only, and it is audited
-- =====================================================================
-- Flag the reviewing student's attempt first (three hard signals), then try to
-- resolve it from every tier.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "review@test.local"}',
         current_setting('test.review')), true);
do $$
declare
  v_sub uuid := current_setting('test.sub_review')::uuid;
  r     record;
begin
  select * into r from public.register_violation(v_sub, 'multiple_faces', null, now(), gen_random_uuid());
  select * into r from public.register_violation(v_sub, 'no_face', null, now(), gen_random_uuid());
  select * into r from public.register_violation(v_sub, 'app_minimized', null, now(), gen_random_uuid());
  if not r.flagged then
    raise exception 'FAIL (f): the fixture attempt did not reach flagged_for_review';
  end if;
  raise notice 'PASS (f): fixture attempt is under review';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (f) i: the attempt under review cannot be marked yet.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "lecturer.a@test.local"}',
         current_setting('test.lecturer_a')), true);
do $$
begin
  begin
    perform public.grade_submission(current_setting('test.sub_review')::uuid, '{}'::jsonb);
    raise exception 'FAIL (f)i: a flagged attempt was marked';
  exception when sqlstate '55000' then
    raise notice 'PASS (f)i: grade_submission refuses an attempt under review';
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);


-- (f) ii: the account under review does not get a vote.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "review@test.local"}',
         current_setting('test.review')), true);
do $$
begin
  begin
    perform public.resolve_flagged_attempt(
      current_setting('test.sub_review')::uuid, 'clear', 'let me off');
    raise exception 'FAIL (f)ii: a student resolved their own review';
  exception when insufficient_privilege then
    raise notice 'PASS (f)ii: a student cannot call resolve_flagged_attempt';
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (f) iii: a lecturer who did not write the paper is refused - the same tier rule
-- as deleting an attempt.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "lecturer.b@test.local"}',
         current_setting('test.lecturer_b')), true);
do $$
begin
  begin
    perform public.resolve_flagged_attempt(
      current_setting('test.sub_review')::uuid, 'disqualify', 'not my paper');
    raise exception 'FAIL (f)iii: a lecturer resolved another lecturer''s attempt';
  exception when insufficient_privilege then
    raise notice 'PASS (f)iii: a lecturer cannot resolve another lecturer''s attempt';
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (f) iv: the paper's author can, and "clear" puts the attempt back in the
-- gradable state.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "lecturer.a@test.local"}',
         current_setting('test.lecturer_a')), true);
do $$
declare
  r record;
begin
  select * into r from public.resolve_flagged_attempt(
    current_setting('test.sub_review')::uuid, 'clear', 'Camera glitch, answers fine.');
  if r.new_status <> 'submitted' then
    raise exception 'FAIL (f)iv: resolving with "clear" produced %', r.new_status;
  end if;
  raise notice 'PASS (f)iv: the author cleared the attempt';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

do $$
declare
  v_sub public.exam_submissions;
  v_log public.attempt_review_logs;
begin
  select * into v_sub from public.exam_submissions
   where id = current_setting('test.sub_review')::uuid;
  if v_sub.status <> 'submitted' then
    raise exception 'FAIL (f)iv: the cleared attempt is %, expected submitted', v_sub.status;
  end if;
  -- "Gradable" means the automatic mark has been computed, not that a score
  -- survived the review.
  if v_sub.score is distinct from 0 then
    raise exception 'FAIL (f)iv: the cleared attempt carries score % (expected 0 from no answers)', v_sub.score;
  end if;

  select * into v_log from public.attempt_review_logs
   where submission_id = current_setting('test.sub_review')::uuid;
  if v_log.decision <> 'clear'
     or v_log.from_status <> 'flagged_for_review'
     or v_log.to_status <> 'submitted'
     or v_log.actor_id <> current_setting('test.lecturer_a')::uuid
     or v_log.note is null then
    raise exception 'FAIL (f)iv: the audit row is wrong: % / % -> % by % (%)',
      v_log.decision, v_log.from_status, v_log.to_status, v_log.actor_id, v_log.note;
  end if;
  raise notice 'PASS (f)iv: one audit row records who decided what, and why';
end $$;



-- (f) v: replaying the decision is idempotent - no second audit row.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "lecturer.a@test.local"}',
         current_setting('test.lecturer_a')), true);
do $$
declare
  r record;
begin
  select * into r from public.resolve_flagged_attempt(
    current_setting('test.sub_review')::uuid, 'clear', 'replayed');
  if r.new_status <> 'submitted' then
    raise exception 'FAIL (f)v: a replayed decision answered %', r.new_status;
  end if;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

do $$
begin
  if (select count(*) from public.attempt_review_logs
       where submission_id = current_setting('test.sub_review')::uuid) <> 1 then
    raise exception 'FAIL (f)v: a replayed decision wrote a second audit row';
  end if;
  raise notice 'PASS (f)v: replaying the decision writes nothing';
end $$;

-- (f) vi: a supervisor resolves another paper's attempt, and "disqualify" sticks.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "supervisor@test.local"}',
         current_setting('test.supervisor')), true);
do $$
declare
  r record;
begin
  select * into r from public.resolve_flagged_attempt(
    current_setting('test.sub_mixed')::uuid, 'disqualify', 'Second screen on camera.');
  if r.new_status <> 'disqualified' then
    raise exception 'FAIL (f)vi: a supervisor disqualification produced %', r.new_status;
  end if;
  raise notice 'PASS (f)vi: a supervisor disqualified the attempt';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

do $$
begin
  if (select status from public.exam_submissions
       where id = current_setting('test.sub_mixed')::uuid) <> 'disqualified' then
    raise exception 'FAIL (f)vi: the disqualified attempt is not disqualified';
  end if;
  if (select score from public.exam_submissions
       where id = current_setting('test.sub_mixed')::uuid) is not null then
    raise exception 'FAIL (f)vi: a disqualified attempt carries a score';
  end if;
  if (select count(*) from public.attempt_review_logs) <> 2 then
    raise exception 'FAIL (f)vi: expected 2 audit rows, found %',
      (select count(*) from public.attempt_review_logs);
  end if;
  raise notice 'PASS (f)vi: the decision changed the row and was audited';
end $$;

-- (f) vii: the audit trail is read-only to clients. No insert policy exists, so a
-- lecturer cannot write their own record of a decision.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "lecturer.a@test.local"}',
         current_setting('test.lecturer_a')), true);
do $$
begin
  begin
    insert into public.attempt_review_logs
      (submission_id, student_id, exam_id, from_status, to_status, decision)
    values (current_setting('test.sub_review')::uuid,
            current_setting('test.review')::uuid,
            current_setting('test.exam')::uuid,
            'flagged_for_review', 'submitted', 'clear');
    raise exception 'FAIL (f)vii: a client inserted an audit row';
  exception when insufficient_privilege then
    raise notice 'PASS (f)vii: clients cannot write the review audit trail';
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (g)  Nothing was rewritten
-- =====================================================================
-- Every check above only ever called the RPCs, so every attempt holds exactly the
-- evidence those calls inserted - no UPDATE in this file touches a log row, which
-- is the "no backfill" rule the migration also keeps.
--   5 soft + 3 hard + 5 mixed + 4 replay (one replayed delivery adds nothing)
--   + 3 review = 20
do $$
declare
  v_rows int;
begin
  select count(*) into v_rows
  from public.proctoring_logs l
  join public.exam_submissions s on s.id = l.submission_id
  where s.exam_id = current_setting('test.exam')::uuid;

  if v_rows <> 20 then
    raise exception 'FAIL (g): expected 20 evidence rows, found %', v_rows;
  end if;
  raise notice 'PASS (g): 20 rows of evidence, all written by the RPC';
end $$;

rollback;
