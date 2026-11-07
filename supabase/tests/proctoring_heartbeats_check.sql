-- =====================================================================
-- PROCTORING HEARTBEATS TEST  -  run against a LOCAL `supabase start` database
-- =====================================================================
-- Run from the repo root with:
--
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres
--     -f supabase/tests/proctoring_heartbeats_check.sql
--
-- Prerequisites: `supabase start` is running and `supabase db reset` has applied
-- `supabase/schema.sql` (which already carries
-- `20261105090000_proctor_heartbeats.sql`). For section (g) only,
-- `supabase/migrations/retention_policy.sql` must have been applied too; if it has
-- not, that section reports SKIP instead of failing.
--
-- WHAT IT PROVES
--   (a) one beat from the attempt's owner is stored once, with the camera and
--       monitor state the client reported, and stamps
--       `exam_submissions.last_heartbeat_at` - the column the live grid reads.
--   (b) replaying one `client_event_id` stores nothing new ('duplicate') but
--       still refreshes liveness, so a retry after a lost response cannot be
--       mistaken for a dead client.
--   (c) a beat inside the 8s server window is 'throttled': no row, liveness still
--       refreshed. That window is what stops a script writing thousands of rows a
--       second while never making an honest 15s client look late.
--   (d) the RPC refuses what it is not for: another student's attempt (42501), a
--       closed attempt (22023), an unknown attempt (P0002) and a caller with no
--       session (28000).
--   (e) `proctor_heartbeats` has no write policy at all, so a client cannot insert
--       a tidier series than the one it sent - the RPC is the only way in.
--   (f) `proctoring_coverage()` separates "nothing to judge yet" from "nothing
--       checked in", flags a long gap and a camera-down beat for a human, and
--       never changes the attempt's status.
--   (g) `purge_expired_proctor_heartbeats()` never deletes a beat belonging to an
--       `ongoing` attempt, dry run or not, and a dry run deletes nothing at all.
--
-- HOW RLS IS APPLIED
--   Identical to `weighted_strikes_check.sql`: `set local role authenticated` plus
--   a `request.jwt.claims` carrying the caller's uuid, then `reset role` and a
--   blank claims string before the next fixture write, because
--   `guard_profile_labels()` refuses a label write from a caller holding claims.
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
  v_lecturer   uuid := gen_random_uuid();
  v_supervisor uuid := gen_random_uuid();
  v_tidy       uuid := gen_random_uuid();  -- (f) beats all the way through
  v_gap        uuid := gen_random_uuid();  -- (f) beats, then silence
  v_silent     uuid := gen_random_uuid();  -- (f) no beats at all
  v_new        uuid := gen_random_uuid();  -- (f) started 30s ago, no beats
  v_closed     uuid := gen_random_uuid();  -- (d)/(g) a finished attempt
  v_beat       uuid := gen_random_uuid();  -- (a)-(e) the RPC's subject
  v_other      uuid := gen_random_uuid();  -- (f) not allowed to read v_gap
  v_exam       uuid := gen_random_uuid();
  v_now        timestamptz := now();
