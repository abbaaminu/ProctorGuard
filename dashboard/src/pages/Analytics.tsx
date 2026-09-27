import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { AlertTriangle, Ban, CheckCircle2, Users } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { Card, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { MetricCard } from "@/components/ui/metric-card";
import { MetricCardSkeleton, Skeleton, TableSkeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";
import type { ExamRow, ProctoringLogRow, SubmissionRow } from "@/types/database";

/**
 * How far back the incident columns look.
 *
 * Bounded on purpose: the log table only grows, so an unbounded "all time" read
 * would get slower every term. Attempts and scores come from `exam_submissions`,
 * which is bounded by the roster and needs no window.
 */
const WINDOW_DAYS = 30;

/** One exam's row in the report. */
type ExamRollup = {
  exam: ExamRow;
  attempts: number;
  ongoing: number;
  completed: number;
  disqualified: number;
  incidents: number;
  /** Percentage of *closed* attempts that were disqualified (0 when none closed). */
  dqRate: number;
  /** Mean score over graded attempts, or null when nothing has been graded. */
  avgScore: number | null;
};

export function Analytics() {
  const [exams, setExams] = useState<ExamRow[]>([]);
  const [submissions, setSubmissions] = useState<SubmissionRow[]>([]);
  const [logs, setLogs] = useState<ProctoringLogRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError(null);

    (async () => {
      const since = new Date(
        Date.now() - WINDOW_DAYS * 24 * 60 * 60 * 1000
      ).toISOString();

      const [examsRes, subsRes, logsRes] = await Promise.all([
        supabase.from("exams").select("*"),
        supabase.from("exam_submissions").select("*"),
        supabase.from("proctoring_logs").select("*").gte("timestamp", since),
      ]);
      if (!active) return;

      // Same rule as the dashboard: a failed read is never rendered as zeros.
      const failure = examsRes.error ?? subsRes.error ?? logsRes.error;
      if (failure) {
        setError(failure.message);
        setLoading(false);
        return;
      }

      setExams((examsRes.data as ExamRow[]) ?? []);
      setSubmissions((subsRes.data as SubmissionRow[]) ?? []);
      setLogs((logsRes.data as ProctoringLogRow[]) ?? []);
      setLoading(false);
    })();

    return () => {
      active = false;
    };
  }, [reloadKey]);

  const rollups = useMemo<ExamRollup[]>(() => {
    // submission id -> exam id, so a log row (which only knows its submission)
    // can be attributed to the exam it belongs to.
    const examBySubmission = new Map(
      submissions.map((s) => [s.id, s.exam_id] as const)
    );

    const incidentsByExam = new Map<string, number>();
    logs.forEach((log) => {
      const examId = examBySubmission.get(log.submission_id);
      if (!examId) return; // a log for a submission outside this read
      incidentsByExam.set(examId, (incidentsByExam.get(examId) ?? 0) + 1);
    });

    return exams
      .map((exam) => {
        const attempts = submissions.filter((s) => s.exam_id === exam.id);
        const completed = attempts.filter((s) => s.status === "submitted").length;
        const disqualified = attempts.filter(
          (s) => s.status === "disqualified"
        ).length;
        const scores = attempts
          .map((s) => s.score)
          .filter((score): score is number => typeof score === "number");
        const closed = completed + disqualified;
        const mean = scores.length
          ? scores.reduce((a, b) => a + b, 0) / scores.length
          : null;

        return {
          exam,
          attempts: attempts.length,
          ongoing: attempts.filter((s) => s.status === "ongoing").length,
          completed,
          disqualified,
          incidents: incidentsByExam.get(exam.id) ?? 0,
          dqRate: closed ? Math.round((disqualified / closed) * 100) : 0,
          avgScore: mean === null ? null : Math.round(mean * 10) / 10,
        };
      })
      // Most-flagged first: that is the exam a supervisor needs to look at.
      .sort(
        (a, b) =>
          b.incidents - a.incidents || a.exam.title.localeCompare(b.exam.title)
      );
  }, [exams, submissions, logs]);

  const totals = useMemo(() => {
    const completed = rollups.reduce((sum, r) => sum + r.completed, 0);
    const disqualified = rollups.reduce((sum, r) => sum + r.disqualified, 0);
    const closed = completed + disqualified;
    // Weighted by graded count so a small exam does not swing the mean.
    const gradedTotal = rollups.reduce(
      (sum, r) => sum + (r.avgScore ?? 0) * r.completed,
      0
    );
    const gradedCount = rollups.reduce(
      (sum, r) => sum + (r.avgScore === null ? 0 : r.completed),
      0
    );

    return {
      attempts: rollups.reduce((sum, r) => sum + r.attempts, 0),
      completed,
      disqualified,
      dqRate: closed ? Math.round((disqualified / closed) * 100) : 0,
      incidents: rollups.reduce((sum, r) => sum + r.incidents, 0),
      avgScore:
        gradedCount > 0 ? Math.round((gradedTotal / gradedCount) * 10) / 10 : null,
    };
  }, [rollups]);

  return (
    <div className="p-6">
      <h1 className="mb-1 text-lg font-semibold text-slate-100">Analytics</h1>
      <p className="mb-6 text-sm text-slate-500">
        Integrity and outcome per exam — incidents over the last {WINDOW_DAYS} days.
      </p>

      {loading && (
        <span role="status" className="sr-only">
          Loading analytics
        </span>
      )}

      {error && (
        <div className="mb-4 flex flex-wrap items-center justify-between gap-3 rounded-md border border-alert/30 bg-alert/10 px-3 py-2 text-sm text-alert">
          <span>Could not load analytics: {error}</span>
          <Button variant="outline" size="sm" onClick={() => setReloadKey((k) => k + 1)}>
            Try again
          </Button>
        </div>
      )}

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        {loading ? (
          Array.from({ length: 4 }).map((_, index) => (
            <MetricCardSkeleton key={index} />
          ))
        ) : (
          <>
            <MetricCard label="Attempts" value={String(totals.attempts)} icon={Users} />
            <MetricCard
              label="Completed"
              value={String(totals.completed)}
              icon={CheckCircle2}
            />
            <MetricCard
              label={`Incidents (${WINDOW_DAYS}d)`}
              value={String(totals.incidents)}
              icon={AlertTriangle}
            />
            <MetricCard
              label="Disqualification rate"
              value={`${totals.dqRate}%`}
              icon={Ban}
              tone="alert"
            />
          </>
        )}
      </div>

      <Card className="mt-6 overflow-hidden">
        <CardHeader className="flex items-center justify-between">
          <CardTitle>Per-exam breakdown</CardTitle>
          {loading ? (
            <Skeleton className="h-3 w-24" />
          ) : (
            <span className="text-xs text-slate-500">
              {totals.avgScore !== null
                ? `Mean score ${totals.avgScore} pts`
                : "Nothing graded yet"}
            </span>
          )}
        </CardHeader>
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-border text-left text-xs uppercase tracking-wide text-slate-500">
              <th scope="col" className="px-4 py-2.5 font-medium">Exam</th>
              <th scope="col" className="px-4 py-2.5 font-medium">Attempts</th>
              <th scope="col" className="px-4 py-2.5 font-medium">In progress</th>
              <th scope="col" className="px-4 py-2.5 font-medium">Completed</th>
              <th scope="col" className="px-4 py-2.5 font-medium">Disqualified</th>
              <th scope="col" className="px-4 py-2.5 font-medium">DQ rate</th>
              <th scope="col" className="px-4 py-2.5 font-medium">Incidents</th>
              <th scope="col" className="px-4 py-2.5 font-medium">Avg score</th>
            </tr>
          </thead>
          <tbody>
            {loading && <TableSkeleton rows={3} columns={8} />}
            {!loading && rollups.length === 0 && (
              <tr>
                <td colSpan={8} className="px-4 py-6 text-center text-slate-500">
                  No exams yet — create one to get started.
                </td>
              </tr>
            )}
            {!loading &&
              rollups.map((row) => (
                <tr
                  key={row.exam.id}
                  className="border-b border-border last:border-0 hover:bg-white/[0.02]"
                >
                  <td className="px-4 py-2.5">
                    <Link
                      to={`/exams/${row.exam.id}/monitor`}
                      className="font-medium text-slate-200 hover:text-accent hover:underline"
                    >
                      {row.exam.title}
                    </Link>
                  </td>
                  <td className="px-4 py-2.5 tabular-nums text-slate-300">{row.attempts}</td>
                  <td className="px-4 py-2.5 tabular-nums text-slate-400">{row.ongoing}</td>
                  <td className="px-4 py-2.5 tabular-nums text-slate-300">{row.completed}</td>
                  <td
                    className={cn(
                      "px-4 py-2.5 tabular-nums",
                      row.disqualified > 0 ? "text-alert" : "text-slate-400"
                    )}
                  >
                    {row.disqualified}
                  </td>
                  <td className="px-4 py-2.5">
                    <div className="flex items-center gap-2">
                      <span className="w-9 tabular-nums text-slate-300">{row.dqRate}%</span>
                      <span
                        aria-hidden
                        className="h-1.5 w-16 overflow-hidden rounded-full bg-white/5"
                      >
                        <span
                          className={cn(
                            "block h-full rounded-full",
                            row.dqRate >= 25 ? "bg-alert" : "bg-accent"
                          )}
                          style={{ width: `${Math.min(row.dqRate, 100)}%` }}
                        />
                      </span>
                    </div>
                  </td>
                  <td
                    className={cn(
                      "px-4 py-2.5 tabular-nums",
                      row.incidents > 0 ? "text-warn" : "text-slate-400"
                    )}
                  >
                    {row.incidents}
                  </td>
                  <td className="px-4 py-2.5 tabular-nums text-slate-300">
                    {row.avgScore !== null ? `${row.avgScore} pts` : "—"}
                  </td>
                </tr>
              ))}
          </tbody>
        </table>
      </Card>
    </div>
  );
}
