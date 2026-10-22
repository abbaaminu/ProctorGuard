-- =====================================================================
-- PROCTORGUARD - PRIVATE EVIDENCE BUCKET (proctor-snapshots)
-- Flips the violation-snapshot bucket from PUBLIC to PRIVATE and keeps the
-- read/upload/purge policies that decide who may touch a still.
--
-- WHY
--   `proctor-snapshots` was created with `public = true` so the supervisor
--   console could render `proctoring_logs.snapshot_url` directly. That made every
--   snapshot a permanent, anonymous URL: anybody who ever saw one - forwarded in
--   a chat, pasted into a report, left in a log export, screenshotted in the
--   console - could fetch a photograph of a student's face, forever, with no
--   expiry and no way to revoke it short of deleting the object. The URL was not
--   guessable, but "not guessable" is not "not public", and the people who hold
--   those links are not the people the evidence is about.
--
-- WHAT CHANGES
--   * The bucket is private, so Storage serves nothing from it without a
--     signature. `createSignedUrl(path, ttl)` is the only read path, and it is
--     minted under the caller's own JWT - the SELECT policy below still decides
--     whether the owning student or staff may create that signature at all.
--   * The app now stores the bucket-relative *path*
--     (`<submission_id>/<action_type>_<epoch-ms>.jpg`) in
--     `proctoring_logs.snapshot_url` instead of a URL, and mints a 10-minute URL
--     when a still is actually displayed (`SupabaseService.signedSnapshotUrl`).
--     A path never expires; a URL always would have.
--   * Rows written before this migration still hold
--     `/storage/v1/object/public/proctor-snapshots/...` values. Their objects are
--     untouched - only their old URLs stop resolving - and both the app and the
--     console normalise the value back to an object path before signing or
--     purging it (`SupabaseService.snapshotObjectPath`), so existing evidence
--     stays reviewable and a reset still removes it.
--
--   This is the upgrade path for an installation that already has the bucket;
--   `schema.sql` section 6 carries the same state for fresh installs. Both are
--   idempotent - safe to re-run.
-- =====================================================================

-- 1. Private, with the same limits the bucket already had.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('proctor-snapshots', 'proctor-snapshots', false, 5242880, array['image/jpeg', 'image/png'])
on conflict (id) do update
  set public             = false,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- 2. Re-assert the policies. They key off `storage.objects.name`, which does not
--    change when a bucket goes private - an object keeps its path and only its
--    ACL changes - so an existing deployment keeps the existing rows valid.
drop policy if exists "Proctor snapshots read access" on storage.objects;
-- The name an earlier `schema.sql` used for the upload policy. Dropped here too, so
-- a project installed before the ownership/ongoing-session check cannot keep a
-- broader insert policy alongside the one this file creates.
drop policy if exists "Proctor snapshots upload access" on storage.objects;
drop policy if exists "Proctor snapshots upload own ongoing session" on storage.objects;
drop policy if exists "Proctor snapshots supervisor purge" on storage.objects;

-- Read (and therefore sign): the student who owns the submission, or any member
-- of staff. A private bucket serves nothing without this - and signing a URL is a
-- SELECT under the hood, so this is the row that decides who can view evidence.
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
      or public.is_staff()
    )
  );

-- Upload: a student may only write into the folder of their OWN submission, and
-- only while it is still 'ongoing' - the storage twin of the ownership check
-- inside register_violation().
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

-- No update policy: a stored snapshot is never rewritten.
--
-- Delete exists for exactly one action - the console's "Reset attempt", which
-- deletes the submission row first (cascading the incident rows) and then has to
-- drop the stills those rows pointed at. It cannot be anchored to the submission
-- folder because by then that folder no longer resolves to a submission row, so
-- it is scoped to the same tier that may delete an attempt at all
-- (`is_attempt_resetter()`).
create policy "Proctor snapshots supervisor purge"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'proctor-snapshots'
    and public.is_attempt_resetter()
  );
