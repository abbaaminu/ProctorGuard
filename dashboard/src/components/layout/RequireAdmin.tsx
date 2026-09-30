import type { ReactNode } from "react";
import { Navigate } from "react-router-dom";
import { useAuth } from "@/hooks/useAuth";
import { canManageAccounts } from "@/lib/roles";

/**
 * Route fence for the administrator-only pages.
 *
 * WHAT THIS IS NOT: authorisation. `useAuth` has already turned away a
 * signed-out visitor and a student, and the database is what actually stops a
 * supervisor from reading or writing anything reserved for an administrator
 * (`profiles_admin_all` is `is_admin()`; the `profiles_guard_role_change`
 * trigger raises `42501` for anyone below admin). This component only decides
 * *where a signed-in staff member lands* — a supervisor has no link to
 * `/accounts` in the first place, so typing the URL by hand should put them back
 * on the dashboard they do have rather than on a page whose table they cannot
 * write to.
 *
 * A redirect rather than a "you may not open this" screen, deliberately: the
 * only way to arrive here is by hand-typing an address that is never linked, and
 * a dead-end apology for a page nobody offered is noise. The counterpart in the
 * Flutter app is `RoleGate`'s split between the supervisor dashboard and
 * `AdminDashboardPage`.
 */
export function RequireAdmin({ children }: { children: ReactNode }) {
  const { profile } = useAuth();

  if (!canManageAccounts(profile?.role)) return <Navigate to="/" replace />;
  return <>{children}</>;
}
