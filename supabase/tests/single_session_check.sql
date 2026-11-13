-- =====================================================================
-- SINGLE-SESSION TEST  -  run against a LOCAL `supabase start` database
-- =====================================================================
-- Run from the repo root with:
--
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres
--     -f supabase/tests/single_session_check.sql
--
-- Prerequisites: `supabase start` is running and `supabase db reset` has applied
-- `supabase/schema.sql`, which already carries section 1b and
-- `20261111090000_single_session.sql`.
--
-- WHAT IT PROVES
--   (a) before an account claims anything the gate is open - `is_current_session()`
--       answers true - and the first claim writes exactly one row. That fail-open
--       half is what keeps an older client, the SQL editor and the service_role key
--       working, so it is the first thing asserted.
--   (b) the winning device claiming again is a no-op: same row, same `claimed_at`,
--       no audit row. "When this device took the account" survives a restart.
--   (c) a newer sign-in takes the account: the row moves to the new `session_id`, and
--       one `session_supersessions` row names both sessions and the attempt that was
--       open at that moment.
--   (d) the replaced device cannot take the account back - its claim comes back
--       `accepted = false`, the row does not move, and no second audit row appears.
--   (e) every write path refuses the replaced device with SQLSTATE `PT409` -
--       `merge_submission_answer`, `merge_submission_text_answer`, `submit_exam`,
--       `register_violation` and `record_heartbeat` - and writes nothing, while the
--       same calls from the winner succeed. The code is the point: a client can tell
--       "another device signed in" from "the attempt closed" (55000).
--   (f) the replaced device cannot open a second attempt on the account (the
--       `submissions_insert_own_ongoing` policy), and the winner can.
--   (g) a token with no `session_id` claim is let through the gate and refused by
--       `claim_session()` (22023); and a claim is per account, so one account's
--       takeover never blocks another account's writing.
--   (h) `active_sessions` is readable by its owner only and writable by nobody: a
--       client cannot delete or overwrite the claim that gates it.
--   (i) the winner closes the attempt with `submit_exam` - the gate is a replacement
--       check, not a lock on the account.
--
-- HOW RLS IS APPLIED
--   Identical to `proctoring_heartbeats_check.sql`: `set local role authenticated`
--   plus a `request.jwt.claims` carrying the caller's uuid, then `reset role` and a
--   blank claims string before the next fixture write. The claims carry the three
--   values the gate reads - `sub`, `session_id` and `iat` - and the two session ids
--   on one account are the whole point of the file.
--
--   The whole file is wrapped in begin; ... rollback; - no data persists, and that
--   is also why `now()` is the *same* instant in every block: it is the
--   transaction's start. Two claims in production are two requests and two
--   transactions, so their `claimed_at` values differ; two claims here cannot,
--   and no block below asserts that this file's clock advanced. What they assert
--   is the row - its `session_id`, its `issued_at`, its label, and a `claimed_at`
--   that never moves backwards - because that is what a client can see.
-- =====================================================================

begin;

-- Fixture helper: profiles.id references auth.users(id), which a plain insert
-- into public.profiles does not create. `active_sessions.user_id` references
-- auth.users too, so the claim in (a) needs these rows to exist. Rolled back with
-- everything else.
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
  v_lecturer uuid := gen_random_uuid();
  v_a        uuid := gen_random_uuid();  -- (a)-(i) one account, two devices
  v_b        uuid := gen_random_uuid();  -- (g) a second account, to prove the scope
  v_exam     uuid := gen_random_uuid();  -- the paper A and B are sitting
  v_exam2    uuid := gen_random_uuid();  -- (f) a paper nobody has started
  v_q        uuid;
  v_iat_a1   bigint := extract(epoch from now())::bigint - 600;  -- A, ten minutes ago
  v_iat_a2   bigint := extract(epoch from now())::bigint - 300;  -- A, five minutes ago
  v_iat_b1   bigint := extract(epoch from now())::bigint - 3600; -- B, an hour ago
