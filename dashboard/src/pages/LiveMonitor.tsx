import { useEffect, useMemo, useState } from "react";
import { useParams } from "react-router-dom";
import { AlertOctagon, Ban, Clock, Image as ImageIcon, X } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { useExamSubmissions } from "@/hooks/useExamSubmissions";
import { useLiveIncidentFeed } from "@/hooks/useLiveIncidentFeed";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge, statusTone } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { cn, formatTime, shortId, timeElapsed } from "@/lib/utils";
import type { ExamRow } from "@/types/database";

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

  const { submissions, disqualify } = useExamSubmissions(examId!);
  const submissionIds = useMemo(() => submissions.map((s) => s.id), [submissions]);
  const logs = useLiveIncidentFeed(submissionIds.length ? submissionIds : null);

  useEffect(() => {
    if (!examId) return;
    supabase.from("exams").select("*").eq("id", examId).single().then(({ data }) => setExam(data));
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

  return (
    <div className="flex h-screen flex-col">
      <header className="flex h-14 shrink-0 items-center justify-between border-b border-border bg-surface-raised px-6">
        <div className="flex items-center gap-3">
          <h1 className="text-sm font-semibold text-slate-100">{exam?.title ?? "Loading exam…"}</h1>
          <span className="flex items-center gap-1 text-xs text-slate-500">
            <Clock size={12} /> {exam?.duration_minutes} min
          </span>
        </div>
        <div className="flex items-center gap-1.5 rounded-full border border-ok/30 bg-ok/10 px-2.5 py-1 text-xs text-ok">
          <span className="h-1.5 w-1.5 rounded-full bg-ok animate-pulseDot" />
          Live sync active
        </div>
      </header>

      <div className="flex flex-1 overflow-hidden">
        {/* Left: candidate roster */}
        <div className="flex-1 overflow-y-auto p-5">
          <p className="mb-3 text-xs font-medium uppercase tracking-wide text-slate-500">
            Candidates ({submissions.length})
          </p>
          <div className="grid grid-cols-3 gap-3">
            {submissions.map((s) => (
              <Card key={s.id} className={cn(s.status === "disqualified" && "border-alert/40")}>
                <CardContent className="p-3.5">
                  <div className="mb-2 flex items-center justify-between">
                    <span className="font-mono text-xs text-slate-400">{shortId(s.student_id)}</span>
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
                  {s.status === "ongoing" && (
                    <Button
                      variant="destructive"
                      size="sm"
                      className="mt-3 w-full"
                      onClick={() => disqualify(s.id)}
                    >
                      <Ban size={13} /> Disqualify
                    </Button>
                  )}
                </CardContent>
              </Card>
            ))}
          </div>
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
            {logs.length === 0 && (
              <p className="p-4 text-sm text-slate-500">No incidents reported yet.</p>
            )}
            {logs.map((log) => (
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
                  <p className="mt-0.5 font-mono text-[11px] text-slate-500">
                    {shortId(log.submission_id)}
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
