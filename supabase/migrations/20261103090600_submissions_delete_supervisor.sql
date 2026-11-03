-- =====================================================================
-- PROCTORGUARD - DELETING AN ATTEMPT: THE TIER THAT ACTS, OR THE AUTHOR
-- Replaces `submissions_delete_supervisor` so that "Reset attempt" is scoped to
-- the institution's intervention tier and to the lecturer who wrote the paper.
--
-- WHY THIS FILE EXISTS
--   The policy was `using (public.is_attempt_resetter())`, and that predicate is
--   admin, supervisor **and every lecturer**. Any lecturer could delete any
--   student's attempt on any paper in the institution: the score, the stored
--   answers, the roster card, and - through `proctoring_logs.submission_id`'s
--   `on delete cascade` - every incident row that attempt had accumulated, which
--   the console client then follows by purging the snapshot objects. That is the
--   destructive half of the review's finding (c), and it needs no forged claim: a
--   plain lecturer account is enough.
--   Resetting is a repair. The person who needs it is the author who discovers the
--   answer key was wrong or the wrong candidate was disqualified - and that person
--   is exactly `owns_exam(exam_id)`, not "anybody employed".
--
-- WHAT CHANGES
--   * `public.is_exam_supervisor()` - admin and supervisor: unchanged, they act on
--     every sitting.
--   * `public.owns_exam(exam_id)` - the author of *that* paper.
--   * A lecturer who did not write the paper: refused.
--   * A student: still refused, as before. A student who could delete their own
--     attempt could erase a graded attempt - and the evidence behind a
--     disqualification - and simply start again.
--
-- WHAT IT DELIBERATELY DOES NOT DO
--   * It does not touch the storage purge policy (`Proctor snapshots supervisor
--     purge`) or the reset audit insert policy. Both still ask
--     `is_attempt_resetter()`, by requirement - so the *sequence*
--     delete -> purge -> audit keeps the tier it had, and only its first step is
--     narrowed here. The consequence is deliberate and is why item 9 of the client
--     work exists: a non-owning lecturer's delete removes zero rows, and the client
--     must read that zero and stop before purging objects or writing an audit row
--     that claims something happened. The atomic version of that sequence - one RPC
--     that checks ownership, deletes, writes the audit row and returns the paths -
--     is proposed in RESET_ATTEMPT_RPC_PROPOSAL.md and not implemented here.
--   * It does not widen the UPDATE tier: `submissions_update_supervisor` still asks
--     `is_exam_supervisor()`, so a lecturer still cannot rewrite a row in place.
--     Being allowed to clear an attempt is not being allowed to edit one.
--   * No `role` test: ownership is the question, and `owns_exam()` answers it from
--     `exams.created_by` whether the caller is a lecturer or an administrator.
--
-- SAFETY
--   * Safe to re-run: `drop policy if exists` + `create policy`.
--   * Pure narrowing: administrators and supervisors keep the reach they had, and
--     a lecturer keeps it for their own papers. The only behaviour that disappears
--     is a lecturer resetting somebody else's paper - which the client never
--     offered them a control for (the console scopes every paper list to
--     `created_by = auth.uid()`), so no working in-app path is lost.
--   * PREREQUISITES: `public.is_exam_supervisor()`, `public.owns_exam(uuid)`,
--     `public.exam_submissions`.
--   * APPLY ORDER: after `20261103090200_exams_select.sql`; independent of the
--     snapshot read policy, but the two are the pair the review's finding (c)
--     names, so apply both before the tests.
--   * `mobile/lib/features/auth/domain/entities/user_profile.dart`
--     (`UserRole.canResetAttempts`) and the sentence in schema.sql §1 that
--     `schema_contract_test.dart` pins both describe this tier as "any lecturer";
--     they have to be re-stated as "the lecturer who owns that paper", which the
--     client now also enforces per row (item 9).
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/20261103090600_submissions_delete_supervisor.sql
--   * Verify (expect is_exam_supervisor() and owns_exam(), and no
--     is_attempt_resetter()):
--       select polname, pg_get_expr(polqual, polrelid)
--         from pg_policy
--        where polrelid = 'public.exam_submissions'::regclass
--          and polname = 'submissions_delete_supervisor';
-- =====================================================================

drop policy if exists "submissions_delete_supervisor" on public.exam_submissions;

create policy "submissions_delete_supervisor"
  on public.exam_submissions for delete
  to authenticated
  using (
    public.is_exam_supervisor()
    or public.owns_exam(exam_id)
  );