begin
  insert into public.profiles (id, role, full_name, email, faculty, department, level)
    values
      (v_lecturer, 'lecturer', 'Lecturer',  'lecturer.ss@test.local', 'Science', 'CS', null),
      (v_a,        'student',  'Student A', 'a.ss@test.local',        null, null, null),
      (v_b,        'student',  'Student B', 'b.ss@test.local',        null, null, null);

  insert into public.exams (id, title, created_by, duration_minutes, is_published)
    values
      (v_exam,  'Single session paper',   v_lecturer, 60, true),
      (v_exam2, 'Single session paper 2', v_lecturer, 60, true);

  insert into public.questions (exam_id, question_text, question_type, points)
    values (v_exam, 'Q1', 'subjective', 1);

  select q.id into v_q from public.questions q where q.exam_id = v_exam limit 1;

  -- One ongoing attempt each: the row a takeover names, and the row the gate guards.
  insert into public.exam_submissions (student_id, exam_id, status, started_at)
    values
      (v_a, v_exam, 'ongoing', now() - interval '5 minutes'),
      (v_b, v_exam, 'ongoing', now() - interval '5 minutes');

  -- The acceptance a start row needs (`student_has_consent`), so (f) tests the
  -- insert policy rather than the consent check: a general acceptance of the version
  -- currently in force, written as postgres the way `record_consent()` would.
  insert into public.proctoring_consents (student_id, exam_id, consent_version)
    select p.id, null, public.current_proctor_consent_version()
      from public.profiles p
     where p.id in (v_a, v_b)
       and public.current_proctor_consent_version() is not null;

  perform set_config('test.a',      v_a::text, false);
  perform set_config('test.b',      v_b::text, false);
  perform set_config('test.exam',   v_exam::text, false);
  perform set_config('test.exam2',  v_exam2::text, false);
  perform set_config('test.q',      v_q::text, false);

  -- The two devices on A's account, and B's single device.
  perform set_config('test.dev_a1', 'dev-a1', false);
  perform set_config('test.dev_a2', 'dev-a2', false);
  perform set_config('test.dev_b1', 'dev-b1', false);
  perform set_config('test.iat_a1', v_iat_a1::text, false);
  perform set_config('test.iat_a2', v_iat_a2::text, false);
  perform set_config('test.iat_b1', v_iat_b1::text, false);

  perform set_config('test.sub_a',
    (select s.id::text from public.exam_submissions s where s.student_id = v_a), false);
  perform set_config('test.sub_b',
    (select s.id::text from public.exam_submissions s where s.student_id = v_b), false);
end $$;

-- =====================================================================
-- (a)  Before any claim the gate is open; the first claim records one row
-- =====================================================================
set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "session_id": "%s", "iat": %s}',
  current_setting('test.a'), current_setting('test.dev_a1'),
  current_setting('test.iat_a1')), true);

do $$
declare
  r     record;
  v_row public.active_sessions;
  v_n   int;
begin
  -- The two helpers read the token, not the table.
  if public.session_claim() is distinct from current_setting('test.dev_a1') then
    raise exception 'FAIL (a): session_claim() read "%s", expected the token''s session_id',
      coalesce(public.session_claim(), 'null');
  end if;
  if public.session_issued_at() is distinct from
       to_timestamp(current_setting('test.iat_a1')::bigint) then
    raise exception 'FAIL (a): session_issued_at() read "%s"',
      coalesce(public.session_issued_at()::text, 'null');
  end if;

  -- No row yet: fail open. This is the branch that keeps an older client working.
  if not public.is_current_session() then
    raise exception 'FAIL (a): an account that never claimed was locked out of its own attempt';
  end if;
  select count(*) into v_n from public.active_sessions;
  if v_n <> 0 then
    raise exception 'FAIL (a): active_sessions held % row(s) before the first claim', v_n;
  end if;

  select * into r from public.claim_session('android');
  if not r.accepted then
    raise exception 'FAIL (a): the first claim was refused';
  end if;
  if r.active_session_id is distinct from current_setting('test.dev_a1') then
    raise exception 'FAIL (a): the claim named "%s" as active', r.active_session_id;
  end if;
  if r.replaced_session_id is not null then
    raise exception 'FAIL (a): a first claim reported replacing "%s"', r.replaced_session_id;
  end if;
  if r.claimed_at is null or r.claimed_at < now() - interval '1 minute' then
    raise exception 'FAIL (a): claimed_at answered %', r.claimed_at;
  end if;

  select * into v_row from public.active_sessions where user_id = auth.uid();
  if v_row.user_id is null then
    raise exception 'FAIL (a): the first claim wrote no active_sessions row';
  end if;
  if v_row.session_id is distinct from current_setting('test.dev_a1') then
    raise exception 'FAIL (a): the row stored session "%s"', v_row.session_id;
  end if;
  if v_row.issued_at is distinct from to_timestamp(current_setting('test.iat_a1')::bigint) then
    raise exception 'FAIL (a): the row stored issued_at % (the token says %)',
      v_row.issued_at, to_timestamp(current_setting('test.iat_a1')::bigint);
  end if;
  if v_row.device_label is distinct from 'android' then
    raise exception 'FAIL (a): the row stored device_label "%s"', v_row.device_label;
  end if;
  if not public.is_current_session() then
    raise exception 'FAIL (a): the claiming session is not the current one';
  end if;

  -- A first claim replaces nothing, so nothing is audited. The audit table is
  -- staff-only under RLS, so that half is read as postgres after (c).

  raise notice 'PASS (a): fail-open before the first claim, exactly one row after it';
