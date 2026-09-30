import type { UserRole } from "@/types/database";

/**
 * The `public.user_role` enum, in its declaration order in
 * `supabase/schema.sql`, mirrored by `UserRole` in `types/database.ts`.
 *
 * These strings are *not* presentation labels: they are what `is_admin()` and
 * `is_staff()` compare `profiles.role` against server-side, so a role check in
 * a view has to spell them exactly. Everything in the console goes through the
 * helpers below rather than writing `=== "admin"` at a call site, so the
 * vocabulary and the labels stay in one file.
 */
export const USER_ROLES: readonly UserRole[] = [
  "admin",
  "lecturer",
  "supervisor",
  "student",
];

/**
 * The roles this console serves — the three `is_staff()` treats alike.
 *
 * `admin` is in here rather than beside it: an administrator is a member of
 * staff who *additionally* gets the account-management page, which is the whole
 * difference `canManageAccounts` below expresses. A student can sign in, but
 * `useAuth` refuses them before any view renders.
 */
export const STAFF_ROLES: readonly UserRole[] = ["admin", "lecturer", "supervisor"];

/** Human wording for a role, used by the roster, the role control and the tile. */
export const ROLE_LABELS: Record<UserRole, string> = {
  admin: "Administrator",
  lecturer: "Lecturer",
  supervisor: "Supervisor",
  student: "Student",
};

/**
 * Label for a role that came *from the database*, which may be one this build
 * does not know about (a role added to the enum in a later migration). An
 * unrecognised value is shown verbatim rather than mapped onto a familiar role,
 * the same stance the Flutter `UserRole.fromDb` takes by throwing: rendering an
 * unknown role as, say, "Supervisor" would describe access the account does not
 * have.
 */
export function roleLabel(role: string | null | undefined): string {
  if (!role) return "Unknown role";
  return ROLE_LABELS[role as UserRole] ?? role;
}

/** True for a `profiles.role` of `admin` — the same test as `public.is_admin()`. */
export function isAdminRole(role: UserRole | null | undefined): boolean {
  return role === "admin";
}

/** True for the three roles `public.is_staff()` accepts. */
export function isStaffRole(role: UserRole | null | undefined): boolean {
  return role != null && STAFF_ROLES.includes(role);
}

/**
 * Whether this account may use the administrator-only console pages (the
 * account roster and its role control).
 *
 * This is the *navigation* half of the rule only. The authoritative half is the
 * database: `profiles_admin_all` is `to authenticated using (is_admin())`, and
 * the `profiles_guard_role_change` trigger raises `42501` for anyone below
 * admin. A role change therefore cannot be smuggled past this console by
 * flipping a value in devtools — the write is refused server-side and the page
 * reports the refusal.
 */
export function canManageAccounts(role: UserRole | null | undefined): boolean {
  return isAdminRole(role);
}

/**
 * What the UI should do about a proposed role change. A discriminated result
 * rather than a boolean, because "nothing to save", "you may not do that" and
 * "go ahead" are three different things to render — and a boolean collapses the
 * middle one into a silent no-op button.
 */
export type RoleChangeVerdict =
  | { kind: "unchanged" }
  | { kind: "save" }
  | { kind: "blocked"; reason: string };

/**
 * Whether one account's role may be moved to `nextRole` from this console.
 *
 * The one rule the database cannot state is the self-demotion lock: an
 * administrator is free to move their own row (they are an admin), but doing it
 * from here would immediately revoke the very page that undoes it, and the way
 * back is the SQL editor. The Flutter roster blocks the same case for the same
 * reason.
 */
export function roleChangeVerdict(
  actorId: string | null | undefined,
  account: { id: string; role: UserRole },
  nextRole: UserRole
): RoleChangeVerdict {
  if (nextRole === account.role) return { kind: "unchanged" };
  if (actorId && account.id === actorId) {
    return {
      kind: "blocked",
      reason:
        "You cannot change your own role — demoting yourself would lock you out of the page that undoes it. Ask another administrator.",
    };
  }
  return { kind: "save" };
}

/**
 * The blast radius of a role change, in one sentence for the confirm dialog.
 *
 * The console confirms role writes rather than applying them on a select
 * change, because a mis-clicked dropdown is otherwise indistinguishable from a
 * decision — and unlike a publish toggle there is no badge to flip back.
 */
export function roleChangeWarning(
  account: { full_name?: string | null; email?: string | null },
  nextRole: UserRole
): string {
  const who = account.full_name?.trim() || account.email?.trim() || "This account";

  switch (nextRole) {
    case "admin":
      return `${who} will be able to manage every account, including yours.`;
    case "lecturer":
    case "supervisor":
      return `${who} will keep console access (exams, monitoring, analytics) but lose account management.`;
    case "student":
      return `${who} will lose access to this console entirely — students take exams in the mobile app only.`;
  }
}
