-- =====================================================================
-- PROCTORING CONSENTS + SNAPSHOT RETENTION TEST
-- run against a LOCAL `supabase start` database
-- =====================================================================
-- Run from the repo root with:
--
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres
--     -f supabase/tests/proctoring_consents_check.sql
--
-- Prerequisites: `supabase start` is running and `supabase db reset` has applied
-- `supabase/schema.sql` (which already carries
-- `20261106090000_proctoring_consents.sql`), and
-- `supabase/migrations/retention_policy.sql` for sections (g) and (h). Missing
-- pieces report SKIP for the sections that need them instead of failing.
--
-- WHAT IT PROVES
--   (a) `record_consent()` stores what a student accepted - the version, the
--       server's own timestamp, the paper - and is idempotent: a replay returns
--       the same row instead of a second one.
--   (b) the read policy is "my own acceptance, or the intervention tier": another
--       student sees nothing, a supervisor sees the row.
--   (c) an acceptance cannot be forged, rewritten or removed by an API caller:
--       no insert for somebody else, no update, no delete. The absence of those
--       grants and policies *is* the control.
--   (d) the RPC refuses what it is not for: no session (28000), a blank version
--       (22023), and a paper the student cannot sit (42501).
--   (e) `submissions_insert_own_ongoing` refuses an attempt with no consent, and
--       allows one after an exam-scoped acceptance - for that paper only - or
--       after a general acceptance (a row with `exam_id IS NULL`).
--   (f) only the version currently in force counts: a consent recorded for older
--       wording stops unlocking the insert the moment `current_version` moves,
--       and the new acceptance unlocks it again.
--   (g) `purge_expired_snapshots()` deletes the expired objects of finished
--       attempts, keeps a live sitting's - and a fresh still's - alone, and keeps
--       the incident row while nulling the pointer to the photograph. A dry run
--       deletes nothing, and a window of zero is refused. The (g) block sets
--       `storage.allow_delete_query` as its *first* statement - the flag the
--       Storage API sets on itself while it is the one deleting - so that on a
--       hosted project the live run reaches the policy instead of the
--       `protect_delete` trigger. Nothing later in that block may reset it, and
--       `mobile/test/schema_contract_test.dart` pins the ordering.
--   (h) the retention windows the notice quotes exist: `proctor_snapshots` 30,
--       `profiles` and `exam_submissions` 180.
--
-- HOW RLS IS APPLIED
--   Identical to `weighted_strikes_check.sql` and
--   `proctoring_heartbeats_check.sql`: `set local role authenticated` plus a
--   `request.jwt.claims` carrying the caller's uuid, then `reset role` and a blank
--   claims string before the next fixture write, because `guard_profile_labels()`
--   refuses a label write from a caller holding claims.
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
  v_lecturer    uuid := gen_random_uuid();
  v_supervisor  uuid := gen_random_uuid();
  v_none        uuid := gen_random_uuid();  -- (e) never accepts anything
  v_exam        uuid := gen_random_uuid();  -- (e) accepts for one paper only
  v_global      uuid := gen_random_uuid();  -- (e) general acceptance
  v_stale       uuid := gen_random_uuid();  -- (e) accepted older wording
  v_version     uuid := gen_random_uuid();  -- (f) acceptance vs a version bump
  v_other       uuid := gen_random_uuid();  -- (b) must not read a classmate's row
  v_closed      uuid := gen_random_uuid();  -- (g) finished attempt with a still
  v_live        uuid := gen_random_uuid();  -- (g) ongoing attempt with a still
  v_orphan      uuid := gen_random_uuid();  -- (g) folder with no attempt left
  v_exam_a      uuid := gen_random_uuid();
  v_exam_b      uuid := gen_random_uuid();
  v_version_now text;