end $$;

reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (b)  The winning device claiming again is a no-op
-- =====================================================================
set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "session_id": "%s", "iat": %s}',
  current_setting('test.a'), current_setting('test.dev_a1'),
  current_setting('test.iat_a1')), true);

do $$
declare
  v_before timestamptz := (select a.claimed_at from public.active_sessions a
                            where a.user_id = auth.uid());
  r        record;
  v_row    public.active_sessions;
  v_n      int;
begin
  -- An app restart, a reconnect, the liveness check: the same token asks again.
  select * into r from public.claim_session('android');
  if not r.accepted then
    raise exception 'FAIL (b): the holding session was refused on a repeat claim';
  end if;
  if r.claimed_at is distinct from v_before then
    raise exception 'FAIL (b): a repeat claim moved claimed_at from % to %', v_before, r.claimed_at;
  end if;

  -- A missing label must not blank the one already stored.
  select * into r from public.claim_session(null);
  if not r.accepted then
    raise exception 'FAIL (b): a repeat claim with no label was refused';
  end if;

  select count(*) into v_n from public.active_sessions;
  if v_n <> 1 then
    raise exception 'FAIL (b): active_sessions held % row(s) after two repeat claims', v_n;
  end if;

  select * into v_row from public.active_sessions where user_id = auth.uid();
  if v_row.claimed_at is distinct from v_before then
    raise exception 'FAIL (b): the stored claimed_at moved from % to %', v_before, v_row.claimed_at;
  end if;
  if v_row.device_label is distinct from 'android' then
    raise exception 'FAIL (b): a null label blanked the stored one ("%s")', v_row.device_label;
  end if;

  raise notice 'PASS (b): a repeat claim keeps the row and the moment it was taken';
end $$;

reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (c)  A newer sign-in takes the account, and the takeover is audited
-- =====================================================================
set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "session_id": "%s", "iat": %s}',
  current_setting('test.a'), current_setting('test.dev_a2'),
  current_setting('test.iat_a2')), true);

do $$
declare
  r      record;
  v_row  public.active_sessions;
  v_prev timestamptz := (select a.claimed_at from public.active_sessions a
                          where a.user_id = auth.uid());
begin
  select * into r from public.claim_session('ios');
  if not r.accepted then
    raise exception 'FAIL (c): a newer sign-in was refused the account';
  end if;
  if r.active_session_id is distinct from current_setting('test.dev_a2') then
    raise exception 'FAIL (c): the claim named "%s" as active', r.active_session_id;
  end if;
  if r.replaced_session_id is distinct from current_setting('test.dev_a1') then
    raise exception 'FAIL (c): the claim reported replacing "%s", expected dev-a1',
      coalesce(r.replaced_session_id, 'null');
  end if;
  -- `now()` is this transaction's start, and the whole file is one transaction, so
  -- a takeover here answers the same instant as the claim it replaced. The rule
  -- that matters to a client is the other direction: the takeover must not record
  -- an earlier moment than the one it replaced, and the row it wrote must hold
  -- exactly the moment it answered (asserted below). A claim that kept the old
  -- device's timestamp would fail here.
  if r.claimed_at < v_prev then
    raise exception 'FAIL (c): claimed_at went backwards (% -> %)', v_prev, r.claimed_at;
  end if;

  select * into v_row from public.active_sessions where user_id = auth.uid();
  if v_row.session_id is distinct from current_setting('test.dev_a2') then
    raise exception 'FAIL (c): the row still names "%s"', v_row.session_id;
  end if;
  if v_row.claimed_at is distinct from r.claimed_at then
    raise exception 'FAIL (c): the claim answered claimed_at % but the row holds %',
      r.claimed_at, v_row.claimed_at;
  end if;
  if v_row.issued_at is distinct from to_timestamp(current_setting('test.iat_a2')::bigint) then
    raise exception 'FAIL (c): the row stored issued_at % (the new token says %)',
      v_row.issued_at, to_timestamp(current_setting('test.iat_a2')::bigint);
  end if;
  if v_row.device_label is distinct from 'ios' then
    raise exception 'FAIL (c): the row stored device_label "%s"', v_row.device_label;
  end if;
  if not public.is_current_session() then
    raise exception 'FAIL (c): the session that just won is not current';
  end if;

  raise notice 'PASS (c)i: the newer sign-in took the account';