begin
  insert into public.profiles (id, role, full_name, email, faculty, department, level)
    values
      (v_lecturer,   'lecturer',   'Lecturer',       'lecturer.hb@test.local',   'Science', 'CS', null),
      (v_supervisor, 'supervisor', 'Supervisor',     'supervisor.hb@test.local', 'Science', 'CS', null),
      (v_tidy,       'student',    'Student Tidy',   'tidy.hb@test.local',       null, null, null),
      (v_gap,        'student',    'Student Gap',    'gap.hb@test.local',        null, null, null),
      (v_silent,     'student',    'Student Silent', 'silent.hb@test.local',     null, null, null),
      (v_new,        'student',    'Student New',    'new.hb@test.local',        null, null, null),
      (v_closed,     'student',    'Student Closed', 'closed.hb@test.local',     null, null, null),
      (v_beat,       'student',    'Student Beat',   'beat.hb@test.local',       null, null, null),
      (v_other,      'student',    'Student Other',  'other.hb@test.local',      null, null, null);

  insert into public.exams (id, title, created_by, duration_minutes, is_published)
    values (v_exam, 'Heartbeat paper', v_lecturer, 60, true);

  insert into public.questions (exam_id, question_text, question_type, points)
    values (v_exam, 'Q1', 'subjective', 1);

  -- One attempt per student (the table is unique on (student_id, exam_id)).
  -- started_at is written explicitly: all the coverage arithmetic is relative to
  -- it, so the fixtures have to place it.
  insert into public.exam_submissions (student_id, exam_id, status, started_at, submitted_at)
    values
      (v_tidy,   v_exam, 'ongoing',   v_now - interval '20 minutes', null),
      (v_gap,    v_exam, 'ongoing',   v_now - interval '20 minutes', null),
      (v_silent, v_exam, 'ongoing',   v_now - interval '20 minutes', null),
      (v_new,    v_exam, 'ongoing',   v_now - interval '30 seconds', null),
      (v_closed, v_exam, 'submitted', v_now - interval '20 minutes', v_now - interval '1 minute'),
      (v_beat,   v_exam, 'ongoing',   v_now - interval '20 minutes', null);

  -- A tidy series: 80 beats at the client's 15s cadence, ending at now().
  insert into public.proctor_heartbeats (submission_id, received_at, client_event_id)
    select s.id, v_now - make_interval(secs => (79 - i) * 15), gen_random_uuid()
    from public.exam_submissions s, generate_series(0, 79) i
    where s.student_id = v_tidy;

  -- Eight beats, then nothing for eighteen minutes: the client died (or the
  -- network did) and the report has to be able to say so.
  insert into public.proctor_heartbeats (submission_id, received_at, client_event_id)
    select s.id, v_now - interval '20 minutes' + make_interval(secs => i * 15), gen_random_uuid()
    from public.exam_submissions s, generate_series(0, 7) i
    where s.student_id = v_gap;

  -- ...and one more that arrived but with no camera behind it: the "monitor up,
  -- blind" case that an empty violation feed used to hide completely.
  insert into public.proctor_heartbeats (submission_id, received_at, camera_ok, client_event_id)
    select s.id, v_now - interval '20 minutes' + interval '120 seconds', false, gen_random_uuid()
    from public.exam_submissions s
    where s.student_id = v_gap;

  perform set_config('test.lecturer',   v_lecturer::text, false);
  perform set_config('test.supervisor', v_supervisor::text, false);
  perform set_config('test.tidy',       v_tidy::text, false);
  perform set_config('test.gap',        v_gap::text, false);
  perform set_config('test.beat',       v_beat::text, false);
  perform set_config('test.closed',     v_closed::text, false);
  perform set_config('test.other',      v_other::text, false);
  perform set_config('test.exam',       v_exam::text, false);

  perform set_config('test.sub_tidy',
    (select id::text from public.exam_submissions where student_id = v_tidy), false);
  perform set_config('test.sub_gap',
    (select id::text from public.exam_submissions where student_id = v_gap), false);
  perform set_config('test.sub_silent',
    (select id::text from public.exam_submissions where student_id = v_silent), false);
  perform set_config('test.sub_new',
    (select id::text from public.exam_submissions where student_id = v_new), false);
  perform set_config('test.sub_closed',
    (select id::text from public.exam_submissions where student_id = v_closed), false);
  perform set_config('test.sub_beat',
    (select id::text from public.exam_submissions where student_id = v_beat), false);
end $$;

-- =====================================================================
-- (a)  The owner's beat is stored once and stamps liveness
-- =====================================================================
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "beat.hb@test.local"}',
         current_setting('test.beat')), true);
do $$
declare
  v_sub   uuid := current_setting('test.sub_beat')::uuid;
  v_event uuid := gen_random_uuid();
  r       record;
  v_hb    public.exam_submissions;
  v_row   public.proctor_heartbeats;