begin
  insert into public.profiles (id, role, full_name, email) values
    (v_lecturer,   'lecturer',   'Ada Lecturer',    'ada.consent@test.local'),
    (v_supervisor, 'supervisor', 'Musa Supervisor', 'musa.consent@test.local'),
    (v_none,       'student',    'No Consent',      'none.consent@test.local'),
    (v_exam,       'student',    'Exam Consent',    'exam.consent@test.local'),
    (v_global,     'student',    'Global Consent',  'global.consent@test.local'),
    (v_stale,      'student',    'Stale Consent',   'stale.consent@test.local'),
    (v_version,    'student',    'Version Consent', 'version.consent@test.local'),
    (v_other,      'student',    'Other Student',   'other.consent@test.local'),
    (v_closed,     'student',    'Closed Attempt',  'closed.consent@test.local'),
    (v_live,       'student',    'Live Attempt',    'live.consent@test.local');

  -- Two published papers with no cohort labels: `student_can_access_exam()` reads
  -- a blank label as "no narrowing", so every student above may sit both - which
  -- is what makes a refusal in (e) mean "refused for want of consent" and nothing
  -- else.
  insert into public.exams (id, title, created_by, duration_minutes, is_published) values
    (v_exam_a, 'Consent paper A', v_lecturer, 60, true),
    (v_exam_b, 'Consent paper B', v_lecturer, 60, true);

  -- `20261109090000_supervisor_exam_assignments.sql`: a supervisor now reaches the
  -- papers an administrator assigned to them, so the supervisor tier this file
  -- exercises on both papers is assigned to both. The scope itself - a supervisor
  -- with *no* row reaching nothing - is proven in `supervisor_scope_check.sql`.
  insert into public.supervisor_exam_assignments (exam_id, supervisor_id, assigned_by)
    values (v_exam_a, v_supervisor, v_lecturer),
           (v_exam_b, v_supervisor, v_lecturer);

  -- Attempts the insert policy is not under test for: one finished (its still may
  -- expire) and one still running (its still may not). Written as postgres, so no
  -- consent is involved.
  insert into public.exam_submissions (student_id, exam_id, status, started_at, submitted_at)
    values
      (v_closed, v_exam_a, 'submitted', now() - interval '2 hours', now() - interval '1 hour'),
      (v_live,   v_exam_a, 'ongoing',   now() - interval '30 minutes', null);

  -- The version the migration shipped. Every block below compares against it
  -- rather than hard-coding the string, so bumping the notice does not fail this
  -- file - only breaking the *rule* does.
  select cc.current_version into v_version_now
    from public.proctoring_consent_config cc where cc.id = 1;

  perform set_config('test.lecturer',   v_lecturer::text, false);
  perform set_config('test.supervisor', v_supervisor::text, false);
  perform set_config('test.none',       v_none::text, false);
  perform set_config('test.exam_stu',   v_exam::text, false);
  perform set_config('test.global',     v_global::text, false);
  perform set_config('test.stale',      v_stale::text, false);
  perform set_config('test.version',    v_version::text, false);
  perform set_config('test.other',      v_other::text, false);
  perform set_config('test.closed',     v_closed::text, false);
  perform set_config('test.live',       v_live::text, false);
  perform set_config('test.orphan',     v_orphan::text, false);
  perform set_config('test.exam_a',     v_exam_a::text, false);
  perform set_config('test.exam_b',     v_exam_b::text, false);
  perform set_config('test.version_now', coalesce(v_version_now, ''), false);
  perform set_config('test.sub_closed',
    (select id::text from public.exam_submissions where student_id = v_closed), false);
  perform set_config('test.sub_live',
    (select id::text from public.exam_submissions where student_id = v_live), false);
end $$;


-- =====================================================================
-- (a)  An acceptance is stored once, with the version and the server's clock
-- =====================================================================
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "exam.consent@test.local"}',
         current_setting('test.exam_stu')), true);
do $$
declare
  v_exam    uuid := current_setting('test.exam_a')::uuid;
  v_version text := current_setting('test.version_now');
  r1        record;
  r2        record;
  v_rows    int;
  v_stored  public.proctoring_consents;
