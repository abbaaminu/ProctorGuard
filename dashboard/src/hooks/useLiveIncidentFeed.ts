import { useEffect, useRef, useState } from "react";
import { supabase } from "@/lib/supabase";
import type { ProctoringLogRow } from "@/types/database";

/// Subscribes to `proctoring_logs` as they're written *and* deleted, optionally
/// scoped to a set of submission IDs (e.g. all submissions for one exam).
/// Keeps the most recent `limit` entries, newest first.
///
/// Deletes matter since a supervisor can clear a whole attempt ("Reset
/// attempt"): the FK cascade takes that attempt's rows, and a feed still showing
/// incidents for a submission that no longer exists would be evidence for an
/// exam nobody can open any more.
///
/// The hook owns its own loading flag: the panel that renders it shows skeleton
/// rows until the seed query resolves, instead of briefly claiming "no incidents
/// reported yet" while the data is still in flight.
export function useLiveIncidentFeed(submissionIds: string[] | null, limit = 100) {
  const [logs, setLogs] = useState<ProctoringLogRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const idsRef = useRef(submissionIds);
  idsRef.current = submissionIds;

  useEffect(() => {
    let active = true;

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
      // A failed seed read used to be indistinguishable from "nothing has
      // happened yet" — the panel simply said "No incidents reported yet." The
      // message is now returned so the monitor can render it, which is the same
      // contract the roster and the dashboard already follow ("empty is not an
      // error").
      const { data, error: seedError } = await query;
      if (!active) return;
      if (seedError) {
        setError(seedError.message);
        setLoading(false);
        return;
      }
      setError(null);
      setLogs((data as ProctoringLogRow[]) ?? []);
      setLoading(false);
    })();

    const channel = supabase
      .channel("proctoring_logs_feed")
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
      .on(
        "postgres_changes",
        { event: "DELETE", schema: "public", table: "proctoring_logs" },
        (payload) => {
          // A DELETE payload carries only the primary key - there is no row left
          // to send, and row security cannot be re-evaluated against it - which
          // is all this needs: drop it from the buffer.
          const removedId = (payload.old as { id?: string } | null)?.id;
          if (!removedId) return;
          setLogs((prev) => prev.filter((log) => log.id !== removedId));
        }
      )
      .subscribe();

    return () => {
      active = false;
      supabase.removeChannel(channel);
    };
    // Re-subscribing per submissionIds change would drop the buffered feed;
    // filtering happens client-side in the callback via idsRef instead.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [limit]);

  return { logs, loading, error };
}
