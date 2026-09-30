import { NavLink } from "react-router-dom";
import {
  BarChart3,
  Circle,
  ClipboardList,
  LayoutDashboard,
  Users,
  type LucideIcon,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { Skeleton } from "@/components/ui/skeleton";
import { SignOutButton } from "@/components/layout/SignOutButton";
import { canManageAccounts, roleLabel } from "@/lib/roles";
import type { UserRole } from "@/types/database";
import {
  REALTIME_STATUS_COPY,
  useRealtimeStatus,
} from "@/hooks/useRealtimeStatus";

interface NavItem {
  to: string;
  label: string;
  icon: LucideIcon;
  /** Matches this path exactly, so `/` does not stay lit on every page. */
  end?: boolean;
  /** Administrator-only entry — see `visibleNavItems` below. */
  adminOnly?: boolean;
}

/**
 * Sidebar navigation.
 *
 * Every entry here has a real page behind it — a nav item that lands on a
 * placeholder ("Settings — coming soon") makes the console look unfinished, so
 * it is added when the page is, not before.
 *
 * `adminOnly` is the only role-conditional thing in the chrome, and it mirrors
 * the server rather than inventing a rule: `/accounts` is the one page built on
 * the admin-only side of the `profiles` policies, so `supervisor` and `lecturer`
 * are not offered a link that would land on a roster they cannot write to. The
 * *rest* of the console is deliberately not branched on `profile.role` — the
 * dashboard, exams, monitoring, analytics and the audit trail are `is_staff()`
 * screens that all three staff roles share, so a role check there would only be
 * a way for the UI to disagree with the database.
 */
const navItems: NavItem[] = [
  { to: "/", label: "Dashboard", icon: LayoutDashboard, end: true },
  { to: "/exams", label: "Exams", icon: ClipboardList },
  { to: "/accounts", label: "Accounts", icon: Users, adminOnly: true },
  { to: "/analytics", label: "Analytics", icon: BarChart3 },
];

/**
 * The nav entries one account may see.
 *
 * Exported because it is the sidebar's only *decision* — the rest of the file is
 * markup — and because `RequireAdmin` has to agree with it: a hidden link and a
 * redirecting route are the same rule seen from two sides, and a check harness
 * can exercise both against a role without rendering anything.
 */
export function visibleNavItems(role: UserRole | null | undefined): NavItem[] {
  return navItems.filter((item) => !item.adminOnly || canManageAccounts(role));
}

export function Sidebar({
  userName,
  userEmail,
  role = null,
  pending = false,
}: {
  userName: string;
  userEmail: string;
  /** The signed-in account's `profiles.role`; decides the admin-only entries. */
  role?: UserRole | null;
  /** True while the session/profile is still being read: show skeleton tiles. */
  pending?: boolean;
}) {
  const status = useRealtimeStatus();
  const copy = REALTIME_STATUS_COPY[status];

  return (
    <aside className="fixed inset-y-0 left-0 z-30 flex w-56 flex-col border-r border-border bg-surface-raised">
      <div className="flex h-14 items-center gap-2 border-b border-border px-4">
        {/*
          Brand mark from `public/icon.png`. `BASE_URL` (rather than a bare
          "/icon.png" or a document-relative path) keeps the reference correct on
          any route and under any configured `base`, and the file name matches
          the favicon's case exactly so case-sensitive hosts serve it.
          `alt=""` because the adjacent wordmark already announces the name.
        */}
        <img
          src={`${import.meta.env.BASE_URL}icon.png`}
          alt=""
          width={24}
          height={24}
          className="h-6 w-6 shrink-0 rounded-md object-contain shadow-glow"
        />
        <span className="text-sm font-semibold tracking-tight text-slate-100">Proctor</span>
      </div>

      <nav className="flex-1 space-y-0.5 px-2 py-3">
        {visibleNavItems(role).map(({ to, label, icon: Icon, end }) => (
          <NavLink
            key={to}
            to={to}
            end={end}
            className={({ isActive }) =>
              cn(
                "flex items-center gap-2.5 rounded-md px-3 py-2 text-sm transition-colors",
                isActive
                  ? "bg-white/5 text-slate-100"
                  : "text-slate-400 hover:bg-white/5 hover:text-slate-200"
              )
            }
          >
            <Icon size={16} strokeWidth={2} />
            {label}
          </NavLink>
        ))}
      </nav>

      <div className="border-t border-border px-3 py-2">
        <div
          role="status"
          title={copy.hint}
          className="flex items-center gap-1.5 rounded-md px-2 py-1.5 text-xs"
        >
          <Circle size={7} className={cn("fill-current", copy.dot)} />
          <span className={copy.text}>{copy.label}</span>
        </div>
      </div>

      {/* The account tile and its one action, in the same bordered footer: the
          profile row keeps its own `flex` line so the sign-out button can sit
          under it at full width. The button is rendered in *both* states — a
          session that is still being read is still a session you may leave, and
          `signOut` needs no profile to end it. */}
      <div className="border-t border-border p-3">
        <div className="flex items-center gap-2">
          {pending ? (
            <div
              role="status"
              aria-label="Loading your profile"
              className="flex w-full items-center gap-2"
            >
              <Skeleton className="h-8 w-8 rounded-full" />
              <div className="min-w-0 flex-1 space-y-1.5">
                <Skeleton className="h-3 w-24" />
                <Skeleton className="h-2.5 w-32" />
              </div>
            </div>
          ) : (
            <>
              <div className="flex h-8 w-8 items-center justify-center rounded-full bg-accent/15 text-xs font-semibold text-accent">
                {userName.slice(0, 1).toUpperCase()}
              </div>
              <div className="min-w-0">
                <p className="truncate text-xs font-medium text-slate-200">{userName}</p>
                {/* The resolved role is shown here because the chrome branches on
                    it: an administrator wondering where the Accounts item went can
                    see which role the console actually read from `profiles`. */}
                <p className="truncate text-[11px] text-slate-500">
                  {roleLabel(role)} · {userEmail}
                </p>
              </div>
            </>
          )}
        </div>

        <SignOutButton className="mt-2" />
      </div>
    </aside>
  );
}