begin
  if v_version = '' then
    raise exception 'FAIL (a): proctoring_consent_config has no current_version';
  end if;

  select * into r1 from public.record_consent(v_exam, v_version);

  if r1.consent_id is null then
    raise exception 'FAIL (a): record_consent returned no row id';
  end if;
  if r1.consent_version <> v_version then
    raise exception 'FAIL (a): stored version % , expected %', r1.consent_version, v_version;
  end if;
  if r1.is_current is not true then
    raise exception 'FAIL (a): the version just read from the config is not reported as current';
  end if;
  if r1.accepted_at is null or r1.accepted_at < now() - interval '5 seconds' then
    raise exception 'FAIL (a): accepted_at is not the server clock (%)', r1.accepted_at;
  end if;

  select * into v_stored from public.proctoring_consents where id = r1.consent_id;
  if v_stored.id is null then
    raise exception 'FAIL (a): the acceptance was not stored';
  end if;
  if v_stored.student_id <> auth.uid() then
    raise exception 'FAIL (a): stored student_id % , expected the caller %',
      v_stored.student_id, auth.uid();
  end if;
  if v_stored.exam_id is distinct from v_exam then
    raise exception 'FAIL (a): stored exam_id was not the paper asked for';
  end if;

  -- A replay after a lost response must not become a second acceptance.
  select * into r2 from public.record_consent(v_exam, v_version);
  if r2.consent_id is distinct from r1.consent_id then
    raise exception 'FAIL (a): a replayed call wrote a new acceptance';
  end if;

  select count(*) into v_rows from public.proctoring_consents
   where student_id = auth.uid() and exam_id = v_exam;
  if v_rows <> 1 then
    raise exception 'FAIL (a): expected 1 row for this paper, found %', v_rows;
  end if;

  raise notice 'PASS (a): one acceptance stored, versioned, idempotent on replay';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (b)  Who may read an acceptance
-- =====================================================================
-- The acceptance recorded in (a) belongs to `test.exam_stu`. A classmate must not
-- see it; a supervisor must. (The `is_staff()` arm is deliberately absent from
-- this policy, so a lecturer is checked below too.)
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "other.consent@test.local"}',
         current_setting('test.other')), true);
do $$
declare
  v_exam    uuid := current_setting('test.exam_a')::uuid;
  v_visible int;
begin
  select count(*) into v_visible from public.proctoring_consents where exam_id = v_exam;
  if v_visible <> 0 then
    raise exception 'FAIL (b): a classmate read % acceptance row(s)', v_visible;
  end if;
  if public.student_has_consent(v_exam) then
    raise exception 'FAIL (b): a classmate inherits somebody else''s acceptance';
  end if;
  raise notice 'PASS (b): a classmate sees nothing';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "musa.consent@test.local"}',
         current_setting('test.supervisor')), true);
do $$
declare
  v_exam    uuid := current_setting('test.exam_a')::uuid;
  v_visible int;
begin
  select count(*) into v_visible from public.proctoring_consents where exam_id = v_exam;
  if v_visible < 1 then
    raise exception 'FAIL (b): a supervisor could not read the acceptance';
  end if;
  raise notice 'PASS (b): the intervention tier reads it';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);


-- A lecturer reads the evidence of a sitting but not "did this person agree": the
-- read policy is `is_exam_supervisor()` (admin + supervisor), not `is_staff()`.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "ada.consent@test.local"}',
         current_setting('test.lecturer')), true);
do $$
declare
  v_exam    uuid := current_setting('test.exam_a')::uuid;
  v_visible int;
begin
  select count(*) into v_visible from public.proctoring_consents where exam_id = v_exam;
  if v_visible <> 0 then
    raise exception 'FAIL (b): a lecturer read % consent row(s) - the tier is too wide', v_visible;
  end if;
  raise notice 'PASS (b): a lecturer does not read acceptances';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (c)  An acceptance cannot be forged, rewritten or removed
