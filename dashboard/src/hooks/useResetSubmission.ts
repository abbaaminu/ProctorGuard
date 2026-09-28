import { useCallback, useState } from "react";
import { supabase } from "@/lib/supabase";

/** Bucket the mobile app uploads violation stills to (see supabase/schema.sql §6). */
const SNAPSHOT_BUCKET = "proctor-snapshots";

export type ResetOutcome = {
  /** False means the attempt is *unchanged*; `error` says why. */
  ok: boolean;
  /** Incident rows the cascade took with the submission. */
  incidents: number;
  /** Snapshot objects removed from Storage afterwards. */
  snapshots: number;
  /** Why nothing was deleted (a refused delete, a failed evidence read). */
  error?: string;
  /**
   * The attempt *is* gone, but its stills are not. A partial reset is reported
   * rather than swallowed: an image left behind in a public bucket is exactly
   * the kind of leftover this feature exists to prevent.
   */
  storageWarning?: string;
};

/**
 * Object path of a stored snapshot, derived from the URL the mobile app wrote
 * onto the log row. Handles both shapes that can end up there - public
 * (`/object/public/<bucket>/<path>`) and signed (`/object/sign/<bucket>/<path>?token=…`)
 * - and returns null for a URL that is not ours (a hand-seeded placeholder, or a
 * host that no longer exists), which the caller then simply skips.
 */
function snapshotPath(url: string): string | null {
  const marker = `${SNAPSHOT_BUCKET}/`;
  const at = url.indexOf(marker);
  if (at === -1) return null;

  const path = url.slice(at + marker.length).split("?")[0];
  if (!path) return null;

  try {
    return decodeURIComponent(path);
  } catch {
    // A malformed escape is not worth failing the reset over: hand the raw path
    // to Storage, which will report the object as not found instead.
    return path;
  }
}

/**
 * Supervisor intervention: reset one attempt.
 *
 * "Reset" means *clear the attempt*, not "reopen the current one": the
 * submission row goes (answers, score, status and the unique
 * `(student_id, exam_id)` slot with it), the FK cascade takes that attempt's
 * proctoring log, and the snapshot objects those rows pointed at are purged from
 * Storage. Afterwards the student can start the exam again from scratch, which
 * is what a crashed laptop or a mis-assigned retake needs.
 *
 * Everything about the ordering here is deliberate:
 *
 *   1. The evidence is read *first*. The log rows disappear with the submission,
 *      and `snapshot_url` is the only record of which objects in the bucket
 *      belonged to this attempt - once the rows are gone the stills are
 *      unreachable, so they could never be cleaned up.
 *   2. The delete is the authoritative step and it asks for the deleted row back
 *      (`.select("id")`). A DELETE that RLS filters out is reported by PostgREST
 *      as *success* while matching zero rows, so an empty result has to be read
 *      as a failure; claiming success on it is the bug this console keeps
 *      fixing elsewhere.
 *   3. The Storage purge runs last and is best effort. The attempt is already
 *      cleared at that point, so a Storage failure is reported as a warning
 *      instead of being turned into a "the reset failed" that would be a lie -
 *      and instead of being dropped, which would leave an orphan behind.
 *
 * Deleting the `storage.objects` rows in SQL would not do: it removes the
 * metadata and leaves the blob in the backing store, so only the Storage API
 * actually reclaims the space.
 */
export function useResetSubmission() {
  const [resetting, setResetting] = useState(false);

  const resetSubmission = useCallback(async (submissionId: string): Promise<ResetOutcome> => {
    setResetting(true);
    try {
      const { data: logRows, error: readError } = await supabase
        .from("proctoring_logs")
        .select("snapshot_url")
        .eq("submission_id", submissionId);
      if (readError) {
        return { ok: false, incidents: 0, snapshots: 0, error: readError.message };
      }

      const paths = [
        ...new Set(
          (logRows ?? [])
            .map((row) => row.snapshot_url)
            .filter((url): url is string => typeof url === "string")
            .map(snapshotPath)
            .filter((path): path is string => path !== null)
        ),
      ];

      const { data: deleted, error: deleteError } = await supabase
        .from("exam_submissions")
        .delete()
        .eq("id", submissionId)
        .select("id");
      if (deleteError) {
        return { ok: false, incidents: 0, snapshots: 0, error: deleteError.message };
      }
      if (!deleted || deleted.length === 0) {
        return {
          ok: false,
          incidents: 0,
          snapshots: 0,
          error:
            "the server deleted nothing - the attempt may already be cleared, and you may not be a supervisor for this exam",
        };
      }

      const incidents = logRows?.length ?? 0;
      if (paths.length === 0) return { ok: true, incidents, snapshots: 0 };

      const { data: removed, error: storageError } = await supabase.storage
        .from(SNAPSHOT_BUCKET)
        .remove(paths);
      if (storageError) {
        console.error("Could not purge snapshots of reset submission", submissionId, storageError);
        return {
          ok: true,
          incidents,
          snapshots: 0,
          storageWarning: `${paths.length} snapshot image(s) could not be removed from Storage (${storageError.message})`,
        };
      }

      // `remove()` reports the objects it actually deleted, which is the honest
      // number to show: a path that was already gone is not counted.
      return { ok: true, incidents, snapshots: removed?.length ?? paths.length };
    } finally {
      setResetting(false);
    }
  }, []);

  return { resetSubmission, resetting };
}
