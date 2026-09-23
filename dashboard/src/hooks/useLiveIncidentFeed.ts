import { useEffect, useRef, useState } from "react";
import { supabase } from "@/lib/supabase";
import type { ProctoringLogRow } from "@/types/database";

/// Subscribes to new `proctoring_logs` rows as they're inserted, optionally
/// scoped to a set of submission IDs (e.g. all submissions for one exam).
/// Keeps the most recent `limit` entries, newest first.
export function useLiveIncidentFeed(submissionIds: string[] | null, limit = 100) {
  const [logs, setLogs] = useState<ProctoringLogRow[]>([]);
  const idsRef = useRef(submissionIds);
  idsRef.current = submissionIds;

  useEffect(() => {
    // Seed with recent history so the feed isn't empty on first paint.
    (async () => {
      let query = supabase
        .from("proctoring_logs")
        .select("*")
        .order("timestamp", { ascending: false })
        .limit(limit);
      if (submissionIds && submissionIds.length > 0) {
        query = query.in("submission_id", submissionIds);
      }
      const { data } = await query;
      if (data) setLogs(data as ProctoringLogRow[]);
    })();

    const channel = supabase
      .channel("proctoring_logs_inserts")
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "proctoring_logs" },
        (payload) => {
          const row = payload.new as ProctoringLogRow;
          const scope = idsRef.current;
          if (scope && scope.length > 0 && !scope.includes(row.submission_id)) return;
          setLogs((prev) => [row, ...prev].slice(0, limit));
        }
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
    // Re-subscribing per submissionIds change would drop the buffered feed;
    // filtering happens client-side in the callback via idsRef instead.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [limit]);

  return logs;
}