-- =====================================================================
-- The control is the absence of a grant and of a policy: no INSERT for somebody
-- else's id, no UPDATE, no DELETE. Run as the student who owns the row - the
-- hardest case, because "own row" is exactly what an INSERT policy allows.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "exam.consent@test.local"}',
         current_setting('test.exam_stu')), true);
do $$
declare
  v_exam   uuid := current_setting('test.exam_a')::uuid;
  v_other  uuid := current_setting('test.other')::uuid;
  v_id     uuid;
  v_rows   int;
begin
  select id into v_id from public.proctoring_consents
   where student_id = auth.uid() and exam_id = v_exam
   limit 1;

  -- i: no acceptance in somebody else's name.
  begin
    insert into public.proctoring_consents (student_id, exam_id, consent_version)
      values (v_other, v_exam, 'forged');
    raise exception 'FAIL (c)i: a student inserted an acceptance for a classmate';
  exception
    when insufficient_privilege or check_violation then null;
  end;

  -- ii: no rewriting of an acceptance that exists.
  begin
    update public.proctoring_consents set consent_version = 'rewritten' where id = v_id;
    get diagnostics v_rows = row_count;
    if v_rows <> 0 then
      raise exception 'FAIL (c)ii: a student rewrote an acceptance (% row(s))', v_rows;
    end if;
  exception
    when insufficient_privilege then null;
  end;

  -- iii: no removal of an acceptance that exists.
  begin
    delete from public.proctoring_consents where id = v_id;
    get diagnostics v_rows = row_count;
    if v_rows <> 0 then
      raise exception 'FAIL (c)iii: a student deleted an acceptance (% row(s))', v_rows;
    end if;
  exception
    when insufficient_privilege then null;
  end;

  -- ...and the row the update/delete just tried to touch is still exactly as it
  -- was: the assertions above prove the statement was refused, this proves the
  -- consequence.
  if (select consent_version from public.proctoring_consents where id = v_id)
       <> current_setting('test.version_now') then
    raise exception 'FAIL (c): the stored version changed';
  end if;

  raise notice 'PASS (c): acceptances are write-once for an API caller';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);


-- =====================================================================
-- (d)  The RPC refuses what it is not for
-- =====================================================================
-- i: no session. Run as postgres with no claims, so the only guard that can fire
-- is the function's own `auth.uid()` check (the table grants would not even be
-- reached from the API for an anonymous caller).
select set_config('request.jwt.claims', '', true);
do $$
declare
  v_exam uuid := current_setting('test.exam_a')::uuid;
begin
  begin
    perform public.record_consent(v_exam, 'no-session');
    raise exception 'FAIL (d)i: record_consent accepted a caller with no session';
  exception
    when sqlstate '28000' then null;
  end;
  raise notice 'PASS (d)i: no session is refused (28000)';
end $$;

-- ii and iii: a blank version, and a paper the student cannot sit.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "none.consent@test.local"}',
         current_setting('test.none')), true);
do $$
declare
  v_exam uuid := current_setting('test.exam_a')::uuid;
begin
  begin
    perform public.record_consent(v_exam, '   ');
    raise exception 'FAIL (d)ii: a blank version was accepted';
  exception
    when sqlstate '22023' then null;
  end;

  begin
    perform public.record_consent(gen_random_uuid(), current_setting('test.version_now'));
    raise exception 'FAIL (d)iii: an acceptance was recorded for a paper that does not exist';
  exception
    when insufficient_privilege then null;
  end;

  raise notice 'PASS (d): blank version refused (22023), unknown paper refused (42501)';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (e)  Consent is a condition of starting an attempt
-- =====================================================================

-- (e) i: no consent, no attempt. `test.none` has accepted nothing.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "none.consent@test.local"}',
         current_setting('test.none')), true);
