-- =====================================================================
-- PROCTOR — SUPABASE SCHEMA + ROW LEVEL SECURITY (PRODUCTION READY)
-- Single source of truth for BOTH ../mobile (Flutter) and ../dashboard (React).
-- Run in Supabase SQL editor. Assumes auth.users is Supabase Auth.
-- =====================================================================

create extension if not exists "uuid-ossp";

-- ---------------------------------------------------------------------
-- 1. USERS (profile table, 1:1 with auth.users)
-- ---------------------------------------------------------------------
create table if not exists public.users (
  id          uuid primary key references auth.users(id) on delete cascade,
  role        text not null check (role in ('student','supervisor')),
  name        text not null,
  email       text not null unique,
  created_at  timestamptz not null default now()
);

alter table public.users enable row level security;

-- Security Definer helper function prevents RLS infinite recursion loops
create or replace function public.is_supervisor()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.users
    where id = auth.uid() and role = 'supervisor'
  );
$$;

-- Drop legacy policies to ensure a clean state
drop policy if exists "users_select_own_or_supervisor" on public.users;
drop policy if exists "Users can view own profile" on public.users;
drop policy if exists "Authenticated users can read profiles" on public.users;
drop policy if exists "users_insert_self" on public.users;
drop policy if exists "users_update_self" on public.users;

create policy "Authenticated users can read profiles"
  on public.users for select
  to authenticated
  using (true);

create policy "users_insert_self"
  on public.users for insert
  to authenticated
  with check (id = auth.uid());

create policy "users_update_self"
  on public.users for update
  to authenticated
  using (id = auth.uid());

-- ---------------------------------------------------------------------
-- 2. EXAMS
-- ---------------------------------------------------------------------
create table if not exists public.exams (
  id               uuid primary key default uuid_generate_v4(),
  title            text not null,
  created_by       uuid not null references public.users(id) on delete cascade,
  duration_minutes int not null check (duration_minutes > 0),
  is_published     boolean not null default false,
  created_at       timestamptz not null default now()
);

alter table public.exams enable row level security;

drop policy if exists "exams_select" on public.exams;
drop policy if exists "exams_insert_supervisor_only" on public.exams;
drop policy if exists "exams_update_owner" on public.exams;
drop policy if exists "exams_delete_owner" on public.exams;

create policy "exams_select"
  on public.exams for select
  to authenticated
  using (
    is_published = true
    or created_by = auth.uid()
    or public.is_supervisor()
  );

create policy "exams_insert_supervisor_only"
  on public.exams for insert
  to authenticated
  with check (
    created_by = auth.uid()
    and public.is_supervisor()
  );

create policy "exams_update_owner"
  on public.exams for update
  to authenticated
  using (created_by = auth.uid());

create policy "exams_delete_owner"
  on public.exams for delete
  to authenticated
  using (created_by = auth.uid());

-- ---------------------------------------------------------------------
-- 3. QUESTIONS
-- ---------------------------------------------------------------------
create table if not exists public.questions (
  id              uuid primary key default uuid_generate_v4(),
  exam_id         uuid not null references public.exams(id) on delete cascade,
  question_text   text not null,
  options         jsonb not null,          -- e.g. ["A","B","C","D"]
  correct_option  int not null,
  points          numeric not null default 1,
  created_at      timestamptz not null default now()
);

alter table public.questions enable row level security;

drop policy if exists "questions_select_owner" on public.questions;
drop policy if exists "questions_select_student_published" on public.questions;
drop policy if exists "questions_write_owner" on public.questions;
drop policy if exists "questions_update_owner" on public.questions;

create policy "questions_select_owner"
  on public.questions for select
  to authenticated
  using (
    exists (select 1 from public.exams e where e.id = exam_id and e.created_by = auth.uid())
  );

create policy "questions_select_student_published"
  on public.questions for select
  to authenticated
  using (
    exists (select 1 from public.exams e where e.id = exam_id and e.is_published = true)
  );

