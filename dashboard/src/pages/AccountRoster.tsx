import { useRef, useState, type ComponentProps, type FormEvent } from "react";
import { Loader2, ShieldCheck, Trash2, UserPlus } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { TableSkeleton } from "@/components/ui/skeleton";
import { Toast, type ToastTone } from "@/components/ui/toast";
import { useAuth } from "@/hooks/useAuth";
import {
  MIN_PASSWORD_LENGTH,
  useAccounts,
  type AccountWriteResult,
  type NewAccountInput,
} from "@/hooks/useAccounts";
import {
  deleteAccountVerdict,
  deleteAccountWarning,
  deletionSummary,
  roleChangeVerdict,
  roleChangeWarning,
  roleLabel,
  USER_ROLES,
} from "@/lib/roles";
import type { ProfileRow, UserRole } from "@/types/database";

type Tone = NonNullable<ComponentProps<typeof Badge>["tone"]>;

/**
 * Roles borrow the `Badge` tones rather than introducing a second palette: an
 * administrator is the one role with extra reach, so it gets the accent colour
 * the live/ongoing badge uses, students are grouped with the "submitted" blue to
 * keep them visually apart from staff, and supervisor/lecturer share the neutral
 * tone because they are the same tier (`is_staff()`).
 */
const ROLE_TONES: Record<UserRole, Tone> = {
  admin: "ongoing",
  lecturer: "neutral",
  supervisor: "neutral",
  student: "submitted",
};

/**
 * Tone for a role that came *from the database*, which may be one this build
 * does not know about (a role added to the enum in a later migration). An
 * unrecognised value gets the neutral tone rather than a familiar role's colour,
 * for the same reason `roleLabel` shows it verbatim.
 */
function roleTone(role: string): Tone {
  return ROLE_TONES[role as UserRole] ?? "neutral";
}

/** Same field styling as the sign-in form, so the console has one form look. */
const FIELD_CLASS =
  "w-full rounded-md border border-border bg-surface-inset px-3 py-2 text-sm text-slate-100 outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/50";

const SELECT_CLASS =
  "h-8 rounded-md border border-border bg-surface-inset px-2 text-xs text-slate-200 outline-none focus:border-accent/50 disabled:opacity-40";

/** `profiles.created_at`, or an em dash for a row (or response) without it. */
function formatJoined(iso?: string | null): string {
  if (!iso) return "—";
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? "—" : date.toLocaleDateString();
}

/**
 * First problem with the "add an account" form, worded for its inline banner.
 *
 * The same three rules the Edge Function enforces server-side (full name,
 * address, password length); checking them here only saves a round trip — the
 * API is still what decides, and its refusal is what the form shows if it
 * disagrees.
 */
function newAccountProblem(input: {
  fullName: string;
  email: string;
  password: string;
}): string | null {
  if (!input.fullName.trim()) return "Enter the person's full name.";

  // Deliberately loose: the Edge Function and Supabase Auth both validate
  // again, and a clever regex here would only reject valid addresses.
  const email = input.email.trim();
  if (!email.includes("@") || !email.split("@").pop()?.includes(".")) {
    return "Enter a valid email address.";
  }

  if (input.password.length < MIN_PASSWORD_LENGTH) {
    return `Use a temporary password of at least ${MIN_PASSWORD_LENGTH} characters.`;
  }
  return null;
}

/**
 * Provision a login for someone who cannot create one for themselves.
 *
 * Creating an account is the one thing on this page that cannot be a PostgREST
 * call: `auth.users` belongs to Supabase Auth, and `profiles_insert_self_student`
 * accepts nothing but `role='student'` from a browser. So the write goes through
 * the `admin-create-user` Edge Function, which verifies the caller's own role
 * (`CREATOR_ROLES` is admin-only) before it uses the service key.
 *
 * The form's own checks only save a round trip; the function is what decides,
 * and its refusal is what the banner shows if the two disagree.
 */