do $$
declare
  v_exam uuid := current_setting('test.exam_a')::uuid;
begin
  if public.student_has_consent(v_exam) then
    raise exception 'FAIL (e)i: student_has_consent() is true with no acceptance';
  end if;

  begin
    insert into public.exam_submissions (exam_id, student_id, status)
      values (v_exam, auth.uid(), 'ongoing');
    raise exception 'FAIL (e)i: an attempt was created without any consent';
  exception
    when insufficient_privilege then null;
  end;

  if exists (select 1 from public.exam_submissions
              where student_id = auth.uid() and exam_id = v_exam) then
    raise exception 'FAIL (e)i: the refused insert left an attempt row behind';
  end if;

  raise notice 'PASS (e)i: no consent, no attempt (42501)';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);


-- (e) ii: the student who accepted for paper A (in (a)) may start paper A...
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "exam.consent@test.local"}',
         current_setting('test.exam_stu')), true);
do $$
declare
  v_a uuid := current_setting('test.exam_a')::uuid;
  v_b uuid := current_setting('test.exam_b')::uuid;
begin
  if not public.student_has_consent(v_a) then
    raise exception 'FAIL (e)ii: the acceptance from (a) does not satisfy the predicate';
  end if;

  insert into public.exam_submissions (exam_id, student_id, status)
    values (v_a, auth.uid(), 'ongoing');

  -- ...but not paper B: an exam-scoped acceptance covers one paper, and a
  -- classmate's general acceptance covers none of this student's.
  begin
    insert into public.exam_submissions (exam_id, student_id, status)
      values (v_b, auth.uid(), 'ongoing');
    raise exception 'FAIL (e)ii: an exam-scoped acceptance unlocked another paper';
  exception
    when insufficient_privilege then null;
  end;

  raise notice 'PASS (e)ii: an exam-scoped acceptance opens that paper only';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (e) iii: a general acceptance (exam_id IS NULL) covers every paper. `test.global`
-- records one and starts paper B, which it has never consented to individually.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "global.consent@test.local"}',
         current_setting('test.global')), true);
do $$
declare
  v_b  uuid := current_setting('test.exam_b')::uuid;
  r    record;
begin
  select * into r from public.record_consent(null, current_setting('test.version_now'));
  if r.consent_id is null then
    raise exception 'FAIL (e)iii: a general acceptance was not recorded';
  end if;
  if r.is_current is not true then
    raise exception 'FAIL (e)iii: the general acceptance is not for the current version';
  end if;

  if not public.student_has_consent(v_b) then
    raise exception 'FAIL (e)iii: a general acceptance does not satisfy the predicate';
  end if;

  insert into public.exam_submissions (exam_id, student_id, status)
    values (v_b, auth.uid(), 'ongoing');

  raise notice 'PASS (e)iii: a general acceptance covers a paper never named';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- (e) iv: a consent recorded for *older wording* is stored (the client is not
-- lying about what it showed) but unlocks nothing: `is_current` is false and the
-- insert is refused.
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "stale.consent@test.local"}',
         current_setting('test.stale')), true);
do $$
declare
  v_a uuid := current_setting('test.exam_a')::uuid;
  r   record;
begin
  select * into r from public.record_consent(v_a, 'draft-notice-v0');

  if r.is_current is not false then
    raise exception 'FAIL (e)iv: an old version string was reported as current';
  end if;
  if r.consent_version <> 'draft-notice-v0' then
    raise exception 'FAIL (e)iv: the stored version was not what the client reported';
  end if;

  if public.student_has_consent(v_a) then
    raise exception 'FAIL (e)iv: consent to replaced wording satisfies the predicate';
  end if;

  begin
    insert into public.exam_submissions (exam_id, student_id, status)
      values (v_a, auth.uid(), 'ongoing');
    raise exception 'FAIL (e)iv: an attempt was created on a stale acceptance';
  exception
    when insufficient_privilege then null;
  end;

  raise notice 'PASS (e)iv: stale wording is recorded, and unlocks nothing';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);


