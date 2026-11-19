-- =====================================================================
-- PROCTORGUARD - ONE READ FOR THE EVIDENCE PAGE
-- =====================================================================
-- Adds public.exam_evidence(p_exam_id): every incident logged against one
-- paper, with the attempt and student it belongs to and the still's object path,
-- for the lecturer and administrator portals' Evidence screen.
--
-- WHY IT EXISTS
--   The stills already live somewhere nobody needs to widen: the private
--   proctor-snapshots bucket, one folder per attempt, and a read policy that
--   asks can_reach_exam() for the paper that folder's attempt was sat on
--   (20261103090500_snapshot_read_policy.sql as narrowed by
--   20261111090100_lecturer_isolation.sql). What is missing is not permission
--   but *enumeration*: a reviewer holds an attempt id only when a dashboard row
--   happens to show it, so 'what happened in this sitting' cannot be asked at
--   all. This function is that question.
--
-- WHY SECURITY INVOKER, WHICH IS THE WHOLE SAFETY ARGUMENT
--   It runs with the caller's own privileges, so row security on
--   proctoring_logs, exam_submissions and profiles still applies on top of the
--   predicate below - a bug in this file cannot hand out a row the policies
--   withhold. The explicit can_reach_exam(p_exam_id) term is the *scope*: it
--   answers for the lecturer who wrote the paper (owns_exam()), for an
--   administrator, and for a supervisor the administrator assigned to it. A null
--   paper answers nothing, so a caller that forgot the argument gets an empty
--   list rather than the whole table.
--
--   The narrower question - 'an administrator reads every paper' - is not
--   assumed here: can_reach_exam() asks can_supervise_exam(), which is
--   role = 'admin' with no assignment needed, and
--   supabase/tests/exam_evidence_check.sql proves the administrator's read on a
--   paper they did not write, next to a lecturer's empty answer on that same
--   paper.
--
-- WHAT IT RETURNS
--   One row per proctoring_logs row, per incident - not one per attempt - so a
--   reviewer can count what happened as well as look at it. weight and
--   counts_toward_dq come from violation_weights *as it stands now*, which is
--   what the incident counts as today; the strike arithmetic that actually ran
--   when the attempt closed is not replayed here (register_violation() and
--   exam_submissions already record its outcome). A missing weight row is read as
--   (1, true), the same default register_violation() uses, so a new action type
--   cannot look like a free pass on this screen either.
--
--   snapshot_url is the value stored on the row: this build's bucket-relative
--   path (<submission_id>/<action_type>_<epoch-ms>.jpg), or - on a row written
--   before the bucket went private - a public URL. The reader normalises both
--   shapes with snapshotObjectPath() and mints a short-lived signed URL per tile;
--   nothing here mints one, and no URL is stored in the returned row.
--
--   student_name is profiles.full_name, and it is NULL when the caller may not
--   read that profile (the roster policy is profiles_select_own_or_staff). The
--   screen falls back to a short form of student_id rather than showing a blank,
--   so a missing name is a display detail and not a failed read.
--
-- WHO MAY CALL IT
--   authenticated and service_role, after the revoke below. anon cannot execute
--   it at all - the anonymous key has no business reading evidence, and the
--   predicate it calls is itself closed to anon
--   (20261113090000_predicate_execute_hardening.sql). A *signed-in* student may
--   call it and gets no rows: can_reach_exam() is false for a student, which the
--   check file asserts for the student who sat the paper - the row is their own,
--   so that is the predicate answering, not a policy hiding it.
--
-- WHAT IT DOES NOT DO
--   * It does not sign, cache or serve an image; the client mints a signed URL
--     per tile and the bucket's policy decides each one.
--   * It does not write, and it does not record that a still was *viewed* -
--     there is no viewing audit. Who looked at which photograph is a separate
--     decision with its own retention question, and it is not taken here.
--   * It does not change any policy, weight, threshold or strike count.
--
-- VERIFIED BY
--   supabase/tests/exam_evidence_check.sql (ends in ROLLBACK): the lecturer reads
--   their own paper and nothing of a colleague's; an administrator reads both; a
--   student and an anonymous caller read nothing; a null paper returns nothing;
--   and the weight, name and snapshot columns carry what this comment says they
--   carry.