function CreateAccountCard({
  createAccount,
  onCreated,
}: {
  createAccount: (input: NewAccountInput) => Promise<AccountWriteResult>;
  onCreated: (email: string) => void;
}) {
  const [fullName, setFullName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  /**
   * Defaults to the role these accounts are mostly made of: creating a *student*
   * is what the public sign-up form is for, so an administrator opening this
   * page is usually provisioning staff.
   */
  const [role, setRole] = useState<UserRole>("lecturer");
  const [submitting, setSubmitting] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (submitting) return; // a double submit must not create two accounts

    setFormError(null);
    const problem = newAccountProblem({ fullName, email, password });
    if (problem) {
      setFormError(problem);
      return;
    }

    setSubmitting(true);
    const result = await createAccount({ fullName, email, password, role });
    setSubmitting(false);
    if (!result.ok) {
      setFormError(result.message);
      return;
    }

    // Clear the credentials, keep the role: several lecturers in a row is the
    // normal case.
    const created = email.trim();
    setFullName("");
    setEmail("");
    setPassword("");
    onCreated(created);
  }

  return (
    <Card className="mt-4">
      <CardHeader>
        <CardTitle>Add an account</CardTitle>
      </CardHeader>
      <CardContent>
        <p className="text-xs text-slate-500">
          Provisioned through the <code className="text-slate-400">admin-create-user</code>{" "}
          Edge Function, which holds the service key. The new account signs in with the
          password you set here, so hand it over by a route you trust.
        </p>

        {formError && (
          <div className="mt-3 rounded-md border border-alert/30 bg-alert/10 px-3 py-2 text-sm text-alert">
            {formError}
          </div>
        )}

        <form onSubmit={submit} className="mt-3 grid grid-cols-2 gap-3">
          <div>
            <label className="mb-1 block text-xs font-medium text-slate-400">
              Full name
            </label>
            <input
              value={fullName}
              onChange={(e) => setFullName(e.target.value)}
              className={FIELD_CLASS}
              placeholder="Dr. Ada Nwosu"
            />
          </div>
          <div>
            <label className="mb-1 block text-xs font-medium text-slate-400">Email</label>
            <input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className={FIELD_CLASS}
              placeholder="ada@university.test"
            />
          </div>
          <div>
            <label className="mb-1 block text-xs font-medium text-slate-400">
              Temporary password
            </label>
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className={FIELD_CLASS}
              placeholder={`At least ${MIN_PASSWORD_LENGTH} characters`}
            />
          </div>
          <div>
            <label className="mb-1 block text-xs font-medium text-slate-400">Role</label>
            <select
              value={role}
              onChange={(e) => setRole(e.target.value as UserRole)}
              className={FIELD_CLASS}
            >
              {USER_ROLES.map((option) => (
                <option key={option} value={option}>
                  {roleLabel(option)}
                </option>
              ))}
            </select>
          </div>
          <div className="col-span-2 flex items-center justify-between">
            <p className="text-[11px] text-slate-500">
              An administrator and a supervisor differ by exactly one page: this one.
            </p>
            <Button type="submit" disabled={submitting}>
              {submitting ? (
                <Loader2 size={14} className="animate-spin" />
              ) : (
                <UserPlus size={15} />
              )}
              Create account
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  );
}

/**
 * The administrator-only account roster.
 *
 * WHY THIS PAGE IS SEPARATE FROM THE REST OF THE CONSOLE — `admin` and
 * `supervisor`/`lecturer` are the same tier for everything else. Every other
 * page reads exams, submissions and incidents through `is_staff()` policies, so
 * the three staff roles share them by design and there is nothing to branch on.
 * The two things an administrator *additionally* may do live here:
 *
 *   * list every profile row (`profiles_admin_all`, admin-only) and move its
 *     `role` — the column `is_admin()` / `is_staff()` read, which
 *     `profiles_guard_role_change` refuses to let anyone below admin touch;
 *   * mint a login through `admin-create-user`;
 *   * and remove an account for good through `admin-delete-user` — the only way
 *     to delete an `auth.users` row, so a `DELETE` issued from this page would
 *     be the wrong write even though `profiles_admin_all` allows it.
 *
 * ROUTING AND AUTHORISATION ARE DIFFERENT THINGS. `RequireAdmin` (and the
 * sidebar item) decide *where a signed-in user lands*; the database decides
 * *what they may do*. Neither is sufficient alone: without the route a
 * supervisor has a nav item that leads nowhere useful, and without the policies
 * a hand-typed request would still be able to re-role accounts. Every refusal
 * this page receives is therefore rendered rather than assumed away.
 */