-- =====================================================================
-- (f)  Only the version currently in force counts
-- =====================================================================
-- The rule the version string exists for: an institution replacing a sentence in
-- the notice must not be met with a corpus of acceptances to the old one.
--
-- `test.version` accepts paper B under the shipped wording...
set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "version.consent@test.local"}',
         current_setting('test.version')), true);
do $$
declare
  v_b uuid := current_setting('test.exam_b')::uuid;
begin
  perform public.record_consent(v_b, current_setting('test.version_now'));
  if not public.student_has_consent(v_b) then
    raise exception 'FAIL (f): the fresh acceptance does not satisfy the predicate';
  end if;
  raise notice 'PASS (f): accepted under the wording in force';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- ...the institution then changes the wording, and with it the version it is
-- keeping. Written as postgres because the config row is not writable through the
-- API - that is the point of section 1 of the migration.
update public.proctoring_consent_config
   set current_version = 'test-bumped-v999', updated_at = now()
 where id = 1;

set local role authenticated;
select set_config('request.jwt.claims',
  format('{"sub": "%s", "role": "authenticated", "email": "version.consent@test.local"}',
         current_setting('test.version')), true);
do $$
declare
  v_b uuid := current_setting('test.exam_b')::uuid;
  r   record;
  v_rows int;
begin
  if public.student_has_consent(v_b) then
    raise exception 'FAIL (f): an acceptance to replaced wording still counts';
  end if;

  begin
    insert into public.exam_submissions (exam_id, student_id, status)
      values (v_b, auth.uid(), 'ongoing');
    raise exception 'FAIL (f): an attempt was created on an acceptance to old wording';
  exception
    when insufficient_privilege then null;
  end;

  -- Accepting the new wording is what unlocks it - and it is a *second* row: the
  -- first acceptance is evidence of what was agreed to then, and is not rewritten.
  select * into r from public.record_consent(v_b, 'test-bumped-v999');
  if r.is_current is not true then
    raise exception 'FAIL (f): the new wording is not reported as current';
  end if;

  select count(*) into v_rows from public.proctoring_consents
   where student_id = auth.uid() and exam_id = v_b;
  if v_rows <> 2 then
    raise exception 'FAIL (f): expected both acceptances kept, found % row(s)', v_rows;
  end if;

  insert into public.exam_submissions (exam_id, student_id, status)
    values (v_b, auth.uid(), 'ongoing');

  raise notice 'PASS (f): a version bump retires the old acceptance, and keeps the record';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- Back to the shipped version, so nothing later in this file reads a bumped one.
update public.proctoring_consent_config
   set current_version = current_setting('test.version_now'), updated_at = now()
 where id = 1;


-- =====================================================================
-- (g)  The stills expire; the incident does not
-- =====================================================================
do $$
declare
  v_closed uuid := current_setting('test.sub_closed')::uuid;
  v_live   uuid := current_setting('test.sub_live')::uuid;
  v_orphan uuid := current_setting('test.orphan')::uuid;
  v_days   int;
  v_dry    bigint;
  v_done   bigint;
  v_expired text;
  v_live_path text;
  v_fresh  text;
  v_orphan_path text;
