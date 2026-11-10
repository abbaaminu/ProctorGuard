-- =====================================================================
-- WEIGHTED STRIKES TEST  -  run against a LOCAL `supabase start` database
-- =====================================================================
-- Run from the repo root with:
--
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres
--     -f supabase/tests/weighted_strikes_check.sql
--
-- Prerequisites: `supabase start` is running, and `supabase db reset` has applied
-- `supabase/schema.sql` (which already carries the 2026110409*.sql changes *and* the
-- re-priced `looking_away` / `audio_noise` rows of
-- 20261108090000_looking_away_and_noise_count.sql), or those migrations have been
-- applied by hand.
--
-- WHAT IT PROVES
--   (a) `violation_weights` has a row for every `action_type`
--       `proctoring_logs_action_type_check` allows - the vocabulary is read out of
--       the constraint itself, so a new type added there without a weight fails
--       here rather than silently scoring as hard.
--   (b) the three UNCOUNTED signals never add up, however many are logged: they are
--       stored as evidence, the count rises, and the attempt stays 'ongoing'.
--   (b)ii  two `looking_away` do not flag and the third does, because a glance off
--       screen became a counted strike (20261108090000).
--   (b)iii two `audio_noise` do not flag and the third does, for the same reason.
--   (b)iv  a mixed history flags on the third *counted* signal and not before,
--       mixing the two newly counted types with the uncounted ones.
--   (c) three counted identity-breaking signals flag: the attempt becomes
--       'flagged_for_review', the sitting is closed (`submitted_at`), and no score
--       is written.
--   (d) a MIXED history flags only when the counted signals reach three: one counted
--       plus a pile of uncounted is still 'ongoing', and the third counted one flags
--       it.
--   (e) replaying one `client_event_id` adds nothing: the row count, the reported
--       `warning_count` and the weighted decision are all unchanged, so a retry
--       after a lost response can never cross the threshold twice.
--   (f) `resolve_flagged_attempt` is the unlock, and it is staff-only: the student
--       cannot call it, the lecturer who did not write the paper cannot call it, and
--       the paper's author, a supervisor and an administrator can - each of which
--       writes exactly one `attempt_review_logs` row, which a replay does not
--       duplicate.
--   (g) `grade_submission` refuses an attempt under review.
--   (h) the lockout holds: once flagged, the student cannot save an answer, cannot
--       submit (the RPC reports the stored ruling and grades nothing), cannot add
--       another strike, cannot reopen the row and cannot create a second attempt on
--       the paper - from this device or any other. (h)6 turns the same question on
--       the staff side: a supervisor may write the row but the immutability trigger
--       still refuses 'ongoing', so an unlock is `resolve_flagged_attempt()` and a
--       retake is "Reset attempt".
--
-- WHAT THE COUNTS COUNT
--   Every `count(*)` here is filtered to a fixture id - `test.exam` for the paper's
--   rows, `test.sub_*` for one attempt's - so the file passes on an empty database and
--   on a live project that already holds attempts, review rows and evidence of its
--   own. An unscoped count is a count of the database rather than of the run: it goes
--   green only on a project nobody has used yet, and red the first time somebody sits
--   a paper. (a) is the one count that is not about rows at all - it counts the
--   vocabulary in `proctoring_logs_action_type_check` against the weights answering
--   it, because `violation_weights` is an operator-editable table.
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
  v_admin      uuid := gen_random_uuid();   -- (f)viii: the third unlock tier
  v_soft       uuid := gen_random_uuid();   -- (b) the uncounted signals only
  v_glance     uuid := gen_random_uuid();   -- (b)ii / (h) three looking_away
  v_noise      uuid := gen_random_uuid();   -- (b)iii / (f)viii three audio_noise
  v_flipmix    uuid := gen_random_uuid();   -- (b)iv counted + uncounted, mixed
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
      (v_admin,      'admin',      'Admin',      'admin@test.local',      'Science', 'CS', null),
      (v_soft,       'student',    'Student Soft',   'soft@test.local',   null, null, null),
      (v_glance,     'student',    'Student Glance', 'glance@test.local', null, null, null),
      (v_noise,      'student',    'Student Noise',  'noise@test.local',  null, null, null),
      (v_flipmix,    'student',    'Student Flip',   'flip@test.local',   null, null, null),
      (v_hard,       'student',    'Student Hard',   'hard@test.local',   null, null, null),
      (v_mixed,      'student',    'Student Mixed',  'mixed@test.local',  null, null, null),
      (v_replay,     'student',    'Student Replay', 'replay@test.local', null, null, null),
      (v_review,     'student',    'Student Review', 'review@test.local', null, null, null);

  -- One untargeted, published paper: these checks are about the escalation rule,
  -- not about who may sit what (targeting_check.sql owns that).
  insert into public.exams (id, title, created_by, duration_minutes, is_published)
    values (v_exam, 'Weighted strikes paper', v_lecturer_a, 60, true);

  -- `20261109090000_supervisor_exam_assignments.sql`: a supervisor reaches the
  -- papers an administrator assigned to them - (f) has the supervisor rewrite and
  -- resolve attempts on this paper, and (f)viii has the administrator unlock the
  -- same one without an assignment (an admin needs none).
  insert into public.supervisor_exam_assignments (exam_id, supervisor_id, assigned_by)
    values (v_exam, v_supervisor, v_admin);

  insert into public.questions (exam_id, question_text, question_type, points)
    values (v_exam, 'Q1', 'subjective', 1);
  -- A multiple-choice question too, so (h) can try to write an option answer to a
  -- closed attempt and have the RPC - not the missing column - be what refuses it.
  insert into public.questions (exam_id, question_text, question_type, points, options, correct_option)
    values (v_exam, 'Q2', 'multiple_choice', 1, '["a","b"]'::jsonb, 0);

  -- One 'ongoing' attempt per student. Written as postgres, so no policy applies;
  -- 'ongoing' is the state register_violation() accepts.
  insert into public.exam_submissions (student_id, exam_id, status)
    values
      (v_soft,    v_exam, 'ongoing'),
      (v_glance,  v_exam, 'ongoing'),
      (v_noise,   v_exam, 'ongoing'),
      (v_flipmix, v_exam, 'ongoing'),
      (v_hard,    v_exam, 'ongoing'),
      (v_mixed,   v_exam, 'ongoing'),
      (v_replay,  v_exam, 'ongoing'),
      (v_review,  v_exam, 'ongoing');

  perform set_config('test.lecturer_a', v_lecturer_a::text, false);
  perform set_config('test.lecturer_b', v_lecturer_b::text, false);
  perform set_config('test.supervisor', v_supervisor::text, false);
  perform set_config('test.admin',      v_admin::text, false);
  perform set_config('test.soft',   v_soft::text, false);
  perform set_config('test.glance', v_glance::text, false);
  perform set_config('test.noise',  v_noise::text, false);
  perform set_config('test.flipmix', v_flipmix::text, false);
  perform set_config('test.hard',   v_hard::text, false);
  perform set_config('test.mixed',  v_mixed::text, false);
  perform set_config('test.replay', v_replay::text, false);
  perform set_config('test.review', v_review::text, false);
  perform set_config('test.exam',   v_exam::text, false);

  perform set_config('test.sub_soft',
    (select id::text from public.exam_submissions where student_id = v_soft), false);
  perform set_config('test.sub_glance',
    (select id::text from public.exam_submissions where student_id = v_glance), false);
  perform set_config('test.sub_noise',
    (select id::text from public.exam_submissions where student_id = v_noise), false);
  perform set_config('test.sub_flipmix',
    (select id::text from public.exam_submissions where student_id = v_flipmix), false);
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
  v_allowed int;
  v_priced  int;
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
  ), priced as (
    select l.action_type, w.action_type is not null as has_row
    from listed l
    left join public.violation_weights w on w.action_type = l.action_type
  )
  select coalesce(string_agg(action_type, ', ' order by action_type)
                    filter (where not has_row), ''),
         count(*),
         count(*) filter (where has_row)
    into v_missing, v_allowed, v_priced
  from priced;

  -- A vocabulary of nothing would make both checks below pass without meaning
  -- anything, so the constraint has to be there before it can be counted.
  if v_allowed = 0 then
    raise exception 'FAIL (a): no action_type CHECK constraint found on public.proctoring_logs';
  end if;

  if v_missing <> '' then
    raise exception 'FAIL (a): no violation_weights row for: %', v_missing;
  end if;

  -- Counted against the vocabulary, not against the table. `violation_weights` is
  -- operator-editable on purpose (the policies let an administrator insert, re-price
  -- or delete a row), so a live project can hold rows this check has no opinion
  -- about - a tuned weight, or a type a newer client posts before the constraint
  -- learned it. What must hold is that every type `proctoring_logs` can store is
  -- priced, exactly once; counting the whole table would assert what the database
  -- happens to contain instead, and fail on a project that is working.
  if v_priced <> v_allowed then
    raise exception 'FAIL (a): expected % weighted action types, found %',
      v_allowed, v_priced;
  end if;
  raise notice 'PASS (a): every allowed action_type has a weight';