export function AccountRoster() {
  const { profile } = useAuth();
  const {
    accounts,
    loading,
    error,
    reload,
    changeRole,
    createAccount,
    deleteAccount,
  } = useAccounts();

  /** Selected-but-unsaved role per account id; cleared once a write lands. */
  const [draftRoles, setDraftRoles] = useState<Record<string, UserRole>>({});
  /** The change the confirm dialog is asking about. */
  const [pendingChange, setPendingChange] = useState<{
    account: ProfileRow;
    role: UserRole;
  } | null>(null);
  const [saving, setSaving] = useState(false);
  /** The account the delete confirm dialog is asking about. */
  const [pendingDelete, setPendingDelete] = useState<ProfileRow | null>(null);
  const [deleting, setDeleting] = useState(false);
  /**
   * A *refused* write, held apart from the hook's read error so a refusal is
   * not erased by the next successful refetch — and shown in the banner, which
   * stays up while it is being read, rather than the toast slot, which is for
   * confirmations.
   */
  const [writeError, setWriteError] = useState<string | null>(null);
  const [toast, setToast] = useState<{ id: number; tone: ToastTone; message: string } | null>(
    null
  );
  const toastId = useRef(0);

  function showToast(tone: ToastTone, message: string) {
    toastId.current += 1;
    setToast({ id: toastId.current, tone, message });
  }

  function selectedRole(account: ProfileRow): UserRole {
    return draftRoles[account.id] ?? account.role;
  }

  /** Roster label: the name, then the address, then a hint of the uuid. */
  function accountName(account: ProfileRow): string {
    return (
      account.full_name?.trim() ||
      account.email?.trim() ||
      `Account ${account.id.slice(0, 8)}`
    );
  }

  async function applyRoleChange() {
    if (!pendingChange) return;

    const { account, role } = pendingChange;
    setSaving(true);
    const result = await changeRole(account.id, role);
    setSaving(false);
    setPendingChange(null);

    if (!result.ok) {
      setWriteError(result.message);
      return;
    }

    setWriteError(null);
    setDraftRoles((previous) => {
      const next = { ...previous };
      delete next[account.id];
      return next;
    });
    showToast("ok", `${accountName(account)} now has the ${roleLabel(role)} role.`);
  }

  /**
   * Delete the account the dialog is asking about.
   *
   * The dialog is not decoration: this is the one irreversible action on the page,
   * so the click that performs it is a second, deliberate one. The hook does the
   * work — including asking the refetched roster to confirm it — while what this
   * handler owns is where the outcome is *said*: a refusal joins the same banner a
   * refused role change uses (it has to stay readable, not vanish in a toast),
   * and a success is a toast like every other completed write here, reporting the
   * counts `admin-delete-user` took before it deleted.
   */
  async function applyDelete() {
    if (!pendingDelete) return;

    const account = pendingDelete;
    setDeleting(true);
    const result = await deleteAccount(account.id);
    setDeleting(false);
    setPendingDelete(null);

    if (!result.ok) {
      setWriteError(result.message);
      return;
    }

    setWriteError(null);
    // The row has left the hook's roster (it was filtered out and the refetch
    // agreed), but a draft role keyed by that id would outlive it — uuids are
    // never reused, so the entry is dropped with the account.
    setDraftRoles((previous) => {
      const next = { ...previous };
      delete next[account.id];
      return next;
    });
    showToast("ok", deletionSummary(account, result.scope));
  }

  return (
    <div className="p-6">
      <div className="mb-6">
        <h1 className="text-lg font-semibold text-slate-100">Accounts</h1>
        <p className="text-sm text-slate-500">
          Every account and the role it signs in with — students take exams in the mobile
          app, staff sign in here, and administrators additionally manage accounts.
        </p>
      </div>

      {(writeError ?? error) && (
        <div className="mb-4 flex items-start justify-between gap-3 rounded-md border border-alert/30 bg-alert/10 px-3 py-2 text-sm text-alert">
          <span>{writeError ?? error}</span>
          <Button
            variant="outline"
            size="sm"
            onClick={() => {
              setWriteError(null);
              reload();
            }}
          >
            Try again
          </Button>
        </div>
      )}

      <Card>
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-border text-left text-xs text-slate-500">
              <th className="px-4 py-2.5 font-medium">Account</th>
              <th className="px-4 py-2.5 font-medium">Role</th>
              <th className="px-4 py-2.5 font-medium">Joined</th>
              <th className="px-4 py-2.5 text-right font-medium">Change role</th>
              <th className="px-4 py-2.5 text-right font-medium">Delete</th>
            </tr>
          </thead>
          <tbody>
            {loading && <TableSkeleton rows={4} columns={5} />}
            {!loading && accounts.length === 0 && (
              <tr>
                <td colSpan={5} className="px-4 py-6 text-center text-slate-500">
                  No accounts yet — create the first one below.
                </td>
              </tr>
            )}
            {accounts.map((account) => {
              const selected = selectedRole(account);
              const verdict = roleChangeVerdict(profile?.id, account, selected);
              const isSelf = account.id === profile?.id;
              const deleteVerdict = deleteAccountVerdict(profile?.id, account);
              return (
                <tr
                  key={account.id}
                  className="border-b border-border last:border-0 hover:bg-white/[0.02]"
                >
                  <td className="px-4 py-2.5">
                    <div className="flex items-center gap-2">
                      <span className="font-medium text-slate-200">
                        {accountName(account)}
                      </span>
                      {isSelf && <Badge tone="neutral">You</Badge>}
                    </div>
                    <p className="text-xs text-slate-500">{account.email}</p>
                  </td>
                  <td className="px-4 py-2.5">
                    <Badge tone={roleTone(account.role)}>{roleLabel(account.role)}</Badge>
                  </td>
                  <td className="px-4 py-2.5 text-slate-400">
                    {formatJoined(account.created_at)}
                  </td>
                  <td className="px-4 py-2.5">
                    {verdict.kind === "blocked" ? (
                      <div
                        className="flex items-center justify-end gap-1.5 text-xs text-slate-500"
                        title={verdict.reason}
                      >
                        <ShieldCheck size={14} className="shrink-0" />
                        Your own role — ask another administrator
                      </div>
                    ) : (
                      <div className="flex items-center justify-end gap-2">
                        <select
                          value={selected}
                          onChange={(e) =>
                            setDraftRoles((previous) => ({
                              ...previous,
                              [account.id]: e.target.value as UserRole,
                            }))
                          }
                          className={SELECT_CLASS}
                          title={`Change the role of ${accountName(account)}`}
                        >
                          {USER_ROLES.map((option) => (
                            <option key={option} value={option}>
                              {roleLabel(option)}
                            </option>
                          ))}
                        </select>
                        {/* Enabled as soon as a *different* role is picked: an
                            always-clickable button that silently does nothing is
                            the shape of bug this console keeps finding. */}
                        <Button
                          size="sm"
                          variant={selected === "student" ? "destructive" : "default"}
                          disabled={verdict.kind === "unchanged"}
                          onClick={() => setPendingChange({ account, role: selected })}
                        >
                          Save
                        </Button>
                      </div>
                    )}
                  </td>
                  <td className="px-4 py-2.5">
                    {/* The self-delete lock, rendered the same way the
                        self-demotion lock above is: the explanation instead of a
                        control, because this administrator *is* the page that
                        would create the account back. `deleteAccountVerdict` is
                        the one place that rule lives, and `admin-delete-user`
                        enforces its own copy of it server-side. */}
                    {deleteVerdict.kind === "blocked" ? (
                      <div
                        className="flex items-center justify-end gap-1.5 text-xs text-slate-500"
                        title={deleteVerdict.reason}
                      >
                        <ShieldCheck size={14} className="shrink-0" />
                        Your own account — ask another administrator
                      </div>
                    ) : (
                      <div className="flex justify-end">
                        <Button
                          variant="destructive"
                          size="sm"
                          title={`Delete ${accountName(account)}`}
                          onClick={() => setPendingDelete(account)}
                        >
                          <Trash2 size={14} />
                          Delete
                        </Button>
                      </div>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </Card>

      <CreateAccountCard
        createAccount={createAccount}
        onCreated={(email) => showToast("ok", `${email} can sign in now.`)}
      />

      <ConfirmDialog
        open={pendingChange !== null}
        title="Change this role?"
        confirmLabel="Change role"
        busyLabel="Saving…"
        busy={saving}
        onConfirm={() => void applyRoleChange()}
        onCancel={() => setPendingChange(null)}
      >
        {pendingChange && (
          <>
            <p>{roleChangeWarning(pendingChange.account, pendingChange.role)}</p>
            <p className="text-xs text-slate-500">
              {roleLabel(pendingChange.account.role)} → {roleLabel(pendingChange.role)}. The
              change applies the next time they sign in, and only an administrator can
              move it back.
            </p>
          </>
        )}
      </ConfirmDialog>

      <ConfirmDialog
        open={pendingDelete !== null}
        title="Delete this account?"
        confirmLabel="Delete account"
        busyLabel="Deleting…"
        busy={deleting}
        onConfirm={() => void applyDelete()}
        onCancel={() => setPendingDelete(null)}
      >
        {pendingDelete && (
          <>
            <p>{deleteAccountWarning(pendingDelete)}</p>
            <p className="text-xs text-slate-500">
              {accountName(pendingDelete)} · {pendingDelete.email}. The login goes with the
              profile, so this cannot be undone from here — the account would have to be
              created again, and the person told about it.
            </p>
          </>
        )}
      </ConfirmDialog>

      {toast && (
        <Toast
          id={toast.id}
          tone={toast.tone}
          message={toast.message}
          onDismiss={() => setToast(null)}
        />
      )}
    </div>
  );
}
