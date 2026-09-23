import { useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { CheckCircle2, XCircle, AlertOctagon } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge, statusTone } from "@/components/ui/badge";
import { formatTime } from "@/lib/utils";
import type { SubmissionRow, ProctoringLogRow, QuestionRow } from "@/types/database";

const INCIDENT_LABELS: Record<string, string> = {
  looking_away: "Looking away",
  multiple_faces: "Multiple faces",
  no_face: "No face",
  app_minimized: "App minimized",
  audio_noise: "Audio noise",
};

export function SubmissionAudit() {
  const { id: submissionId } = useParams<{ id: string }>();
  const [submission, setSubmission] = useState<SubmissionRow | null>(null);
  const [logs, setLogs] = useState<ProctoringLogRow[]>([]);
  const [questions, setQuestions] = useState<QuestionRow[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!submissionId) {
      setLoading(false);
      return;
    }
    (async () => {
      const { data: sub } = await supabase.from("exam_submissions").select("*").eq("id", submissionId).single();
      if (!sub) { setLoading(false); return; }
      setSubmission(sub as SubmissionRow);

      const [{ data: logRows }, { data: questionRows }] = await Promise.all([
        supabase.from("proctoring_logs").select("*").eq("submission_id", submissionId).order("timestamp"),
        supabase.from("questions").select("*").eq("exam_id", sub.exam_id),
      ]);
      setLogs((logRows as ProctoringLogRow[]) ?? []);
      setQuestions((questionRows as QuestionRow[]) ?? []);
      setLoading(false);
    })();
  }, [submissionId]);

  if (loading) return <div className="p-6 text-sm text-slate-500">Loading…</div>;
  if (!submission) return <div className="p-6 text-sm text-slate-500">Submission not found.</div>;

  return (
    <div className="p-6">
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-lg font-semibold text-slate-100">Submission audit</h1>
          <p className="font-mono text-xs text-slate-500">{submission.id}</p>
        </div>
        <div className="flex items-center gap-3">
          <Badge tone={statusTone(submission.status)}>{submission.status}</Badge>
          <span className="text-lg font-semibold text-slate-100">
            {submission.score != null ? `${submission.score} pts` : "—"}
          </span>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-4">
        <Card>
          <CardHeader><CardTitle>Incident timeline</CardTitle></CardHeader>
          <CardContent className="p-0">
            {logs.length === 0 ? (
              <p className="p-4 text-sm text-slate-500">No incidents recorded during this session.</p>
            ) : (
              <ol className="relative border-l border-border ml-4 py-2">
                {logs.map((log) => (
                  <li key={log.id} className="mb-4 ml-4 last:mb-0">
                    <span className="absolute -left-[5px] mt-1.5 h-2.5 w-2.5 rounded-full bg-alert" />
                    <div className="flex items-center gap-2">
                      <AlertOctagon size={13} className="text-alert" />
                      <span className="text-sm font-medium text-slate-200">
                        {INCIDENT_LABELS[log.action_type] ?? log.action_type}
                      </span>
                      <span className="font-mono text-[11px] text-slate-500">{formatTime(log.timestamp)}</span>
                    </div>
                  </li>
                ))}
              </ol>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader><CardTitle>Question breakdown</CardTitle></CardHeader>
          <CardContent className="space-y-3 p-4">
            {questions.map((q, i) => {
              const studentAnswer = submission.answers?.[q.id];
              const isCorrect = studentAnswer === q.correct_option;
              return (
                <div key={q.id} className="rounded-md border border-border bg-surface-inset p-3">
                  <p className="mb-1.5 text-sm text-slate-200">
                    {i + 1}. {q.question_text}
                  </p>
                  <div className="flex items-center gap-4 text-xs">
                    <span className="flex items-center gap-1 text-slate-400">
                      Student: {studentAnswer != null ? q.options[studentAnswer] : "No answer"}
                      {studentAnswer != null &&
                        (isCorrect ? (
                          <CheckCircle2 size={13} className="text-ok" />
                        ) : (
                          <XCircle size={13} className="text-alert" />
                        ))}
                    </span>
                    {!isCorrect && (
                      <span className="text-slate-500">Correct: {q.options[q.correct_option]}</span>
                    )}
                  </div>
                </div>
              );
            })}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