end $$;

reset role;
select set_config('request.jwt.claims', '', true);

-- The audit is staff-only under RLS (`session_supersessions_select_staff`: admin, or
-- the paper's owner/supervisor), so it is read here as postgres - the same rows a
-- supervisor's query would return. It also proves the count: one takeover, one row,
-- so neither the first claim in (a) nor the repeats in (b) were audited.
do $$
declare
  v_log public.session_supersessions;
  v_n   int;
begin
  select count(*) into v_n from public.session_supersessions;
  if v_n <> 1 then
    raise exception 'FAIL (c)ii: % audit row(s) for one takeover', v_n;
  end if;

  select * into v_log from public.session_supersessions;
  if v_log.user_id is distinct from current_setting('test.a')::uuid then
    raise exception 'FAIL (c)ii: the audit row names user %', v_log.user_id;
  end if;
  if v_log.previous_session_id is distinct from current_setting('test.dev_a1')
     or v_log.new_session_id is distinct from current_setting('test.dev_a2') then
    raise exception 'FAIL (c)ii: the audit row records % -> %',
      v_log.previous_session_id, v_log.new_session_id;
  end if;
  -- "Did the second login happen while the paper was open?" - the question the
  -- submission_id/exam_id pair exists to answer.
  if v_log.submission_id is distinct from current_setting('test.sub_a')::uuid then
    raise exception 'FAIL (c)ii: the audit row names attempt %, expected the open one',
      coalesce(v_log.submission_id::text, 'null');
  end if;
  if v_log.exam_id is distinct from current_setting('test.exam')::uuid then
    raise exception 'FAIL (c)ii: the audit row names paper %',
      coalesce(v_log.exam_id::text, 'null');
  end if;
  if v_log.device_label is distinct from 'ios' then
    raise exception 'FAIL (c)ii: the audit row stored device_label "%s"', v_log.device_label;
  end if;
  if v_log.superseded_at is null then
    raise exception 'FAIL (c)ii: the audit row carries no superseded_at';
  end if;

  raise notice 'PASS (c)ii: one takeover, one audit row, naming both sessions and the open attempt';
end $$;

-- =====================================================================
-- (d)  The replaced device cannot take the account back
-- =====================================================================
set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "session_id": "%s", "iat": %s}',
  current_setting('test.a'), current_setting('test.dev_a1'),
  current_setting('test.iat_a1')), true);

do $$
declare
  r      record;
  v_row  public.active_sessions;
begin
  -- A restored tab, an app resumed from the background: the old token calls again.
  -- Its `iat` is older than the stored one, so it loses - "newest wins", not "last to
  -- call wins".
  select * into r from public.claim_session('android');
  if r.accepted then
    raise exception 'FAIL (d): the replaced device took the account back';
  end if;
  if r.active_session_id is distinct from current_setting('test.dev_a2') then
    raise exception 'FAIL (d): the refusal named "%s", expected the winner dev-a2',
      coalesce(r.active_session_id, 'null');
  end if;
  if r.replaced_session_id is not null then
    raise exception 'FAIL (d): a refused claim reported replacing "%s"', r.replaced_session_id;
  end if;

  select * into v_row from public.active_sessions where user_id = auth.uid();
  if v_row.session_id is distinct from current_setting('test.dev_a2') then
    raise exception 'FAIL (d): the refused claim moved the row to "%s"', v_row.session_id;
  end if;
  if r.claimed_at is distinct from v_row.claimed_at then
    raise exception 'FAIL (d): the refusal reported claimed_at % but the row holds %',
      r.claimed_at, v_row.claimed_at;
  end if;
  if public.is_current_session() then
    raise exception 'FAIL (d): the replaced device still answers is_current_session() = true';
  end if;

  raise notice 'PASS (d): the replaced device is refused and the row does not move';