-- ---------------------------------------------------------------------
-- 1. The read
-- ---------------------------------------------------------------------
-- returns table (...) rather than the neighbouring setof record
-- (proctoring_coverage_for_exam): this one is called by the app through
-- PostgREST, which has to know the column names and types before the first row
-- arrives, and a record-returning function leaves it unable to answer.
create or replace function public.exam_evidence(p_exam_id uuid)
returns table (
  log_id             uuid,
  submission_id      uuid,
  student_id         uuid,
  student_name       text,
  action_type        text,
  weight             int,
  counts_toward_dq   boolean,
  logged_at          timestamptz,
  snapshot_url       text,
  attempt_status     text,
  attempt_started_at timestamptz
)
language sql
security invoker
stable
set search_path = public, pg_temp
as $$
  select
    l.id,
    l.submission_id,
    s.student_id,
    p.full_name,
    l.action_type,
    coalesce(w.weight, 1),
    coalesce(w.counts_toward_dq, true),
    l.timestamp,
    l.snapshot_url,
    s.status,
    s.started_at
  from public.proctoring_logs l
  join public.exam_submissions s on s.id = l.submission_id
  left join public.profiles p on p.id = s.student_id
  left join public.violation_weights w on w.action_type = l.action_type
  -- The null term is not decoration: s.exam_id = null is null and would filter
  -- every row anyway, but the predicate is written to answer 'nothing' for a null
  -- paper in one place rather than by accident of three-valued logic.
  where p_exam_id is not null
    and public.can_reach_exam(p_exam_id)
    and s.exam_id = p_exam_id
  -- Newest sitting first, and inside one sitting oldest incident first: a
  -- reviewer reads a sitting the way it happened.
  order by s.started_at desc, l.timestamp;
$$;

comment on function public.exam_evidence(uuid) is
  'Every incident logged against one paper, for the Evidence screen: one row per proctoring_logs row with its attempt, student and still path. SECURITY INVOKER, scoped by can_reach_exam(p_exam_id) - the lecturer who wrote the paper, an administrator, or a supervisor assigned to it - so row security still applies on top. Returns nothing for a null paper, and nothing for a student. It signs nothing: the client mints a short-lived URL per still through the bucket policy.';

revoke execute on function public.exam_evidence(uuid) from public, anon;
grant execute on function public.exam_evidence(uuid) to authenticated, service_role;


-- =====================================================================
-- 2. VERIFY
-- =====================================================================
-- Reads the catalogue back instead of reporting success because the file ran. A
-- drop function + re-create would reset the ACL to the default (EXECUTE to
-- PUBLIC) and quietly re-open the endpoint, so the grant is checked rather than
-- assumed - the same reasoning as 20261113090000_predicate_execute_hardening.sql.
do $$
declare
  v_oid     oid := to_regprocedure('public.exam_evidence(uuid)');
  v_definer boolean;
  v_config  text[];
  v_public  boolean;
begin
  if v_oid is null then
    raise exception 'FAIL: public.exam_evidence(uuid) was not created';
  end if;

  -- The guard 20261111090100_lecturer_isolation.sql installs. Creating this
  -- function on a project without it fails at create (the body is validated),
  -- but the message here names the file instead of leaving a bare 42883.
  if to_regprocedure('public.can_reach_exam(uuid)') is null then
    raise exception 'FAIL: public.can_reach_exam(uuid) does not exist - apply 20261111090100_lecturer_isolation.sql first, or this read is scoped by nothing';
  end if;

  select p.prosecdef, p.proconfig into v_definer, v_config
  from pg_proc p
  where p.oid = v_oid;

  if v_definer then
    raise exception 'FAIL: exam_evidence is SECURITY DEFINER - it must run with the caller''s privileges so row security still applies';
  end if;

  if not exists (
    select 1 from unnest(coalesce(v_config, array[]::text[])) as c
    where c like 'search_path=%'
  ) then
    raise exception 'FAIL: exam_evidence has no search_path set - a caller-supplied path could resolve a table it does not mean';
  end if;

  select exists (
    select 1
    from pg_proc p
    cross join lateral aclexplode(
      coalesce(p.proacl, acldefault('f', p.proowner))
    ) a
    where p.oid = v_oid
      and a.grantee = 0
      and a.privilege_type = 'EXECUTE'
  ) into v_public;

  if v_public then
    raise exception 'FAIL: exam_evidence is still executable by PUBLIC - the default ACL is in place (was the function dropped and re-created after this file ran?)';
  end if;

  if has_function_privilege('anon', v_oid, 'EXECUTE') then
    raise exception 'FAIL: anon can execute exam_evidence - the anonymous key may not read a student''s evidence';
  end if;

  if not has_function_privilege('authenticated', v_oid, 'EXECUTE') then
    raise exception 'FAIL: authenticated cannot execute exam_evidence - the Evidence screen answers 42501 for every account';
  end if;

  if not has_function_privilege('service_role', v_oid, 'EXECUTE') then
    raise exception 'FAIL: service_role cannot execute exam_evidence - the admin tooling reads through it';
  end if;

  raise notice 'PASS: exam_evidence is invoker-rights, search_path-pinned, executable by authenticated and service_role only, and scoped by can_reach_exam()';
end $$;