create policy "questions_write_owner"
  on public.questions for insert
  to authenticated
  with check (
    exists (select 1 from public.exams e where e.id = exam_id and e.created_by = auth.uid())
  );

create policy "questions_update_owner"
  on public.questions for update
  to authenticated
  using (
    exists (select 1 from public.exams e where e.id = exam_id and e.created_by = auth.uid())
  );

-- Student-safe view: strips correct_option so students never receive answer keys
create or replace view public.questions_public as
  select id, exam_id, question_text, options, points, created_at
  from public.questions;

alter view public.questions_public set (security_invoker = true);

-- ---------------------------------------------------------------------
-- 4. EXAM SUBMISSIONS
-- ---------------------------------------------------------------------
create table if not exists public.exam_submissions (
  id            uuid primary key default uuid_generate_v4(),
  student_id    uuid not null references public.users(id) on delete cascade,
  exam_id       uuid not null references public.exams(id) on delete cascade,
  answers       jsonb not null default '{}'::jsonb,
  status        text not null default 'ongoing'
                check (status in ('ongoing','submitted','disqualified')),
  score         numeric,
  started_at    timestamptz not null default now(),
  submitted_at  timestamptz,
  unique (student_id, exam_id)
);

alter table public.exam_submissions enable row level security;

drop policy if exists "submissions_select_own_or_supervisor" on public.exam_submissions;
drop policy if exists "submissions_insert_own" on public.exam_submissions;
drop policy if exists "submissions_update_own_ongoing" on public.exam_submissions;
drop policy if exists "submissions_update_supervisor" on public.exam_submissions;

create policy "submissions_select_own_or_supervisor"
  on public.exam_submissions for select
  to authenticated
  using (
    student_id = auth.uid()
    or exists (
      select 1 from public.exams e
      where e.id = exam_id and e.created_by = auth.uid()
    )
  );

create policy "submissions_insert_own"
  on public.exam_submissions for insert
  to authenticated
  with check (student_id = auth.uid());

create policy "submissions_update_own_ongoing"
  on public.exam_submissions for update
  to authenticated
  using (student_id = auth.uid() and status = 'ongoing');

create policy "submissions_update_supervisor"
  on public.exam_submissions for update
  to authenticated
  using (
    exists (select 1 from public.exams e where e.id = exam_id and e.created_by = auth.uid())
  );

-- ---------------------------------------------------------------------
-- 5. PROCTORING LOGS
-- ---------------------------------------------------------------------
create table if not exists public.proctoring_logs (
  id             uuid primary key default uuid_generate_v4(),
  submission_id  uuid not null references public.exam_submissions(id) on delete cascade,
  action_type    text not null check (
                   action_type in ('looking_away','multiple_faces','no_face','app_minimized','audio_noise')
                 ),
  timestamp      timestamptz not null default now(),
  snapshot_url   text
);

alter table public.proctoring_logs enable row level security;

drop policy if exists "logs_select_own_or_supervisor" on public.proctoring_logs;
drop policy if exists "logs_insert_own_ongoing" on public.proctoring_logs;

create policy "logs_select_own_or_supervisor"
  on public.proctoring_logs for select
  to authenticated
  using (
    exists (
      select 1 from public.exam_submissions s
      where s.id = submission_id and s.student_id = auth.uid()
    )
    or exists (
      select 1 from public.exam_submissions s
      join public.exams e on e.id = s.exam_id
      where s.id = submission_id and e.created_by = auth.uid()
    )
  );

create policy "logs_insert_own_ongoing"
  on public.proctoring_logs for insert
  to authenticated
  with check (
    exists (
      select 1 from public.exam_submissions s
      where s.id = submission_id
        and s.student_id = auth.uid()
        and s.status = 'ongoing'
    )
  );

