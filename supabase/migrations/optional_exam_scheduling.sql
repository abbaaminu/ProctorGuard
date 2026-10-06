-- =====================================================================
-- PROCTORGUARD - OPTIONAL EXAM SCHEDULING (start / end windows)
-- Gives `public.exams` an optional window: `starts_at` and `ends_at`, both
-- nullable. A paper with neither bound is *unscheduled* - the student portal
-- offers it the moment it is published, exactly as every paper behaved before
-- this file - and a paper with one or both bounds is offered only inside them.
--
-- WHY THIS FILE EXISTS
--   `create table if not exists public.exams (...)` in `schema.sql` cannot add
--   a column to a table that already exists, so a live project would keep a
--   scheduling-free `exams` table while the console sent `starts_at`. The
--   statements below are the upgrade path; `schema.sql` section 2 carries the
--   same DDL (plus the two guarded `add column if not exists` statements) for
--   fresh installs, and the two files must be kept in step.
--
--   Scheduling is not a client-side nicety: three server rules are widened with
--   it, and each one is the *only* enforcement of its rule.
--     1. `submissions_insert_own_ongoing` is the policy every attempt row is
--        created under. It now asks the window as well as `is_published`, so a
--        patched client cannot open an attempt before the paper opens or after
--        it closes (the client's own lock on the tile is courtesy, not security).
--     2. `attempt_deadline()` is new, and it is the one place "how long do I have
--        left" is answered: the attempt's own duration, capped by `ends_at`. The
--        two answer-merge RPCs read it before writing an answer, and
--        `submit_exam()` reads it for the `submitted_at` it records. Without the
--        cap, a student who started 50 minutes before a hard close would still
--        be given the full duration.
--     3. `submit_exam()` itself is replaced for that second reason only; its
--        grading is unchanged (still `auto_graded_score()`), so an expired or
--        late attempt is closed and marked from the answers saved before the
--        deadline rather than rejected outright.
--
--   Both null is the default and the common case: nothing marks a paper as
--   scheduled except the author choosing a date on the console's "New paper"
--   dialog, and `exams.starts_at`/`ends_at` are the only columns that say so.
--
-- SAFETY
--   * Safe to re-run: the two columns are `add column if not exists`, the check
--     is dropped by name before it is re-created, and every function and policy
--     is `create or replace` / `drop ... if exists` + `create`.
--   * Additive for data: no row is rewritten. Every existing paper keeps both
--     columns NULL and is therefore open whenever it is published - the
--     behaviour it had before this file ran. The one statement that can fail on
--     existing data is the new `ends_at > starts_at` check, and it can only fail
--     if a row already holds an inverted pair - which nothing could have written
--     before these columns existed, so on a real project it is a no-op.
--   * Order matters: this file replaces `submit_exam()`,
--     `merge_submission_answer()` and `merge_submission_text_answer()`. Apply it
--     **after** `question_types_and_grading.sql` (whose `submit_exam()` this one
--     extends); re-running an older hardening file afterwards would replace
--     those functions with copies that predate scheduling, which is the same
--     caveat `question_types_and_grading.sql` documents for its own copies.
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/optional_exam_scheduling.sql
--   * Verify with:
--       select column_name, is_nullable, data_type
--         from information_schema.columns
--        where table_schema = 'public' and table_name = 'exams';
--       select conname, pg_get_constraintdef(oid)
--         from pg_constraint
--        where conrelid = 'public.exams'::regclass;
--       select public.attempt_deadline(
--         now(), 60, now() + interval '10 minutes'
--       );  -- 10 minutes from now: the window caps the hour
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. THE WINDOW
-- ---------------------------------------------------------------------
-- Both nullable: NULL is "no bound", not "unknown". Two statements rather than
-- one so each column's absence is independent, and so a project that somehow
-- has one of them is repaired rather than skipped.
alter table public.exams add column if not exists starts_at timestamptz;
alter table public.exams add column if not exists ends_at   timestamptz;

-- Drop-by-name first: on a live project the name already exists, and an
-- `if not exists` guard would leave the old definition in place (the same
-- reason `question_types_and_grading.sql` drops its checks by name).
alter table public.exams drop constraint if exists exams_window_ordered;
alter table public.exams
  add constraint exams_window_ordered
  check (starts_at is null or ends_at is null or ends_at > starts_at);

comment on column public.exams.starts_at is
  'When the paper is first offered to students. NULL = an unscheduled paper, offered as soon as it is published.';
comment on column public.exams.ends_at is
  'When the paper closes: no new attempt may be created, and an attempt still in progress is capped by this instant (see attempt_deadline()). NULL = no hard close.';


-- ---------------------------------------------------------------------
-- 2. THE ONE ANSWER TO "HOW LONG HAVE I GOT?"
-- ---------------------------------------------------------------------
-- `p_ends_at` NULL (an unscheduled paper) means `'infinity'`, so the `least()`
-- collapses to the duration and the pre-scheduling arithmetic is unchanged.
--
-- IMMUTABLE and no SECURITY DEFINER: it reads no table and depends on no
-- session, so it can be called from a policy, from a definer RPC and from a
-- future trigger and answer the same thing. It is a pure function of its three
-- arguments - which is exactly what makes it testable from the SQL editor.
create or replace function public.attempt_deadline(
  p_started_at       timestamptz,
  p_duration_minutes int,
  p_ends_at          timestamptz
)
returns timestamptz
language sql
immutable
as $$
  select least(
    p_started_at + make_interval(mins => p_duration_minutes),
    coalesce(p_ends_at, 'infinity'::timestamptz)
  );
$$;

comment on function public.attempt_deadline(timestamptz, int, timestamptz) is
  'The effective deadline of an attempt: started_at + duration_minutes, capped by the exam window''s ends_at (NULL ends_at = no cap).';

revoke execute on function public.attempt_deadline(timestamptz, int, timestamptz) from public, anon;
grant execute on function public.attempt_deadline(timestamptz, int, timestamptz) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. SCHEDULING IS ENFORCED WHERE THE ATTEMPT IS CREATED
-- ---------------------------------------------------------------------
-- `now()` (transaction time) rather than `clock_timestamp()`: the row's own
-- `started_at` is checked against `now()` by the same policy, so both halves of
-- this WITH CHECK read one instant. The bounds are inclusive - a paper that
-- opens at 09:00 is startable at 09:00:00.000.
drop policy if exists "submissions_insert_own_ongoing" on public.exam_submissions;
create policy "submissions_insert_own_ongoing"
  on public.exam_submissions for insert
  to authenticated
  with check (
    student_id = auth.uid()
    and status = 'ongoing'
    and score is null
    and answers = '{}'::jsonb
    and submitted_at is null
    and started_at = now()
    and exists (
      select 1 from public.exams e
      where e.id = exam_id
        and e.is_published = true
        -- The window. Both NULL (the unscheduled paper) passes: an optional
        -- bound cannot be a mandatory condition.
        and (e.starts_at is null or now() >= e.starts_at)
        and (e.ends_at  is null or now() <= e.ends_at)
    )
  );

-- ---------------------------------------------------------------------
-- 4. THE TWO ANSWER-MERGE RPCs READ THE SAME DEADLINE
-- ---------------------------------------------------------------------
-- Bodies are `schema.sql`'s, with the deadline expression swapped for the
-- helper. Everything else (ownership, the `ongoing` guard, the 2000-character
-- cap) is deliberately untouched: this file is about when an answer may land,
-- not about what an answer may be.
create or replace function public.merge_submission_answer(
  p_submission_id uuid,
  p_question_id uuid,
  p_selected_option int
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication is required to save an exam answer'
      using errcode = '42501';
  end if;

  update public.exam_submissions as s
  set answers = jsonb_set(
        coalesce(s.answers, '{}'::jsonb),
        array[p_question_id::text],
        to_jsonb(p_selected_option),
        true
      )
  where s.id = p_submission_id
    and s.student_id = auth.uid()
    and s.status = 'ongoing'
    and exists (
      select 1
      from public.exams e
      where e.id = s.exam_id
        -- The window's `ends_at` is the hard close: an answer that arrives
        -- after the paper shuts is refused even inside the duration.
        and clock_timestamp() < public.attempt_deadline(
          s.started_at, e.duration_minutes, e.ends_at
        )
    );

  if not found then
    raise exception 'submission is not active or its exam deadline has passed'
      using errcode = '55000';
  end if;
end;
$$;
revoke execute on function public.merge_submission_answer(uuid, uuid, int) from public, anon;
grant execute on function public.merge_submission_answer(uuid, uuid, int) to authenticated, service_role;

create or replace function public.merge_submission_text_answer(
  p_submission_id uuid,
  p_question_id   uuid,
  p_answer        text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication is required to save an exam answer'
      using errcode = '42501';
  end if;

  update public.exam_submissions as s
  set answers = jsonb_set(
        coalesce(s.answers, '{}'::jsonb),
        array[p_question_id::text],
        to_jsonb(left(coalesce(p_answer, ''), 2000)),
        true
      )
  where s.id = p_submission_id
    and s.student_id = auth.uid()
    and s.status = 'ongoing'
    and exists (
      select 1
      from public.exams e
      where e.id = s.exam_id
        and clock_timestamp() < public.attempt_deadline(
          s.started_at, e.duration_minutes, e.ends_at
        )
    );

  if not found then
    raise exception 'submission is not active or its exam deadline has passed'
      using errcode = '55000';
  end if;
end;
$$;
revoke execute on function public.merge_submission_text_answer(uuid, uuid, text) from public, anon;
grant execute on function public.merge_submission_text_answer(uuid, uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 5. THE CLOSE RECORDS THE WINDOW-AWARE DEADLINE
-- ---------------------------------------------------------------------
-- One line differs from `schema.sql`'s copy: `v_ends_at` is read with the
-- duration and the effective submit time is `attempt_deadline(...)` rather than
-- `started_at + duration_minutes`. Grading is untouched - it is still
-- `auto_graded_score()` - so an attempt closed after a hard close is still
-- marked from the answers that reached the row before it, which is the same
-- treatment an attempt closed after its own duration has always had.
create or replace function public.submit_exam(
  p_submission_id uuid,
  p_disqualified  boolean default false
)
returns table(result_status text, final_score numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student uuid;
  v_exam    uuid;
  v_status  text;
  v_started_at timestamptz;
  v_duration_minutes int;
  v_ends_at timestamptz;
  v_submitted_at timestamptz;
  v_score   numeric;
begin
  if auth.uid() is null then
    raise exception 'authentication is required to submit an exam'
      using errcode = '42501';
  end if;

  select s.student_id, s.exam_id, s.status, s.started_at,
         e.duration_minutes, e.ends_at
    into v_student, v_exam, v_status, v_started_at,
         v_duration_minutes, v_ends_at
  from public.exam_submissions s
  join public.exams e on e.id = s.exam_id
  where s.id = p_submission_id
  for update of s;

  if v_student is null then
    raise exception 'submission % does not exist', p_submission_id
      using errcode = 'P0002';
  end if;

  if v_student <> auth.uid() and not public.is_exam_supervisor() then
    raise exception 'submission % does not belong to the caller', p_submission_id
      using errcode = '42501';
  end if;

  -- Already closed: report the stored outcome (retry-safe).
  if v_status <> 'ongoing' then
    return query
      select s.status, s.score
      from public.exam_submissions s
      where s.id = p_submission_id;
    return;
  end if;

  -- Expired attempts are closed and graded from answers saved before the
  -- deadline. Record the deadline as the effective submit time for late closes:
  -- whichever came first, the attempt's own duration or the paper's close.
  v_submitted_at := least(
    clock_timestamp(),
    public.attempt_deadline(v_started_at, v_duration_minutes, v_ends_at)
  );

  -- A disqualified attempt is never graded: a score would imply it counts.
  if p_disqualified then
    update public.exam_submissions
    set status = 'disqualified', submitted_at = now(), score = null
    where id = p_submission_id;

    return query select 'disqualified'::text, null::numeric;
    return;
  end if;

  -- Grading is a sum of `questions.points` over the questions the student got
  -- right, and it has to cover every automatically graded shape:
  --   * multiple choice: the stored jsonb number equals `correct_option`
  --   * true/false and fill in the blank: the stored jsonb string matches
  --     `correct_text_answer` case-insensitively after trimming, so "  http "
  --     counts for "HTTP" and "TRUE" counts for "true"
  -- A 'subjective' row never matches: it has no key, and its marks arrive later
  -- through `grade_submission()` after a person read it. An unanswered question
  -- stores nothing, so `->>` is NULL and the comparison is NULL (never true) - it
  -- simply does not score.
  --
  -- The sum itself lives in `auto_graded_score()` so this close and a later
  -- `grade_submission()` cannot drift apart about which answers count.
  v_score := public.auto_graded_score(p_submission_id);

  update public.exam_submissions
  set status = 'submitted', submitted_at = v_submitted_at, score = v_score
  where id = p_submission_id;

  return query select 'submitted'::text, v_score;
end;
$$;

comment on function public.submit_exam(uuid, boolean) is
  'Closes and grades a student''s own attempt; late answer writes are rejected and an expired attempt is graded from saved answers. The deadline is started_at + duration_minutes, capped by the exam window''s ends_at. Idempotent.';

revoke execute on function public.submit_exam(uuid, boolean) from public, anon;
grant execute on function public.submit_exam(uuid, boolean) to authenticated, service_role;