begin
  -- `storage.allow_delete_query` is the flag the Storage API sets on itself while
  -- it is the one deleting. On a hosted project `storage.objects` carries the
  -- `storage.protect_delete()` trigger, which refuses *every* other SQL delete
  -- with 42501, and `purge_expired_snapshots()` is `security definer` but still a
  -- plain SQL delete inside - so without this flag the live run below never
  -- reaches the policy under test, it only meets the project's guard.
  --
  -- It is set here, as this block's *first* statement, rather than beside the call
  -- that needs it: `is_local = true` lasts until the end of the transaction (the
  -- whole file is one `begin` ... `rollback`, so one flag covers every statement
  -- in this block), and putting it at the top is what makes the ordering
  -- structural instead of incidental - no fixture write, no dry run and no
  -- statement added later can run ahead of it, and the live call can never end up
  -- on the far side of a reset. Nothing after this line in this block may clear
  -- it: a `reset all`, a `discard all` or a second `set_config` with `'false'`
  -- puts `protect_delete()` back in front of the live run.
  --
  -- `mobile/test/schema_contract_test.dart` pins both halves of that: the flag is
  -- the first statement of the block, and nothing between it and the live call
  -- mentions it again.
  perform set_config('storage.allow_delete_query', 'true', true);

  if to_regprocedure('public.purge_expired_snapshots(interval, boolean)') is null then
    raise notice 'SKIP (g): supabase/migrations/20261106090100_snapshot_retention.sql has not been applied';
    return;
  end if;
  if to_regclass('storage.objects') is null
     or not exists (select 1 from storage.buckets where id = 'proctor-snapshots') then
    raise notice 'SKIP (g): no proctor-snapshots bucket in this database';
    return;
  end if;

  -- The window is an operator setting, not a constant: read it, so the fixture is
  -- older than whatever this project keeps instead of hard-coding 30 days.
  select rp.retention_days into v_days
    from public.retention_policies rp
   where rp.table_name = 'proctor_snapshots'
     and rp.enabled
   limit 1;
  if v_days is null then
    raise notice 'SKIP (g): no enabled proctor_snapshots retention policy';
    return;
  end if;

  -- Four objects, covering the four cases the function has to tell apart.
  -- `<submission_id>/<action_type>_<epoch-ms>.jpg` is the path convention
  -- (schema.sql section 6); the folder is what resolves to an attempt.
  v_expired     := v_closed::text || '/looking_away_1.jpg';   -- aged out, finished
  v_live_path   := v_live::text   || '/looking_away_1.jpg';   -- aged out, still running
  v_fresh       := v_closed::text || '/no_face_2.jpg';        -- finished, too new
  v_orphan_path := v_orphan::text || '/looking_away_1.jpg';   -- aged out, no attempt

  insert into storage.objects (bucket_id, name, created_at) values
    ('proctor-snapshots', v_expired,     now() - make_interval(days => v_days + 2)),
    ('proctor-snapshots', v_live_path,   now() - make_interval(days => v_days + 2)),
    ('proctor-snapshots', v_fresh,       now()),
    ('proctor-snapshots', v_orphan_path, now() - make_interval(days => v_days + 2));

  insert into public.proctoring_logs (submission_id, action_type, timestamp, snapshot_url) values
    (v_closed, 'looking_away', now() - make_interval(days => v_days + 2), v_expired),
    (v_live,   'looking_away', now() - make_interval(days => v_days + 2), v_live_path),
    (v_closed, 'no_face',      now(),                                     v_fresh);

  -- A dry run counts and changes nothing.
  select public.purge_expired_snapshots(make_interval(days => v_days), true) into v_dry;
  if v_dry < 2 then
    raise exception 'FAIL (g): the purge counted % object(s), expected at least 2', v_dry;
  end if;
  if not exists (select 1 from storage.objects
                  where bucket_id = 'proctor-snapshots' and name = v_expired) then
    raise exception 'FAIL (g): the purge deleted during the dry run';
  end if;
  if not exists (select 1 from public.proctoring_logs
                  where snapshot_url = v_expired) then
    raise exception 'FAIL (g): the dry run nulled a pointer';
  end if;

  -- The real run: the finished attempt's expired still and the orphaned one go,
  -- the live sitting's and the fresh one stay. It deletes through
  -- `purge_expired_snapshots()`, so it runs under the `storage.allow_delete_query`
  -- flag set at the top of this block - see the note there for why it lives there
  -- and not here. The dry run above needed no flag, because it deletes nothing.
  select public.purge_expired_snapshots(make_interval(days => v_days), false) into v_done;
  if v_done < 2 then
    raise exception 'FAIL (g): the purge deleted % object(s), expected at least 2', v_done;
  end if;

  if exists (select 1 from storage.objects
              where bucket_id = 'proctor-snapshots'
                and name in (v_expired, v_orphan_path)) then
    raise exception 'FAIL (g): an expired object survived the purge';
  end if;
  if not exists (select 1 from storage.objects
                  where bucket_id = 'proctor-snapshots' and name = v_live_path) then
    raise exception 'FAIL (g): the purge deleted a live sitting''s still';
  end if;
  if not exists (select 1 from storage.objects
                  where bucket_id = 'proctor-snapshots' and name = v_fresh) then
    raise exception 'FAIL (g): the purge deleted a still inside the window';
  end if;

  -- The incident survives; only its pointer goes.
  if not exists (select 1 from public.proctoring_logs
                  where submission_id = v_closed
                    and action_type = 'looking_away'
                    and timestamp < now() - make_interval(days => v_days)
                    and snapshot_url is null) then
    raise exception 'FAIL (g): the expired incident row did not keep its row with a NULL pointer';
  end if;
  if not exists (select 1 from public.proctoring_logs
                  where submission_id = v_closed
                    and action_type = 'no_face'
                    and snapshot_url = v_fresh) then
    raise exception 'FAIL (g): a live pointer was nulled';
  end if;
  if not exists (select 1 from public.proctoring_logs
                  where submission_id = v_live and snapshot_url = v_live_path) then
    raise exception 'FAIL (g): an ongoing attempt''s pointer was nulled';
  end if;

  raise notice 'PASS (g): expired stills go, live and fresh ones stay, incidents survive';