-- ---------------------------------------------------------------------
-- 6. STORAGE BUCKET (Proctoring Violation Snapshots)
-- ---------------------------------------------------------------------
-- Path convention written by the mobile app (core/services/supabase_service.dart):
--   <submission_id>/<action_type>_<epoch-ms>.jpg
-- so the first folder is always the submission the snapshot belongs to.
-- The bucket is public because the supervisor console renders the URL straight
-- in an <img>; anyone holding a URL can fetch that snapshot, so treat it as
-- unguessable rather than secret. The policies below still scope uploads to
-- the owning student. Everything here is idempotent - safe to re-run.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('proctor-snapshots', 'proctor-snapshots', true, 5242880, array['image/jpeg', 'image/png'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Proctor snapshots read access" on storage.objects;
drop policy if exists "Proctor snapshots upload access" on storage.objects;
drop policy if exists "Proctor snapshots upload own ongoing session" on storage.objects;

-- Read: the student who owns the submission, or the supervisor who owns the
-- exam (public buckets already serve /object/public/... without a policy; this
-- covers list()/download() through the SDKs).
create policy "Proctor snapshots read access"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'proctor-snapshots'
    and (
      exists (
        select 1 from public.exam_submissions s
        where s.id::text = (storage.foldername(name))[1]
          and s.student_id = auth.uid()
      )
      or exists (
        select 1 from public.exam_submissions s
        join public.exams e on e.id = s.exam_id
        where s.id::text = (storage.foldername(name))[1]
          and e.created_by = auth.uid()
      )
    )
  );

-- Upload: authenticated students only, and only into a folder for their OWN
-- submission while it is still 'ongoing' - mirrors the append-only
-- logs_insert_own_ongoing policy on public.proctoring_logs.
create policy "Proctor snapshots upload own ongoing session"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'proctor-snapshots'
    and exists (
      select 1 from public.exam_submissions s
      where s.id::text = (storage.foldername(name))[1]
        and s.student_id = auth.uid()
        and s.status = 'ongoing'
    )
  );

-- Deliberately no update/delete policy: snapshots are evidence, so like the
-- log rows they hang off they are append-only for clients.

-- ---------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------
create index if not exists idx_questions_exam_id on public.questions(exam_id);
create index if not exists idx_submissions_exam_id on public.exam_submissions(exam_id);
create index if not exists idx_submissions_student_id on public.exam_submissions(student_id);
create index if not exists idx_logs_submission_id on public.proctoring_logs(submission_id);
create index if not exists idx_logs_timestamp on public.proctoring_logs(timestamp desc);

-- ---------------------------------------------------------------------
-- Realtime setup
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'proctoring_logs') then
    alter publication supabase_realtime add table public.proctoring_logs;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'exam_submissions') then
    alter publication supabase_realtime add table public.exam_submissions;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Server-side 3-strike escalation (RPC)
-- ---------------------------------------------------------------------
-- p_snapshot_url is optional, so a client that only knows the violation type
-- keeps working. The 2-argument overload is dropped explicitly: leaving it in
-- place would make `register_violation(uuid, text)` ambiguous ("function
-- register_violation(uuid, text) is not unique") now that a defaulted
-- 3-argument version exists.
drop function if exists public.register_violation(uuid, text);

create or replace function public.register_violation(
  p_submission_id uuid,
  p_action_type   text,
  p_snapshot_url  text default null
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
  insert into public.proctoring_logs (submission_id, action_type, snapshot_url)
  values (p_submission_id, p_action_type, p_snapshot_url);

  select count(*) into v_count
  from public.proctoring_logs
  where submission_id = p_submission_id;

  if v_count >= 3 then
    update public.exam_submissions
    set status = 'disqualified', submitted_at = now()
    where id = p_submission_id and status = 'ongoing';
    v_status := 'disqualified';
  else
    v_status := 'ongoing';
  end if;

  return query select v_count, (v_status = 'disqualified');
end;
$$;

-- ---------------------------------------------------------------------
-- Race-safe partial-answer merge (RPC)
-- ---------------------------------------------------------------------
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
  update public.exam_submissions
  set answers = jsonb_set(
        coalesce(answers, '{}'::jsonb),
        array[p_question_id::text],
        to_jsonb(p_selected_option),
        true
      )
  where id = p_submission_id
    and student_id = auth.uid()
    and status = 'ongoing';
end;
$$;