end $$;

reset role;
select set_config('request.jwt.claims', '', true);

-- The refusal wrote nothing: still exactly one audit row, and it still points the
-- same way.
do $$
declare
  v_n int;
begin
  select count(*) into v_n from public.session_supersessions;
  if v_n <> 1 then
    raise exception 'FAIL (d): a refused claim added an audit row (% rows)', v_n;
  end if;
  raise notice 'PASS (d): a refused claim is not a takeover and is not audited';
end $$;

-- =====================================================================
-- (e)  Every write path refuses the replaced device with PT409
-- =====================================================================
-- One block, five calls, one SQLSTATE. `PT409` (class PT = PostgreSQL's "other"
-- branch) is deliberately not 55000 ("this attempt is closed") and not 42501 ("not
-- yours"): the client turns exactly this code into "You signed in on another
-- device", and nothing else.
set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "session_id": "%s", "iat": %s}',
  current_setting('test.a'), current_setting('test.dev_a1'),
  current_setting('test.iat_a1')), true);

do $$
declare
  v_sub uuid := current_setting('test.sub_a')::uuid;
  v_q   uuid := current_setting('test.q')::uuid;
begin
  begin
    perform public.merge_submission_answer(v_sub, v_q, 2);
    raise exception 'FAIL (e)i: a replaced device saved an option answer';
  exception when sqlstate 'PT409' then
    raise notice 'PASS (e)i: merge_submission_answer refused a replaced device';
  end;

  begin
    perform public.merge_submission_text_answer(v_sub, v_q, 'late text');
    raise exception 'FAIL (e)i: a replaced device saved a free-text answer';
  exception when sqlstate 'PT409' then
    raise notice 'PASS (e)i: merge_submission_text_answer refused a replaced device';
  end;

  begin
    perform 1 from public.submit_exam(v_sub);
    raise exception 'FAIL (e)i: a replaced device handed the paper in';
  exception when sqlstate 'PT409' then
    raise notice 'PASS (e)i: submit_exam refused a replaced device';
  end;

  begin
    perform 1 from public.register_violation(v_sub, 'looking_away');
    raise exception 'FAIL (e)i: a replaced device registered a violation';
  exception when sqlstate 'PT409' then
    raise notice 'PASS (e)i: register_violation refused a replaced device';
  end;

  begin
    perform 1 from public.record_heartbeat(v_sub, true, true, '0.9.0');
    raise exception 'FAIL (e)i: a replaced device sent a heartbeat';
  exception when sqlstate 'PT409' then
    raise notice 'PASS (e)i: record_heartbeat refused a replaced device';
  end;
end $$;

reset role;
select set_config('request.jwt.claims', '', true);

-- The refusals wrote nothing at all: not a partial answer, not a log row, not a beat,
-- and the attempt is still open. Read as postgres so the answer does not depend on a
-- student's read policy.
do $$
declare
  v_sub   uuid := current_setting('test.sub_a')::uuid;
  s       public.exam_submissions;
  v_logs  int;
  v_beats int;
begin
  select * into s from public.exam_submissions where id = v_sub;
  if s.answers <> '{}'::jsonb then
    raise exception 'FAIL (e)i: a refused write still landed: answers = %', s.answers;
  end if;
  if s.status <> 'ongoing' then
    raise exception 'FAIL (e)i: a refused hand-in closed the attempt (status %)', s.status;
  end if;
  if s.submitted_at is not null then
    raise exception 'FAIL (e)i: a refused hand-in set submitted_at = %', s.submitted_at;
  end if;
  if s.last_heartbeat_at is not null then
    raise exception 'FAIL (e)i: a refused beat recorded last_heartbeat_at = %', s.last_heartbeat_at;
  end if;

  select count(*) into v_logs from public.proctoring_logs where submission_id = v_sub;
  if v_logs <> 0 then
    raise exception 'FAIL (e)i: a refused violation left % proctoring_logs row(s)', v_logs;
  end if;

  select count(*) into v_beats from public.proctor_heartbeats where submission_id = v_sub;
  if v_beats <> 0 then
    raise exception 'FAIL (e)i: a refused beat left % proctor_heartbeats row(s)', v_beats;
  end if;

  raise notice 'PASS (e)i: five refusals, nothing written';
end $$;

