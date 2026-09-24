import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import type { SubmissionRow } from "@/types/database";

/**
 * One exam's roster, live.
 *
 * Errors used to be swallowed (`const { data } = await ...`), which made a
 * failed read indistinguishable from an exam nobody has started — so the load
 * error is now returned and the monitor renders it.
 */
export function useExamSubmissions(examId: string) {
  const [submissions, setSubmissions] = useState<SubmissionRow[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!examId) return;
    let active = true;

    (async () => {
      const { data, error: loadError } = await supabase
        .from("exam_submissions")
        .select("*")
        .eq("exam_id", examId)
        .order("started_at");
      if (!active) return;
      if (loadError) {
        setError(loadError.message);
        return;
      }
      setError(null);
      setSubmissions((data as SubmissionRow[]) ?? []);
    })();

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
      active = false;
      supabase.removeChannel(channel);
    };
  }, [examId]);

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

  return { submissions, error, disqualify };
}

