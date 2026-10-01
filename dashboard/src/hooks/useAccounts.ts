import { useCallback, useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import {
  createAccountMessage,
  deleteAccountMessage,
  roleChangeErrorMessage,
  rosterErrorMessage,
} from "@/lib/api-errors";
import type { RemovalScope } from "@/lib/roles";
import type { ProfileRow, UserRole } from "@/types/database";

/**
 * The Edge Function that is the only supported way to mint an account that is
 * not a student (`supabase/functions/admin-create-user`). `auth.users` belongs
 * to Supabase Auth and `profiles_insert_self_student` accepts nothing but
 * `role='student'`, so the service_role key has to do both writes server-side.
 */
export const CREATE_ACCOUNT_FUNCTION = "admin-create-user";

/**
 * The Edge Function that is the only supported way to remove an account for good
 * (`supabase/functions/admin-delete-user`).
 *
 * Deleting the *row* is not deleting the account: `auth.users` belongs to
 * Supabase Auth, so a PostgREST `DELETE` on `profiles` — which is what
 * `profiles_admin_all` would happily allow — leaves a login that still signs in
 * but has no profile row. `schema.sql` says so over that very policy. So the
 * browser never deletes a row itself: it asks this function, which removes the
 * login with the service key and lets `on delete cascade` take the row (and the
 * exams, submissions and incident logs hanging off it) with it.
 */
export const DELETE_ACCOUNT_FUNCTION = "admin-delete-user";

/**
 * Supabase Auth's default minimum, mirrored by the Edge Function so the form's
 * message and the API's agree.
 */
export const MIN_PASSWORD_LENGTH = 6;

/** Outcome of a roster write. A refusal always carries its sentence. */
export type AccountWriteResult = { ok: true } | { ok: false; message: string };

/**
 * Outcome of a deletion. Separate from `AccountWriteResult` because a success
 * carries more than "ok": the counts `admin-delete-user` took immediately before
 * the write, which are what the confirmation sentence reports
 * (`deletionSummary`).
 */
export type DeleteAccountResult =
  | { ok: true; scope: RemovalScope }
  | { ok: false; message: string };

export interface NewAccountInput {
  email: string;
  /** Never trimmed: spaces can be part of a password, and the server hashes it verbatim. */
  password: string;
  fullName: string;
  role: UserRole;
}

/**
 * Reads the `profiles.role` values this console can see, and writes them when
 * the caller is an administrator.
 *
 * WHAT AUTHORISES EACH HALF — deliberately not the same thing:
 *
 *   * the read is allowed for every *staff* role (`profiles_select_own_or_staff`
 *     is `id = auth.uid() or is_staff()`), which is why supervisors see real
 *     names in the monitor and the audit trail;
 *   * the write is admin-only twice over — `profiles_admin_all` is
 *     `to authenticated using (is_admin())`, and the
 *     `profiles_guard_role_change` trigger raises `42501` for anyone below
 *     admin even if a policy let the row through;
 *   * creating an account cannot be a PostgREST call at all, hence the Edge
 *     Function.
 *
 * The page gates itself on `profile.role` for *navigation*, but it never treats
 * that as authorisation: every refusal the server sends is rendered, so a
 * console that somehow reached here as a supervisor reports the refusal instead
 * of showing a change that did not happen.
 */
export function useAccounts() {
  const [accounts, setAccounts] = useState<ProfileRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  /**
   * `quiet` is for the refetch a realtime event triggers: the data is being
   * corrected, not loaded for the first time, and swapping the table for
   * skeleton rows on every write would make the roster flicker while an
   * administrator is reading it.
   */
  const load = useCallback(
    async ({
      quiet = false,
    }: { quiet?: boolean } = {}): Promise<ProfileRow[] | null> => {
      if (!quiet) setLoading(true);

      const { data, error: loadError } = await supabase
        .from("profiles")
        .select("*")
        // Oldest first, like the Flutter roster: the seeded/bootstrap admin — the
        // account an administrator looks for — stays at the top.
        .order("created_at", { ascending: true });

      if (loadError) {
        setError(rosterErrorMessage(loadError));
        setLoading(false);
        return null;
      }

      const rows = (data as ProfileRow[] | null) ?? [];
      setError(null);
      setAccounts(rows);
      setLoading(false);

      // The rows, not just the state: `deleteAccount` takes the *refetched* roster
      // as its verdict on a 200 — the same reason `changeRole` asks for the written
      // row back instead of trusting a status code.
      return rows;
    },
    []
  );

  useEffect(() => {
    let active = true;
    const run = (quiet: boolean) => {
      if (active) void load({ quiet });
    };

    run(false);

    // Another administrator's appointment (or a signup) has to appear here
    // without a reload, and a role write performed by a second console is
    // exactly when a stale roster would be believed.
    const channel = supabase
      .channel("accounts_roster")
      .on("postgres_changes", { event: "*", schema: "public", table: "profiles" }, () =>
        run(true)
      )
      .subscribe();

    return () => {
      active = false;
      supabase.removeChannel(channel);
    };
  }, [load]);

  const reload = useCallback(() => {
    void load();
  }, [load]);

  /**
   * Move one account onto another role.
   *
   * `.select("id, role")` is load-bearing. `profiles_admin_all` filters rows a
   * non-admin caller cannot touch, and a policy-filtered UPDATE matches zero
   * rows **without raising** — PostgREST reports success. Asking for the written
   * row back is the only way to tell a saved role apart from a write that
   * silently did nothing (`useResetSubmission` and `ExamManager` carry the same
   * caveat).
   */
  const changeRole = useCallback(
    async (accountId: string, role: UserRole): Promise<AccountWriteResult> => {
      const { data, error: writeError } = await supabase
        .from("profiles")
        .update({ role })
        .eq("id", accountId)
        .select("id, role");

      if (writeError) return { ok: false, message: roleChangeErrorMessage(writeError) };
      if (!data || data.length === 0) {
        return {
          ok: false,
          message:
            "The server changed nothing — that account may have been deleted. Reload the list and try again.",
        };
      }

      // Patch the row in place so the badge follows the write immediately; the
      // realtime event that follows refetches the same value a moment later.
      setAccounts((previous) =>
        previous.map((account) =>
          account.id === accountId ? { ...account, role } : account
        )
      );
      return { ok: true };
    },
    []
  );

  const createAccount = useCallback(
    async (input: NewAccountInput): Promise<AccountWriteResult> => {
      const { data, error: invokeError } = await invokeCreateAccount(input);

      if (invokeError) {
        return {
          ok: false,
          message: await describeFunctionFailure(invokeError, createAccountMessage),
        };
      }

      // A 200 carrying `{ error }` (a proxy in front of the function, or an
      // older deployment) must not be mistaken for a created account.
      if (
        data &&
        typeof data === "object" &&
        typeof (data as { error?: unknown }).error === "string"
      ) {
        return { ok: false, message: createAccountMessage(200, data) };
      }

      // The roster is the only proof the account exists, so refetch it rather
      // than insert a local row the server might not agree with.
      await load({ quiet: true });
      return { ok: true };
    },
    [load]
  );

  /**
   * Remove one account for good — the login *and* the row.
   *
   * The browser deliberately issues no `DELETE` of its own: `profiles_admin_all`
   * allows one, and it would remove only the profile, leaving a login that still
   * signs in to nothing. So the write goes to the `admin-delete-user` Edge
   * Function, which holds the service key and removes the `auth.users` row, with
   * the profile (and the exams, submissions and incident logs hanging off it)
   * following through `on delete cascade`.
   *
   * Nothing about the answer is taken on trust. A 200 carrying `{ error }` is a
   * refusal, not a deletion — a proxy in front of the function, or an older
   * deployment, can produce one. And as in `changeRole`, the *rows* are the
   * verdict: the roster is refetched quietly and a row that is still listed is
   * reported as a failure, because an administrator told an account was deleted
   * must not find it in the table on the next paint.
   */
  const deleteAccount = useCallback(
    async (accountId: string): Promise<DeleteAccountResult> => {
      const { data, error: invokeError } = await invokeDeleteAccount(accountId);

      if (invokeError) {
        return {
          ok: false,
          message: await describeFunctionFailure(invokeError, deleteAccountMessage),
        };
      }
      if (
        data &&
        typeof data === "object" &&
        typeof (data as { error?: unknown }).error === "string"
      ) {
        return { ok: false, message: deleteAccountMessage(200, data) };
      }

      // Drop the row on the strength of that 200 — the server has just said the
      // login is gone — and then let the quiet refetch settle it, which also puts
      // the row back if the confirmation disagrees with the optimistic removal.
      setAccounts((previous) =>
        previous.filter((account) => account.id !== accountId)
      );

      const rows = await load({ quiet: true });
      if (rows?.some((account) => account.id === accountId)) {
        return {
          ok: false,
          message:
            "The server said the account was deleted, but it is still listed. Reload the list and try again.",
        };
      }

      return { ok: true, scope: removedCounts(data) };
    },
    [load]
  );

  return {
    accounts,
    loading,
    error,
    reload,
    changeRole,
    createAccount,
    deleteAccount,
  };
}

/** Split out so the two call sites in `createAccount` stay readable. */
function invokeCreateAccount(input: NewAccountInput) {
  return supabase.functions.invoke(CREATE_ACCOUNT_FUNCTION, {
    body: {
      email: input.email.trim(),
      password: input.password,
      full_name: input.fullName.trim(),
      role: input.role,
    },
  });
}

/**
 * The delete call, in one place: the function name and the request body.
 *
 * `{ id }` is the shape `admin-delete-user` documents; it also accepts
 * `account_id` / `accountId`, but a caller with no reason to vary should not.
 */
function invokeDeleteAccount(accountId: string) {
  return supabase.functions.invoke(DELETE_ACCOUNT_FUNCTION, {
    body: { id: accountId },
  });
}

/**
 * The `removed` counts of a delete response, and zeros for a body that carries
 * none.
 *
 * Zeros are the honest fallback rather than a guess: a deployment that did not
 * report counts did not *say* how much went with the account, so the confirmation
 * sentence reports nothing extra instead of inventing a number about data that is
 * already gone.
 */
function removedCounts(data: unknown): RemovalScope {
  const removed = (
    data as { removed?: { exams?: unknown; submissions?: unknown } } | null
  )?.removed;

  return {
    exams: typeof removed?.exams === "number" ? removed.exams : 0,
    submissions:
      typeof removed?.submissions === "number" ? removed.submissions : 0,
  };
}

/**
 * Turns a failed `functions.invoke` into the sentence the function wrote.
 *
 * supabase-js answers a non-2xx with an error object carrying the `Response` in
 * `context`, and answers a request that never arrived with `FunctionsFetchError`
 * — whose `context` is the failed *fetch* (`TypeError: Failed to fetch`), not a
 * response. Both shapes are read here, so the page never has to know which one
 * happened. The body is read from a `clone()` because a response body can only
 * be consumed once.
 *
 * `describe` is the function-specific reader (`createAccountMessage` /
 * `deleteAccountMessage`), which is where the deployment-specific sentence lives:
 * this helper knows the transport, not which function was called.
 */
async function describeFunctionFailure(
  error: unknown,
  describe: (status: number, body: unknown) => string
): Promise<string> {
  const context = (error as { context?: unknown } | null)?.context;

  // Only a `Response` has a status and a body to read. Both other shapes mean
  // the request never arrived — `FunctionsFetchError` puts the *transport* error
  // in `context` (a `TypeError`, so it has neither `clone()` nor `status`) and a
  // bare throw carries nothing but a message. Reading a status off those would
  // print "refused the request (undefined)" at someone who is simply offline,
  // so they are the status-0 case that sentence is written for.
  if (isResponseLike(context)) {
    let body: unknown = null;
    try {
      body = await context.clone().json();
    } catch {
      try {
        body = await context.clone().text();
      } catch {
        body = null;
      }
    }
    return describe(context.status, body);
  }

  const message = (error as { message?: string } | null)?.message;
  return describe(0, message);
}

/** A real `Response`, not the failed fetch `FunctionsFetchError` stores. */
function isResponseLike(value: unknown): value is Response {
  const candidate = value as Response | null | undefined;
  return (
    typeof candidate?.clone === "function" && typeof candidate.status === "number"
  );
}
