import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import { AuthProvider, useAuth } from "@/hooks/useAuth";
import { AppShell } from "@/components/layout/AppShell";
import { LoginPage } from "@/pages/Login";
import { DashboardOverview } from "@/pages/DashboardOverview";
import { ExamManager } from "@/pages/ExamManager";
import { LiveMonitor } from "@/pages/LiveMonitor";
import { SubmissionAudit } from "@/pages/SubmissionAudit";

function RequireSupervisor({ children }: { children: React.ReactNode }) {
  const { loading, profile } = useAuth();

  if (loading) {
    return <div className="flex min-h-screen items-center justify-center bg-surface text-sm text-slate-500">Loading…</div>;
  }
  if (!profile) {
    // Signed out, or signed in without a supervisor profile — `useAuth` puts the
    // reason (a failed profile read, a student account) in its `error`, which
    // LoginPage renders above the form. The console itself stays unreachable.
    return <LoginPage />;
  }
  return <>{children}</>;
}

function AppRoutes() {
  return (
    <RequireSupervisor>
      <AppShell>
        <Routes>
          <Route path="/" element={<DashboardOverview />} />
          <Route path="/exams" element={<ExamManager />} />
          <Route path="/exams/:id/monitor" element={<LiveMonitor />} />
          <Route path="/submissions/:id" element={<SubmissionAudit />} />
          <Route path="/analytics" element={<DashboardOverview />} />
          <Route path="/settings" element={<div className="p-6 text-sm text-slate-500">Settings — coming soon.</div>} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </AppShell>
    </RequireSupervisor>
  );
}

export default function App() {
  return (
    <BrowserRouter>
      <AuthProvider>
        <AppRoutes />
      </AuthProvider>
    </BrowserRouter>
  );
}
