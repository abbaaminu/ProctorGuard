import { useEffect, useMemo, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { AlertOctagon, Ban, Clock, FileText, Image as ImageIcon, X } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { useExamSubmissions } from "@/hooks/useExamSubmissions";
import { useLiveIncidentFeed } from "@/hooks/useLiveIncidentFeed";
import { useAccountNames } from "@/hooks/useAccountNames";
import {
  REALTIME_STATUS_COPY,
  useRealtimeStatus,
} from "@/hooks/useRealtimeStatus";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge, statusTone } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  CandidateCardSkeleton,
  FeedRowSkeleton,
  Skeleton,
} from "@/components/ui/skeleton";
import { cn, formatTime, shortId, timeElapsed } from "@/lib/utils";
import type { ExamRow, SubmissionRow } from "@/types/database";

const INCIDENT_LABELS: Record<string, string> = {
  looking_away: "Looking away",
  multiple_faces: "Multiple faces",
  no_face: "No face",
  app_minimized: "App minimized",
  audio_noise: "Audio noise",
};

function SnapshotModal({ url, onClose }: { url: string; onClose: () => void }) {
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 p-4" onClick={onClose}>
      <div className="max-w-lg rounded-lg border border-border bg-surface-raised p-2" onClick={(e) => e.stopPropagation()}>
        <div className="mb-2 flex justify-end">
          <button onClick={onClose} className="text-slate-400 hover:text-slate-200"><X size={18} /></button>
        </div>
        <img src={url} alt="Violation snapshot" className="max-h-[70vh] w-full rounded-md object-contain" />
      </div>
    </div>
  );
}