end $$;

-- =====================================================================
-- (b)  The UNCOUNTED signals never add up, however many are logged
-- =====================================================================
-- `copy_paste_attempt`, `right_click_blocked` and `idle_afk` are weight 0 and
-- `counts_toward_dq = false`: the evidence is still stored - every one of these rows
-- is in proctoring_logs - and the student is still warned; what must not happen is
-- the attempt ending, at six rows or at sixty.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "soft@test.local"}',
         current_setting('test.soft')), true);
do $$
declare
  v_sub uuid := current_setting('test.sub_soft')::uuid;
  r     record;
begin
  -- Two of each, so "repetition never adds up" is what is being proved rather than
  -- "three different uncounted types happen to sum to zero".
  select * into r from public.register_violation(v_sub, 'right_click_blocked', null, now(), gen_random_uuid());
  select * into r from public.register_violation(v_sub, 'copy_paste_attempt',  null, now(), gen_random_uuid());
  select * into r from public.register_violation(v_sub, 'idle_afk',            null, now(), gen_random_uuid());

  if r.disqualified or r.flagged then
    raise exception 'FAIL (b): three uncounted signals ended the attempt (count %, disqualified %, flagged %)',
      r.warning_count, r.disqualified, r.flagged;
  end if;

  select * into r from public.register_violation(v_sub, 'right_click_blocked', null, now(), gen_random_uuid());
  select * into r from public.register_violation(v_sub, 'copy_paste_attempt',  null, now(), gen_random_uuid());
  select * into r from public.register_violation(v_sub, 'idle_afk',            null, now(), gen_random_uuid());

  if r.disqualified or r.flagged then
    raise exception 'FAIL (b): six uncounted signals ended the attempt';
  end if;
  if r.warning_count <> 6 then
    raise exception 'FAIL (b): expected 6 stored rows, RPC reported %', r.warning_count;
  end if;
  raise notice 'PASS (b): six uncounted signals stored, attempt still ongoing';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

