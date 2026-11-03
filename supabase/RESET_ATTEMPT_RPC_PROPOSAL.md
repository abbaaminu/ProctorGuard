# Proposal — `reset_attempt()`, one RPC for the whole reset

**Status:** proposed, **not implemented**. No SQL in this change adds it.
**Supersedes nothing.** The policies in `schema.sql` §4/§6/§7 keep working as they are.

## The gap it closes

"Reset attempt" is three separate calls from the console, in this order:

| # | Call | Authorised by |
|---|------|---------------|
| 1 | `delete from exam_submissions where id = …` | `submissions_delete_supervisor` (`is_exam_supervisor() or owns_exam(exam_id)`) |
| 2 | `storage.from('proctor-snapshots').remove(paths)` | `Proctor snapshots supervisor purge` (`is_attempt_resetter()`) |
| 3 | `insert into session_reset_logs …` | `session_reset_logs_insert_supervisor` (`is_attempt_resetter()`) |

Step 1 is ownership-scoped (the hardened rule). Steps 2 and 3 are not, by design: they
must keep working for the caller step 1 has just allowed, and a lecturer's legitimate
reset has to purge its own evidence and record itself.

That leaves three seams a client can drive on its own:

* **A reset that half-happens.** If the app dies between 1 and 2, the attempt is gone
  and its images are not: `proctoring_logs` cascaded, so nothing names those objects
  any more, and only a manual sweep can find them.
* **A purge without a delete.** A caller refused by step 1 (`42501`, or zero rows) can
  still call steps 2 and 3 directly, because `is_attempt_resetter()` does not ask
  whether that attempt was theirs. The console does not do this — `resetSubmission()`
  checks the `.delete().select(...)` result and stops — but the permission does.
* **An audit row that describes a delete that did not happen.** Same shape as above:
  the insert policy cannot see whether a row was removed.

The client-side guard is a good guard. It is not an authorisation boundary: the
boundary is what the database enforces when a patched client calls the endpoints
itself.

## The proposed function

```sql
create or replace function public.reset_attempt(p_submission_id uuid)
returns table (
  deleted        boolean,
  incidents      int,
  snapshot_paths text[]
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exam_id  uuid;
  v_student  uuid;
  v_paths    text[];
  v_logs     int;
begin
  if auth.uid() is null then
    raise exception 'authentication is required to reset an attempt'
      using errcode = '42501';
  end if;

  -- Ownership first, and with the row locked: the delete below must act on the row
  -- this check approved.
  select s.exam_id, s.student_id
    into v_exam_id, v_student
  from public.exam_submissions s
  where s.id = p_submission_id
  for update;

  if v_exam_id is null then
    return query select false, 0, '{}'::text[];   -- already gone: not an error
  end if;

  if not (public.is_exam_supervisor() or public.owns_exam(v_exam_id)) then
    raise exception 'this attempt is not yours to reset'
      using errcode = '42501',
            hint = 'only an administrator, a supervisor, or the author of the paper may reset it';
  end if;

  -- Evidence paths are read *before* the cascade removes the rows that name them.
  select coalesce(array_agg(sl.snapshot_url), '{}'::text[]), count(*)
    into v_paths, v_logs
  from public.proctoring_logs sl
  where sl.submission_id = p_submission_id
    and sl.snapshot_url is not null;

  delete from public.exam_submissions where id = p_submission_id;

  insert into public.session_reset_logs
    (submission_id, student_id, exam_id, incidents, snapshots, storage_warning)
  values
    (p_submission_id, v_student, v_exam_id, v_logs, cardinality(v_paths), null);

  return query select true, v_logs, v_paths;
end;
$$;

revoke execute on function public.reset_attempt(uuid) from public, anon;
grant execute on function public.reset_attempt(uuid) to authenticated, service_role;
```

## What it does not do

* **It cannot delete the objects.** `storage.objects` rows are deletable from SQL, but
  the *bytes* live in the Storage backend; only the Storage API removes them. The
  function therefore returns `snapshot_paths` and the client still calls
  `storage.remove(...)`. What changes is that the path list comes from inside the same
  transaction as the delete, so it cannot be stale, forged, or read after the cascade
  has already destroyed it.
* **It does not touch the three existing policies**, so the console keeps working
  unchanged during the rollout (a new RPC on top of unchanged policies is additive).
  Once the client calls the RPC, `storage_warning` is written afterwards by the second,
  narrow update the console already performs — or the RPC can grow a
  `p_storage_warning text default null` parameter and be called twice (once to reset,
  once to annotate).
* **It does not change `is_attempt_resetter()`.** The purge policy still asks it; the
  function never depends on it, because the function has already checked ownership.

## Client change it enables

```dart
final row = await _client.rpc('reset_attempt', params: {'p_submission_id': submissionId});
// row: {deleted, incidents, snapshot_paths}
if (row['deleted'] == false) { /* nothing to do, report "already cleared" */ }
final paths = (row['snapshot_paths'] as List).cast<String>();
final removed = paths.isEmpty ? 0 : (await _client.storage.from(snapshotBucket).remove(paths)).length;
```

`resetSubmission()` keeps its current shape — including the `.delete().select()` check,
which stays as the fallback path for any client that has not moved to the RPC yet.

## Order of work, when it is approved

1. Apply this function as `supabase/migrations/<timestamp>_reset_attempt_rpc.sql`, plus
   the `schema.sql` §9 copy.
2. Extend `supabase/tests/targeting_check.sql` with a block asserting `42501` for a
   lecturer who does not own the paper, and `deleted = true` plus the path array for the
   author.
3. Switch `DashboardRepositoryImpl.resetSubmission()` to the RPC, keeping the existing
   warning plumbing for the Storage call.
4. Drop nothing: the three policies stay, because the function's `security definer`
   delete needs no policy relaxation and none is granted.