begin
  perform set_config('test.event', v_event::text, false);

  -- No liveness yet: the state the dashboard reads as "never reported", which
  -- must not be confused with "reported and saw nothing".
  select * into v_hb from public.exam_submissions where id = v_sub;
  if v_hb.id is null then
    raise exception 'FAIL (a): the owner cannot read the attempt it is sitting';
  end if;
  if v_hb.last_heartbeat_at is not null then
    raise exception 'FAIL (a): the fixture already had a heartbeat at %',
      v_hb.last_heartbeat_at;
  end if;

  select * into r from public.record_heartbeat(
    v_sub, false, false, '1.0.0+1', now() - interval '2 seconds', v_event);

  if r.outcome <> 'recorded' then
    raise exception 'FAIL (a): the first beat returned %', r.outcome;
  end if;
  if r.beat_count <> 1 then
    raise exception 'FAIL (a): beat_count is %, expected 1', r.beat_count;
  end if;

  select * into v_hb from public.exam_submissions where id = v_sub;
  if v_hb.last_heartbeat_at is null then
    raise exception 'FAIL (a): the beat did not stamp last_heartbeat_at';
  end if;
  if v_hb.last_heartbeat_at < now() - interval '5 seconds' then
    raise exception 'FAIL (a): last_heartbeat_at was not refreshed to now (%)',
      v_hb.last_heartbeat_at;
  end if;
  if v_hb.status <> 'ongoing' then
    raise exception 'FAIL (a): a heartbeat changed the attempt status to %', v_hb.status;
  end if;

  -- The row carries what the client said about the camera and the monitor: this
  -- is the "running but blind" case the empty violation feed used to hide.
  select * into v_row from public.proctor_heartbeats where submission_id = v_sub;
  if v_row.id is null then
    raise exception 'FAIL (a): the beat was not stored';
  end if;
  if v_row.camera_ok or v_row.monitoring_ok then
    raise exception 'FAIL (a): stored camera_ok %, monitoring_ok % - expected false/false',
      v_row.camera_ok, v_row.monitoring_ok;
  end if;
  if v_row.app_version <> '1.0.0+1' then
    raise exception 'FAIL (a): app_version was not stored (%)', v_row.app_version;
  end if;
  if v_row.client_time is null then
    raise exception 'FAIL (a): the device clock was dropped';
  end if;
  if v_row.client_event_id <> v_event then
    raise exception 'FAIL (a): client_event_id was not stored';
  end if;
  raise notice 'PASS (a): one beat stored, camera/monitor state kept, liveness stamped';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- Liveness is deliberately rolled back before (b) and (c) so "the beat refreshed
-- it" is observable instead of assumed. Done as postgres: a student cannot write
-- this column, and would not want to.
update public.exam_submissions
   set last_heartbeat_at = now() - interval '5 minutes'
 where id = current_setting('test.sub_beat')::uuid;

-- =====================================================================
-- (b)  A replayed beat is stored once and still proves the client is alive
-- =====================================================================
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "beat.hb@test.local"}',
         current_setting('test.beat')), true);
do $$
declare
  v_sub   uuid := current_setting('test.sub_beat')::uuid;
  v_event uuid := current_setting('test.event')::uuid;  -- the beat stored in (a)
  r       record;
  v_hb    public.exam_submissions;
  v_beats int;
  v_first timestamptz;
begin
  select count(*), min(received_at) into v_beats, v_first
  from public.proctor_heartbeats where submission_id = v_sub;

  select * into r from public.record_heartbeat(v_sub, true, true, '1.0.0+1', null, v_event);

  if r.outcome <> 'duplicate' then
    raise exception 'FAIL (b): a replayed beat returned %', r.outcome;
  end if;
  if r.recorded_at <> v_first then
    raise exception 'FAIL (b): the replay reported %, expected the stored beat at %',
      r.recorded_at, v_first;
  end if;
  if (select count(*) from public.proctor_heartbeats where submission_id = v_sub) <> v_beats then
    raise exception 'FAIL (b): the replay grew the series from % rows', v_beats;
  end if;
  -- The camera flags on the replay are *not* written: nothing was inserted, so a
  -- retry cannot upgrade a "camera down" beat into a clean one.
  if (select camera_ok from public.proctor_heartbeats where submission_id = v_sub) then
    raise exception 'FAIL (b): the replay rewrote the stored camera state';
  end if;

  -- ...but the client is talking to us now, and the grid must see that.
  select * into v_hb from public.exam_submissions where id = v_sub;
  if v_hb.id is null then
    raise exception 'FAIL (b): the owner cannot read the attempt it is sitting';
  end if;
  if v_hb.last_heartbeat_at < now() - interval '5 seconds' then
    raise exception 'FAIL (b): a replayed beat left liveness at %', v_hb.last_heartbeat_at;
  end if;
  raise notice 'PASS (b): a replayed beat stored nothing and refreshed liveness';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

update public.exam_submissions
   set last_heartbeat_at = now() - interval '5 minutes'
 where id = current_setting('test.sub_beat')::uuid;

-- =====================================================================
-- (c)  A beat inside the 8s window is throttled, not lost
-- =====================================================================
-- The client beats every 15s, so an honest client is never inside this window;
-- two tabs, a resume and a timer firing together are. Nothing is stored, and the
-- attempt is still marked alive.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "beat.hb@test.local"}',
         current_setting('test.beat')), true);
