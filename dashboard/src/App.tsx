import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import { AuthProvider, useAuth } from "@/hooks/useAuth";
import { AppShell } from "@/components/layout/AppShell";
import { PageSkeleton } from "@/components/ui/skeleton";
import { LoginPage } from "@/pages/Login";
import { DashboardOverview } from "@/pages/DashboardOverview";
import { ExamManager } from "@/pages/ExamManager";
import { LiveMonitor } from "@/pages/LiveMonitor";
import { SubmissionAudit } from "@/pages/SubmissionAudit";
import { Analytics } from "@/pages/Analytics";
import { AccountRoster } from "@/pages/AccountRoster";
import { RequireAdmin } from "@/components/layout/RequireAdmin";

/**
 * Routing + the console shell.
 *
 * The shell is deliberately *not* gated on the session check: the sidebar and
 * the header are static, so they paint on the first frame while `useAuth`
 * resolves the session, and only the page area shows a skeleton. The old
 * implementation swapped the entire app for a full-screen "Loading…" element,
 * which hid the chrome, made the first paint feel like a hang and re-mounted the
 * layout on every auth event.
 */
function AppRoutes() {
  const { loading, profile } = useAuth();

  if (loading) {
    return (
      <AppShell profilePending>
        <PageSkeleton />
      </AppShell>
    );
  }

  if (!profile) {
    // Signed out, or signed in without a supervisor profile — `useAuth` puts the
    // reason (a failed profile read, a student account) in its `error`, which
    // LoginPage renders above the form. The console itself stays unreachable.
    return <LoginPage />;
  }

  return (
    <AppShell>
      <Routes>
        <Route path="/" element={<DashboardOverview />} />
        <Route path="/exams" element={<ExamManager />} />
        <Route path="/exams/:id/monitor" element={<LiveMonitor />} />
        <Route path="/submissions/:id" element={<SubmissionAudit />} />
        {/* A real report page. This used to render `DashboardOverview`, so the
            "Analytics" nav item silently showed the dashboard again. */}
        <Route path="/analytics" element={<Analytics />} />
        {/* The one administrator-only route. The sidebar does not render its
            link for a supervisor, and `RequireAdmin` sends a hand-typed address
            back to the dashboard; the `profiles` policies and the
            `profiles_guard_role_change` trigger are what actually refuse a
            non-admin, so this fence is about where a staff member lands, not
            about what they are allowed to do. */}
        <Route
          path="/accounts"
          element={
            <RequireAdmin>
              <AccountRoster />
            </RequireAdmin>
          }
        />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </AppShell>
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
