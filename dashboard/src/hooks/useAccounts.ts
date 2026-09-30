import { useCallback, useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import {
  createAccountMessage,
  roleChangeErrorMessage,
  rosterErrorMessage,
} from "@/lib/api-errors";
import type { ProfileRow, UserRole } from "@/types/database";

/**
 * The Edge Function that is the only supported way to mint an account that is
 * not a student (`supabase/functions/admin-create-user`). `auth.users` belongs
 * to Supabase Auth and `profiles_insert_self_student` accepts nothing but
 * `role='student'`, so the service_role key has to do both writes server-side.
 */
export const CREATE_ACCOUNT_FUNCTION = "admin-create-user";

/**
 * Supabase Auth's default minimum, mirrored by the Edge Function so the form's
 * message and the API's agree.
 */
export const MIN_PASSWORD_LENGTH = 6;

/** Outcome of a roster write. A refusal always carries its sentence. */
export type AccountWriteResult = { ok: true } | { ok: false; message: string };

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
  const load = useCallback(async ({ quiet = false }: { quiet?: boolean } = {}) => {
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
      return;
    }

    setError(null);
    setAccounts((data as ProfileRow[] | null) ?? []);
    setLoading(false);
  }, []);

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
        return { ok: false, message: await describeFunctionFailure(invokeError) };
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

  return { accounts, loading, error, reload, changeRole, createAccount };
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
 * Turns a failed `functions.invoke` into the sentence the function wrote.
 *
 * supabase-js answers a non-2xx with an error object carrying the `Response` in
 * `context`, and throws (`FunctionsFetchError`, or a plain network error) only
 * when no response arrived at all — both shapes are read here, so the page
 * never has to know which one happened. The body is read from a `clone()`
 * because a response body can only be consumed once.
 */
async function describeFunctionFailure(error: unknown): Promise<string> {
  const context = (error as { context?: Response } | null)?.context;
  if (context) {
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
    return createAccountMessage(context.status, body);
  }

  const message = (error as { message?: string } | null)?.message;
  return createAccountMessage(0, message);
}
