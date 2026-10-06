-- =====================================================================
-- PROCTORGUARD - FOUR QUESTION TYPES + MARKING BY HAND
-- Widens `public.questions` from two shapes to four ('multiple_choice',
-- 'true_false', 'fill_in_the_blank', 'subjective') and adds the table and the
-- RPC that carry the marks a lecturer awards to an essay by hand.
--
-- WHY THIS FILE EXISTS SEPARATELY
--   `schema.sql` guards its shape rules with `drop constraint if exists` +
--   `add constraint` (and creates the new table with `create table if not
--   exists`), so a re-run of that file is fine on an existing project - but a
--   project that predates this change has already been *created*, and the two
--   checks naming the old two-value list and the old two-shape rule are what
--   that database holds. A console authoring a true/false or subjective
--   question against it would get `23514 new row for relation "questions"
--   violates check constraint "questions_question_type_check"` - a schema
--   error where the lecturer expected a saved question. This file is the
--   upgrade path; `schema.sql` sections 3 and 8 carry the same DDL for fresh
--   installs, and the two must be kept in step.
--
--   `submit_exam()` is replaced as well, and not only for symmetry: the copy on
--   a live project grades multiple-choice and fill-in-the-blank answers, so a
--   true/false row would silently never score. The body below is `schema.sql`'s,
--   with the automatic sum moved into `auto_graded_score()`.
--
-- SAFETY
--   * Safe to re-run: both constraints are dropped by name before being
--     re-created, the table is `create table if not exists`, and every function
--     is `create or replace`.
--   * Additive for data: no row is rewritten and nothing is deleted. The one
--     statement that can fail on existing data is the new `points >= 0` check,
--     and it fails by design if this project really holds a zero-or-negative
--     weighted question - that row breaks `submit_exam()`'s sum long before
--     this file mentions it, so fix the row (`update public.questions set
--     points = 1 where points < 0;`) and re-run.
--   * `question_grades` starts empty: marks awarded through the console's
--     grading view are the only rows that will ever be in it, and an attempt
--     graded before this migration simply has no per-answer record.
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/question_types_and_grading.sql
--     (`db query -f` also sends `create or replace function`, which `db push`
--     would not, since this file is not managed as a migration version.)
--   * Verify with:
--       select conname, pg_get_constraintdef(oid)
--         from pg_constraint
--        where conrelid = 'public.questions'::regclass;
--       select count(*) from public.question_grades;
--     after authoring one true/false question and marking one essay: the first
--     query shows four allowed types, the second counts the mark.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. FOUR SHAPES
-- ---------------------------------------------------------------------
-- The drop is the point: on a live project the name already exists, so an
-- `if not exists` guard would have left the old two-value check in place.
alter table public.questions
  drop constraint if exists questions_question_type_check;
alter table public.questions
  add constraint questions_question_type_check
  check (question_type in ('multiple_choice', 'true_false',
                           'fill_in_the_blank', 'subjective'));

-- One answer key per row, matching the row's type. 'true_false' stores the
-- word in `correct_text_answer` ('true' / 'false'), which is also what a
-- true/false tap writes into `exam_submissions.answers` - the same JSON string
-- path `merge_submission_text_answer()` already owns. 'subjective' is the
-- deliberate exception: its shape is having no key at all, because the mark
-- comes from a person through `grade_submission()`.
alter table public.questions
  drop constraint if exists questions_answer_key_shape;
alter table public.questions
  add constraint questions_answer_key_shape
  check (
    (question_type = 'multiple_choice' and correct_option is not null)
    or
    (question_type = 'true_false'
      and lower(btrim(coalesce(correct_text_answer, ''))) in ('true', 'false'))
    or
    (question_type = 'fill_in_the_blank'
      and coalesce(btrim(correct_text_answer), '') <> '')
    or
    question_type = 'subjective'
  );

-- `points` feeds the sum `submit_exam()` writes into `score`, so a
-- zero-or-negative weight lets a paper mark itself down.
alter table public.questions drop constraint if exists questions_points_non_negative;
alter table public.questions
  add constraint questions_points_non_negative check (points >= 0);

-- ---------------------------------------------------------------------
-- 2. QUESTION GRADES (the marks a person awarded)
-- ---------------------------------------------------------------------
-- One row per hand-marked answer. The student's own words stay where they were
-- written - `exam_submissions.answers`, frozen the moment the attempt closed by
-- `guard_submission_immutability` - so a re-mark reads the same evidence the
-- first mark did.
create table if not exists public.question_grades (
  id            uuid primary key default uuid_generate_v4(),
  submission_id uuid not null references public.exam_submissions(id) on delete cascade,
  question_id   uuid not null references public.questions(id) on delete cascade,
  awarded       numeric not null check (awarded >= 0),
  feedback      text,
  graded_by     uuid not null default auth.uid(),
  graded_at     timestamptz not null default now(),
  unique (submission_id, question_id)
);

alter table public.question_grades enable row level security;

drop policy if exists "question_grades_select_staff" on public.question_grades;

-- Read: the staff tier, matching the attempts and their incident rows. Students
-- read nothing here; their total is on their own `exam_submissions.score`.
create policy "question_grades_select_staff"
  on public.question_grades for select
  to authenticated
  using (public.is_staff());

