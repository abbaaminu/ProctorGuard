-- =====================================================================
-- PROCTORGUARD - WEIGHTED STRIKES AND THE "UNDER REVIEW" STATE
-- Replaces `register_violation()` so the automatic escalation reads the weights
-- from `public.violation_weights` instead of counting rows, sends at-threshold
-- attempts to `flagged_for_review` instead of disqualifying them, and adds
-- `resolve_flagged_attempt()` for the human decision.
--
-- WHY THIS FILE EXISTS
--   `if (select count(*) ...) >= 3 then status = 'disqualified'` made every log
--   row equal evidence: three right-clicks disqualified a student exactly like
--   three sustained second-face sightings. It also made the *server* the judge of
--   a case only a person can decide, with no record of who ended the attempt or
--   why. Two changes fix that together:
--     1. only rows whose weight says `counts_toward_dq` contribute points, and
--     2. reaching the threshold stops the session as `flagged_for_review` - the
--        paper is closed and the student is told a supervisor will review it -
--        rather than branding the attempt `disqualified` on the spot.
--   No evidence is thrown away: every detected signal is still inserted into
--   `proctoring_logs` exactly as before, and the soft ones are still in front of
--   the supervisor. Only the automatic *consequence* is weighted.
--
-- WHAT CHANGES
--   * `exam_submissions.status` accepts `flagged_for_review` (see the DO block
--     below, which finds the old check by definition so a differently-named copy
--     is still replaced).
--   * `register_violation()` - same name, same five arguments (four defaulted),
--     same grants, same snapshot-path rule, same `client_event_id` idempotency,
--     same `for update` ownership lock:
--       - the weighted score is `sum(weight)` over rows where `counts_toward_dq`,
--       - a type with no row in `violation_weights` is scored as (1, counted) -
--         fail closed, so a new action_type the check constraint accepts can never
--         become a free pass,
--       - the threshold is 3 weighted points (six hard signals at weight 1 => any
--         three; five soft ones at weight 0 => never),
--       - at the threshold the attempt becomes `flagged_for_review`, with
--         `submitted_at` set (the sitting is over) and `score` cleared (nothing is
--         being marked while it is under review),
--       - the return shape keeps `warning_count` (all stored evidence, which is
--         what the client's risk index reads) and `disqualified`, and adds
--         `flagged boolean`. `warning_count` is deliberately NOT the weighted
--         score: the supervisor console counts evidence, and a student's "3 flags"
--         must not silently become "1 flag worth 3".
--   * `resolve_flagged_attempt(p_submission_id, p_decision, p_note)` - the only
--     writer of the two outcomes, supervisor-only (see its own note), which sets
--     `disqualified` or restores the attempt to `submitted` and writes one audit
--     row.
--   * `public.attempt_review_logs` - who resolved which attempt, how, and with
--     what note. Read-only to clients: the definer RPC is the only writer.
--   * `grade_submission()` - refuses a flagged attempt. It is included here as a
--     verbatim copy of its definition with one extra branch, and nothing else
--     touched, so the diff between the two versions is the whole review of it.


-- WHAT DELIBERATELY DOES NOT CHANGE (each is a status list, each is correct)
--   * `questions_public` and the snapshot-upload policy test `status = 'ongoing'`:
--     a flagged attempt is closed, so it reads no more questions and writes no
--     more stills - exactly what happens to a submitted one.
--   * `submit_exam()` returns the stored state for anything not 'ongoing', so a
--     replay of a late submit on a flagged attempt cannot overwrite the review
--     (and cannot grade it: `p_disqualified` is only consulted for 'ongoing').
--   * `merge_submission_answer()` / `merge_submission_text_answer()` require
--     'ongoing': a queued answer must not land after the review froze the paper.
--   * `guard_submission_immutability` treats every non-'ongoing' row as closed, so
--     'flagged_for_review' inherits the frozen `answers` and the refusal to reopen.
--     Moving flagged -> submitted or -> disqualified is closed-to-closed, which it
--     allows on purpose (a mistaken disqualification can already be undone).
--   * No policy is re-created: none of them enumerates statuses.
--
-- NO BACKFILL, ON PURPOSE
--   This file writes no `proctoring_logs` row and re-reads no existing attempt:
--   an attempt already disqualified under the old rule stays disqualified, and an
--   ongoing attempt keeps its full history and simply scores under the new rule
--   from here on. There is no reconciliation UPDATE: deciding *after the fact* that
--   a sitting somebody already failed should have been a review case is a human's
--   call, not a migration's. See the README, "Tuning the violation weights".
--
-- SAFETY
--   * Safe to re-run: the status check is dropped by definition, the audit table is
--     `if not exists` with `drop policy if exists`, and every function is
--     `create or replace` - except `register_violation()`, which is dropped first
--     because it gains a third output column and Postgres refuses to re-type an
--     existing function (its grants are re-applied at the end).
--   * Safe on a live table: the CHECK is added NOT VALID and then validated, so
--     there is no rewrite and no long lock; an existing row with an unknown status
--     surfaces as a validation error that names the row.
--   * PREREQUISITES: `20261104090000_violation_weights.sql` (this file reads the
--     table), `public.is_exam_supervisor()`, `public.owns_exam(uuid)`,
--     `public.auto_graded_score(uuid)`.
--   * APPLY ORDER: after `20261104090000_violation_weights.sql`; independent of
--     the Edge Functions and of `retention_policy.sql`.
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/20261104090100_weighted_strikes_and_flagged_review.sql
--   * Verify (expect one constraint, validated, listing four statuses):
--       select pg_get_constraintdef(oid) from pg_constraint
--        where conrelid = 'public.exam_submissions'::regclass
--          and contype = 'c' and pg_get_constraintdef(oid) like '%status%';
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. `exam_submissions.status` learns 'flagged_for_review'
-- ---------------------------------------------------------------------
-- Dropped by *definition* (any CHECK on this table that mentions `status`), the
-- same way 20261103090700 replaces the action_type constraint: a project created
-- from an older schema.sql has an auto-named copy, and `add constraint` would
-- otherwise leave two checks disagreeing.
do $$
declare
  v_constraint text;
begin
  if to_regclass('public.exam_submissions') is null then
    raise notice 'public.exam_submissions is missing: run schema.sql first, then re-run this file.';
    return;
  end if;

  for v_constraint in
    select con.conname
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join pg_namespace nsp on nsp.oid = rel.relnamespace
     where nsp.nspname = 'public'
       and rel.relname = 'exam_submissions'
       and con.contype = 'c'
       and pg_get_constraintdef(con.oid) like '%status%'
  loop
    raise notice 'exam_submissions: dropping the previous status constraint (%)', v_constraint;
    execute format('alter table public.exam_submissions drop constraint %I', v_constraint);
  end loop;
end $$;

alter table public.exam_submissions
  add constraint exam_submissions_status_check
  check (status in ('ongoing', 'flagged_for_review', 'submitted', 'disqualified'))
  not valid;

alter table public.exam_submissions
  validate constraint exam_submissions_status_check;

-- ---------------------------------------------------------------------
-- 2. The audit trail behind "resolve"
-- ---------------------------------------------------------------------
-- `register_violation()` now stops an attempt without deciding whether it is
-- disqualified, so *somebody* has to decide - and "who ended this student's
-- sitting, and on what grounds" is exactly the question an appeal turns on. One
-- row per resolution, written only by `resolve_flagged_attempt()` below.
--
-- No foreign keys, for the same reason `session_reset_logs` has none: the attempt
-- this row describes can be deleted by "Reset attempt" afterwards, and a reference
-- would either refuse to record the resolution or blank out the id that ties the
-- record to the attempt it is about. `student_id` and `exam_id` are kept as plain
-- uuid evidence so a deleted exam cannot take its review trail with it.
create table if not exists public.attempt_review_logs (
  id            uuid primary key default uuid_generate_v4(),
  submission_id uuid not null,
  student_id    uuid not null,
  exam_id       uuid not null,
  from_status   text not null,
  to_status     text not null,
  decision      text not null check (decision in ('disqualify', 'clear')),
  note          text,
  actor_id      uuid not null default auth.uid(),
  created_at    timestamptz not null default now()
);

comment on table public.attempt_review_logs is
  'One row per resolve_flagged_attempt() call: who decided what about an attempt that reached the weighted threshold, with their note. Read-only to clients.';

alter table public.attempt_review_logs enable row level security;

drop policy if exists "attempt_review_logs_select_staff" on public.attempt_review_logs;

-- Read: the intervention tier sees every review; the lecturer who wrote the paper
-- sees the reviews of their own sitting. Students get no rows - the record names
-- the member of staff who made the call. Same reach as `session_reset_logs`.
create policy "attempt_review_logs_select_staff"
  on public.attempt_review_logs for select
  to authenticated
  using (public.is_exam_supervisor() or public.owns_exam(exam_id));

-- There is deliberately NO insert (or update, or delete) policy. The row is
-- written inside `resolve_flagged_attempt()` - a SECURITY DEFINER function that
-- has already checked the caller's tier - so `actor_id = auth.uid()` is the
-- database's answer rather than a client's claim, and a record its own author can
-- rewrite or remove is not a record.
grant select on public.attempt_review_logs to authenticated;
revoke insert, update, delete on public.attempt_review_logs from authenticated;
revoke all on public.attempt_review_logs from anon;

-- ---------------------------------------------------------------------
-- 3. `grade_submission()` learns the third closed state
-- ---------------------------------------------------------------------
-- Verbatim copy of the definition in `schema.sql` (section 8's marking RPC), with
-- exactly ONE added branch: a flagged attempt is refused, because a mark awarded
-- while the review is open would be a mark on a sitting that may not count - and
-- `resolve_flagged_attempt(..., 'clear')` recomputes the score from the automatic
-- key, so a hand-awarded mark taken before the decision would be lost silently.
-- Everything else - the owner/admin tier, the subjective-only rule, the cap at
-- `questions.points`, the upsert and the score recomputation - is unchanged, and
-- `schema_contract_test.dart` compares this copy against schema.sql.



create or replace function public.grade_submission(
  p_submission_id uuid,
  p_grades        jsonb
)
returns table(final_score numeric, graded_answers int, ungraded_answers int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exam    uuid;
  v_status  text;
  v_owner   uuid;
  v_entry   record;
  v_awarded numeric;
  v_points  numeric;
  v_graded  int;
  v_open    int;
  v_score   numeric;
begin
  if auth.uid() is null then
    raise exception 'authentication is required to grade an attempt'
      using errcode = '42501';
  end if;

  if p_grades is null or jsonb_typeof(p_grades) <> 'object' then
    raise exception 'the marks must be a json object keyed by question id'
      using errcode = '22023';
  end if;

  select s.exam_id, s.status, e.created_by
    into v_exam, v_status, v_owner
  from public.exam_submissions s
  join public.exams e on e.id = s.exam_id
  where s.id = p_submission_id
  for update of s;

  if v_exam is null then
    raise exception 'submission % does not exist', p_submission_id
      using errcode = 'P0002';
  end if;

  -- The academic owner, not the wider invigilation tier: a supervisor may clear
  -- an attempt, but the mark on somebody's paper is the lecturer's call. An
  -- administrator is the deliberate exception - the role that can already
  -- intervene in a submission directly.
  if v_owner <> auth.uid() and not public.is_admin() then
    raise exception 'only the exam owner may grade its answers'
      using errcode = '42501';
  end if;

  -- An open attempt has not been handed in, so its answers can still change and
  -- there is nothing final to mark yet.
  if v_status = 'ongoing' then
    raise exception 'submission % is still in progress', p_submission_id
      using errcode = '55000';
  end if;

  -- A disqualified attempt is never graded: a score would imply it counts.
  if v_status = 'disqualified' then
    raise exception 'submission % was disqualified and is not graded',
      p_submission_id
      using errcode = '55000';
  end if;

  -- The third closed state, added by this migration only: an attempt that reached
  -- the weighted threshold is under review, and a mark entered now would be a mark
  -- on a sitting that may not count. `resolve_flagged_attempt()` is the way out -
  -- it either disqualifies the attempt or restores it to 'submitted', after which
  -- this function grades it normally.
  if v_status = 'flagged_for_review' then
    raise exception 'submission % is under review and is not graded until it is resolved',
      p_submission_id
      using errcode = '55000';
  end if;

  for v_entry in
    select key as question_id, value as mark from jsonb_each(p_grades)
  loop
    select q.points into v_points
    from public.questions q
    where q.id = v_entry.question_id::uuid
      and q.exam_id = v_exam
      and q.question_type = 'subjective';

    if v_points is null then
      raise exception 'question % is not a subjective question of this exam',
        v_entry.question_id
        using errcode = '22023';
    end if;

    -- `is distinct from` rather than `<>`: a missing `awarded` key has a NULL
    -- type, and NULL silently passes a plain inequality - the NULL mark would
    -- then be refused by the column with a raw NOT NULL error instead of this
    -- sentence.
    if jsonb_typeof(v_entry.mark) is distinct from 'object'
       or jsonb_typeof(v_entry.mark -> 'awarded') is distinct from 'number' then
      raise exception 'question % needs a numeric "awarded" mark',
        v_entry.question_id
        using errcode = '22023';
    end if;

    v_awarded := (v_entry.mark ->> 'awarded')::numeric;

    if v_awarded < 0 or v_awarded > v_points then
      raise exception 'marks for question % must be between 0 and %',
        v_entry.question_id, v_points
        using errcode = '22023';
    end if;

    insert into public.question_grades
      (submission_id, question_id, awarded, feedback, graded_by)
    values (
      p_submission_id,
      v_entry.question_id::uuid,
      v_awarded,
      -- Capped like `merge_submission_text_answer`: a feedback box must not be
      -- able to park an unbounded blob on a row a report will read. An empty box
      -- is stored as NULL rather than as "", so "no remark" has one shape.
      nullif(left(coalesce(v_entry.mark ->> 'feedback', ''), 2000), ''),
      auth.uid()
    )
    on conflict (submission_id, question_id) do update
      set awarded   = excluded.awarded,
          feedback  = excluded.feedback,
          graded_by = excluded.graded_by,
          graded_at = now();
  end loop;

  -- What the console reports back: how much of this paper is marked, and what the
  -- attempt is worth so far. Both are counted from the rows rather than from the
  -- request, so a caller that sent three marks learns the same numbers the
  -- attempt holds.
  select count(*) filter (where g.id is not null)
    into v_graded
  from public.questions q
  left join public.question_grades g
    on g.question_id = q.id and g.submission_id = p_submission_id
  where q.exam_id = v_exam
    and q.question_type = 'subjective';

  select count(*)
    into v_open
  from public.questions q
  where q.exam_id = v_exam
    and q.question_type = 'subjective'
    and not exists (
      select 1 from public.question_grades g
      where g.submission_id = p_submission_id and g.question_id = q.id
    );

  -- `score` is rewritten from scratch - automatic marks plus what was awarded -
  -- which is what makes a re-mark a correction, and why a partially marked
  -- attempt already carries a meaningful total. `guard_submission_immutability`
  -- allows this write to a closed row (score is exactly what a re-mark may
  -- change) while still refusing any change to `answers`.
  select public.auto_graded_score(p_submission_id)
       + coalesce(sum(g.awarded), 0)
    into v_score
  from public.question_grades g
  where g.submission_id = p_submission_id;

  update public.exam_submissions
  set score = v_score
  where id = p_submission_id;

  return query select v_score, v_graded, v_open;
end;
$$;

comment on function public.grade_submission(uuid, jsonb) is
  'Marks an attempt''s subjective answers (paper owner or admin only): upserts one question_grades row per answer and recomputes score as automatic + awarded. Idempotent.';

revoke execute on function public.grade_submission(uuid, jsonb) from public, anon;
grant execute on function public.grade_submission(uuid, jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4. `register_violation()`: weighted, and it stops instead of convicting
-- ---------------------------------------------------------------------
-- The signature, the grants, the ownership re-check, the snapshot-path rule and
-- the `client_event_id` idempotency are carried over unchanged - a queued event
-- replayed by the offline client still inserts nothing and still cannot turn one
-- violation into two strikes. Three things are different:
--
--   * The score is weighted, read from `public.violation_weights`. Every log row is
--     still inserted (evidence is evidence), but only rows whose type says
--     `counts_toward_dq` add points - so three soft signals reach 0 and close
--     nothing, while three hard ones reach 3.
--   * A type with no row is scored as (1, counted): fail closed. A future action
--     type added to the check constraint but not seeded here must not become a
--     free pass for the one signal nobody has judged yet.
--   * At the threshold the attempt becomes `flagged_for_review`, not
--     `disqualified`: the sitting is closed (`submitted_at`) and unmarked
--     (`score = null`), and a supervisor decides through `resolve_flagged_attempt()`.
--
-- `warning_count` stays the raw count of stored evidence, not the weighted score:
-- the client's risk index and the supervisor's "N flags" both mean rows, and
-- re-purposing the column would quietly change both. The weighted total is
-- derivable from `proctoring_logs` + `violation_weights` whenever a screen wants
-- to show it.
--
-- The two- and three-argument overloads are dropped first for the reason
-- schema.sql gives: a defaulted five-argument function would make a 3-argument
-- named call ambiguous. The five-argument one is dropped here because it gains a
-- third output column, and `create or replace` refuses to change a return type.
drop function if exists public.register_violation(uuid, text);
drop function if exists public.register_violation(uuid, text, text);
drop function if exists public.register_violation(uuid, text, text, timestamptz, uuid);

create or replace function public.register_violation(
  p_submission_id    uuid,
  p_action_type      text,
  p_snapshot_url     text default null,
  p_client_timestamp timestamptz default null,
  p_client_event_id  uuid default null
)
returns table(warning_count int, disqualified boolean, flagged boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  -- The bar, in weighted points. Three, because every seeded hard type weighs 1:
  -- "any three hard signals" is exactly the rule this replaces for the signals
  -- that deserve it, and a soft type at weight 0 can never reach it alone.
  c_flag_threshold constant int := 3;

  v_count    int;
  v_status   text;
  v_snapshot_path text;
  v_weighted int;
begin
  if auth.uid() is null then
    raise exception 'authentication is required to register a violation'
      using errcode = '42501';
  end if;

  -- SECURITY DEFINER is required here (a student may neither insert into
  -- proctoring_logs nor update exam_submissions), which is exactly why the
  -- function has to re-check who is asking: without this guard any signed-in
  -- account could close a classmate's attempt by calling the RPC with their
  -- submission id. The row lock is what serialises two frames arriving together,
  -- so the weighted sum below cannot be computed twice from a stale snapshot.
  select s.status
    into v_status
  from public.exam_submissions s
  where s.id = p_submission_id
    and s.student_id = auth.uid()
  for update;

  if v_status is null then
    raise exception 'submission % does not belong to the caller', p_submission_id
      using errcode = '42501';
  end if;

  -- Frames that arrive after the attempt closed (submitted, flagged or already
  -- disqualified) must not append more evidence or resurrect the session: report
  -- the final state instead of raising, so a late callback is harmless. `flagged`
  -- is reported from the stored status so a client that missed the ruling still
  -- learns the attempt is under review.
  if v_status <> 'ongoing' then
    select count(*) into v_count
    from public.proctoring_logs
    where submission_id = p_submission_id;
    return query select v_count, (v_status = 'disqualified'),
                        (v_status = 'flagged_for_review');
    return;
  end if;

  -- Only THIS attempt's own snapshot object is stored, and only in the exact
  -- shape `SupabaseService.snapshotPath()` mints:
  --     <p_submission_id>/<action_type>_<epoch-ms>.(jpg|png)
  -- Unchanged from schema.sql: anything else - another submission's folder, a
  -- path outside the bucket, a full URL, a folder-shaped name this app never
  -- minted - is stored as NULL and the violation still counts. The incident is
  -- the fact; the photograph is the optional attachment.
  v_snapshot_path := case
    when p_snapshot_url ~ ('^' || p_submission_id::text || '/[a-z_]+_[0-9]+\.(jpg|png)$')
      then p_snapshot_url
    else null
  end;

  -- `on conflict` + the unique index on client_event_id is what makes the
  -- client's offline retry safe: the same event replayed inserts nothing, and the
  -- score below is read back from the table, so a retry can never turn one
  -- violation into two strikes - weighted or not.
  insert into public.proctoring_logs (
    submission_id, action_type, snapshot_url, client_timestamp, client_event_id
  )
  values (
    p_submission_id,
    p_action_type,
    v_snapshot_path,
    coalesce(p_client_timestamp, now()),
    p_client_event_id
  )
  on conflict (client_event_id) where client_event_id is not null do nothing;

  select count(*) into v_count
  from public.proctoring_logs
  where submission_id = p_submission_id;

  -- The weighted score for the whole attempt, not the increment: `client_event_id`
  -- deduplication, a retried delivery and a replayed queue all have to arrive at
  -- the same number as the rows actually stored.
  --
  -- `left join` + coalesce is the fail-closed shape: a row whose action_type has
  -- no weight yet counts as one point, so widening the check constraint can never
  -- hand out a free signal. `counts_toward_dq` gates the point, and a soft row
  -- contributes 0 even if somebody gives it a weight later.
  select coalesce(sum(
           case
             when coalesce(w.counts_toward_dq, true) then coalesce(w.weight, 1)
             else 0
           end
         ), 0)::int
    into v_weighted
  from public.proctoring_logs l
  left join public.violation_weights w on w.action_type = l.action_type
  where l.submission_id = p_submission_id;

  if v_weighted >= c_flag_threshold then
    -- The sitting is over, but nobody has decided anything: `flagged_for_review`
    -- means "a person must look at this". `submitted_at` is set once (a replayed
    -- call keeps the original close time) and `score` is cleared because marking
    -- does not start until the review ends.
    update public.exam_submissions
       set status = 'flagged_for_review',
           submitted_at = coalesce(submitted_at, now()),
           score = null
     where id = p_submission_id
       and status = 'ongoing';
    return query select v_count, false, true;
    return;
  end if;

  return query select v_count, false, false;
end;
$$;

comment on function public.register_violation(uuid, text, text, timestamptz, uuid) is
  'The single write path for proctoring evidence: ownership-checked, idempotent per client_event_id, and weighted - only types whose violation_weights row counts_toward_dq add points. At 3 weighted points the attempt becomes flagged_for_review for resolve_flagged_attempt() instead of being disqualified automatically.';

revoke execute on function public.register_violation(uuid, text, text, timestamptz, uuid) from public, anon;
grant execute on function public.register_violation(uuid, text, text, timestamptz, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 5. The human decision: `resolve_flagged_attempt()`
-- ---------------------------------------------------------------------
-- The only way out of `flagged_for_review`, and the only writer of
-- `attempt_review_logs`. A server that stops an attempt on a weighted score and
-- then leaves it stopped forever is worse than the 3-strike rule it replaces: the
-- student would have no outcome and the paper would never be marked.
--
-- WHO MAY CALL IT
--   The same tier that may delete an attempt on this paper
--   (`is_exam_supervisor() or owns_exam(exam_id)`) - administrators and
--   supervisors anywhere, a lecturer on the papers they wrote, and a lecturer on
--   somebody else's paper never. That is deliberately narrower than `is_staff()`
--   and deliberately does NOT include the student: the account under review does
--   not get a vote.
--
-- WHAT IT DOES
--   'disqualify' -> status 'disqualified', score cleared: the attempt does not count.
--   'clear'      -> status 'submitted', score recomputed from the automatic key by
--                   `auto_graded_score()`, which is the gradable state (subjective
--                   marks are entered afterwards through `grade_submission()`,
--                   which refuses a flagged attempt precisely so a mark cannot be
--                   awarded on a sitting that then stops counting).
--   Either way, one row in `attempt_review_logs`: from-status, to-status, the
--   decision, the note, and `actor_id = auth.uid()`.
--
-- IDEMPOTENT, LIKE EVERY OTHER RPC HERE
--   Calling it on an attempt that is no longer flagged (already resolved, or closed
--   normally) returns the status the row already holds and writes no second audit
--   row, so a lost response can be retried. Calling it on an 'ongoing' attempt
--   raises: there is nothing to review yet, and silently closing a live sitting
--   would be a reset by another name.
create or replace function public.resolve_flagged_attempt(
  p_submission_id uuid,
  p_decision      text,
  p_note          text default null
)
returns table(new_status text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status  text;
  v_student uuid;
  v_exam    uuid;
  v_to      text;
  v_score   numeric;
begin
  if auth.uid() is null then
    raise exception 'authentication is required to resolve a flagged attempt'
      using errcode = '42501';
  end if;

  if p_decision is null or p_decision not in ('disqualify', 'clear') then
    raise exception 'a review decision must be ''disqualify'' or ''clear'' (got %)',
      coalesce(p_decision, 'null')
      using errcode = '22023';
  end if;

  -- Locked for the duration: two supervisors pressing "Disqualify" and "Clear" in
  -- the same second must produce one decision and one audit row, not two rows that
  -- disagree.
  select s.status, s.student_id, s.exam_id
    into v_status, v_student, v_exam
  from public.exam_submissions s
  where s.id = p_submission_id
  for update;

  if v_status is null then
    raise exception 'submission % does not exist', p_submission_id
      using errcode = 'P0002';
  end if;

  -- The tier check runs BEFORE the status check on purpose: whether an attempt is
  -- flagged is not something an unauthorised caller should learn from an error
  -- message, and the refusal has to be identical for every attempt they may not
  -- touch.
  if not (public.is_exam_supervisor() or public.owns_exam(v_exam)) then
    raise exception 'only a supervisor, or the lecturer who wrote this paper, may resolve a flagged attempt'
      using errcode = '42501';
  end if;

  if v_status = 'ongoing' then
    raise exception 'submission % is still in progress: there is nothing to review', p_submission_id
      using errcode = '55000';
  end if;

  if v_status <> 'flagged_for_review' then
    -- Already decided (or never flagged): report the stored outcome and write
    -- nothing. This is the retry-safe arm - a client that lost the response can
    -- replay the call without a second audit row appearing.
    return query select v_status;
    return;
  end if;

  if p_decision = 'disqualify' then
    v_to := 'disqualified';
    v_score := null;
  else
    v_to := 'submitted';
    -- The automatic part of the mark, exactly as submit_exam() computes it, so
    -- "clear" lands the attempt in the same state a normal hand-in would.
    v_score := public.auto_graded_score(p_submission_id);
  end if;

  update public.exam_submissions
     set status = v_to,
         score = v_score,
         submitted_at = coalesce(submitted_at, now())
   where id = p_submission_id;

  insert into public.attempt_review_logs (
    submission_id, student_id, exam_id, from_status, to_status, decision, note
  )
  values (
    p_submission_id,
    v_student,
    v_exam,
    v_status,
    v_to,
    p_decision,
    -- Capped like every other free-text field in this schema: a note must not be
    -- able to park an unbounded blob on a row a report reads. Blank becomes NULL,
    -- so "no note" has one shape.
    nullif(btrim(left(coalesce(p_note, ''), 2000)), '')
  );

  return query select v_to;
end;
$$;

comment on function public.resolve_flagged_attempt(uuid, text, text) is
  'The human decision behind flagged_for_review: disqualify or clear an attempt that reached the weighted threshold, supervisor-only (or the paper''s author), and the only writer of attempt_review_logs. Idempotent; refuses an ongoing attempt.';

revoke execute on function public.resolve_flagged_attempt(uuid, text, text) from public, anon;
grant execute on function public.resolve_flagged_attempt(uuid, text, text) to authenticated, service_role;

-- Verification: no attempt may be left in a state the app cannot explain, and the
-- review trail must agree with the row it describes.
--   select status, count(*) from public.exam_submissions group by status;
--   select r.decision, r.from_status, r.to_status, r.note, p.full_name
--     from public.attempt_review_logs r
--     join public.profiles p on p.id = r.actor_id
--    order by r.created_at desc
--    limit 20;