do $$
begin
  if (select status from public.exam_submissions
       where id = current_setting('test.sub_soft')::uuid) <> 'ongoing' then
    raise exception 'FAIL (b): an uncounted-only attempt is not ongoing';
  end if;
  if (select count(*) from public.proctoring_logs
       where submission_id = current_setting('test.sub_soft')::uuid) <> 6 then
    raise exception 'FAIL (b): uncounted evidence was not stored';
  end if;
  raise notice 'PASS (b): all six uncounted signals are on the record';
end $$;
-- =====================================================================
-- (b)ii  Three `looking_away` flag the attempt, two do not
-- =====================================================================
-- The signal this release changed. It is the same weighted rule as a second face in
-- frame now: two glances are two points and a third closes the sitting - while the
-- client still decides what a "glance" is (15 deg on both axes, held for 2 s) before
-- it ever calls the RPC (`proctoring_thresholds.dart`, pinned by
-- `proctoring_thresholds_test.dart`).
--
-- The attempt flagged here is also the fixture for (h): it is the one whose lockout
-- is then tested from the student's side.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "glance@test.local"}',
         current_setting('test.glance')), true);
do $$
declare
  v_sub uuid := current_setting('test.sub_glance')::uuid;
  r     record;
begin
  select * into r from public.register_violation(v_sub, 'looking_away', null, now(), gen_random_uuid());
  if r.flagged or r.disqualified then
    raise exception 'FAIL (b)ii: one look-away ended the attempt';
  end if;

  select * into r from public.register_violation(v_sub, 'looking_away', null, now(), gen_random_uuid());
  if r.flagged or r.disqualified then
    raise exception 'FAIL (b)ii: two look-aways ended the attempt (count %, flagged %)',
      r.warning_count, r.flagged;
  end if;
  if r.warning_count <> 2 then
    raise exception 'FAIL (b)ii: expected 2 stored rows, RPC reported %', r.warning_count;
  end if;

  -- The third is the threshold.
  select * into r from public.register_violation(v_sub, 'looking_away', null, now(), gen_random_uuid());
  if not r.flagged then
    raise exception 'FAIL (b)ii: three look-aways did not flag the attempt';
  end if;
  if r.disqualified then
    raise exception 'FAIL (b)ii: the threshold disqualified instead of flagging';
  end if;
  raise notice 'PASS (b)ii: two look-aways are two points, the third flags the attempt';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

