-- =====================================================================
-- EXAM EVIDENCE SCOPE TEST  -  run against `supabase start` or a hosted project
-- =====================================================================
-- Run from the repo root with:
--
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres
--     -f supabase/tests/exam_evidence_check.sql
--
-- Against a hosted project, use that project's connection string and connect the
-- way `schema.sql` was applied - as the owner role (`postgres`) - because the
-- fixtures below are written with no policy in the way, and every check block sets
-- its own role from there.
--
-- Prerequisites: `supabase start` is running, and `supabase db reset` has applied
-- `supabase/schema.sql` (which now carries `public.exam_evidence()`) or
-- `supabase/migrations/20261114090000_exam_evidence.sql` on an existing project -
-- plus `20261111090100_lecturer_isolation.sql`, which installs the
-- `can_reach_exam()` guard this read is scoped by, and
-- `20261113090000_predicate_execute_hardening.sql`, which is why an anonymous
-- caller is refused rather than answered.
--
-- WHAT IT PROVES
--   The scope of `public.exam_evidence(uuid)` is the paper, and the *person* who
--   may ask about it:
--
--   (a) the lecturer who wrote the paper reads every incident on it - one row per
--       `proctoring_logs` row, with the attempt, the student's name, the still's
--       stored path, the attempt's status, and the weight and DQ flag from
--       `violation_weights`;
--   (b) that same lecturer reads **nothing** on a colleague's paper, even though
--       the incidents there are real rows this database holds - the block asserts
--       the fixtures exist as `postgres` first, so a zero here is the predicate
--       answering and not an empty table;
--   (c) an **administrator** reads both papers. This half is proved rather than
--       assumed: the fixture administrator wrote neither paper, so every row it
--       sees arrived through `can_supervise_exam()`'s admin arm inside
--       `can_reach_exam()`;
--   (d) a second lecturer is the control for (c): the same two calls, scoped to
--       their own paper - one answer of 1 and one of 0;
--   (e) a **student** reads nothing, including on the paper they sat. The attempt
--       is their own and the incident row is theirs, so this is the predicate
--       refusing rather than row security hiding;
--   (f) an **anonymous** caller cannot execute the function at all (42501) -
--       EXECUTE was revoked from `public, anon`;
--   (g) a **null** paper returns nothing, for an administrator and for a
--       lecturer; and
--   (h) the columns mean what `20261114090000_exam_evidence.sql` says: the still
--       path is the stored value (not a signed URL), a row with no still stays
--       null, and an action type with no `violation_weights` row is read as
--       (1, true) instead of appearing to cost nothing.
--
-- HOW RLS IS APPLIED
--   Identical to `supervisor_scope_check.sql` and its family: each block does
--   `set local role authenticated`, sets a `request.jwt.claims` carrying the
--   caller's uuid, runs the check, then `reset role` and blanks the claims before
--   the next fixture write (the claims are transaction-local and would otherwise
--   still be set - and `guard_profile_labels()` refuses a label write from any
--   caller carrying them). The claims object is built with `jsonb_build_object()`
--   rather than a `format()`'d string, which keeps this file free of doubled
--   quotes. The whole file is wrapped in begin; ... rollback; and every fixture is
--   written as `postgres`, so nothing persists.
--
-- FIXTURES AND A LIVE PROJECT
--   Every fixture row is keyed to a `gen_random_uuid()` from this run, and every
--   count below is filtered to one of those ids - the paper, the attempt, the
--   profile - rather than to a whole table, so the same file asks the same
--   question on an empty `supabase start` database and on a live project that
--   already holds accounts, papers, attempts and evidence. No fixture is looked up
--   by name or by "the only row there is", and no account is assumed to exist.
--
--   `public.profiles.id` references `auth.users(id)`, which a plain insert into
--   `public.profiles` does not create (23503 `profiles_id_fkey`). The parent rows
--   come from `tmp_fixture_auth_user()` at the top of the transaction: a BEFORE
--   INSERT trigger on `public.profiles`, SECURITY DEFINER, so the fixtures are
--   ordinary `insert into public.profiles` statements and the helper is rolled
--   back with everything else.
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

