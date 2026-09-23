import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import { AuthProvider, useAuth } from "@/hooks/useAuth";
import { AppShell } from "@/components/layout/AppShell";
import { LoginPage } from "@/pages/Login";
import { DashboardOverview } from "@/pages/DashboardOverview";
import { ExamManager } from "@/pages/ExamManager";
import { LiveMonitor } from "@/pages/LiveMonitor";
import { SubmissionAudit } from "@/pages/SubmissionAudit";

function RequireSupervisor({ children }: { children: React.ReactNode }) {
  const { loading, profile, error } = useAuth();

  if (loading) {
    return <div className="flex min-h-screen items-center justify-center bg-surface text-sm text-slate-500">Loading…</div>;
  }
  if (!profile) {
    return <LoginPage />;
  }
  if (error) {
    // Authenticated but role check failed elsewhere — defensive fallback,
    // primary messaging happens on the login screen itself.
    return <Navigate to="/" replace />;
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