do $$
begin
  if (select status from public.exam_submissions
       where id = current_setting('test.sub_glance')::uuid) <> 'flagged_for_review' then
    raise exception 'FAIL (b)ii: three look-aways left the attempt open';
  end if;
  raise notice 'PASS (b)ii: the glance-only attempt is under review';
end $$;

-- =====================================================================
-- (b)iii  Three `audio_noise` flag the attempt, two do not
-- =====================================================================
-- The second signal this release changed. One episode is one strike on the client
-- (`AudioNoiseDetector` latches until the level drops back below the threshold, and
-- the level has to stay above it for 2 s first), so three rows here are three
-- separate noisy episodes as far as the server is concerned - it only counts them.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "noise@test.local"}',
         current_setting('test.noise')), true);
do $$
declare
  v_sub uuid := current_setting('test.sub_noise')::uuid;
  r     record;
begin
  select * into r from public.register_violation(v_sub, 'audio_noise', null, now(), gen_random_uuid());
  if r.flagged or r.disqualified then
    raise exception 'FAIL (b)iii: one noisy-room strike ended the attempt';
  end if;

  select * into r from public.register_violation(v_sub, 'audio_noise', null, now(), gen_random_uuid());
  if r.flagged or r.disqualified then
    raise exception 'FAIL (b)iii: two noisy-room strikes ended the attempt (count %, flagged %)',
      r.warning_count, r.flagged;
  end if;

  select * into r from public.register_violation(v_sub, 'audio_noise', null, now(), gen_random_uuid());
  if not r.flagged then
    raise exception 'FAIL (b)iii: three noisy-room strikes did not flag the attempt';
  end if;
  if r.disqualified then
    raise exception 'FAIL (b)iii: the threshold disqualified instead of flagging';
  end if;
  raise notice 'PASS (b)iii: two noisy-room strikes are two points, the third flags the attempt';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);



-- =====================================================================
-- (b)iv  Mixed: the two new signals count alongside a hard one, the uncounted do not
-- =====================================================================
-- Six rows, three of them pointed: look-away (1), paste (0), right-click (0),
-- noise (2), idle (0), second face (3 -> flagged). Nothing flags until the third
-- counted point arrives, which is the rule the whole table exists for.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "flip@test.local"}',
         current_setting('test.flipmix')), true);
do $$
declare
  v_sub uuid := current_setting('test.sub_flipmix')::uuid;
  r     record;
begin
  select * into r from public.register_violation(v_sub, 'looking_away',        null, now(), gen_random_uuid());
  select * into r from public.register_violation(v_sub, 'copy_paste_attempt',  null, now(), gen_random_uuid());
  if r.flagged then
    raise exception 'FAIL (b)iv: one counted + one uncounted flagged the attempt';
  end if;

  select * into r from public.register_violation(v_sub, 'right_click_blocked', null, now(), gen_random_uuid());
  select * into r from public.register_violation(v_sub, 'audio_noise',         null, now(), gen_random_uuid());
  if r.flagged then
    raise exception 'FAIL (b)iv: two counted + two uncounted flagged the attempt';
  end if;
  if r.warning_count <> 4 then
    raise exception 'FAIL (b)iv: expected 4 rows, RPC reported %', r.warning_count;
  end if;

  -- A fifth row that counts for nothing: the score is still 2.
  select * into r from public.register_violation(v_sub, 'idle_afk', null, now(), gen_random_uuid());
  if r.flagged then
    raise exception 'FAIL (b)iv: an idle-device row pushed the attempt over';
  end if;

  -- The third counted point: one hard signal.
  select * into r from public.register_violation(v_sub, 'multiple_faces', null, now(), gen_random_uuid());
  if not r.flagged then
    raise exception 'FAIL (b)iv: the third counted point did not flag the attempt';
  end if;
  raise notice 'PASS (b)iv: look-away + noise + a second face flag; the uncounted rows do not';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);


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
  -- Scoped to the fixture paper: a live project already holds review rows of its own,
  -- so an unscoped count here measured the database rather than this run.
  if (select count(*) from public.attempt_review_logs
       where exam_id = current_setting('test.exam')::uuid) <> 2 then
    raise exception 'FAIL (f)vi: expected 2 audit rows, found %',
      (select count(*) from public.attempt_review_logs
        where exam_id = current_setting('test.exam')::uuid);
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
-- (f) viii: an administrator unlocks too - the second half of `is_exam_supervisor()`,
-- and the tier the student's own "under review" screen names. The attempt here is
-- the `audio_noise` one from (b)iii, unresolved until now, so this is also the proof
-- that an unlock works on a flag raised by a *counted glance/noise* rather than by a
-- camera signal.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "admin@test.local"}',
         current_setting('test.admin')), true);