-- =====================================================================
-- FIXTURES  (as `postgres`, so no policy applies)
-- =====================================================================
do $$
declare
  v_admin      uuid := gen_random_uuid();
  v_writer     uuid := gen_random_uuid();  -- wrote the paper under test
  v_rival      uuid := gen_random_uuid();  -- wrote the other paper
  v_s1         uuid := gen_random_uuid();  -- flagged attempt on the writer's paper
  v_s2         uuid := gen_random_uuid();  -- attempt on the rival's paper
  v_s3         uuid := gen_random_uuid();  -- second, newer attempt on the writer's paper
  v_paper_a    uuid := gen_random_uuid();
  v_paper_b    uuid := gen_random_uuid();
  v_att_a      uuid := gen_random_uuid();
  v_att_a2     uuid := gen_random_uuid();
  v_att_b      uuid := gen_random_uuid();
  v_logs       int;
begin
  insert into public.profiles (id, role, full_name, email) values
    (v_admin,  'admin',    'Evidence Admin',  'evidence.admin@test.local'),
    (v_writer, 'lecturer', 'Paper Writer',    'evidence.writer@test.local'),
    (v_rival,  'lecturer', 'Rival Writer',    'evidence.rival@test.local'),
    (v_s1,     'student',  'Student One',     'evidence.s1@test.local'),
    (v_s2,     'student',  'Student Two',     'evidence.s2@test.local'),
    (v_s3,     'student',  'Student Three',   'evidence.s3@test.local');

  -- The administrator wrote neither paper: every row it reads below arrived
  -- through the admin arm of can_supervise_exam(), not through owns_exam().
  insert into public.exams (id, title, created_by, duration_minutes, is_published) values
    (v_paper_a, 'Paper under test', v_writer, 60, true),
    (v_paper_b, 'Colleague paper',  v_rival,  60, true);

  -- Two sittings of the writer's paper (the newer one first in the expected
  -- order) and one of the rival's.
  insert into public.exam_submissions
    (id, student_id, exam_id, status, started_at, submitted_at) values
    (v_att_a,  v_s1, v_paper_a, 'flagged_for_review',
     now() - interval '40 minutes', now() - interval '5 minutes'),
    (v_att_a2, v_s3, v_paper_a, 'ongoing',
     now() - interval '10 minutes', null),
    (v_att_b,  v_s2, v_paper_b, 'submitted',
     now() - interval '20 minutes', now() - interval '2 minutes');

  -- Incidents. `looking_away` and `copy_paste_attempt` carry a still in the
  -- bucket's convention (`<submission_id>/<action_type>_<epoch-ms>.jpg`);
  -- `multiple_faces` and `no_face` deliberately carry none, which is the shape a
  -- row written while the client was offline has.
  insert into public.proctoring_logs (submission_id, action_type, timestamp, snapshot_url) values
    (v_att_a,  'looking_away',       now() - interval '39 minutes',
     v_att_a::text  || '/looking_away_1.jpg'),
    (v_att_a,  'copy_paste_attempt', now() - interval '38 minutes',
     v_att_a::text  || '/copy_paste_attempt_2.jpg'),
    (v_att_a2, 'multiple_faces',     now() - interval '9 minutes',  null),
    (v_att_b,  'no_face',            now() - interval '19 minutes', null);

  -- The fixture sanity the zero-answers below depend on: asked as `postgres`, so
  -- the count is the table's own and not what a policy will show a caller.
  select count(*) into v_logs
  from public.proctoring_logs l
  join public.exam_submissions s on s.id = l.submission_id
  where s.exam_id = v_paper_a;
  if v_logs <> 3 then
    raise exception 'fixture: expected 3 incidents on the writer''s paper, found %', v_logs;
  end if;

  select count(*) into v_logs
  from public.proctoring_logs l
  join public.exam_submissions s on s.id = l.submission_id
  where s.exam_id = v_paper_b;
  if v_logs <> 1 then
    raise exception 'fixture: expected 1 incident on the rival''s paper, found %', v_logs;
  end if;

  perform set_config('test.admin',   v_admin::text,   false);
  perform set_config('test.writer',  v_writer::text,  false);
  perform set_config('test.rival',   v_rival::text,   false);
  perform set_config('test.s1',      v_s1::text,      false);
  perform set_config('test.s2',      v_s2::text,      false);
  perform set_config('test.paper_a', v_paper_a::text, false);
  perform set_config('test.paper_b', v_paper_b::text, false);
  perform set_config('test.att_a',   v_att_a::text,   false);
  perform set_config('test.att_a2',  v_att_a2::text,  false);
  perform set_config('test.att_b',   v_att_b::text,   false);
