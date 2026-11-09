-- =====================================================================
-- PROCTORGUARD - A SUPERVISOR IS SCOPED TO THE SITTINGS THEY ARE ASSIGNED TO
-- Adds `public.supervisor_exam_assignments` and the predicate that reads it, and
-- moves every supervisor arm in the schema from "the intervention tier, anywhere"
-- to "the intervention tier, on this paper".
--
-- WHY THIS FILE EXISTS
--   `is_exam_supervisor()` answers a *tier* question - is this account an admin or
--   a supervisor - and every policy that asked it granted that tier the whole
--   institution: any attempt, any incident feed, any face, any paper's questions.
--   That is the right reach for an administrator, who is accountable for the
--   deployment, and the wrong one for a supervisor, who is accountable for the
--   sittings they were put in charge of. In a department with two simultaneous
--   papers, the invigilator of the morning sitting could read the faces, the
--   incidents and the review decisions recorded in the afternoon one, and could
--   reset an attempt in it. Nothing recorded that they had been asked to.
--   The rule now: **a supervisor reaches exactly the papers an administrator
--   assigned to them**, and an administrator still reaches every paper.
--
-- WHAT CHANGES
--   1. A new table, `public.supervisor_exam_assignments` - one row per
--      (paper, supervisor), written only by an administrator, readable by the
--      supervisor it names and by administrators. `guard_supervisor_assignment()`
--      refuses a row whose `supervisor_id` is not a `supervisor` account.
--   2. Two new predicates:
--        is_supervisor_only()      role = 'supervisor' - the one staff label this
--                                  file narrows (admin and lecturer are not
--                                  "supervisor only", so nothing about them moves);
--        can_supervise_exam(uuid)  an administrator, or a supervisor assigned to
--                                  that paper. The answer to "may this account
--                                  intervene in *this* sitting?".
--   3. Every policy and RPC that asked `is_exam_supervisor()` now asks
--      `can_supervise_exam(<the paper the row belongs to>)`:
--        exams_select, exam_allowed_students_select, questions_select_supervisor,
--        questions_public (view), submissions_select_own_or_supervisor,
--        submissions_update_supervisor, submissions_delete_supervisor,
--        consents_select_own_or_supervisor, logs_select_own_or_supervisor,
--        heartbeats_select_own_or_supervisor, "Proctor snapshots read access",
--        session_reset_logs_select_staff, session_reset_logs_insert_supervisor,
--        attempt_review_logs_select_staff, question_grades_select_staff,
--        and proctoring_coverage(), proctoring_coverage_for_exam(),
--        resolve_flagged_attempt(), submit_exam().
--
-- WHAT IT DOES NOT DO
--   * **A lecturer keeps exactly what they had.** Every `owns_exam()` arm is
--     untouched, `is_staff()`'s roster read is untouched for lecturers, and
--     `is_attempt_resetter()` still names all three staff roles. The lecturer
--     console reads the same rows before and after this file.
--   * An **administrator** keeps every paper: `can_supervise_exam()` is true for
--     `role = 'admin'` without an assignment, so the admin console's monitor,
--     analytics and reset controls are unchanged.
--   * No student gains anything. The student arms (`student_id = auth.uid()`,
--     `student_can_access_exam()`, `questions_public`'s window) are copied across
--     unchanged.
--   * It deletes **no** evidence and rewrites **no** row of `proctoring_logs`,
--     `exam_submissions`, `proctor_heartbeats`, `proctoring_consents`,
--     `session_reset_logs` or `attempt_review_logs`. It changes who may read and
--     write them from now on.
--   * It does not backfill assignments for accounts that are already supervisors:
--     guessing "this supervisor keeps all 400 papers" would recreate the hole this
--     file closes. An existing supervisor sees an empty console until an
--     administrator assigns them a sitting - which is the state the console names.
--   * It does not delete an assignment when an account stops being a supervisor:
--     `can_supervise_exam()` asks the role as well as the row, so a demoted
--     account loses the reach immediately, and re-promoting it restores the
--     sittings it was trusted with.
--
-- SAFETY
--   * Safe to re-run. The table, the index and the trigger are `if not exists` /
--     `create or replace`; every policy is dropped by name before it is recreated
--     (a `create policy` on an existing name is a 42710).
--   * Fail-closed for the supervisor: no row, no reach. The failure mode of a
--     forgotten assignment is an empty console, never an over-broad one.
--   * The verification block at the bottom refuses to look successful if the
--     table, the predicates or the rewrites are missing - including a scan of
--     `pg_policies` that raises if any policy still asks `is_exam_supervisor()`,
--     which is exactly the drift this file removes.
--   * `is_exam_supervisor()` itself stays defined: the tier is still the right
--     question for *identity* actions (see
--     `supabase/functions/admin-reset-password/index.ts`), and a database that has
--     not re-run its older files still has policies calling it. It is no longer
--     asked by any policy in this file or in `schema.sql`.
--
-- APPLY ORDER
--   * Last. It rewrites policies and functions created by
--     `20261103090200_exams_select.sql`, `20261103090300_questions_public.sql`,
--     `20261103090500_snapshot_read_policy.sql`,
--     `20261103090600_submissions_delete_supervisor.sql`,
--     `20261104090100_weighted_strikes_and_flagged_review.sql`,
--     `20261105090000_proctor_heartbeats.sql`,
--     `20261106090000_proctoring_consents.sql`, `academic_targeting.sql`,
--     `lecturer_scoped_log_reads.sql`, `question_types_and_grading.sql`,
--     `secure_exam_access_and_deadlines.sql`, `session_reset_logs.sql`,
--     `staff_attempt_resets.sql` and `strict_targeting_null_profiles.sql`, so it
--     must come after every one of them (the apply lists in
--     `apply_in_order.ps1` / `apply_live_cli.ps1` put it there).
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/20261109090000_supervisor_exam_assignments.sql
--   * Or re-run `supabase/schema.sql`, which carries the same objects for a fresh
--     install (§2c, and the predicates beside `is_staff()`).
--   * Verify (the block at the bottom raises; to look by hand):
--       select exam_id, supervisor_id, assigned_by, assigned_at
--         from public.supervisor_exam_assignments order by assigned_at desc;
--       select proname from pg_proc
--        where pronamespace = 'public'::regnamespace
--          and proname in ('is_supervisor_only', 'can_supervise_exam');
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. WHICH SUPERVISOR MAY RUN WHICH PAPER
-- ---------------------------------------------------------------------
-- One row per (paper, supervisor). Deliberately not a column on `exams`
-- (`supervisor_id`): a sitting is run by whoever is free that morning, and a
-- department has more than one invigilator - a single column would be a lie the
-- first week it was used.
--
-- `assigned_by` is the administrator who made the assignment, defaulted to
-- `auth.uid()` and re-checked by the insert policy below, so "who put this person
-- on this paper" is the database's answer rather than a client's claim - the shape
-- `session_reset_logs.actor_id` already uses.
--
-- Both foreign keys cascade: deleting a paper or an account takes its assignments
-- with it. An assignment to something that no longer exists grants nothing, and
-- leaving the row behind would only make the admin screen lie.
create table if not exists public.supervisor_exam_assignments (
  exam_id       uuid not null references public.exams(id) on delete cascade,
  supervisor_id uuid not null references public.profiles(id) on delete cascade,
  assigned_by   uuid not null default auth.uid(),
  assigned_at   timestamptz not null default now(),
  -- One row per pair: assigning the same supervisor twice is a no-op, not a
  -- second grant that a later unassign would have to guess between.
  primary key (exam_id, supervisor_id)
);

comment on table public.supervisor_exam_assignments is
  'Which supervisor may run which paper. Read by can_supervise_exam(), written only by an administrator. No row = no reach: a supervisor sees, reads and intervenes in exactly the papers listed here.';

-- The primary key already serves "who runs this paper" (its `exam_id` prefix);
-- this index serves the supervisor's own console ("which papers are mine") and the
-- cascade when an account is deleted.
create index if not exists idx_supervisor_assignments_supervisor
  on public.supervisor_exam_assignments(supervisor_id);

-- Nothing but a supervisor account may be assigned. `can_supervise_exam()` asks
-- the role as well as the row, so this is not the guard that makes the scope hold -
-- it is the guard that keeps the *table* honest, so the admin screen cannot record
-- a grant that will never do anything and a later reader cannot mistake it for one.
create or replace function public.guard_supervisor_assignment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role public.user_role;
begin
  select p.role into v_role
  from public.profiles p
  where p.id = new.supervisor_id;

  if v_role is null then
    raise exception 'supervisor assignment: no account with id %', new.supervisor_id
      using errcode = '23503';
  end if;

  if v_role <> 'supervisor' then
    raise exception 'supervisor assignment: % is a %, and only a supervisor account may be assigned to a paper',
      new.supervisor_id, v_role
      using errcode = '23514';
  end if;

  return new;
end $$;

comment on function public.guard_supervisor_assignment() is
  'Refuses a supervisor_exam_assignments row whose supervisor_id is not a supervisor account. can_supervise_exam() asks the role too, so this keeps the table honest rather than carrying the scope.';

drop trigger if exists guard_supervisor_assignment on public.supervisor_exam_assignments;
create trigger guard_supervisor_assignment
  before insert or update on public.supervisor_exam_assignments
  for each row execute function public.guard_supervisor_assignment();

alter table public.supervisor_exam_assignments enable row level security;

drop policy if exists "supervisor_assignments_select_own_or_admin" on public.supervisor_exam_assignments;
drop policy if exists "supervisor_assignments_insert_admin" on public.supervisor_exam_assignments;
drop policy if exists "supervisor_assignments_delete_admin" on public.supervisor_exam_assignments;

-- Read: the supervisor the row names, and administrators (who assign them). A
-- lecturer does not read this table - their own reach comes from `owns_exam()`, and
-- who else was put on a paper is the administrator's business.
create policy "supervisor_assignments_select_own_or_admin"
  on public.supervisor_exam_assignments for select
  to authenticated
  using (supervisor_id = auth.uid() or public.is_admin());

-- Write: administrators only, and only in their own name.
create policy "supervisor_assignments_insert_admin"
  on public.supervisor_exam_assignments for insert
  to authenticated
  with check (public.is_admin() and assigned_by = auth.uid());

-- Unassigning is a DELETE of the pair. There is deliberately NO update policy: the
-- row is a fact ("this person runs this paper"), and changing either half of it is
-- a different assignment, not an edit.
create policy "supervisor_assignments_delete_admin"
  on public.supervisor_exam_assignments for delete
  to authenticated
  using (public.is_admin());

revoke all on table public.supervisor_exam_assignments from anon;
revoke update, truncate on table public.supervisor_exam_assignments from authenticated;
grant select, insert, delete on table public.supervisor_exam_assignments to authenticated;
grant all on table public.supervisor_exam_assignments to service_role;

-- ---------------------------------------------------------------------
-- 2. THE TWO PREDICATES
-- ---------------------------------------------------------------------
-- `is_supervisor_only()` is the one staff label this file narrows; admin and
-- lecturer answer false, which is what leaves their policies exactly as they were.
-- `can_supervise_exam(uuid)` is the per-paper question that replaces the tier
-- question in every policy below. Both are copied from `supabase/schema.sql`
-- character for character.

create or replace function public.is_supervisor_only()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'supervisor'
  );