-- =====================================================================
-- (e)ii  The same five calls from the winning device succeed
-- =====================================================================
-- The gate is a *replacement* check, not a lock: the account keeps writing the
-- moment it holds the row. Same account, same attempt, same paper - only the token
-- differs from (e)i.
set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "session_id": "%s", "iat": %s}',
  current_setting('test.a'), current_setting('test.dev_a2'),
  current_setting('test.iat_a2')), true);

do $$
declare
  v_sub uuid := current_setting('test.sub_a')::uuid;
  v_q   uuid := current_setting('test.q')::uuid;
  r     record;
begin
  perform public.merge_submission_answer(v_sub, v_q, 2);
  perform public.merge_submission_text_answer(v_sub, v_q, 'on the new phone');

  select * into r from public.register_violation(v_sub, 'looking_away', null, now(),
                                                gen_random_uuid());
  if r.warning_count <> 1 or r.disqualified then
    raise exception 'FAIL (e)ii: the winner''s strike came back as % / disqualified %',
      r.warning_count, r.disqualified;
  end if;

  select * into r from public.record_heartbeat(v_sub, true, true, '0.9.0', now(),
                                               gen_random_uuid());
  if r.outcome <> 'recorded' then
    raise exception 'FAIL (e)ii: the winner''s beat answered "%s", expected recorded', r.outcome;
  end if;

  if not public.is_current_session() then
    raise exception 'FAIL (e)ii: the winner stopped being current while writing';
  end if;

  raise notice 'PASS (e)ii: the winning device writes answers, a strike and a beat';
end $$;

reset role;
select set_config('request.jwt.claims', '', true);

-- And those writes did land (same postgres read as before, inverted).
do $$
declare
  v_sub  uuid := current_setting('test.sub_a')::uuid;
  s      public.exam_submissions;
  v_logs int;
  v_beats int;
begin
  select * into s from public.exam_submissions where id = v_sub;
  if s.answers ->> current_setting('test.q') is distinct from 'on the new phone' then
    raise exception 'FAIL (e)ii: the free-text answer did not land (answers = %)', s.answers;
  end if;
  if s.status <> 'ongoing' then
    raise exception 'FAIL (e)ii: a strike closed the attempt (status %)', s.status;
  end if;
  if s.last_heartbeat_at is null then
    raise exception 'FAIL (e)ii: the winner''s beat recorded no last_heartbeat_at';
  end if;

  select count(*) into v_logs from public.proctoring_logs where submission_id = v_sub;
  if v_logs <> 1 then
    raise exception 'FAIL (e)ii: % proctoring_logs row(s) for one strike', v_logs;
  end if;

  select count(*) into v_beats from public.proctor_heartbeats where submission_id = v_sub;
  if v_beats <> 1 then
    raise exception 'FAIL (e)ii: % proctor_heartbeats row(s) for one beat', v_beats;
  end if;

  raise notice 'PASS (e)ii: the winner''s writes landed, and only the winner''s';
end $$;

-- =====================================================================
-- (f)  A replaced device cannot open a second attempt; the winner can
-- =====================================================================
-- `submissions_insert_own_ongoing` is the one write during a sitting that is not an
-- RPC, so it carries its own `is_current_session()` arm. Without it a superseded
-- device could start a fresh attempt - answers empty, clock restarted - and keep
-- writing into *that* one, because every later gate would compare it with a row it
-- had just created.
set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "session_id": "%s", "iat": %s}',
  current_setting('test.a'), current_setting('test.dev_a1'),
  current_setting('test.iat_a1')), true);

do $$
declare
  v_exam2 uuid := current_setting('test.exam2')::uuid;
  v_n     int;
begin
  begin
    insert into public.exam_submissions (student_id, exam_id)
    values (auth.uid(), v_exam2);
    raise exception 'FAIL (f): a replaced device opened a second attempt';
  exception when insufficient_privilege then
    raise notice 'PASS (f)i: the insert policy refused a replaced device (42501)';
  end;

  -- A refused WITH CHECK writes nothing: the subtransaction rolled the row back.
  select count(*) into v_n
    from public.exam_submissions s
   where s.exam_id = v_exam2;
  if v_n <> 0 then
    raise exception 'FAIL (f)i: the refused insert left % row(s)', v_n;
  end if;
end $$;

reset role;
select set_config('request.jwt.claims', '', true);