end $$;

-- =====================================================================
-- (a)  the lecturer who wrote the paper reads every incident on it
-- =====================================================================
set local role authenticated;
select set_config('request.jwt.claims',
  jsonb_build_object(
    'sub',   current_setting('test.writer'),
    'role',  'authenticated',
    'email', 'evidence.writer@test.local'
  )::text, true);
do $$
declare
  v_rows     int;
  v_first    uuid;
  v_name     text;
  v_status   text;
  v_path     text;
  v_weight   int;
  v_counts   boolean;
  v_e_weight int;
  v_e_counts boolean;
begin
  select count(*) into v_rows
  from public.exam_evidence(current_setting('test.paper_a')::uuid);
  if v_rows <> 3 then
    raise exception 'FAIL (a): the author read % incident row(s) of their own paper, expected 3', v_rows;
  end if;

  -- Order: the sitting that started 10 minutes ago comes before the one that
  -- started 40 minutes ago, so the first row belongs to the newer attempt.
  select e.submission_id into v_first
  from public.exam_evidence(current_setting('test.paper_a')::uuid) e
  limit 1;
  if v_first <> current_setting('test.att_a2')::uuid then
    raise exception 'FAIL (a)ii: the newest sitting was not read first (got %)', v_first;
  end if;

  -- The flagged sitting's two incidents, with who sat it and what state it is in.
  select count(*) into v_rows
  from public.exam_evidence(current_setting('test.paper_a')::uuid) e
  where e.submission_id = current_setting('test.att_a')::uuid;
  if v_rows <> 2 then
    raise exception 'FAIL (a)iii: the flagged attempt showed % incident(s), expected 2', v_rows;
  end if;

  select e.student_name, e.attempt_status into v_name, v_status
  from public.exam_evidence(current_setting('test.paper_a')::uuid) e
  where e.action_type = 'looking_away'
  limit 1;
  if v_name <> 'Student One' then
    raise exception 'FAIL (a)iv: the incident did not carry the student''s name (got %)', v_name;
  end if;
  if v_status <> 'flagged_for_review' then
    raise exception 'FAIL (a)v: the incident did not carry the attempt''s status (got %)', v_status;
  end if;

  -- The still column is the *stored path*, so the client can normalise and sign
  -- it. A URL here would be either stale or public, and neither belongs in a row.
  select e.snapshot_url into v_path
  from public.exam_evidence(current_setting('test.paper_a')::uuid) e
  where e.action_type = 'looking_away'
  limit 1;
  if v_path <> current_setting('test.att_a') || '/looking_away_1.jpg' then
    raise exception 'FAIL (a)vi: the still path was rewritten (got %)', v_path;
  end if;
  if v_path like 'http%' then
    raise exception 'FAIL (a)vii: the still column carries a URL, not the stored path (%)', v_path;
  end if;

  -- The weight is read from violation_weights on every call rather than being a
  -- constant in the function: compare the two answers for a counted action and
  -- for a stored-but-soft one.
  select w.weight, w.counts_toward_dq into v_weight, v_counts
  from public.violation_weights w
  where w.action_type = 'copy_paste_attempt';
  select e.weight, e.counts_toward_dq into v_e_weight, v_e_counts
  from public.exam_evidence(current_setting('test.paper_a')::uuid) e
  where e.action_type = 'copy_paste_attempt';
  if v_e_weight is distinct from v_weight or v_e_counts is distinct from v_counts then
    raise exception 'FAIL (a)viii: copy_paste_attempt reported (%, %), the weights table says (%, %)',
      v_e_weight, v_e_counts, v_weight, v_counts;
  end if;

  -- A row with no still stays null rather than becoming an empty string the
  -- reader would try to sign.
  select count(*) into v_rows
  from public.exam_evidence(current_setting('test.paper_a')::uuid) e
  where e.snapshot_url is null;
  if v_rows <> 1 then
    raise exception 'FAIL (a)ix: % row(s) with no still, expected exactly the one written without a snapshot', v_rows;
  end if;

  raise notice 'PASS (a): the author reads all three incidents on their own paper, with name, status, still path and weights';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (b)  ...and nothing at all on a colleague's paper
