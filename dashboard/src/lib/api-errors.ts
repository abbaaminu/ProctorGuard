/**
 * Every server refusal this console can meet, turned into a sentence.
 *
 * Two families, deliberately kept apart because they have different owners:
 *
 *   * **Account faults** (`42501` from a policy, an expired JWT) are about the
 *     person signed in — they can act on them, or an administrator can.
 *   * **Deployment faults** (`42501` naming the *schema*, `PGRST205` naming a
 *     table that the API does not know) are about the project: every account
 *     fails identically and no retry by the caller can change that. Those two
 *     sentences name the file an operator has to run instead of accusing the
 *     person at the keyboard. The account-shaped wording they replace ("not
 *     allowed to read its profile. Ask an administrator to check your access.")
 *     was actively misleading while the whole project — every account, and every
 *     screen — was failing for the one missing grant.
 *
 * `useAuth` (the sign-in path) and `hooks/useAccounts` (the roster) both land
 * here, so a schema-level denial reads the same in either place.
 *
 * Nothing in this file touches React or Supabase: it is string classification,
 * which keeps the deployment/account split testable on its own.
 */

/** The shapes these calls answer with (`AuthError`, `PostgrestError`). */
export interface ApiError {
  message?: string;
  code?: string | null;
}

export const NO_API_ACCESS_MESSAGE =
  "The database has not given its API access to these tables yet, so no account can be read. " +
  "An administrator must run supabase/migrations/grant_api_roles_public_schema.sql against this project.";

export const UNKNOWN_TABLE_MESSAGE =
  "This project's API does not know the profiles table yet. " +
  "An administrator must run supabase/schema.sql against it.";

/**
 * `42501` whose message names a schema or a table — `permission denied for
 * schema public`, in practice — is a *deployment* fault, not an account one.
 * PostgREST runs every request as `anon`/`authenticated`, and those roles need
 * the ordinary Postgres privileges (USAGE on the schema, then SELECT on the
 * table) long before any policy is consulted; without them every account fails
 * identically and no re-read by this session can change that.
 *
 * The match is deliberately on Postgres's own wording, so a `42501` raised by a
 * policy — or by `profiles_guard_role_change` ("profiles.role is immutable for
 * non-admins") — still falls through to the account-specific branch.
 */
export function isSchemaOrTableDenial(error: ApiError): boolean {
  if (error.code !== "42501") return false;
  return /permission denied for (schema|table|relation|sequence|function|view)/i.test(
    error.message ?? ""
  );
}

/**
 * The other half of the same deployment fault: `PGRST205` ("Could not find the
 * table 'public.profiles' in the schema cache") means this project's API does
 * not know the table at all, so `supabase/schema.sql` was never applied to it.
 */
export function isUnknownTableError(error: ApiError): boolean {
  const message = (error.message ?? "").toLowerCase();
  return error.code === "PGRST205" || message.includes("could not find the table");
}

/**
 * PostgREST / GoTrue codes that mean "this session is not allowed to do that".
 *
 * `42501` is `insufficient_privilege` — an RLS policy (or the
 * `profiles_guard_role_change` trigger) refusing the statement. `PGRST301` /
 * `PGRST302` are PostgREST's own "the JWT expired" / "no JWT was sent" answers.
 * All three are terminal for the *account*: retrying with the same session
 * cannot succeed. A `42501` that names a schema or a table never reaches this
 * set — `isSchemaOrTableDenial` answers that one first, because it is the
 * project's fault rather than the caller's.
 */
const PERMISSION_CODES = new Set(["42501", "PGRST301", "PGRST302"]);

export function isPermissionError(code: string | null | undefined): boolean {
  return code != null && PERMISSION_CODES.has(code);
}

/**
 * Why the account roster could not be read.
 *
 * `profiles_select_own_or_staff` lets every staff role read every row, so a
 * refusal here is either the deployment fault above or a session problem —
 * never "you are not allowed to see this page", which the console decides from
 * `profile.role` before it renders the table at all.
 */
export function rosterErrorMessage(error: ApiError): string {
  if (isSchemaOrTableDenial(error)) return NO_API_ACCESS_MESSAGE;
  if (isUnknownTableError(error)) return UNKNOWN_TABLE_MESSAGE;
  if (isPermissionError(error.code)) {
    return "This account is not allowed to read the account roster. Ask an administrator to check your access.";
  }
  return (
    error.message?.trim() ||
    "Could not load the accounts. Check your connection and try again."
  );
}