-- The winner starts it instead - same paper, same account, later token.
set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "session_id": "%s", "iat": %s}',
  current_setting('test.a'), current_setting('test.dev_a2'),
  current_setting('test.iat_a2')), true);

do $$
declare
  v_exam2 uuid := current_setting('test.exam2')::uuid;
  s       public.exam_submissions;
  v_n     int;
begin
  insert into public.exam_submissions (student_id, exam_id)
  values (auth.uid(), v_exam2);

  select count(*) into v_n
    from public.exam_submissions sub
   where sub.exam_id = v_exam2 and sub.student_id = auth.uid();
  if v_n <> 1 then
    raise exception 'FAIL (f)ii: the winner''s start row is % row(s), expected 1', v_n;
  end if;

  select * into s from public.exam_submissions sub
   where sub.exam_id = v_exam2 and sub.student_id = auth.uid();
  if s.status <> 'ongoing' or s.answers <> '{}'::jsonb then
    raise exception 'FAIL (f)ii: the start row is % with answers %', s.status, s.answers;
  end if;

  raise notice 'PASS (f)ii: the winning device opens the attempt';
end $$;

reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (g)  A token with no session_id claim, and a second account
-- =====================================================================
-- Two compatibility properties, both load-bearing:
--   1. a client that predates `session_id` (or any request without a token) has
--      nothing to contradict, so the gate lets it through - and `claim_session()`
--      says so plainly (22023) rather than writing an unusable claim;
--   2. the order is per account. B's token is an hour old, older than A's claim by
--      nine minutes, and it still wins B's own account.
set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated"}', current_setting('test.a')), true);

do $$
declare
  v_sub uuid := current_setting('test.sub_a')::uuid;
  r     record;
begin
  if not public.is_current_session() then
    raise exception 'FAIL (g): a token with no session_id claim was locked out - an older client would stop working';
  end if;
  if public.session_claim() is not null then
    raise exception 'FAIL (g): session_claim() answered "%s" for a token that carries none',
      public.session_claim();
  end if;

  begin
    select * into r from public.claim_session('legacy');
    raise exception 'FAIL (g): claim_session() accepted a request with no session_id';
  exception when invalid_parameter_value then
    raise notice 'PASS (g)i: a token with no session_id is let through and cannot claim (22023)';
  end;

  -- The gate still lets such a caller write: that is the fail-open half, on purpose.
  -- The *outcome* is allowed to be 'throttled' - (e)ii beat a few seconds ago and the
  -- window is 8s - so what this asserts is that no exception was raised and the
  -- liveness row was refreshed, not which of the three accepted answers came back.
  select * into r from public.record_heartbeat(v_sub, true, true, '0.8.0', now(),
                                               gen_random_uuid());
  if r.outcome not in ('recorded', 'throttled', 'duplicate') then
    raise exception 'FAIL (g): an older client''s beat answered "%s"', r.outcome;
  end if;
  if (select s.last_heartbeat_at from public.exam_submissions s where s.id = v_sub) is null then
    raise exception 'FAIL (g): an older client''s beat refreshed no liveness';
  end if;
  raise notice 'PASS (g)i: a request with no session_id claim still writes its own attempt';
end $$;

reset role;
select set_config('request.jwt.claims', '', true);

-- B signs in. B has no claim row, so an hour-old token is still the newest thing on
-- B's account - and A's takeover must not have touched it.
set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "session_id": "%s", "iat": %s}',
  current_setting('test.b'), current_setting('test.dev_b1'),
  current_setting('test.iat_b1')), true);

do $$
declare
  r     record;
  v_row public.active_sessions;
  v_n   int;
begin
  select * into r from public.claim_session('desktop');
  if not r.accepted then
    raise exception 'FAIL (g)ii: B''s first claim was refused because A had signed in twice';
  end if;
  if r.replaced_session_id is not null then
    raise exception 'FAIL (g)ii: B''s first claim reported replacing "%s"', r.replaced_session_id;
  end if;

  select * into v_row from public.active_sessions where user_id = auth.uid();
  if v_row.session_id is distinct from current_setting('test.dev_b1') then
    raise exception 'FAIL (g)ii: B''s row names "%s"', coalesce(v_row.session_id, 'null');
  end if;
  if v_row.issued_at is distinct from to_timestamp(current_setting('test.iat_b1')::bigint) then
    raise exception 'FAIL (g)ii: B''s row stored issued_at %', v_row.issued_at;
  end if;
  if not public.is_current_session() then
    raise exception 'FAIL (g)ii: B cannot write its own attempt';
  end if;

  select count(*) into v_n from public.active_sessions;
  if v_n <> 1 then
    raise exception 'FAIL (g)ii: active_sessions holds % row(s), expected one account''s', v_n;
  end if;

  raise notice 'PASS (g)ii: B''s older token wins B''s own account';
