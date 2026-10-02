-- Apply after the base schema to harden exam ownership, staff interventions,
-- answer RPC deadlines, and anonymous RPC execution.

create or replace function public.is_exam_supervisor()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('admin', 'supervisor')
  );
$$;

drop policy if exists "exams_update_owner" on public.exams;
create policy "exams_update_owner"
  on public.exams for update
  to authenticated
  using (created_by = auth.uid() and public.is_staff());

drop policy if exists "exams_delete_owner" on public.exams;
create policy "exams_delete_owner"
  on public.exams for delete
  to authenticated
  using (created_by = auth.uid() and public.is_staff());

drop policy if exists "questions_select_owner" on public.questions;
create policy "questions_select_owner"
  on public.questions for select
  to authenticated
  using (
    exists (
      select 1 from public.exams e
      where e.id = exam_id and e.created_by = auth.uid()
    )
    and public.is_staff()
  );

drop policy if exists "questions_write_owner" on public.questions;
create policy "questions_write_owner"
  on public.questions for insert
  to authenticated
  with check (
    exists (
      select 1 from public.exams e
      where e.id = exam_id and e.created_by = auth.uid()
    )
    and public.is_staff()
  );

drop policy if exists "questions_update_owner" on public.questions;
create policy "questions_update_owner"
  on public.questions for update
  to authenticated
  using (
    exists (
      select 1 from public.exams e
      where e.id = exam_id and e.created_by = auth.uid()
    )
    and public.is_staff()
  );

drop policy if exists "questions_delete_owner" on public.questions;
create policy "questions_delete_owner"
  on public.questions for delete
  to authenticated
  using (
    exists (
      select 1 from public.exams e
      where e.id = exam_id and e.created_by = auth.uid()
    )
    and public.is_staff()
  );

drop policy if exists "submissions_update_supervisor" on public.exam_submissions;
create policy "submissions_update_supervisor"
  on public.exam_submissions for update
  to authenticated
  using (public.is_exam_supervisor())
  with check (public.is_exam_supervisor());

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
      where e.id = exam_id and e.is_published = true
    )
  );

drop policy if exists "submissions_delete_supervisor" on public.exam_submissions;
create policy "submissions_delete_supervisor"
  on public.exam_submissions for delete
  to authenticated
  using (public.is_exam_supervisor());

drop policy if exists "Proctor snapshots supervisor purge" on storage.objects;
create policy "Proctor snapshots supervisor purge"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'proctor-snapshots'
    and public.is_exam_supervisor()
  );

drop function if exists public.register_violation(uuid, text);
drop function if exists public.register_violation(uuid, text, text);

create or replace function public.register_violation(
  p_submission_id    uuid,
  p_action_type      text,
  p_snapshot_url     text default null,
  p_client_timestamp timestamptz default null,
  p_client_event_id  uuid default null
)
returns table(warning_count int, disqualified boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'authentication is required to register a violation'
      using errcode = '42501';
  end if;

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

  if v_status <> 'ongoing' then
    select count(*) into v_count
    from public.proctoring_logs
    where submission_id = p_submission_id;
    return query select v_count, (v_status = 'disqualified');
    return;
  end if;

  insert into public.proctoring_logs (
    submission_id, action_type, snapshot_url, client_timestamp, client_event_id
  )
  values (
    p_submission_id,
    p_action_type,
    p_snapshot_url,
    coalesce(p_client_timestamp, now()),
    p_client_event_id
  )
  on conflict (client_event_id) where client_event_id is not null do nothing;

  select count(*) into v_count
  from public.proctoring_logs
  where submission_id = p_submission_id;

  if v_count >= 3 then
    update public.exam_submissions
    set status = 'disqualified', submitted_at = now(), score = null
    where id = p_submission_id and status = 'ongoing';
    return query select v_count, true;
  else
    return query select v_count, false;
  end if;
end;
$$;
revoke execute on function public.register_violation(uuid, text, text, timestamptz, uuid) from public, anon;
grant execute on function public.register_violation(uuid, text, text, timestamptz, uuid) to authenticated, service_role;

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
        and clock_timestamp() < s.started_at
          + make_interval(mins => e.duration_minutes)
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
        and clock_timestamp() < s.started_at
          + make_interval(mins => e.duration_minutes)
    );

  if not found then
    raise exception 'submission is not active or its exam deadline has passed'
      using errcode = '55000';
  end if;
end;
$$;
revoke execute on function public.merge_submission_text_answer(uuid, uuid, text) from public, anon;
grant execute on function public.merge_submission_text_answer(uuid, uuid, text) to authenticated, service_role;

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
  v_exam uuid;
  v_status text;
  v_started_at timestamptz;
  v_duration_minutes int;
  v_submitted_at timestamptz;
  v_score numeric;
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

  if v_status <> 'ongoing' then
    return query
      select s.status, s.score
      from public.exam_submissions s
      where s.id = p_submission_id;
    return;
  end if;

  if p_disqualified then
    update public.exam_submissions
    set status = 'disqualified', submitted_at = clock_timestamp(), score = null
    where id = p_submission_id;

    return query select 'disqualified'::text, null::numeric;
    return;
  end if;

  v_submitted_at := least(
    clock_timestamp(),
    v_started_at + make_interval(mins => v_duration_minutes)
  );

  select coalesce(sum(q.points), 0)
    into v_score
  from public.questions q
  join public.exam_submissions s on s.id = p_submission_id
  where q.exam_id = v_exam
    and (
      (
        q.question_type = 'multiple_choice'
        and s.answers -> q.id::text = to_jsonb(q.correct_option)
      )
      or
      (
        q.question_type = 'fill_in_the_blank'
        and coalesce(btrim(q.correct_text_answer), '') <> ''
        and lower(btrim(s.answers ->> q.id::text)) =
            lower(btrim(q.correct_text_answer))
      )
    );

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
