-- =====================================================================
-- PROCTORGUARD - SNAPSHOTS: THE STUDENT, THE TIER THAT ACTS, THE AUTHOR
-- Replaces the `proctor-snapshots` SELECT policy so a lecturer can sign a URL for
-- the evidence of the papers they wrote, and not for anyone else's.
--
-- WHY THIS FILE EXISTS
--   The bucket is private and every read is a signed URL minted under the
--   caller's own JWT, which means signing a URL *is* a SELECT on
--   `storage.objects` - so this policy is the only thing standing between a still
--   and a colleague who did not write the paper. It ended in
--   `or public.is_staff()`, and `is_staff()` is everybody employed: any lecturer
--   could sign a ten-minute URL to a photograph of any student in any sitting, at
--   any time, for as long as the object existed. That is the same objection
--   `owns_exam()`'s docstring already makes about `proctoring_logs` - the roster
--   read tier and the *evidence* read tier are deliberately different questions -
--   applied to the evidence itself, except that here the evidence is a face.
--
-- THE NEW PREDICATE (three audiences, no more)
--   1. `public.is_exam_supervisor()` - admin or supervisor: the intervention tier,
--      whose job is every sitting in the institution.
--   2. The student whose submission the object belongs to: the folder name is the
--      submission id (`<submission_id>/<action_type>_<epoch-ms>.jpg`), so the same
--      submission-id-to-`auth.uid()` lookup the upload policy already uses
--      identifies the owner. They may review their own evidence after the sitting
--      as well as during it - this branch has no `status` test on purpose.
--   3. `public.owns_exam(s.exam_id)` - the lecturer who wrote the paper the
--      attempt belongs to, reached through `exam_submissions.exam_id` because that
--      is the row the object's folder resolves to.
--
-- WHAT IT DELIBERATELY DOES NOT DO
--   * The supervisor branch is *not* wrapped in the `exists`, so the intervention
--     tier can still read an object whose folder no longer resolves to a
--     submission - which is the state between the delete of an attempt and the
--     purge of its stills, and the state of any object orphaned by a failed purge.
--     Scoping it to a row would make evidence unreadable exactly while somebody is
--     trying to clean it up.
--   * No change to the upload policy (`Proctor snapshots upload own ongoing
--     session`): a student still writes only into their own ongoing attempt.
--   * No change to the purge policy (`Proctor snapshots supervisor purge`) or to
--     the reset audit policy, by requirement - the client-ordered delete/purge/
--     audit sequence is left exactly as it is, and the reset RPC that would make
--     it atomic is proposed in RESET_ATTEMPT_RPC_PROPOSAL.md rather than
--     implemented here. (A later file,
--     `20261103090800_snapshot_purge_not_live_attempt.sql`, does narrow that purge
--     - to the state in which the attempt row is already gone. This file leaves it
--     exactly as it found it.)
--   * No bucket change: the bucket stays private, and an expired URL stays dead.
--   * No `storage.foldername` change: the path shape is what existing rows already
--     carry, and `SupabaseService.snapshotObjectPath` normalises legacy full URLs
--     to the same shape before signing.
--
-- SAFETY
--   * Safe to re-run: `drop policy if exists` + `create policy`.
--   * Pure narrowing: the old rule was "owner or any staff member"; the new one is
--     "owner or admin/supervisor or the paper's author". Every caller who could
--     sign before still can if they are an administrator, a supervisor, the
--     student themselves, or the author of that paper.
--   * PREREQUISITES: `public.is_exam_supervisor()`, `public.owns_exam(uuid)`,
--     `public.exam_submissions`, and the private bucket + folder convention from
--     `private_proctor_snapshots.sql`.
--   * APPLY ORDER: after `private_proctor_snapshots.sql` (this replaces the policy
--     that file creates, so re-running that older file would undo this one) and
--     after `20261103090200_exams_select.sql`; independent of the questions files.
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/20261103090500_snapshot_read_policy.sql
--   * Verify (expect is_exam_supervisor() and owns_exam() and no is_staff()):
--       select polname, pg_get_expr(polqual, polrelid)
--         from pg_policy
--        where polrelid = 'storage.objects'::regclass
--          and polname = 'Proctor snapshots read access';
-- =====================================================================

drop policy if exists "Proctor snapshots read access" on storage.objects;

create policy "Proctor snapshots read access"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'proctor-snapshots'
    and (
      public.is_exam_supervisor()
      or exists (
        select 1 from public.exam_submissions s
        where s.id::text = (storage.foldername(name))[1]
          and (s.student_id = auth.uid() or public.owns_exam(s.exam_id))
      )
    )
  );