end $$;

reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (h)  Nobody can write their own claim, and only the owner can read it
-- =====================================================================
-- `active_sessions` has a read policy and **no write policy**: `claim_session()`
-- is SECURITY DEFINER and is the only writer. A client that could UPDATE its own
-- row could name itself the winner after losing, which would make the whole section
-- advisory. Each attempt below is wrapped: whether the server answers "no rows"
-- (the policy filters everything) or raises, the stored claim must not move.
set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "session_id": "%s", "iat": %s}',
  current_setting('test.a'), current_setting('test.dev_a2'),
  current_setting('test.iat_a2')), true);

do $$
declare
  v_row public.active_sessions;
  v_n   int;
begin
  begin
    update public.active_sessions set session_id = 'hijacked' where user_id = auth.uid();
  exception when others then null;
  end;

  begin
    delete from public.active_sessions where user_id = auth.uid();
  exception when others then null;
  end;

  begin
    insert into public.active_sessions (user_id, session_id, issued_at)
    values (auth.uid(), 'hijacked', now());
    raise exception 'FAIL (h): a client inserted its own claim row';
  exception when insufficient_privilege then
    null;
  end;

  select * into v_row from public.active_sessions where user_id = auth.uid();
  if v_row.session_id is distinct from current_setting('test.dev_a2') then
    raise exception 'FAIL (h): the claim moved to "%s" without claim_session()',
      coalesce(v_row.session_id, 'null');
  end if;
  if not public.is_current_session() then
    raise exception 'FAIL (h): a client write left the account gated against itself';
  end if;

  -- The audit is staff-only: the student it happened to cannot read it back.
  select count(*) into v_n from public.session_supersessions;
  if v_n <> 0 then
    raise exception 'FAIL (h): a student can read % session_supersessions row(s)', v_n;
  end if;

  raise notice 'PASS (h): the claim is read-only from a client and the audit is staff-only';
end $$;

reset role;
select set_config('request.jwt.claims', '', true);

-- B cannot read A's claim: the read policy is `user_id = auth.uid()`.
set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "session_id": "%s", "iat": %s}',
  current_setting('test.b'), current_setting('test.dev_b1'),
  current_setting('test.iat_b1')), true);

do $$
declare
  v_n int;
begin
  select count(*) into v_n
    from public.active_sessions
   where user_id = current_setting('test.a')::uuid;
  if v_n <> 0 then
    raise exception 'FAIL (h): B can read % of A''s claim row(s)', v_n;
  end if;
  raise notice 'PASS (h): a claim row is visible to its owner only';
end $$;

reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (i)  The winner still owns the attempt end to end
-- =====================================================================
-- The gate must not read as "the account is locked after a takeover": the device
-- that won carries on, closes the paper, and is graded.
set local role authenticated;
select set_config('request.jwt.claims', format(
  '{"sub": "%s", "role": "authenticated", "session_id": "%s", "iat": %s}',
  current_setting('test.a'), current_setting('test.dev_a2'),
  current_setting('test.iat_a2')), true);

do $$
declare
  v_sub uuid := current_setting('test.sub_a')::uuid;
  r     record;
  s     public.exam_submissions;
begin
  select * into r from public.submit_exam(v_sub);
  if r.result_status is distinct from 'submitted' then
    raise exception 'FAIL (i): the winner''s hand-in answered "%s"', r.result_status;
  end if;
  if r.final_score is distinct from 0 then
    raise exception 'FAIL (i): a paper with no automatically graded answer scored %',
      r.final_score;
  end if;

  select * into s from public.exam_submissions where id = v_sub;
  if s.status <> 'submitted' or s.submitted_at is null then
    raise exception 'FAIL (i): the attempt is % with submitted_at %', s.status, s.submitted_at;
  end if;

  raise notice 'PASS (i): the winning session closes and grades the attempt';
end $$;

reset role;
select set_config('request.jwt.claims', '', true);

-- Nothing survives: the fixture users, papers, attempts, claims and audit rows all
-- go with the transaction.
rollback;
