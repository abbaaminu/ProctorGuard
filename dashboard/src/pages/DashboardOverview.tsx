import { useEffect, useMemo, useState } from "react";
import { Activity, Users, AlertTriangle, Ban } from "lucide-react";
import {
  BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer,
  LineChart, Line, Legend,
} from "recharts";
import { supabase } from "@/lib/supabase";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import type { ExamRow, SubmissionRow, ProctoringLogRow } from "@/types/database";

function MetricCard({
  label, value, icon: Icon, tone = "default",
}: { label: string; value: string; icon: typeof Activity; tone?: "default" | "alert" }) {
  return (
    <Card>
      <CardContent className="flex items-center justify-between p-4">
        <div>
          <p className="text-xs font-medium text-slate-500">{label}</p>
          <p className="mt-1 text-2xl font-semibold tabular-nums text-slate-100">{value}</p>
        </div>
        <div
          className={`flex h-9 w-9 items-center justify-center rounded-md ${
            tone === "alert" ? "bg-alert/15 text-alert" : "bg-accent/15 text-accent"
          }`}
        >
          <Icon size={18} />
        </div>
      </CardContent>
    </Card>
  );
}

const INCIDENT_LABELS: Record<string, string> = {
  looking_away: "Looking away",
  multiple_faces: "Multiple faces",
  no_face: "No face",
  app_minimized: "App minimized",
  audio_noise: "Audio noise",
};

export function DashboardOverview() {
  const [exams, setExams] = useState<ExamRow[]>([]);
  const [submissions, setSubmissions] = useState<SubmissionRow[]>([]);
  const [logs, setLogs] = useState<ProctoringLogRow[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    (async () => {
      const [examsRes, subsRes, logsRes] = await Promise.all([
        supabase.from("exams").select("*"),
        supabase.from("exam_submissions").select("*"),
        supabase
          .from("proctoring_logs")
          .select("*")
          .gte("timestamp", new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()),
      ]);
      setExams((examsRes.data as ExamRow[]) ?? []);
      setSubmissions((subsRes.data as SubmissionRow[]) ?? []);
      setLogs((logsRes.data as ProctoringLogRow[]) ?? []);
      setLoading(false);
    })();
  }, []);

  const activeLiveExams = exams.filter((e) => e.is_published).length;
  const activeCandidates = submissions.filter((s) => s.status === "ongoing").length;
  const incidentsToday = logs.length;
  const dqRate = submissions.length
    ? Math.round((submissions.filter((s) => s.status === "disqualified").length / submissions.length) * 100)
    : 0;

  const incidentBreakdown = useMemo(() => {
    const counts: Record<string, number> = {};
    logs.forEach((l) => {
      counts[l.action_type] = (counts[l.action_type] ?? 0) + 1;
    });
    return Object.entries(counts).map(([type, count]) => ({
      type: INCIDENT_LABELS[type] ?? type,
      count,
    }));
  }, [logs]);

  const timeline = useMemo(() => {
    // Bucket submissions/disqualifications by day for the trailing window
    // present in the data — a lightweight client-side rollup rather than a
    // dedicated Postgres view, since dashboard volume is low.
    const byDay: Record<string, { day: string; completed: number; disqualified: number }> = {};
    submissions.forEach((s) => {
      if (!s.submitted_at) return;
      const day = s.submitted_at.slice(0, 10);
      byDay[day] ??= { day, completed: 0, disqualified: 0 };
      if (s.status === "submitted") byDay[day].completed += 1;
      if (s.status === "disqualified") byDay[day].disqualified += 1;
    });
    return Object.values(byDay).sort((a, b) => a.day.localeCompare(b.day));
  }, [submissions]);

  if (loading) {
    return <div className="p-6 text-sm text-slate-500">Loading dashboard…</div>;
  }

  return (
    <div className="p-6">
      <h1 className="mb-1 text-lg font-semibold text-slate-100">Dashboard</h1>
      <p className="mb-6 text-sm text-slate-500">Exam activity across your organization</p>

      <div className="grid grid-cols-4 gap-4">
        <MetricCard label="Active live exams" value={String(activeLiveExams)} icon={Activity} />
        <MetricCard label="Active candidates" value={String(activeCandidates)} icon={Users} />
        <MetricCard label="Incidents (24h)" value={String(incidentsToday)} icon={AlertTriangle} />
        <MetricCard label="Disqualification rate" value={`${dqRate}%`} icon={Ban} tone="alert" />
      </div>

      <div className="mt-6 grid grid-cols-2 gap-4">
        <Card>
          <CardHeader><CardTitle>Incident breakdown</CardTitle></CardHeader>
          <CardContent className="h-64">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={incidentBreakdown}>
                <CartesianGrid strokeDasharray="3 3" stroke="#1E2430" vertical={false} />
                <XAxis dataKey="type" tick={{ fill: "#64748b", fontSize: 11 }} axisLine={{ stroke: "#1E2430" }} />
                <YAxis tick={{ fill: "#64748b", fontSize: 11 }} axisLine={{ stroke: "#1E2430" }} allowDecimals={false} />
                <Tooltip
                  contentStyle={{ background: "#12161F", border: "1px solid #1E2430", borderRadius: 6, fontSize: 12 }}
                  labelStyle={{ color: "#e2e8f0" }}
                />
                <Bar dataKey="count" fill="#3DD6C1" radius={[4, 4, 0, 0]} />
              </BarChart>
            </ResponsiveContainer>
          </CardContent>
        </Card>

        <Card>
          <CardHeader><CardTitle>Completions vs. disqualifications</CardTitle></CardHeader>
          <CardContent className="h-64">
            <ResponsiveContainer width="100%" height="100%">
              <LineChart data={timeline}>
                <CartesianGrid strokeDasharray="3 3" stroke="#1E2430" vertical={false} />
                <XAxis dataKey="day" tick={{ fill: "#64748b", fontSize: 11 }} axisLine={{ stroke: "#1E2430" }} />
                <YAxis tick={{ fill: "#64748b", fontSize: 11 }} axisLine={{ stroke: "#1E2430" }} allowDecimals={false} />
                <Tooltip
                  contentStyle={{ background: "#12161F", border: "1px solid #1E2430", borderRadius: 6, fontSize: 12 }}
                  labelStyle={{ color: "#e2e8f0" }}
                />
                <Legend wrapperStyle={{ fontSize: 12 }} />
                <Line type="monotone" dataKey="completed" stroke="#3DD68C" strokeWidth={2} dot={false} />
                <Line type="monotone" dataKey="disqualified" stroke="#F0475A" strokeWidth={2} dot={false} />
              </LineChart>
            </ResponsiveContainer>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