do $$
declare
  v_sub   uuid := current_setting('test.sub_beat')::uuid;
  r       record;
  v_hb    public.exam_submissions;
  v_beats int;
begin
  select count(*) into v_beats
  from public.proctor_heartbeats where submission_id = v_sub;

  select * into r from public.record_heartbeat(v_sub, true, true, null, null, gen_random_uuid());

  if r.outcome <> 'throttled' then
    raise exception 'FAIL (c): a beat inside the window returned %', r.outcome;
  end if;
  if (select count(*) from public.proctor_heartbeats where submission_id = v_sub) <> v_beats then
    raise exception 'FAIL (c): a throttled beat still inserted a row';
  end if;

  select * into v_hb from public.exam_submissions where id = v_sub;
  if v_hb.id is null then
    raise exception 'FAIL (c): the owner cannot read the attempt it is sitting';
  end if;
  if v_hb.last_heartbeat_at < now() - interval '5 seconds' then
    raise exception 'FAIL (c): a throttled beat left liveness at %', v_hb.last_heartbeat_at;
  end if;
  raise notice 'PASS (c): a throttled beat stored nothing and refreshed liveness';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (d)  The RPC refuses what it is not for
-- =====================================================================
-- A heartbeat is evidence, so the calls that must not work matter as much as the
-- one that does: somebody else's attempt, a finished attempt, an attempt that does
-- not exist, and a caller with no session at all.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "other.hb@test.local"}',
         current_setting('test.other')), true);
do $$
declare
  v_state text;
  v_sub   uuid := current_setting('test.sub_gap')::uuid;
begin
  begin
    perform public.record_heartbeat(v_sub, true, true, null, null, gen_random_uuid());
    v_state := 'no error';
  exception when others then
    v_state := sqlstate;
  end;

  if v_state <> '42501' then
    raise exception 'FAIL (d): another student''s attempt accepted a beat (%), expected 42501',
      v_state;
  end if;
  raise notice 'PASS (d): a student cannot report for another student''s attempt';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- Whether the refusal wrote anything is checked as postgres: RLS would hide another
-- student's rows from the caller above and turn this into a vacuous assertion.
do $$
begin
  if exists (select 1 from public.proctor_heartbeats
              where submission_id = current_setting('test.sub_gap')::uuid
                and received_at > now() - interval '1 minute') then
    raise exception 'FAIL (d): a refused beat still inserted a row';
  end if;
  raise notice 'PASS (d): the refused beat left no row behind';
end $$;

set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "closed.hb@test.local"}',
         current_setting('test.closed')), true);
do $$
declare
  v_state  text;
  v_sub    uuid := current_setting('test.sub_closed')::uuid;
  v_before int;
begin
  select count(*) into v_before from public.proctor_heartbeats where submission_id = v_sub;

  begin
    perform public.record_heartbeat(v_sub, true, true, null, null, gen_random_uuid());
    v_state := 'no error';
  exception when others then
    v_state := sqlstate;
  end;

  -- 22023 = invalid_parameter_value: the attempt is not 'ongoing'. Accepting these
  -- would let an ended sitting keep its coverage looking healthy after the fact.
  if v_state <> '22023' then
    raise exception 'FAIL (d): a submitted attempt accepted a beat (%), expected 22023',
      v_state;
  end if;
  if (select count(*) from public.proctor_heartbeats where submission_id = v_sub) <> v_before then
    raise exception 'FAIL (d): a beat for a closed attempt was stored anyway';
  end if;

  begin
    perform public.record_heartbeat(gen_random_uuid(), true, true, null, null, gen_random_uuid());
    v_state := 'no error';
  exception when others then
    v_state := sqlstate;
  end;
  if v_state <> 'P0002' then
    raise exception 'FAIL (d): an unknown attempt returned % instead of P0002', v_state;
  end if;
  raise notice 'PASS (d): a closed or unknown attempt refuses a beat';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- No claims at all: the app lost its session and the timer kept firing.
set local role authenticated;
do $$
declare
  v_state text;
begin
  begin
    perform public.record_heartbeat(current_setting('test.sub_beat')::uuid, true, true, null, null, gen_random_uuid());
    v_state := 'no error';
  exception when others then
    v_state := sqlstate;
  end;

  -- 28000 = invalid_authorization_specification.
  if v_state <> '28000' then
    raise exception 'FAIL (d): a signed-out caller got % instead of 28000', v_state;
  end if;
  raise notice 'PASS (d): a signed-out caller cannot report a heartbeat';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (e)  The table has no write policy: the RPC is the only way in