do $$
declare
  r record;
begin
  select * into r from public.resolve_flagged_attempt(
    current_setting('test.sub_noise')::uuid, 'clear', 'Room was a corridor; answers fine.');
  if r.new_status <> 'submitted' then
    raise exception 'FAIL (f)viii: an admin unlock produced %', r.new_status;
  end if;
  raise notice 'PASS (f)viii: an administrator unlocked the noisy-room attempt';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

do $$
declare
  v_log public.attempt_review_logs;
begin
  if (select status from public.exam_submissions
       where id = current_setting('test.sub_noise')::uuid) <> 'submitted' then
    raise exception 'FAIL (f)viii: the unlocked attempt is not submitted';
  end if;
  select * into v_log from public.attempt_review_logs
   where submission_id = current_setting('test.sub_noise')::uuid;
  if v_log.decision <> 'clear'
     or v_log.actor_id <> current_setting('test.admin')::uuid then
    raise exception 'FAIL (f)viii: the audit row names % / %',
      v_log.decision, v_log.actor_id;
  end if;
  -- Three audit rows on this paper now: lecturer (clear), supervisor (disqualify),
  -- admin (clear) - counted on `test.exam`, because a live project has review rows of
  -- its own and this asserts what the run wrote.
  if (select count(*) from public.attempt_review_logs
       where exam_id = current_setting('test.exam')::uuid) <> 3 then
    raise exception 'FAIL (f)viii: expected 3 audit rows, found %',
      (select count(*) from public.attempt_review_logs
        where exam_id = current_setting('test.exam')::uuid);
  end if;
  raise notice 'PASS (f)viii: the admin unlock is audited against the admin account';
end $$;



-- =====================================================================
-- (h)  The lockout: a flagged attempt cannot be continued, reopened or replaced
-- =====================================================================
-- The student-facing half of the rule: three counted strikes close the attempt, and
-- from that moment *nothing* on this device - or on any other - puts them back in the
-- paper. Each refusal below is a different door:
--   1. an answer write    -> `merge_submission_answer` / `..._text_answer` require
--                            `status = 'ongoing'` (55000);
--   2. a submit           -> `submit_exam` reports the stored ruling and grades
--                            nothing, so "hand in" cannot turn a review into a mark;
--   3. another strike     -> `register_violation` returns the final state and appends
--                            no evidence;
--   4. reopening the row  -> the student has no UPDATE policy at all, so the write
--                            touches zero rows;
--   5. a fresh attempt    -> the insert policy and `unique (student_id, exam_id)`
--                            between them refuse a second row on the same paper.
-- and the same lockout from the staff side, which is (h)6: a supervisor can write
-- the row (they hold `submissions_update_supervisor`) but the immutability trigger
-- refuses 'ongoing', so "unlock" is `resolve_flagged_attempt()` and a retake is
-- "Reset attempt" - never a reopened attempt.
-- The attempt under test is `sub_glance` from (b)ii: flagged, three rows.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "glance@test.local"}',
         current_setting('test.glance')), true);
do $$
declare
  v_sub   uuid := current_setting('test.sub_glance')::uuid;
  v_q_mc  uuid;
  v_q_txt uuid;
  r       record;
  v_rows  int;
