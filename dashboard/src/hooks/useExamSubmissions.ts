import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import type { SubmissionRow } from "@/types/database";

export function useExamSubmissions(examId: string) {
  const [submissions, setSubmissions] = useState<SubmissionRow[]>([]);

  useEffect(() => {
    let active = true;

    (async () => {
      const { data } = await supabase
        .from("exam_submissions")
        .select("*")
        .eq("exam_id", examId)
        .order("started_at");
      if (active && data) setSubmissions(data as SubmissionRow[]);
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

  async function disqualify(submissionId: string) {
    await supabase
      .from("exam_submissions")
      .update({ status: "disqualified", submitted_at: new Date().toISOString() })
      .eq("id", submissionId);
  }

  return { submissions, disqualify };
}