-- =====================================================================
-- If a client could insert here it could backfill the tidy series it never sent,
-- which is the one thing these rows exist to make hard.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "beat.hb@test.local"}',
         current_setting('test.beat')), true);
do $$
declare
  v_state text;
begin
  begin
    insert into public.proctor_heartbeats (submission_id, camera_ok, monitoring_ok)
      values (current_setting('test.sub_beat')::uuid, true, true);
    v_state := 'no error';
  exception when others then
    v_state := sqlstate;
  end;

  if v_state <> '42501' then
    raise exception 'FAIL (e): a client inserted a heartbeat directly (%), expected 42501',
      v_state;
  end if;
  raise notice 'PASS (e): proctor_heartbeats accepts no direct client write';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (f)  Coverage separates "not running" from "nothing seen"
-- =====================================================================
-- Read as the supervisor, which is the audience a coverage report is for.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "supervisor.hb@test.local"}',
         current_setting('test.supervisor')), true);
do $$
declare
  v_cov record;
begin
  -- A client that kept its 15s cadence all the way through is not a finding.
  select * into v_cov
  from public.proctoring_coverage(current_setting('test.sub_tidy')::uuid);
  if v_cov.risk_flag then
    raise exception 'FAIL (f): a tidy series was flagged (%)', v_cov.reason;
  end if;
  if v_cov.beats <> 80 then
    raise exception 'FAIL (f): the tidy attempt shows % beats, expected 80', v_cov.beats;
  end if;
  if v_cov.reason not like '%proctoring was running throughout%' then
    raise exception 'FAIL (f): a clean report reads "%s"', v_cov.reason;
  end if;

  -- Beats, then eighteen minutes of nothing: a finding for a human.
  select * into v_cov
  from public.proctoring_coverage(current_setting('test.sub_gap')::uuid);
  if not v_cov.risk_flag then
    raise exception 'FAIL (f): an eighteen-minute silence was not flagged';
  end if;
  if v_cov.reason not like '%went quiet%' then
    raise exception 'FAIL (f): the gap report does not say why (%)', v_cov.reason;
  end if;
  -- The ninth beat arrived with no camera behind it, which is a finding of its own:
  -- "the monitor was up but blind" is exactly what an empty log feed used to hide.
  if v_cov.camera_down_beats <> 1 then
    raise exception 'FAIL (f): % camera-down beats, expected 1', v_cov.camera_down_beats;
  end if;
  if v_cov.reason not like '%camera was not streaming%' then
    raise exception 'FAIL (f): the report does not mention the blind beat (%)', v_cov.reason;
  end if;
  -- The disclaimer is part of the answer: a supervisor reads `reason` first.
  if v_cov.reason not like '%never disqualifies%' then
    raise exception 'FAIL (f): the flag does not disclaim being a verdict (%)', v_cov.reason;
  end if;

  -- Nothing ever checked in: its own finding, never "clean".
  select * into v_cov
  from public.proctoring_coverage(current_setting('test.sub_silent')::uuid);
  if not v_cov.risk_flag or v_cov.beats <> 0 then
    raise exception 'FAIL (f): zero beats reported as flag %, beats %',
      v_cov.risk_flag, v_cov.beats;
  end if;
  if v_cov.reason not like '%never checked in%' then
    raise exception 'FAIL (f): a silent attempt reads "%s"', v_cov.reason;
  end if;

  -- Thirty seconds into an attempt, silence means nothing yet.
  select * into v_cov
  from public.proctoring_coverage(current_setting('test.sub_new')::uuid);
  if v_cov.risk_flag then
    raise exception 'FAIL (f): an attempt inside the grace window was flagged (%)', v_cov.reason;
  end if;
  if v_cov.reason not like '%too early to judge%' then
    raise exception 'FAIL (f): the grace report reads "%s"', v_cov.reason;
  end if;

  raise notice 'PASS (f): coverage distinguishes no signal, a gap, and no data yet';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- Coverage informs; it does not act. Run as postgres so no policy can hide a