begin
  select id into v_q_mc from public.questions
   where exam_id = current_setting('test.exam')::uuid and question_type = 'multiple_choice';
  select id into v_q_txt from public.questions
   where exam_id = current_setting('test.exam')::uuid and question_type = 'subjective';

  -- (h) 1: an answer write is refused, for both answer shapes.
  begin
    perform public.merge_submission_answer(v_sub, v_q_mc, 1);
    raise exception 'FAIL (h)1: a flagged attempt accepted an option answer';
  exception when sqlstate '55000' then
    raise notice 'PASS (h)1: merge_submission_answer refuses a flagged attempt';
  end;

  begin
    perform public.merge_submission_text_answer(v_sub, v_q_txt, 'still here');
    raise exception 'FAIL (h)1: a flagged attempt accepted a written answer';
  exception when sqlstate '55000' then
    raise notice 'PASS (h)1: merge_submission_text_answer refuses a flagged attempt';
  end;

  if (select answers from public.exam_submissions where id = v_sub) <> '{}'::jsonb then
    raise exception 'FAIL (h)1: a refused answer still landed in the row';
  end if;

  -- (h) 2: "hand in" reports the ruling instead of closing the paper as submitted.
  select * into r from public.submit_exam(v_sub);
  if r.result_status <> 'flagged_for_review' then
    raise exception 'FAIL (h)2: submit_exam answered % for a flagged attempt', r.result_status;
  end if;
  if r.final_score is not null then
    raise exception 'FAIL (h)2: submit_exam graded a flagged attempt (%)', r.final_score;
  end if;
  raise notice 'PASS (h)2: submit_exam reports the review and grades nothing';

  -- (h) 3: another strike cannot be appended, so the evidence list is frozen.
  select * into r from public.register_violation(v_sub, 'looking_away', null, now(), gen_random_uuid());
  if not r.flagged or r.disqualified then
    raise exception 'FAIL (h)3: a strike on a flagged attempt answered flagged % / disqualified %',
      r.flagged, r.disqualified;
  end if;
  if r.warning_count <> 3 then
    raise exception 'FAIL (h)3: a strike was appended to a closed attempt (count %)', r.warning_count;
  end if;
  raise notice 'PASS (h)3: no evidence is appended to a closed attempt';

  -- (h) 4: the student cannot put the row back to 'ongoing'. There is no student
  -- UPDATE policy, so the statement matches nothing at all.
  update public.exam_submissions
     set status = 'ongoing'
   where id = v_sub;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'FAIL (h)4: a student reopened a closed attempt (% rows)', v_rows;
  end if;
  raise notice 'PASS (h)4: a student cannot reopen the attempt';

  -- (h) 5: a second attempt on the same paper is refused. The insert policy answers
  -- first in this fixture (there is no consent row), and `unique (student_id,
  -- exam_id)` is the backstop behind it - either way no second row exists.
  begin
    insert into public.exam_submissions (exam_id, student_id, status)
      values (current_setting('test.exam')::uuid, current_setting('test.glance')::uuid, 'ongoing');
    raise exception 'FAIL (h)5: a student inserted a second attempt on the paper';
  exception
    when insufficient_privilege then
      raise notice 'PASS (h)5: submissions_insert_own_ongoing refuses a second attempt';
    when unique_violation then
      raise notice 'PASS (h)5: unique (student_id, exam_id) refuses a second attempt';
  end;

  raise notice 'PASS (h): the attempt is locked from every client door';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);


-- (h) 6: not even a supervisor can put it back to 'ongoing' - and the refusal is the
-- trigger's, not the policy's, so it holds for every caller. A supervisor *can*
-- update the row (`submissions_update_supervisor`), which is what makes this check
-- worth having: the status still cannot move backwards, because
-- `guard_submission_immutability()` raises 42501 when it would. Reopening a decided
-- attempt is not a repair the console offers, and the way to let somebody retake is
-- "Reset attempt", which deletes the row (and cascades its evidence). Written down
-- here so the rule is not mistaken for something only the student is blocked by.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "supervisor@test.local"}',
         current_setting('test.supervisor')), true);
do $$
begin
  begin
    update public.exam_submissions
       set status = 'ongoing'
     where id = current_setting('test.sub_glance')::uuid;
    raise exception 'FAIL (h)6: a closed attempt was reopened by staff';
  exception when insufficient_privilege then
    raise notice 'PASS (h)6: a closed attempt cannot be reopened, even by staff';
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (g)  Nothing was rewritten
-- =====================================================================
-- Every check above only ever called the RPCs, so every attempt holds exactly the
-- evidence those calls inserted - no UPDATE in this file touches a log row, which
-- is the "no backfill" rule the migration also keeps. The locked attempt in (h)
-- contributed nothing either: a refused answer, submit or strike appends no row.
--   6 uncounted (b) + 3 look-away (b)ii + 3 noise (b)iii + 6 mixed (b)iv
--   + 3 hard (c) + 5 mixed (d) + 4 replay (one replayed delivery adds nothing)
--   + 3 review (f) = 33
do $$
declare
  v_rows int;
begin
  select count(*) into v_rows
  from public.proctoring_logs l
  join public.exam_submissions s on s.id = l.submission_id
  where s.exam_id = current_setting('test.exam')::uuid;

  if v_rows <> 33 then
    raise exception 'FAIL (g): expected 33 evidence rows, found %', v_rows;
  end if;
  raise notice 'PASS (g): 33 rows of evidence, all written by the RPC';
end $$;

rollback;