-- No insert, update or delete policy on purpose: `grade_submission()` is
-- SECURITY DEFINER and re-checks that the caller owns the paper, so it is the
-- single write path - the same shape `proctoring_logs` uses for violations.
create index if not exists idx_question_grades_question_id
  on public.question_grades(question_id);

-- ---------------------------------------------------------------------
-- 3. THE AUTOMATIC SUM, IN ONE PLACE
-- ---------------------------------------------------------------------
-- `submit_exam()` calls this to set `score` when an attempt closes, and
-- `grade_submission()` calls it to recompute that same part after an essay is
-- marked. Without one home for the predicate, a re-mark would eventually
-- disagree with the close that preceded it about which answers counted.
--
-- SECURITY DEFINER because the caller's own policies hide the answer key
-- (`questions` has no student SELECT policy, so every attempt would grade 0
-- under invoker semantics). It returns one number, never the key it read.
create or replace function public.auto_graded_score(p_submission_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(q.points), 0)
  from public.questions q
  join public.exam_submissions s on s.id = p_submission_id
  where q.exam_id = s.exam_id
    and (s.student_id = auth.uid() or public.is_staff())
    and (
      (
        q.question_type = 'multiple_choice'
        and s.answers -> q.id::text = to_jsonb(q.correct_option)
      )
      or
      (
        q.question_type in ('fill_in_the_blank', 'true_false')
        and coalesce(btrim(q.correct_text_answer), '') <> ''
        and lower(btrim(s.answers ->> q.id::text)) =
            lower(btrim(q.correct_text_answer))
      )
    );
$$;

comment on function public.auto_graded_score(uuid) is
  'Automatic part of an attempt''s score (multiple-choice, true/false and fill-in-the-blank answers). Marks awarded by hand live in question_grades.';

revoke execute on function public.auto_graded_score(uuid) from public, anon;
grant execute on function public.auto_graded_score(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4. MARKING THE SUBJECTIVE ANSWERS
-- ---------------------------------------------------------------------
-- The only writer of `question_grades`, and the only writer of a `score` a
-- person influenced. `p_grades` is a JSON object keyed by question id:
--
--   { "<question uuid>": { "awarded": 7.5, "feedback": "Good structure." } }
--
-- Owner (or admin) only, subjective questions of that paper only, a handed-in
-- attempt only, and never more than the question is worth. The marks are
-- upserted and `score` is recomputed - automatic plus awarded - so replaying
-- the call after a dropped connection changes nothing, and re-marking is a
-- correction of the same row rather than a second award.
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
  -- administrator is the deliberate exception.
  if v_owner <> auth.uid() and not public.is_admin() then
    raise exception 'only the exam owner may grade its answers'
      using errcode = '42501';
  end if;

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
    -- type, which a plain inequality lets through as NULL (not false), and the
    -- NULL mark would then be refused by the column with a raw NOT NULL error.
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
      nullif(left(coalesce(v_entry.mark ->> 'feedback', ''), 2000), ''),
      auth.uid()
    )
    on conflict (submission_id, question_id) do update
      set awarded   = excluded.awarded,
          feedback  = excluded.feedback,
          graded_by = excluded.graded_by,
          graded_at = now();
  end loop;

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

  -- Rewritten from scratch: that is what makes a re-mark a correction, and why a
  -- partially marked attempt already carries a meaningful total.
  -- `guard_submission_immutability` allows this write to a closed row (score is
  -- exactly what a re-mark may change) while still refusing any change to
  -- `answers`.
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
-- 5. submit_exam() GRADES TRUE/FALSE TOO
-- ---------------------------------------------------------------------
-- The copy already deployed on this project sums `points` for
-- 'multiple_choice' and 'fill_in_the_blank' rows only, so a true/false answer
-- would never score. The body below is `schema.sql`'s, with the sum delegated to
-- `auto_graded_score()` above - one predicate, used by the close and by every
-- re-mark that follows it. Everything else about the function is unchanged:
-- idempotent, rejects late writes, grades an expired attempt from the answers it
-- already holds, and never grades a disqualified one.
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
  v_submitted_at timestamptz;
  v_score   numeric;
begin
  if auth.uid() is null then
    raise exception 'authentication is required to submit an exam'
      using errcode = '42501';
  end if;

  select s.student_id, s.exam_id, s.status, s.started_at, e.duration_minutes
    into v_student, v_exam, v_status, v_started_at, v_duration_minutes
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
  -- deadline. Record the deadline as the effective submit time for late closes.
  v_submitted_at := least(
    clock_timestamp(),
    v_started_at + make_interval(mins => v_duration_minutes)
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
  -- right: multiple-choice by stored index, true/false and fill-in-the-blank by
  -- stored wording (trimmed, case-insensitive). See `auto_graded_score()`.
  v_score := public.auto_graded_score(p_submission_id);

  update public.exam_submissions
  set status = 'submitted', submitted_at = v_submitted_at, score = v_score
  where id = p_submission_id;

  return query select 'submitted'::text, v_score;
end;
$$;

comment on function public.submit_exam(uuid, boolean) is
  'Closes and grades a student''s own attempt; late answer writes are rejected and an expired attempt is graded from saved answers. Idempotent.';

revoke execute on function public.submit_exam(uuid, boolean) from public, anon;
grant execute on function public.submit_exam(uuid, boolean) to authenticated, service_role;