-- status change the function itself made.
do $$
begin
  if (select status from public.exam_submissions
       where id = current_setting('test.sub_gap')::uuid) <> 'ongoing' then
    raise exception 'FAIL (f): reading coverage changed the attempt status';
  end if;
  if (select score from public.exam_submissions
       where id = current_setting('test.sub_gap')::uuid) is not null then
    raise exception 'FAIL (f): reading coverage wrote a score';
  end if;
  raise notice 'PASS (f): a flagged coverage report left the attempt exactly as it was';
end $$;

-- ---- visibility: the same three audiences as the read policy ----
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "other.hb@test.local"}',
         current_setting('test.other')), true);
do $$
declare
  v_state text;
begin
  begin
    perform public.proctoring_coverage(current_setting('test.sub_gap')::uuid);
    v_state := 'no error';
  exception when others then
    v_state := sqlstate;
  end;
  if v_state <> '42501' then
    raise exception 'FAIL (f): another student read a coverage report (%)', v_state;
  end if;
  raise notice 'PASS (f): coverage is not a way around the attempt read policy';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- The lecturer who wrote the paper is the third audience `owns_exam()` names: the
-- coverage function re-checks the policy in code, so this proves the two agree.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "lecturer.hb@test.local"}',
         current_setting('test.lecturer')), true);
do $$
declare
  v_beats int;
  v_n     int;
begin
  select beats into v_beats
  from public.proctoring_coverage(current_setting('test.sub_gap')::uuid);
  if v_beats is null or v_beats <> 9 then
    raise exception 'FAIL (f): the paper''s author read % beats from an attempt with 9',
      v_beats;
  end if;

  select count(*) into v_n
  from public.proctoring_coverage_for_exam(current_setting('test.exam')::uuid)
    as c(submission_id uuid, student_id uuid, exam_id uuid, status text,
         started_at timestamptz, ended_at timestamptz, beats int, expected_beats int,
         coverage_ratio numeric, first_beat_at timestamptz, last_beat_at timestamptz,
         longest_gap_seconds int, silent_seconds int, camera_down_beats int,
         monitoring_down_beats int, risk_flag boolean, reason text);
  if v_n <> 6 then
    raise exception 'FAIL (f): the paper''s author saw % attempts, expected 6', v_n;
  end if;
  raise notice 'PASS (f): the paper''s author reads coverage for the whole sitting';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- A student asking about their own paper: the wrapper filters visibility *before*
-- the lateral call, so they get their own row instead of an exception raised for a
-- classmate's.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "tidy.hb@test.local"}',
         current_setting('test.tidy')), true);
do $$
declare
  v_n int;
begin
  select count(*) into v_n
  from public.proctoring_coverage_for_exam(current_setting('test.exam')::uuid)
    as c(submission_id uuid, student_id uuid, exam_id uuid, status text,
         started_at timestamptz, ended_at timestamptz, beats int, expected_beats int,
         coverage_ratio numeric, first_beat_at timestamptz, last_beat_at timestamptz,
         longest_gap_seconds int, silent_seconds int, camera_down_beats int,
         monitoring_down_beats int, risk_flag boolean, reason text);

  if v_n <> 1 then
    raise exception 'FAIL (f): a student saw % attempt(s) on their own paper, expected 1', v_n;
  end if;
  raise notice 'PASS (f): a student sees only their own coverage in the exam-wide call';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- The audience the report is actually for: one call, every attempt, flagged rows
-- first.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "supervisor.hb@test.local"}',
         current_setting('test.supervisor')), true);
do $$
declare
  v_n       int;
  v_flagged int;
  v_first   uuid;
  v_first_flagged boolean;
  v_first_last    timestamptz;