export function LiveMonitor() {
  const { id: examId } = useParams<{ id: string }>();
  const [exam, setExam] = useState<ExamRow | null>(null);
  const [snapshot, setSnapshot] = useState<string | null>(null);
  const [flash, setFlash] = useState(false);
  /** Action-level failure: a disqualify that the server refused, say. */
  const [actionError, setActionError] = useState<string | null>(null);

  // The header badge reports the actual socket state instead of a hardcoded
  // "Live sync active": Realtime only affects *streaming*, and the badge says so.
  const realtimeStatus = useRealtimeStatus();
  const badgeCopy = REALTIME_STATUS_COPY[realtimeStatus];

  const {
    submissions,
    loading: rosterLoading,
    error: rosterError,
    disqualify,
  } = useExamSubmissions(examId ?? "");
  const submissionIds = useMemo(() => submissions.map((s) => s.id), [submissions]);
  const { logs, loading: feedLoading } = useLiveIncidentFeed(
    submissionIds.length ? submissionIds : null
  );
  // `id -> name` so the roster and the feed read like a class list instead of a
  // wall of uuids (RLS lets a supervisor read every profile row).
  const { names, loading: namesLoading } = useAccountNames();

  useEffect(() => {
    if (!examId) return;
    supabase
      .from("exams")
      .select("*")
      .eq("id", examId)
      .single()
      .then(({ data }) => setExam(data));
  }, [examId]);

  // Visual ping when a new violation lands — flash the feed header briefly
  // rather than an intrusive toast, since supervisors watch this panel
  // continuously during a live session.
  useEffect(() => {
    if (logs.length === 0) return;
    setFlash(true);
    const t = setTimeout(() => setFlash(false), 500);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [logs[0]?.id]);

  const incidentCountBySubmission = useMemo(() => {
    const counts: Record<string, number> = {};
    logs.forEach((l) => { counts[l.submission_id] = (counts[l.submission_id] ?? 0) + 1; });
    return counts;
  }, [logs]);

  const labelFor = (studentId: string) => names[studentId] ?? `Student ${shortId(studentId)}`;

  /** submission id -> student id, for the feed rows (a log only knows its submission). */
  const studentBySubmission = useMemo(
    () => Object.fromEntries(submissions.map((s) => [s.id, s.student_id])),
    [submissions]
  );

  const feedLabel = (submissionId: string) => {
    const studentId = studentBySubmission[submissionId];
    return studentId ? labelFor(studentId) : shortId(submissionId);
  };

  /**
   * Closing an attempt is irreversible (the server never reopens one), so it
   * takes an explicit confirmation — and a refused write is reported instead of
   * leaving the supervisor wondering why nothing happened.
   */
  async function handleDisqualify(submission: SubmissionRow) {
    const label = labelFor(submission.student_id);
    if (!confirm(`Disqualify ${label}? The attempt is closed immediately and cannot be reopened.`)) {
      return;
    }

    setActionError(null);
    const ok = await disqualify(submission.id);
    if (!ok) {
      setActionError(
        `Could not disqualify ${label}. The attempt is unchanged — check that you are a supervisor for this exam.`
      );
    }
  }

  return (
    <div className="flex h-screen flex-col">
      <header className="flex h-14 shrink-0 items-center justify-between border-b border-border bg-surface-raised px-6">
        <div className="flex items-center gap-3">
          {exam ? (
            <>
              <h1 className="text-sm font-semibold text-slate-100">{exam.title}</h1>
              <span className="flex items-center gap-1 text-xs text-slate-500">
                <Clock size={12} /> {exam.duration_minutes} min
              </span>
            </>
          ) : (
            // The header never says "Loading exam…": it shows the shape of the
            // title and swaps in the real one when the row arrives.
            <Skeleton className="h-4 w-52" />
          )}
        </div>
        <div
          title={badgeCopy.hint}
          className={cn(
            "flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs",
            badgeCopy.badge
          )}
        >
          <span className={cn("h-1.5 w-1.5 rounded-full bg-current", status === "connected" && "animate-pulseDot")} />
          {badgeCopy.label}
        </div>
      </header>

      <div className="flex flex-1 overflow-hidden">
        {/* Left: candidate roster */}
        <div className="flex-1 overflow-y-auto p-5">
          <div className="mb-3 flex items-center gap-2 text-xs font-medium uppercase tracking-wide text-slate-500">
            <span>Candidates{rosterLoading ? "" : ` (${submissions.length})`}</span>
            {rosterLoading && <Skeleton className="h-3 w-6" />}
          </div>

          {rosterError && (
            <div className="mb-3 rounded-md border border-alert/30 bg-alert/10 px-3 py-2 text-sm text-alert">
              Could not load the roster: {rosterError}
            </div>
          )}
          {actionError && (
            <div className="mb-3 rounded-md border border-alert/30 bg-alert/10 px-3 py-2 text-sm text-alert">
              {actionError}
            </div>
          )}

          {rosterLoading ? (
            <div className="grid grid-cols-3 gap-3" role="status" aria-label="Loading candidates">
              {Array.from({ length: 3 }).map((_, index) => (
                <CandidateCardSkeleton key={index} />
              ))}
            </div>
          ) : submissions.length === 0 && !rosterError ? (
            <p className="text-sm text-slate-500">No student has started this exam yet.</p>
          ) : (
            <div className="grid grid-cols-3 gap-3">
              {submissions.map((s) => (
                <Card key={s.id} className={cn(s.status === "disqualified" && "border-alert/40")}>
                  <CardContent className="p-3.5">
                    <div className="mb-2 flex items-center justify-between gap-2">
                      {namesLoading ? (
                        <Skeleton className="h-4 w-28" />
                      ) : (
                        <span className="truncate text-sm font-medium text-slate-200">
                          {labelFor(s.student_id)}
                        </span>
                      )}
                      <Badge tone={statusTone(s.status)}>{s.status}</Badge>
                    </div>
                    <div className="flex items-center justify-between text-xs text-slate-500">
                      <span>{s.status === "ongoing" ? timeElapsed(s.started_at) : "—"}</span>
                      <span>{s.score != null ? `${s.score} pts` : "Unscored"}</span>
                    </div>
                    {(incidentCountBySubmission[s.id] ?? 0) > 0 && (
                      <div className="mt-2 flex items-center gap-1 text-xs text-warn">
                        <AlertOctagon size={12} /> {incidentCountBySubmission[s.id]} flag(s)
                      </div>
                    )}
                    <div className="mt-3 flex items-center gap-2">
                      <Link
                        to={`/submissions/${s.id}`}
                        className="inline-flex items-center gap-1 text-xs text-accent hover:underline"
                      >
                        <FileText size={12} /> Audit
                      </Link>
                      {s.status === "ongoing" && (
                        <Button
                          variant="destructive"
                          size="sm"
                          className="ml-auto"
                          onClick={() => handleDisqualify(s)}
                        >
                          <Ban size={13} /> Disqualify
                        </Button>
                      )}
                    </div>
                  </CardContent>
                </Card>
              ))}
            </div>
          )}
        </div>

        {/* Right: realtime incident feed */}
        <div className="w-96 shrink-0 border-l border-border bg-surface-inset">
          <div
            className={cn(
              "flex items-center justify-between border-b border-border px-4 py-3 transition-colors",
              flash && "bg-alert/10"
            )}
          >
            <CardTitle className="text-slate-300">Live incident feed</CardTitle>
            <span className="text-xs text-slate-500">{logs.length}</span>
          </div>
          <div className="h-[calc(100vh-56px-49px)] overflow-y-auto">
            {feedLoading && (
              <div role="status" aria-label="Loading incidents">
                {Array.from({ length: 5 }).map((_, index) => (
                  <FeedRowSkeleton key={index} />
                ))}
              </div>
            )}
            {!feedLoading && logs.length === 0 && (
              <p className="p-4 text-sm text-slate-500">No incidents reported yet.</p>
            )}
            {!feedLoading && logs.map((log) => (
              <div
                key={log.id}
                className="animate-rowIn flex items-start gap-2.5 border-b border-border px-4 py-3"
              >
                <AlertOctagon size={15} className="mt-0.5 shrink-0 text-alert" />
                <div className="min-w-0 flex-1">
                  <div className="flex items-center justify-between">
                    <span className="text-sm font-medium text-slate-200">
                      {INCIDENT_LABELS[log.action_type] ?? log.action_type}
                    </span>
                    <span className="font-mono text-[11px] text-slate-500">{formatTime(log.timestamp)}</span>
                  </div>
                  <p className="mt-0.5 text-[11px] text-slate-500">
                    {feedLabel(log.submission_id)}
                    {" · "}
                    <Link
                      to={`/submissions/${log.submission_id}`}
                      className="text-accent hover:underline"
                    >
                      audit
                    </Link>
                  </p>
                  {log.snapshot_url && (
                    <button
                      onClick={() => setSnapshot(log.snapshot_url)}
                      className="mt-1.5 flex items-center gap-1 text-xs text-accent hover:underline"
                    >
                      <ImageIcon size={12} /> View snapshot
                    </button>
                  )}
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>

      {snapshot && <SnapshotModal url={snapshot} onClose={() => setSnapshot(null)} />}
    </div>
  );
}
