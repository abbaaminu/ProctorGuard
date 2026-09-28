import { useCallback, useEffect, useRef, useState } from "react";
import { supabase } from "@/lib/supabase";
import type { SubmissionRow } from "@/types/database";

/**
 * One exam's roster, live: the initial read, realtime patches on top of it, and
 * an explicit `reload()` for a write the console already knows about (a reset).
 *
 * Errors used to be swallowed (`const { data } = await ...`), which made a
 * failed read indistinguishable from an exam nobody has started — so the load
 * error is now returned and the monitor renders it.
 */
export function useExamSubmissions(examId: string) {
  const [submissions, setSubmissions] = useState<SubmissionRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  /** Bumped by `reload()` to re-run the read below; the channel is left alone. */
  const [reloadToken, setReloadToken] = useState(0);
  /**
   * Which exam the cards on screen belong to.
   *
   * A re-read of the *same* exam keeps them up (only a changed exam shows the
   * skeleton again), so a reset that calls `reload()` does not blank a live
   * supervisor's roster for a round trip.
   */
  const loadedExamRef = useRef<string | null>(null);

  useEffect(() => {
    if (!examId) {
      // No id to query: stop the skeleton rather than pulsing forever.
      setLoading(false);
      return;
    }
    let active = true;
    // A failed first read leaves this null, so a retry still shows the skeleton.
    if (loadedExamRef.current !== examId) setLoading(true);

    (async () => {
      const { data, error: loadError } = await supabase
        .from("exam_submissions")
        .select("*")
        .eq("exam_id", examId)
        .order("started_at");
      if (!active) return;
      if (loadError) {
        setError(loadError.message);
        setLoading(false);
        return;
      }
      setError(null);
      setSubmissions((data as SubmissionRow[]) ?? []);
      loadedExamRef.current = examId;
      setLoading(false);
    })();

    return () => {
      active = false;
    };
  }, [examId, reloadToken]);

  /**
   * Realtime is deliberately its own effect: a `reload()` must not tear the
   * channel down and up again, or it would drop the events buffered in between —
   * the same reason the incident feed filters client-side instead of
   * re-subscribing on every roster change.
   */
  useEffect(() => {
    if (!examId) return;

    const channel = supabase
      .channel(`exam_submissions_${examId}`)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "exam_submissions", filter: `exam_id=eq.${examId}` },
        (payload) => {
          setSubmissions((prev) => {
            if (payload.eventType === "INSERT") {
              return [...prev, payload.new as SubmissionRow];
            }
            if (payload.eventType === "UPDATE") {
              return prev.map((s) => (s.id === payload.new.id ? (payload.new as SubmissionRow) : s));
            }
            if (payload.eventType === "DELETE") {
              return prev.filter((s) => s.id !== (payload.old as SubmissionRow).id);
            }
            return prev;
          });
        }
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, [examId]);

  /**
   * Re-read the roster now.
   *
   * Called after a write the console knows changed a row (a reset attempt) so
   * the list is right immediately, instead of depending on a realtime DELETE
   * that the `exam_id` filter may never deliver.
   */
  const reload = useCallback(() => setReloadToken((token) => token + 1), []);

  /**
   * Supervisor intervention: close an ongoing attempt as disqualified.
   *
   * Returns false instead of throwing so the caller can say *why* nothing
   * happened — the update is rejected by RLS for an exam the caller does not
   * own, and that failure used to be invisible (the row simply kept its old
   * status). `status = 'ongoing'` keeps a double click from re-stamping an
   * attempt that was already closed.
   */
  async function disqualify(submissionId: string): Promise<boolean> {
    const { error: updateError } = await supabase
      .from("exam_submissions")
      .update({ status: "disqualified", submitted_at: new Date().toISOString() })
      .eq("id", submissionId)
      .eq("status", "ongoing");
    if (updateError) {
      console.error("Could not disqualify submission", submissionId, updateError);
      return false;
    }
    return true;
  }

  return { submissions, loading, error, disqualify, reload };
}

