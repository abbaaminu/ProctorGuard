-- =====================================================================
-- PROCTORGUARD - THE SNAPSHOT PURGE MAY ONLY TOUCH A FINISHED RESET
-- Replaces `Proctor snapshots supervisor purge` so an object is deletable only
-- when its folder no longer resolves to a submission row, on top of the reset
-- tier the policy already asked for.
--
-- WHY THIS FILE EXISTS
--   `is_attempt_resetter()` is admin, supervisor **and every lecturer**, so the
--   purge policy let any lecturer delete any snapshot object in the bucket - while
--   the attempt it belonged to was still running. That is a straight evidence
--   wipe with no trace of it:
--     * no attempt row is deleted, so `session_reset_logs` records nothing;
--     * the "Reset attempt" control the console offers a lecturer is scoped to
--       their own paper (`submissions_delete_supervisor`, `20261103090600`), but
--       the Storage call behind it never was - the object could be removed without
--       the delete that is supposed to come first;
--     * a still is the only artefact a supervisor or an appeal actually looks at,
--       and a live sitting is exactly when it matters.
--   `20261103090600` narrowed the *delete* of an attempt to
--   `is_exam_supervisor() or owns_exam(exam_id)`. The purge was left on the wider
--   predicate on purpose - it has to run after the row is gone, when folder-based
--   ownership no longer resolves - but nothing tied it to that order. This file
--   ties it: the folder must NOT resolve to a submission.
--
-- THE NEW PREDICATE (three terms, all required)
--   1. `bucket_id = 'proctor-snapshots'` - unchanged; no other bucket is in reach.
--   2. `public.is_attempt_resetter()` - unchanged; the tier that resets attempts.
--   3. `not exists (select 1 from public.exam_submissions s
--                  where s.id::text = (storage.foldername(name))[1])`
--      - the folder's first segment is not a live submission id. The same
--      `storage.foldername(name))[1]` expression the read and upload policies use,
--      so all three agree on what "this attempt's folder" means.
--   With (3) alone the policy would be a hole - any signed-in account could delete
--   the orphaned stills of a finished reset - so (2) stays beside it.
--
--   The subquery runs under the caller's own permissions (`storage.objects` policy
--   expressions are not definer rights), so it is read as staff: term (2) names
--   admin, supervisor and lecturer, every one of them is `is_staff()`, and
--   `submissions_select_own_or_supervisor` lets staff read every attempt. The
--   `not exists` therefore sees the whole table rather than an RLS-empty view of it.
--   A role that could reset attempts but could not read `exam_submissions` would
--   make term (3) vacuously true, so the two tiers have to stay paired.
--
-- THE ORDER IT REQUIRES, AND WHO ALREADY DOES IT
--   `DashboardRepositoryImpl.resetSubmission()` in
--   `mobile/lib/features/dashboard/data/repositories/dashboard_repository_impl.dart`
--   (1) reads the paths off `proctoring_logs`, (2) deletes the `exam_submissions`
--   row with `.select(...)` and stops if nothing came back, and only then
--   (3) calls `storage.from('proctor-snapshots').remove(paths)`. Purge therefore
--   always runs with the row already gone, which is the state term 3 requires.
--   Any other caller must do the same: delete the attempt first, purge second. A
--   purge attempted first now removes zero objects instead of somebody's evidence
--   (Storage refuses silently, exactly as RLS does elsewhere in this schema).
--
-- WHAT IT DELIBERATELY DOES NOT DO
--   * No change to the read policy (`Proctor snapshots read access`) or the upload
--     policy (`Proctor snapshots upload own ongoing session`).
--   * No change to `submissions_delete_supervisor` or to `is_attempt_resetter()`.
--   * No object, path or row is rewritten - this is a policy replacement only.
--
-- SAFETY
--   * Safe to re-run: `drop policy if exists` + `create policy`.
--   * Pure narrowing, and the only flow that exists in the app already satisfies
--     it. The behaviour that disappears is "delete a live sitting's evidence", which
--     no legitimate path performs.
--   * PREREQUISITES: `public.is_attempt_resetter()` (`schema.sql` section 1 or
--     `staff_attempt_resets.sql`), `public.exam_submissions` (`schema.sql` section
--     4), the private `proctor-snapshots` bucket and its policies
--     (`private_proctor_snapshots.sql`).
--   * APPLY ORDER: after `20261103090700_register_violation_snapshot_path.sql`
--     (the write half of the same trail: the path regex there is what makes a
--     stored `snapshot_url` a nameable object) and after
--     `20261103090600_submissions_delete_supervisor.sql`. Also after
--     `private_proctor_snapshots.sql`, which creates the policy this replaces.
--   * DO NOT RE-RUN `private_proctor_snapshots.sql` (or
--     `staff_attempt_resets.sql`, or `secure_exam_access_and_deadlines.sql`)
--     AFTER this file: each of them recreates this policy at the old two-term
--     predicate and would put the hole straight back. Re-apply this file after any
--     of them. `schema.sql` carries the same three-term policy, so a fresh install
--     never needs this file at all.
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/20261103090800_snapshot_purge_not_live_attempt.sql
--   * Verify (expect the `not exists` arm next to `is_attempt_resetter()`):
--       select polname, pg_get_expr(polqual, polrelid) as using_expr
--         from pg_policy
--        where polrelid = 'storage.objects'::regclass
--          and polname = 'Proctor snapshots supervisor purge';
-- =====================================================================

drop policy if exists "Proctor snapshots supervisor purge" on storage.objects;

create policy "Proctor snapshots supervisor purge"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'proctor-snapshots'
    and public.is_attempt_resetter()
    and not exists (
      select 1 from public.exam_submissions s
      where s.id::text = (storage.foldername(name))[1]
    )
  );

-- A DELETE that has a WHERE clause (which is what `storage.remove()` issues) must
-- also pass the table's SELECT policies: Postgres only lets a statement delete rows
-- it is allowed to see. The read policy above admits a lecturer only through an
-- attempt row, and the purge runs exactly when that row is gone, so without this
-- companion the purge matched 0 rows for a lecturer and left the stills behind.
-- Same predicate as the purge policy, on SELECT; it exposes only already-orphaned
-- objects, to the tier that is about to delete them.
drop policy if exists "Proctor snapshots orphan read for purge" on storage.objects;
create policy "Proctor snapshots orphan read for purge"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'proctor-snapshots'
    and public.is_attempt_resetter()
    and not exists (
      select 1 from public.exam_submissions s
      where s.id::text = (storage.foldername(name))[1]
    )
  );