$$;

comment on function public.is_supervisor_only() is
  'True only for a supervisor account - the staff label whose reach supervisor_exam_assignments narrows. Admin and lecturer are false, which is what keeps their policies unchanged.';

create or replace function public.can_supervise_exam(p_exam_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select p_exam_id is not null
     and (
       exists (
         select 1 from public.profiles
         where id = auth.uid() and role = 'admin'
       )
       or exists (
         select 1
         from public.profiles p
         join public.supervisor_exam_assignments a on a.supervisor_id = p.id
         where p.id = auth.uid()
           and p.role = 'supervisor'
           and a.exam_id = p_exam_id
       )
     );
$$;

comment on function public.can_supervise_exam(uuid) is
  'True when the caller may supervise this paper: an administrator, or a supervisor assigned to it in supervisor_exam_assignments. False for a supervisor with no assignment, for a lecturer (who reaches their own papers through owns_exam()) and for a null paper.';

revoke execute on function public.can_supervise_exam(uuid) from public, anon;
grant execute on function public.can_supervise_exam(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. THE POLICIES (each dropped by name, then recreated)
-- ---------------------------------------------------------------------
-- Every statement below is the one in `supabase/schema.sql`, character for
-- character: `schema_contract_test.dart` compares the two copies and fails if a
-- fresh install and an upgraded project would enforce different predicates.
-- Only the supervisor arm changed - `is_exam_supervisor()` became
-- `can_supervise_exam(<the paper the row belongs to>)` - and every student, author
-- and lecturer arm is the sentence it was before.

drop policy if exists "exams_select" on public.exams;
create policy "exams_select"
  on public.exams for select
  to authenticated
  using (
    (
      public.is_staff()
      and (not public.is_supervisor_only() or public.can_supervise_exam(id))
    )
    or created_by = auth.uid()
    or public.student_can_access_exam(id)
  );

drop policy if exists "exam_allowed_students_select" on public.exam_allowed_students;
create policy "exam_allowed_students_select"
  on public.exam_allowed_students for select
  to authenticated
  using (
    student_id = auth.uid()
    or (
      public.is_staff()
      and (not public.is_supervisor_only() or public.can_supervise_exam(exam_id))
    )
  );

drop policy if exists "questions_select_supervisor" on public.questions;
create policy "questions_select_supervisor"
  on public.questions for select
  to authenticated
  using (
    public.can_supervise_exam(exam_id)
    or public.owns_exam(exam_id)
  );

drop policy if exists "submissions_select_own_or_supervisor" on public.exam_submissions;
create policy "submissions_select_own_or_supervisor"
  on public.exam_submissions for select
  to authenticated
  using (
    student_id = auth.uid()
    or (
      public.is_staff()
      and (not public.is_supervisor_only() or public.can_supervise_exam(exam_id))
    )
  );

drop policy if exists "submissions_update_supervisor" on public.exam_submissions;
create policy "submissions_update_supervisor"
  on public.exam_submissions for update
  to authenticated
  using (public.can_supervise_exam(exam_id))
  with check (public.can_supervise_exam(exam_id));

drop policy if exists "submissions_delete_supervisor" on public.exam_submissions;
create policy "submissions_delete_supervisor"
  on public.exam_submissions for delete
  to authenticated
  using (
    public.can_supervise_exam(exam_id)
    or public.owns_exam(exam_id)
  );

drop policy if exists "consents_select_own_or_supervisor" on public.proctoring_consents;
create policy "consents_select_own_or_supervisor"
  on public.proctoring_consents for select
  to authenticated
  using (
    student_id = auth.uid()
    or (exam_id is not null and public.can_supervise_exam(exam_id))
  );

drop policy if exists "logs_select_own_or_supervisor" on public.proctoring_logs;
create policy "logs_select_own_or_supervisor"
  on public.proctoring_logs for select
  to authenticated
  using (
    exists (
      select 1 from public.exam_submissions s
      where s.id = submission_id
        and (
          s.student_id = auth.uid()
          or public.owns_exam(s.exam_id)
          or public.can_supervise_exam(s.exam_id)
        )
    )
  );

drop policy if exists "heartbeats_select_own_or_supervisor" on public.proctor_heartbeats;
create policy "heartbeats_select_own_or_supervisor"
  on public.proctor_heartbeats for select
  to authenticated
  using (
    exists (
      select 1 from public.exam_submissions s
      where s.id = submission_id
        and (
          s.student_id = auth.uid()
          or public.owns_exam(s.exam_id)
          or public.can_supervise_exam(s.exam_id)
        )
    )
  );

drop policy if exists "Proctor snapshots read access" on storage.objects;
create policy "Proctor snapshots read access"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'proctor-snapshots'
    and exists (
      select 1 from public.exam_submissions s
      where s.id::text = (storage.foldername(name))[1]
        and (
          s.student_id = auth.uid()
          or public.owns_exam(s.exam_id)
          or public.can_supervise_exam(s.exam_id)
        )
    )
  );

drop policy if exists "session_reset_logs_select_staff" on public.session_reset_logs;
create policy "session_reset_logs_select_staff"
  on public.session_reset_logs for select
  to authenticated
  using (public.can_supervise_exam(exam_id) or public.owns_exam(exam_id));

drop policy if exists "session_reset_logs_insert_supervisor" on public.session_reset_logs;
create policy "session_reset_logs_insert_supervisor"
  on public.session_reset_logs for insert
  to authenticated
  with check (
    (public.can_supervise_exam(exam_id) or public.owns_exam(exam_id))
    and actor_id = auth.uid()
  );

drop policy if exists "attempt_review_logs_select_staff" on public.attempt_review_logs;
create policy "attempt_review_logs_select_staff"
  on public.attempt_review_logs for select
  to authenticated
  using (public.can_supervise_exam(exam_id) or public.owns_exam(exam_id));

drop policy if exists "question_grades_select_staff" on public.question_grades;
create policy "question_grades_select_staff"
  on public.question_grades for select
  to authenticated
  using (
    public.is_staff()
    and (
      not public.is_supervisor_only()
      or exists (
        select 1 from public.exam_submissions s
        where s.id = submission_id and public.can_supervise_exam(s.exam_id)
      )
    )
  );

-- `questions_public` is a definer VIEW rather than a policy, so it is rebuilt
-- from its own DDL (a view cannot be `alter`ed into a new predicate), together
-- with the grants and revokes that follow it. Its supervisor arm is the same
-- `can_supervise_exam(e.id)` the policies above ask.
drop view if exists public.questions_public;

create view public.questions_public as
  select q.id,
         q.exam_id,
         q.question_text,
         q.question_type,
         q.options,
         q.points,
         q.created_at
  from public.questions q
  join public.exams e on e.id = q.exam_id
  left join public.exam_submissions s
         on s.exam_id = e.id
        and s.student_id = auth.uid()
  where public.can_supervise_exam(e.id)
     or e.created_by = auth.uid()
     or (
       public.student_can_access_exam(e.id)
       and (e.starts_at is null or now() >= e.starts_at)
       and (e.ends_at   is null or now() <= e.ends_at)
     )
     or (
       s.status = 'ongoing'
       and s.started_at + make_interval(mins => e.duration_minutes) > now()
     );

alter view public.questions_public set (security_invoker = false);

comment on view public.questions_public is
  'Student-facing question feed: neither answer key; one row per audience - supervisor/admin, the paper''s author, a student the paper is offered to while its window is open, or the owner of an ongoing attempt until its deadline.';

grant select on public.questions_public to authenticated;

-- ... and now take the reader the view was never meant for out of it.
--
-- That grant is not what keeps the public key away: section 0's blanket
-- `grant all privileges on all tables` runs on *every* install of this file -
-- including a re-run over a database where this view already exists - and the
-- `alter default privileges` beside it re-applies the same privileges to
-- anything created later, so `anon` holds SELECT on this view (and on
-- `questions`, the table holding the answer keys) unless it is revoked here,
-- after both objects exist. A revoke, not a missing grant, is what makes the
-- reach deterministic no matter which order this file is applied in.
--
-- Both revokes stay BELOW the create for the same reason the view itself moved
-- below `exam_submissions`: a revoke can only name an object that exists, and
-- section 0's default privileges are what put the grant there in the first place.
--
-- Nothing in the app needs the feed with the anonymous key: every read of
-- it happens after sign-in (the student's own `questions_public` query runs with
-- their session, and staff access to `questions` uses their session), and the only anonymous
-- consumer was `.github/workflows/keep_alive.yml`, which pinged this view to
-- prove the schema was reachable - i.e. exactly the reach being removed here. It
-- pings `profiles` now, which answers 200 `[]` for `anon` because no policy
-- grants it a row: the schema proves itself without the answer key's table being
-- reachable at all.
revoke all on public.questions_public from anon;
revoke all on public.questions        from anon;

-- ---------------------------------------------------------------------
-- 4. THE RPCs THAT ACT ON SOMEBODY ELSE'S ATTEMPT
-- ---------------------------------------------------------------------
-- A SECURITY DEFINER function does not go through RLS, so its own tier check is
-- the only gate it has. The three readers and the one writer that acted on any
-- paper now act on the papers the caller may supervise.

create or replace function public.proctoring_coverage(p_submission_id uuid)
returns table (
  submission_id         uuid,
  student_id            uuid,
  exam_id               uuid,
  status                text,
  started_at            timestamptz,
  ended_at              timestamptz,
  beats                 int,
  expected_beats        int,
  coverage_ratio        numeric,
  first_beat_at         timestamptz,
  last_beat_at          timestamptz,
  longest_gap_seconds   int,
  silent_seconds        int,
  camera_down_beats     int,
  monitoring_down_beats int,
  risk_flag             boolean,
  reason                text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  -- The cadence the client is expected to keep (mobile ProctoringHeartbeatService).
  -- Expected beats are derived from the attempt's own length, so a 20-minute
  -- sitting is not judged against a 2-hour one.
  c_expected_interval constant numeric  := 15;
  -- Anything longer than this between two beats is a gap worth a human's time.
  c_gap_threshold     constant int      := 60;
  -- No verdict of any kind for the first stretch of an attempt.
  c_grace             constant interval := interval '90 seconds';

  v_sub      public.exam_submissions;
  v_now      timestamptz := now();
  v_end      timestamptz;
  v_window   numeric;
  v_beats    int;
  v_expected int;
  v_ratio    numeric;
  v_first    timestamptz;
  v_last     timestamptz;
  v_gap      int;
  v_head     int;
  v_tail     int;
  v_camera   int;
  v_monitor  int;
  v_silent   int;
  v_flag     boolean := false;
  v_reasons  text[]  := '{}';
begin
  select * into v_sub
  from public.exam_submissions s
  where s.id = p_submission_id;

  if not found then
    raise exception 'proctoring_coverage: no attempt with id %', p_submission_id
      using errcode = 'P0002';
  end if;

  -- SECURITY DEFINER, so the visibility rule the RLS policy on
  -- `proctor_heartbeats` would have applied has to be spelled out here. Same
  -- three audiences as `logs_select_own_or_supervisor`.
  if not (
    v_sub.student_id = auth.uid()
    or public.owns_exam(v_sub.exam_id)
    or public.can_supervise_exam(v_sub.exam_id)
  ) then
    raise exception 'proctoring_coverage: attempt % is not yours to read', p_submission_id
      using errcode = '42501';
  end if;

  v_end := coalesce(v_sub.submitted_at, v_now);

  select count(*),
         min(h.received_at),
         max(h.received_at),
         count(*) filter (where not h.camera_ok),
         count(*) filter (where not h.monitoring_ok)
    into v_beats, v_first, v_last, v_camera, v_monitor
  from public.proctor_heartbeats h
  where h.submission_id = p_submission_id;

  -- Longest silence *between* stored beats, then the two ends: the head gap
  -- (attempt started, nothing checked in yet) and the tail (client went quiet
  -- before the attempt closed). All three are the same fact - a stretch with no
  -- evidence of a running monitor - so the report keeps the largest.
  select coalesce(max(g.seconds), 0) into v_gap
  from (
    select extract(epoch from (h.received_at
             - lag(h.received_at) over (order by h.received_at)))::int as seconds
    from public.proctor_heartbeats h
    where h.submission_id = p_submission_id
  ) g
  where g.seconds is not null;

  v_head := greatest(0, extract(epoch from (coalesce(v_first, v_end) - v_sub.started_at))::int);
  v_tail := greatest(0, extract(epoch from (v_end - coalesce(v_last, v_sub.started_at)))::int);
  v_gap  := greatest(v_gap, v_head, v_tail);

  v_window   := greatest(0, extract(epoch from (v_end - v_sub.started_at)));
  v_expected := floor(v_window / c_expected_interval)::int + 1;
  v_ratio    := round(v_beats::numeric / greatest(v_expected, 1), 3);

  -- Silence *now* only means something while the attempt is live; a closed
  -- attempt's silence is already in the tail gap above.
  v_silent := case
    when v_sub.status = 'ongoing'
      then greatest(0, extract(epoch from (v_now - coalesce(v_last, v_sub.started_at)))::int)
    else 0
  end;

  if v_sub.status = 'ongoing' and v_now - v_sub.started_at < c_grace then
    -- Too early to say anything: reported as a row (so a console can still show
    -- "0 beats so far") but never as a gap.
    v_reasons := array_append(v_reasons, 'attempt just started - too early to judge');
  else
    if v_beats = 0 then
      v_flag := true;
      v_reasons := array_append(v_reasons,
        'the proctoring client never checked in - no evidence of monitoring for this attempt');
    end if;
    if v_gap > c_gap_threshold then
      v_flag := true;
      v_reasons := array_append(v_reasons,
        format('proctoring went quiet for %ss (longest, including the ends)', v_gap));
    end if;
    if v_camera > 0 then
      v_flag := true;
      v_reasons := array_append(v_reasons,
        format('the camera was not streaming on %s heartbeat(s)', v_camera));
    end if;
    if v_ratio < 0.5 then
      v_flag := true;
      v_reasons := array_append(v_reasons,
        format('only %s of ~%s expected heartbeats arrived', v_beats, v_expected));
    end if;
    if v_monitor > 0 and v_camera = 0 then
      -- Recorded, never flagged on its own: a beat with monitoring_ok = false and
      -- the camera up is the client admitting it was backgrounded, which the gap
      -- rules above will usually have caught anyway.
      v_reasons := array_append(v_reasons,
        format('%s heartbeat(s) reported monitoring inactive', v_monitor));
    end if;
    if v_flag then
      v_reasons := array_append(v_reasons,
        'flag for human review only - a gap can be a dropped network or a broken webcam; coverage never disqualifies an attempt');
    elsif v_reasons = '{}' then
      v_reasons := array_append(v_reasons,
        format('%s heartbeats, largest gap %ss - proctoring was running throughout', v_beats, v_gap));
    end if;
  end if;

  return query select
    v_sub.id, v_sub.student_id, v_sub.exam_id, v_sub.status,
    v_sub.started_at,
    case when v_sub.submitted_at is null then null else v_end end,
    v_beats, v_expected, v_ratio, v_first, v_last,
    v_gap, v_silent, v_camera, v_monitor, v_flag,
    array_to_string(v_reasons, '; ');
end;
$$;

create or replace function public.proctoring_coverage_for_exam(p_exam_id uuid)
returns setof record
language sql
security invoker
set search_path = public, pg_temp
as $$
  select c.*
  from public.exam_submissions s
  cross join lateral public.proctoring_coverage(s.id) c
  where s.exam_id = p_exam_id
    and (
      s.student_id = auth.uid()
      or public.owns_exam(s.exam_id)
      or public.can_supervise_exam(s.exam_id)
    )
  order by c.risk_flag desc, c.last_beat_at nulls first;
$$;

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
  -- the same second must produce one decision and one audit row, not two that
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
  if not (public.can_supervise_exam(v_exam) or public.owns_exam(v_exam)) then
    raise exception 'only a supervisor, or the lecturer who wrote this paper, may resolve a flagged attempt'
      using errcode = '42501';
  end if;

  if v_status = 'ongoing' then
    raise exception 'submission % is still in progress: there is nothing to review', p_submission_id
      using errcode = '55000';
  end if;

  if v_status <> 'flagged_for_review' then
    -- Already decided (or never flagged): report the stored outcome and write
    -- nothing, so a client that lost the response can replay the call without a
    -- second audit row appearing.
    return query select v_status;
    return;
  end if;

  if p_decision = 'disqualify' then
    v_to := 'disqualified';
    v_score := null;
  else
    v_to := 'submitted';
    -- The automatic part of the mark, exactly as submit_exam() computes it, so
    -- "clear" lands the attempt in the state a normal hand-in would.
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
    -- Capped like every other free-text field here, and blank becomes NULL so "no
    -- note" has one shape.
    nullif(btrim(left(coalesce(p_note, ''), 2000)), '')
  );

  return query select v_to;
end;
$$;

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

  if v_student <> auth.uid() and not public.can_supervise_exam(v_exam) then
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
  -- `attempt_deadline()` is the attempt's own duration capped by the paper's
  -- close, so a late arrival inside a scheduled window records the window's end.
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

-- ---------------------------------------------------------------------
-- 5. VERIFY
-- ---------------------------------------------------------------------
-- Raises rather than reporting success on a project where the table, a predicate or
-- one of the rewrites did not land. Every statement above is `if not exists` or
-- `create or replace`, so a half-applied file would otherwise look clean - and the
-- one drift this file exists to remove (a policy still asking the *tier* question
-- about a row whose paper is known) is exactly what the `pg_policies` scan catches.
do $$
declare
  v_left  text;
  v_count int;
begin
  if to_regclass('public.supervisor_exam_assignments') is null then
    raise exception 'FAIL: public.supervisor_exam_assignments does not exist';
  end if;

  if not exists (
    select 1 from pg_trigger
     where tgname = 'guard_supervisor_assignment'
       and tgrelid = 'public.supervisor_exam_assignments'::regclass
  ) then
    raise exception 'FAIL: guard_supervisor_assignment is not on the table';
  end if;

  select count(*) into v_count
  from pg_proc
  where pronamespace = 'public'::regnamespace
    and proname in ('is_supervisor_only', 'can_supervise_exam');
  if v_count <> 2 then
    raise exception 'FAIL: the two predicates were not installed (found %)', v_count;
  end if;

  -- No policy may still ask the tier question: every table below can name the paper
  -- its row belongs to, so the tier answer there is the hole this file closes.
  select string_agg(format('%s.%s', p.schemaname, p.policyname), ', ' order by p.policyname)
    into v_left
  from pg_policies p
  where (p.schemaname = 'public'
         or (p.schemaname = 'storage' and p.tablename = 'objects'))
    and (coalesce(p.qual, '') || coalesce(p.with_check, '')) like '%is_exam_supervisor%';
  if v_left is not null then
    raise exception 'FAIL: still asking is_exam_supervisor() where the paper is known: %', v_left;
  end if;

  select count(*) into v_count
  from pg_policies p
  where (p.schemaname = 'public'
         or (p.schemaname = 'storage' and p.tablename = 'objects'))
    and (coalesce(p.qual, '') || coalesce(p.with_check, '')) like '%can_supervise_exam%';
  if v_count < 14 then
    raise exception 'FAIL: only % policies ask can_supervise_exam(), expected at least 14', v_count;
  end if;

  -- The definer view is not a policy, so it gets its own look: a project that kept
  -- the old view would still serve an unassigned supervisor the questions of any
  -- paper, which is the read this file removes.
  if pg_get_viewdef('public.questions_public'::regclass, true)
       not like '%can_supervise_exam%' then
    raise exception 'FAIL: questions_public still asks the tier question';
  end if;

  raise notice 'supervisor scope installed: % policies and the question feed ask can_supervise_exam()', v_count;
end $$;