end $$;

-- A window of zero (or a negative one) is refused rather than clamped: it would
-- mean "delete every still, including the one from the sitting happening now".
do $$
begin
  if to_regprocedure('public.purge_expired_snapshots(interval, boolean)') is null then
    raise notice 'SKIP (g): the purge function is not installed';
    return;
  end if;
  begin
    perform public.purge_expired_snapshots(interval '0');
    raise exception 'FAIL (g): a zero window was accepted';
  exception
    when sqlstate '22023' then null;
  end;
  raise notice 'PASS (g): a zero window is refused (22023)';
end $$;


-- =====================================================================
-- (h)  The retention windows the notice quotes exist
-- =====================================================================
-- `ProctorConsentConfig` in the app renders "deleted after 30 days" and "kept for
-- 180 days" from its own constants; these rows are what make those sentences
-- true. `mobile/test/schema_contract_test.dart` pins the two together.
do $$
declare
  v_snap   integer;
  v_exams  integer;
  v_users  integer;
begin
  if to_regclass('public.retention_policies') is null then
    raise notice 'SKIP (h): supabase/migrations/retention_policy.sql has not been applied';
    return;
  end if;

  select rp.retention_days into v_snap
    from public.retention_policies rp
   where rp.table_name = 'proctor_snapshots' and rp.enabled limit 1;
  select rp.retention_days into v_exams
    from public.retention_policies rp
   where rp.table_name = 'exam_submissions' and rp.enabled limit 1;
  select rp.retention_days into v_users
    from public.retention_policies rp
   where rp.table_name = 'profiles' and rp.enabled limit 1;

  if coalesce(v_snap, -1) <> 30 then
    raise exception 'FAIL (h): proctor_snapshots retention is %, expected 30', v_snap;
  end if;
  if coalesce(v_exams, -1) <> 180 then
    raise exception 'FAIL (h): exam_submissions retention is %, expected 180', v_exams;
  end if;
  if coalesce(v_users, -1) <> 180 then
    raise exception 'FAIL (h): profiles retention is %, expected 180', v_users;
  end if;

  raise notice 'PASS (h): snapshot 30 days, attempt and account records 180 days';
end $$;

rollback;