-- =====================================================================
-- The fixtures block already proved, as `postgres`, that this paper holds one
-- incident. So the zero below is the predicate answering, not an empty database.
set local role authenticated;
select set_config('request.jwt.claims',
  jsonb_build_object(
    'sub',   current_setting('test.writer'),
    'role',  'authenticated',
    'email', 'evidence.writer@test.local'
  )::text, true);
do $$
declare
  v_rows int;
begin
  select count(*) into v_rows
  from public.exam_evidence(current_setting('test.paper_b')::uuid);
  if v_rows <> 0 then
    raise exception 'FAIL (b): the author read % incident row(s) of a colleague''s paper', v_rows;
  end if;
  raise notice 'PASS (b): a lecturer reads nothing on a paper they did not write and were not assigned to';
end $$;

reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (c)  an administrator reads every paper - proved, not assumed
-- =====================================================================
-- The fixture administrator wrote neither paper, so owns_exam() is false for
-- both. Every row here arrived through can_reach_exam()'s admin arm.
set local role authenticated;
select set_config('request.jwt.claims',
  jsonb_build_object(
    'sub',   current_setting('test.admin'),
    'role',  'authenticated',
    'email', 'evidence.admin@test.local'
  )::text, true);
do $$
declare
  v_rows int;
  v_name text;
begin
  select count(*) into v_rows
  from public.exam_evidence(current_setting('test.paper_a')::uuid);
  if v_rows <> 3 then
    raise exception 'FAIL (c): the administrator read % incident row(s) of the first paper, expected 3', v_rows;
  end if;

  select count(*) into v_rows
  from public.exam_evidence(current_setting('test.paper_b')::uuid);
  if v_rows <> 1 then
    raise exception 'FAIL (c)ii: the administrator read % incident row(s) of the second paper, expected 1', v_rows;
  end if;

  select e.student_name into v_name
  from public.exam_evidence(current_setting('test.paper_b')::uuid) e
  limit 1;
  if v_name <> 'Student Two' then
    raise exception 'FAIL (c)iii: the administrator did not get the second paper''s student name (got %)', v_name;
  end if;

  raise notice 'PASS (c): an administrator reads both papers through the admin arm of can_reach_exam()';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (d)  the control: a second lecturer, the same two calls
-- =====================================================================
-- The mirror image of (b) and (c). Without this block, (c) would only prove that
-- *somebody* reads both papers; with it, the difference between the two
-- lecturers is the paper they wrote and nothing else.
set local role authenticated;
select set_config('request.jwt.claims',
  jsonb_build_object(
    'sub',   current_setting('test.rival'),
    'role',  'authenticated',
    'email', 'evidence.rival@test.local'
  )::text, true);
do $$
declare
  v_mine   int;
  v_theirs int;
begin
  select count(*) into v_mine
  from public.exam_evidence(current_setting('test.paper_b')::uuid);
  select count(*) into v_theirs
  from public.exam_evidence(current_setting('test.paper_a')::uuid);

  if v_mine <> 1 then
    raise exception 'FAIL (d): the second author read % incident row(s) of their own paper, expected 1', v_mine;
  end if;
  if v_theirs <> 0 then
    raise exception 'FAIL (d)ii: the second author read % incident row(s) of a colleague''s paper', v_theirs;
  end if;

  raise notice 'PASS (d): the second lecturer reads their own paper and none of the first author''s';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
-- =====================================================================
-- (e)  a student reads nothing, their own sitting included
-- =====================================================================
-- Not a row-security answer: the attempt is theirs and so is the incident row,
-- so `proctoring_logs`' own policy would show it. The empty list is
-- can_reach_exam() refusing, which is the scope this screen is built on.
set local role authenticated;
select set_config('request.jwt.claims',
  jsonb_build_object(
    'sub',   current_setting('test.s1'),
    'role',  'authenticated',
    'email', 'evidence.s1@test.local'
  )::text, true);
do $$
declare
  v_rows int;
  v_att  int;