begin
  select count(*), count(*) filter (where c.risk_flag)
    into v_n, v_flagged
  from public.proctoring_coverage_for_exam(current_setting('test.exam')::uuid)
    as c(submission_id uuid, student_id uuid, exam_id uuid, status text,
         started_at timestamptz, ended_at timestamptz, beats int, expected_beats int,
         coverage_ratio numeric, first_beat_at timestamptz, last_beat_at timestamptz,
         longest_gap_seconds int, silent_seconds int, camera_down_beats int,
         monitoring_down_beats int, risk_flag boolean, reason text);

  if v_n <> 6 then
    raise exception 'FAIL (f): the supervisor saw % attempts, expected 6', v_n;
  end if;
  -- Four, not two: `gap` (18 minutes of silence) and `silent` (never checked in)
  -- are the obvious ones, `closed` is a finished attempt with no beats at all, and
  -- `beat` only started reporting in the last few seconds of a twenty-minute
  -- sitting. `tidy` is clean and `new` is still inside the grace window.
  if v_flagged <> 4 then
    raise exception 'FAIL (f): % attempts flagged, expected 4 (gap, silent, closed, beat)',
      v_flagged;
  end if;

  select c.submission_id, c.risk_flag, c.last_beat_at into v_first, v_first_flagged, v_first_last
  from public.proctoring_coverage_for_exam(current_setting('test.exam')::uuid)
    as c(submission_id uuid, student_id uuid, exam_id uuid, status text,
         started_at timestamptz, ended_at timestamptz, beats int, expected_beats int,
         coverage_ratio numeric, first_beat_at timestamptz, last_beat_at timestamptz,
         longest_gap_seconds int, silent_seconds int, camera_down_beats int,
         monitoring_down_beats int, risk_flag boolean, reason text)
  limit 1;

  -- Never-checked-in attempts are the ones a supervisor has to see before a tidy
  -- series, so the order puts them (flagged, no last beat) at the top.
  if not v_first_flagged or v_first_last is not null then
    raise exception 'FAIL (f): the exam-wide call did not lead with a silent attempt (flag %, last beat %)',
      v_first_flagged, v_first_last;
  end if;
  if v_first not in (current_setting('test.sub_silent')::uuid,
                     current_setting('test.sub_closed')::uuid) then
    raise exception 'FAIL (f): the first row was %, not a never-reported attempt', v_first;
  end if;
  raise notice 'PASS (f): the supervisor gets every attempt, risk first';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (g)  Retention never prunes a live attempt's beats
-- =====================================================================
-- The nightly purge deletes beats past the 30-day window - except those belonging
-- to an attempt that is still `ongoing`, because deleting them would punch a hole
-- in a report that is still being written and then read as a gap the client never
-- caused. That guard is the whole point of this section.
do $$
declare
  v_dry  bigint;
  v_live bigint;
  v_days integer;
  v_sub_closed uuid := current_setting('test.sub_closed')::uuid;
  v_sub_live   uuid := current_setting('test.sub_gap')::uuid;
begin
  if to_regprocedure('public.purge_expired_proctor_heartbeats(boolean)') is null then
    raise notice 'SKIP (g): supabase/migrations/retention_policy.sql has not been applied';
    return;
  end if;

  -- The window is an operator setting, not a constant: read it so the fixture is
  -- older than whatever this project keeps, instead of hard-coding 30 days and
  -- failing on a site that shortened (or lengthened) the policy.
  select rp.retention_days into v_days
    from public.retention_policies rp
   where rp.table_name = 'proctor_heartbeats'
     and rp.enabled
   limit 1;
  if v_days is null then
    raise notice 'SKIP (g): no enabled proctor_heartbeats retention policy';
    return;
  end if;

  -- One expired beat on a finished attempt, one on an attempt that is still
  -- running. Both are older than the policy window.
  insert into public.proctor_heartbeats (submission_id, received_at, client_event_id)
    values
      (v_sub_closed, now() - make_interval(days => v_days + 1), gen_random_uuid()),
      (v_sub_live,   now() - make_interval(days => v_days + 1), gen_random_uuid());

  select public.purge_expired_proctor_heartbeats(true) into v_dry;
  if v_dry < 1 then
    raise exception 'FAIL (g): the dry run counted nothing, so it cannot be checking';
  end if;
  if not exists (select 1 from public.proctor_heartbeats
                  where submission_id = v_sub_closed
                    and received_at < now() - make_interval(days => v_days)) then
    raise exception 'FAIL (g): a dry run deleted the closed attempt''s expired beat';
  end if;

  select public.purge_expired_proctor_heartbeats() into v_live;
  if v_live < 1 then
    raise exception 'FAIL (g): the purge deleted nothing';
  end if;

  if exists (select 1 from public.proctor_heartbeats
              where submission_id = v_sub_closed
                and received_at < now() - make_interval(days => v_days)) then
    raise exception 'FAIL (g): the closed attempt''s expired beat survived the purge';
  end if;
  if not exists (select 1 from public.proctor_heartbeats
                  where submission_id = v_sub_live
                    and received_at < now() - make_interval(days => v_days)) then
    raise exception 'FAIL (g): the purge deleted a beat belonging to an ongoing attempt';
  end if;

  raise notice 'PASS (g): retention prunes finished attempts only';
end $$;

rollback;
