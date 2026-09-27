import { useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { CheckCircle2, XCircle, AlertOctagon } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { useAccountNames } from "@/hooks/useAccountNames";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge, statusTone } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import { formatTime } from "@/lib/utils";
import { incidentLabel } from "@/lib/incidents";
import type { SubmissionRow, ProctoringLogRow, QuestionRow } from "@/types/database";

/**
 * Mirrors the grading in `submit_exam()` for a fill-in-the-blank answer: the
 * server trims and lowercases both sides, so the audit view has to agree with it
 * or a correct answer would look wrong here.
 */
function normalise(value: string | null | undefined) {
  return (value ?? "").trim().toLowerCase();
}

export function SubmissionAudit() {
  const { id: submissionId } = useParams<{ id: string }>();
  const [submission, setSubmission] = useState<SubmissionRow | null>(null);
  const [logs, setLogs] = useState<ProctoringLogRow[]>([]);
  const [questions, setQuestions] = useState<QuestionRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const { names } = useAccountNames();

  useEffect(() => {
    if (!submissionId) {
      setLoading(false);
      return;
    }

    let active = true;

    (async () => {
      const { data: sub, error: submissionError } = await supabase
        .from("exam_submissions")
        .select("*")
        .eq("id", submissionId)
        .single();
      if (!active) return;

      if (submissionError || !sub) {
        // A network/RLS failure previously rendered as "Submission not found."
        // — saying what actually happened is worth the extra state.
        setError(submissionError?.message ?? "Submission not found.");
        setLoading(false);
        return;
      }

      setSubmission(sub as SubmissionRow);

      const [logRows, questionRows] = await Promise.all([
        supabase.from("proctoring_logs").select("*").eq("submission_id", submissionId).order("timestamp"),
        supabase.from("questions").select("*").eq("exam_id", sub.exam_id),
      ]);
      if (!active) return;

      setLogs((logRows.data as ProctoringLogRow[]) ?? []);
      setQuestions((questionRows.data as QuestionRow[]) ?? []);
      setLoading(false);
    })();

    return () => {
      active = false;
    };
  }, [submissionId]);

  if (loading) {
    return (
      <div className="p-6">
        <span role="status" className="sr-only">
          Loading the submission audit
        </span>

        <div className="mb-6 flex items-center justify-between">
          <div className="space-y-2">
            <Skeleton className="h-5 w-44" />
            <Skeleton className="h-3 w-32" />
            <Skeleton className="h-3 w-56" />
          </div>
          <Skeleton className="h-7 w-28 rounded-md" />
        </div>

        <div className="grid grid-cols-2 gap-4">
          {[0, 1].map((panel) => (
            <Card key={panel}>
              <CardHeader>
                <Skeleton className="h-4 w-40" />
              </CardHeader>
              <CardContent className="space-y-3">
                {[0, 1, 2].map((row) => (
                  <Skeleton key={row} className="h-16 w-full" />
                ))}
              </CardContent>
            </Card>
          ))}
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="p-6">
        <h1 className="mb-1 text-lg font-semibold text-slate-100">Submission audit</h1>
        <div className="mt-4 rounded-md border border-alert/30 bg-alert/10 px-3 py-2 text-sm text-alert">
          {error}
        </div>
      </div>
    );
  }

  if (!submission) return <div className="p-6 text-sm text-slate-500">Submission not found.</div>;

  return (
    <div className="p-6">
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-lg font-semibold text-slate-100">Submission audit</h1>
          <p className="text-xs text-slate-400">
            {names[submission.student_id] ?? "Unknown student"}
          </p>
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
                        {incidentLabel(log.action_type)}
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
            {questions.length === 0 && (
              <p className="text-sm text-slate-500">
                No questions are stored for this exam.
              </p>
            )}
            {questions.map((q, i) => {
              const answer = submission.answers?.[q.id];
              const isBlank = q.question_type === "fill_in_the_blank";
              // Stored answers are a number for a choice question and a string
              // for a typed one, so the two shapes are compared separately.
              const isCorrect = isBlank
                ? typeof answer === "string" && normalise(answer) === normalise(q.correct_text_answer)
                : answer === q.correct_option;
              const studentAnswer = isBlank
                ? typeof answer === "string" && answer.trim().length > 0
                  ? answer
                  : null
                : typeof answer === "number"
                  ? q.options[answer] ?? `Option ${answer + 1}`
                  : null;
              const expectedAnswer = isBlank
                ? q.correct_text_answer
                : typeof q.correct_option === "number"
                  ? q.options[q.correct_option]
                  : null;

              return (
                <div key={q.id} className="rounded-md border border-border bg-surface-inset p-3">
                  <div className="mb-1.5 flex items-center justify-between gap-2">
                    <span className="text-[11px] font-medium uppercase tracking-wide text-slate-500">
                      Question {i + 1} of {questions.length}
                    </span>
                    <span className="text-[11px] text-slate-500">
                      {isBlank ? "Fill in the blank" : "Multiple choice"} · {q.points} pt
                    </span>
                  </div>
                  <p className="mb-1.5 text-sm text-slate-200">{q.question_text}</p>
                  <div className="flex items-center gap-4 text-xs">
                    <span className="flex items-center gap-1 text-slate-400">
                      Student: {studentAnswer ?? "No answer"}
                      {studentAnswer != null &&
                        (isCorrect ? (
                          <CheckCircle2 size={13} className="text-ok" />
                        ) : (
                          <XCircle size={13} className="text-alert" />
                        ))}
                    </span>
                    {!isCorrect && expectedAnswer && (
                      <span className="text-slate-500">Correct: {expectedAnswer}</span>
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
