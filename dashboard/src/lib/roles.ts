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
  const who = accountIdentity(account);

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

/**
 * How a sentence names an account: the name, then the address, then a neutral
 * fallback for a row (or a response) that carries neither.
 *
 * Shared by the role-change warning and the deletion copy below so the two
 * destructive controls on the roster address the same person the same way.
 */
function accountIdentity(account: {
  full_name?: string | null;
  email?: string | null;
}): string {
  return account.full_name?.trim() || account.email?.trim() || "This account";
}

/**
 * What the UI should do about deleting one account: offer the control, or explain
 * why it cannot be used. A discriminated result for the same reason
 * `RoleChangeVerdict` is one — "you may" and "you may not, because X" are two
 * different things to render, and a boolean would collapse the second into a
 * button that silently does nothing.
 *
 * The one rule is the self-delete lock, which is `roleChangeVerdict`'s
 * self-demotion refusal seen from the other side. The caller is an administrator
 * (this page is admin-only) and the account they are signed in with is the last
 * one they can remove: deleting it would revoke the very page that mints its
 * replacement, and the way back is the SQL editor. Refusing it is therefore also
 * what guarantees at least one administrator survives — and the server-side half
 * of the same rule is the 403 in `admin-delete-user`, which is what a request
 * typed straight at the API meets.
 */
export type DeleteAccountVerdict =
  | { kind: "delete" }
  | { kind: "blocked"; reason: string };

export function deleteAccountVerdict(
  actorId: string | null | undefined,
  account: { id: string }
): DeleteAccountVerdict {
  if (actorId && account.id === actorId) {
    return {
      kind: "blocked",
      reason:
        "You cannot delete the account you are signed in with — it is the page that creates its replacement. Ask another administrator.",
    };
  }
  return { kind: "delete" };
}

/** What `admin-delete-user` counted as removed, as its 200 body reports it. */
export interface RemovalScope {
  exams: number;
  submissions: number;
}

/**
 * What a deletion will take with it, in one sentence for the confirm dialog.
 *
 * This is a delete, not a deactivation, and the schema makes its reach exact:
 * `profiles.id` references `auth.users(id) on delete cascade`, so the login and
 * the row go together — and so does everything the schema hangs off that row.
 * For a member of staff that is every exam they created: its questions, every
 * attempt submitted for those exams, and the incident log behind each attempt.
 * For a student it is their own attempts, and the log behind each of them.
 *
 * The dialog names the *kind* of thing that goes rather than a count, because the
 * counts only exist where the write happens: `admin-delete-user` takes them
 * immediately before it deletes and reports them back (`deletionSummary`). A
 * number read when the dialog opened would be a guess by the time the button is
 * pressed, and a wrong number on a destructive confirm is worse than none — what
 * an administrator needs before clicking is what *kind* of data is at stake,
 * which the foreign keys fix by role.
 */
export function deleteAccountWarning(account: {
  role: UserRole;
  full_name?: string | null;
  email?: string | null;
}): string {
  const who = accountIdentity(account);
  if (account.role === "student") {
    return (
      `${who} loses the login and the profile row, and every exam attempt this ` +
      `account has submitted — with the incident log behind each one — goes with it.`
    );
  }
  return (
    `${who} loses the login and the profile row, and every exam this account ` +
    `created goes with it: its questions, every attempt submitted for those exams, ` +
    `and the incident log behind each attempt.`
  );
}

/**
 * The confirmation line for a completed deletion: what went, as the server
 * counted it immediately before the write.
 *
 * Read it as the receipt for the dialog's warning — the dialog says what *kind*
 * of thing a delete takes, this says how much it actually took, from the one
 * place that could count it honestly. A zero is reported by omission ("along
 * with 0 exams" would be noise), and one of a thing is singular.
 */
export function deletionSummary(
  account: { full_name?: string | null; email?: string | null },
  scope: RemovalScope
): string {
  const counted: string[] = [];
  if (scope.exams > 0) {
    counted.push(`${scope.exams} exam${scope.exams === 1 ? "" : "s"}`);
  }
  if (scope.submissions > 0) {
    counted.push(`${scope.submissions} attempt${scope.submissions === 1 ? "" : "s"}`);
  }

  const who = accountIdentity(account);
  return counted.length > 0
    ? `${who} was deleted, along with ${joinWords(counted)}.`
    : `${who} was deleted.`;
}

/** "a", "a and b", "a, b and c" — for a list of at most a few counted things. */
function joinWords(parts: string[]): string {
  if (parts.length === 1) return parts[0];
  return `${parts.slice(0, -1).join(", ")} and ${parts[parts.length - 1]}`;
}