begin
  select count(*) into v_rows
  from public.exam_evidence(current_setting('test.paper_a')::uuid);
  if v_rows <> 0 then
    raise exception 'FAIL (e): a student read % incident row(s) of the paper they sat', v_rows;
  end if;

  -- The control: the same caller can still see their own incident row, so the
  -- zero above is the predicate and not an account with no evidence at all.
  select count(*) into v_att
  from public.proctoring_logs l
  where l.submission_id = current_setting('test.att_a')::uuid;
  if v_att <> 2 then
    raise exception 'FAIL (e)ii: the student reads % of their own incident rows - the fixture is not what this block assumes', v_att;
  end if;

  raise notice 'PASS (e): a student gets no evidence rows, although their own incidents are readable to them';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- =====================================================================
-- (f)  an anonymous caller cannot execute it at all
-- =====================================================================
set local role anon;
select set_config('request.jwt.claims', '', true);
do $$
declare
  v_rows int;
begin
  begin
    select count(*) into v_rows
    from public.exam_evidence(current_setting('test.paper_a')::uuid);
    raise exception 'FAIL (f): an anonymous caller read % evidence row(s)', v_rows;
  exception when insufficient_privilege then
    raise notice 'PASS (f): EXECUTE is revoked from public and anon, so an anonymous request is refused (42501)';
  end;
end $$;
reset role;

-- =====================================================================
-- (g)  a null paper returns nothing
-- =====================================================================
-- The argument is easy to omit from a client that trusts a route parameter; the
-- answer must be an empty list rather than every incident on the project.
set local role authenticated;
select set_config('request.jwt.claims',
  jsonb_build_object(
    'sub',   current_setting('test.admin'),
    'role',  'authenticated',
    'email', 'evidence.admin@test.local'
  )::text, true);
do $$
declare
  v_rows int;
begin
  select count(*) into v_rows
  from public.exam_evidence(null::uuid);
  if v_rows <> 0 then
    raise exception 'FAIL (g): a null paper returned % incident row(s)', v_rows;
  end if;
  raise notice 'PASS (g): a null paper returns nothing, for an administrator as for anyone else';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

set local role authenticated;
select set_config('request.jwt.claims',
  jsonb_build_object(
    'sub',   current_setting('test.writer'),
    'role',  'authenticated',
    'email', 'evidence.writer@test.local'
  )::text, true);
do $$
declare
  v_rows int;
begin
  select count(*) into v_rows
  from public.exam_evidence(null::uuid);
  if v_rows <> 0 then
    raise exception 'FAIL (g)ii: a null paper returned % incident row(s) to the author', v_rows;
  end if;
  raise notice 'PASS (g)ii: the same answer for the lecturer who wrote a paper';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
-- =====================================================================
-- (h)  the columns mean what the migration says they mean
-- =====================================================================
-- Two shapes the screen depends on, both written as `postgres` because they are
-- fixture edits: an action type with no `violation_weights` row (the migration
-- reads it as (1, true), the same default register_violation() uses), and the
-- ordinary case afterwards.
do $$
begin
  delete from public.violation_weights where action_type = 'idle_afk';
  insert into public.proctoring_logs (submission_id, action_type, timestamp)
    values (current_setting('test.att_a')::uuid, 'idle_afk', now() - interval '37 minutes');
end $$;

set local role authenticated;
select set_config('request.jwt.claims',
  jsonb_build_object(
    'sub',   current_setting('test.writer'),
    'role',  'authenticated',
    'email', 'evidence.writer@test.local'
  )::text, true);
do $$
declare
  v_weight int;
  v_counts boolean;
  v_rows   int;
begin
  select e.weight, e.counts_toward_dq into v_weight, v_counts
  from public.exam_evidence(current_setting('test.paper_a')::uuid) e
  where e.action_type = 'idle_afk';
  if v_weight <> 1 or not v_counts then
    raise exception 'FAIL (h): an action type with no weight row read as (%, %), expected (1, true)', v_weight, v_counts;
  end if;

  -- And the row it added is in the same read, so the list is not silently capped.
  select count(*) into v_rows
  from public.exam_evidence(current_setting('test.paper_a')::uuid);
  if v_rows <> 4 then
    raise exception 'FAIL (h)ii: the paper now holds 4 incidents, the read returned %', v_rows;
  end if;

  raise notice 'PASS (h): a missing weight row is read as (1, true), the same default register_violation() applies';
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- Nothing here persists: every fixture above is rolled back.
rollback;

select set_config('request.jwt.claims', '', true);