/**
 * Why a role write was refused.
 *
 * `42501` is the interesting one: it is what the `profiles_guard_role_change`
 * trigger raises ("profiles.role is immutable for non-admins") and what
 * `profiles_admin_all` produces for a non-admin caller. The console only offers
 * the control to an administrator, so reaching this branch means the session
 * changed underneath the page — either way, the sentence is the same one the
 * Flutter roster shows, and it names the rule rather than leaking the SQL.
 */
export function roleChangeErrorMessage(error: ApiError): string {
  if (isSchemaOrTableDenial(error)) return NO_API_ACCESS_MESSAGE;
  if (isUnknownTableError(error)) return UNKNOWN_TABLE_MESSAGE;
  if (error.code === "42501") return "Only an administrator may change accounts.";
  if (isPermissionError(error.code)) return "Your session has expired. Sign in again.";
  return (
    error.message?.trim() || "The server refused the change. Try again."
  );
}

/**
 * Why `admin-create-user` did not create the account.
 *
 * The Edge Function answers `{ error: "<sentence for the administrator>" }` and
 * the page shows that body verbatim — it is written for this reader. The status
 * fallbacks exist for the cases where there is no body to read: a relay/fetch
 * failure (`status 0`, the request never arrived), an un-deployed function
 * (404, which is a deployment step rather than a refusal), and a refused caller.
 */
export function createAccountMessage(
  status: number,
  body: unknown,
  functionName = "admin-create-user"
): string {
  if (status === 0) {
    return "Could not reach the server. Check your connection and try again.";
  }
  const fromBody =
    body && typeof body === "object" && typeof (body as { error?: unknown }).error === "string"
      ? ((body as { error: string }).error ?? "").trim()
      : "";
  if (fromBody) return fromBody;
  if (typeof body === "string" && body.trim()) return body.trim();
  if (status === 404) {
    return `The ${functionName} function is not deployed on this project (see supabase/functions/${functionName}).`;
  }
  if (status === 401 || status === 403) {
    return "Only an administrator can create accounts.";
  }
  return `The server refused the request (${status}). Try again.`;
}

/**
 * Narrows anything `catch`ed — or returned in a `{ error }` slot — into the
 * `{ message, code }` shape above, so a `TypeError` from the fetch layer and a
 * structured `AuthError` are read the same way.
 */
function asApiError(error: unknown): ApiError {
  if (error && typeof error === "object") {
    const candidate = error as ApiError;
    return { message: candidate.message, code: candidate.code };
  }
  return { message: typeof error === "string" ? error : undefined };
}

/**
 * The browser's wording for a request that never reached the server. Chrome and
 * Safari say "Failed to fetch" / "Load failed"; Firefox says "NetworkError when
 * attempting to fetch resource."; `AuthRetryableFetchError` — supabase-js's own
 * offline case — carries "Failed to fetch" too.
 */
function isNetworkFailure(lowerMessage: string): boolean {
  return (
    lowerMessage.includes("failed to fetch") ||
    lowerMessage.includes("networkerror") ||
    lowerMessage.includes("load failed") ||
    lowerMessage.includes("network request failed")
  );
}

/**
 * Why the console could not end the session.
 *
 * Worth a sentence of its own because of what a *failed* sign-out means:
 * supabase-js clears the stored session only once its revoke call has
 * succeeded, so a refusal or a transport error leaves the session **live on the
 * device**. Painting the login form over it is the one thing that must not
 * happen here — it is the trap `useAuth` already documents for a profile read —
 * so the console stays where it is and says so, and the same button retries.
 * (An expired token is not this case: GoTrue's 401/403/404 on the revoke
 * endpoint means the session is already gone, and the SDK drops it silently.)
 */
export function signOutErrorMessage(error: unknown): string {
  const { message = "", code } = asApiError(error);
  if (isNetworkFailure(message.toLowerCase())) {
    return "Could not reach the server to sign out, so this session is still active. Check your connection and try again.";
  }
  if (isPermissionError(code)) {
    return "Your session had already expired. Sign in again to continue.";
  }
  return message
    ? `Could not sign out: ${message}`
    : "Could not sign out, so this session is still active. Check your connection and try again.";
}
