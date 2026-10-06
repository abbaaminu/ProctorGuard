// =====================================================================
// Edge Function: `admin-reset-password`
// =====================================================================
// Sets a new password on an existing account. This is what the admin
// dashboard's roster calls: this deployment has no "forgot password" mail
// flow, so minting a fresh temporary password and handing it over is how a
// locked-out person gets back in.
//
// WHY IT HAS TO BE A FUNCTION
//   `auth.users` belongs to Supabase Auth, not to `public`. A signed-in caller
//   can change *their own* password through GoTrue, but nothing in PostgREST
//   touches another account's credentials, and `auth.admin.updateUserById`
//   needs the service_role key — which must never ship inside the mobile app.
//   So the write happens here, for the same reason `admin-create-user` exists.
//
//   Deploy with:  supabase functions deploy admin-reset-password
//   (JWT verification stays ON — the platform default. It is not the
//   authorization check, though: every signed-in user holds a valid JWT, so
//   the role read below is what actually gates the write; the JWT only
//   establishes *who* is asking.)
//
// REQUEST  POST, `Authorization: Bearer <access token>`
//   { "id": "<auth.users.id uuid>", "password": "<the new password>" }
//   `userId` / `accountId` are accepted as spellings of `id`.
//
// RESPONSE 200
//   { "id": "...", "email": "...", "full_name": "...", "role": "..." }
// RESPONSE 4xx / 5xx
//   { "error": "a sentence written for the administrator" }
//
// WHO MAY CALL IT
//   Admins only (`RESETTER_ROLES`). The check is on the *server*: the JWT is
//   verified against the Auth server, the caller's own `profiles.role` is read
//   back through a client carrying the caller's token (so RLS filters it,
//   exactly as in the app), and only then is the service_role client used. A
//   student, lecturer or supervisor who calls this gets 403 and no write — the
//   same two-key dance as `admin-create-user`, for the same reason: an
//   authorization decision the caller controls is not a decision.
//
//   An admin *may* reset their own password here. The self-checks in the other
//   two admin paths (`admin-delete-user` refuses to delete the caller; the
//   `guard_user_role_change()` trigger refuses a self-demotion) exist because
//   those actions can remove the caller's only route back in. A password
//   change cannot lock anybody out of a screen, and there is no self-service
//   reset to fall back on, so no self-check applies.
//
// NOT WRITTEN TO `public.session_reset_logs`
//   That table (schema.sql §7) records *attempt* resets — a supervisor clearing
//   a student's exam — because that action destroys proctoring evidence.
//   Changing a password destroys nothing, and Supabase Auth keeps its own
//   record against `auth.users`, so there is deliberately no row for it.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type Role = "admin" | "lecturer" | "supervisor" | "student";

/**
 * Supabase Auth's own floor on password length, doubled as the client-side
 * validator so the admin form's message and this API's agree.
 */
const MIN_PASSWORD_LENGTH = 6;

/**
 * The roles allowed to set somebody else's password.
 *
 * `admin` only, deliberately: `profiles_admin_all` is admin-only, and the admin
 * console is the account-management screen. A supervisor resetting *attempts*
 * is a proctoring action (`is_exam_supervisor()`); resetting a *password* is an
 * identity action, and the schema keeps those in different tiers. If a product
 * decision ever widens this, add the role here *and* reword the 403 below
 * together — the Flutter suite mirrors that sentence.
 */
const RESETTER_ROLES: readonly Role[] = ["admin"];

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

/** Every failure answers `{ error }` — the shape the Flutter client reads. */
function fail(message: string, status = 400): Response {
  return json({ error: message }, status);
}

/**
 * The first usable string among `keys`, trimmed — `""` when the body has none.
 *
 * Exists for `id` / `userId` / `accountId`: the roster's own vocabulary is the
 * column name, while a hand-written request or a JavaScript client reaching for
 * camelCase spells it differently. Both name the same field, so both are
 * accepted rather than answering 400 over a spelling this function could have
 * understood. (The password is read directly, never through here: its spaces
 * are its own.)
 */
function stringField(
  payload: Record<string, unknown>,
  ...keys: string[]
): string {
  for (const key of keys) {
    const value = payload[key];
    if (typeof value === "string") return value.trim();
  }
  return "";
}

Deno.serve(async (request: Request): Promise<Response> => {
  // Browser clients preflight cross-origin POSTs; answering also keeps this
  // function usable from every supported client.
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (request.method !== "POST") {
    return fail("Use POST.", 405);
  }

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ??
    Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) {
    return fail(
      "This function is misconfigured: SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY must all be set.",
      500,
    );
  }

  const token = (request.headers.get("Authorization") ?? "")
    .replace(/^Bearer\s+/i, "")
    .trim();
  if (!token) {
    return fail("Sign in as an administrator first.", 401);
  }

  // Two clients on purpose, exactly as in `admin-create-user`: `caller` carries
  // the anon key plus the caller's JWT, so everything it does is filtered by RLS
  // exactly as it would be in the apps — that is what makes the role check
  // trustworthy. `admin` carries the service_role key and is only touched after
  // that check has passed.
  const caller = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Verifies the token's signature and expiry against the Auth server; a
  // hand-forged JWT cannot get past this.
  const { data: callerData, error: callerError } = await caller.auth.getUser(
    token,
  );
  if (callerError || !callerData.user) {
    return fail("That session is no longer valid — sign in again.", 401);
  }

  // `profiles_select_own_or_staff` lets the caller read their own row, so this
  // works with the anon key and no service_role privileges — the role that
  // decides the answer cannot come from the privileged client.
  const { data: callerProfile, error: callerProfileError } = await caller
    .from("profiles")
    .select("role")
    .eq("id", callerData.user.id)
    .maybeSingle();
  if (callerProfileError) {
    return fail(
      `Could not check your role: ${callerProfileError.message}`,
      500,
    );
  }
  const callerRole = callerProfile?.role as Role | undefined;
  if (!callerRole || !RESETTER_ROLES.includes(callerRole)) {
    return fail("Only an administrator can reset passwords.", 403);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return fail("Expected a JSON body.");
  }

  const id = stringField(payload, "id", "userId", "accountId");
  // Checked before the id reaches Auth: `updateUserById` answers a bare "user
  // not found" for anything it cannot parse, which would read like a missing
  // account rather than a malformed request.
  if (!UUID_PATTERN.test(id)) {
    return fail("Expected the account's id (a uuid).");
  }

  // Read verbatim, never through `stringField`: leading or trailing spaces are
  // part of the password, and trimming would silently set a different one than
  // the administrator typed.
  const password = typeof payload.password === "string"
    ? payload.password
    : "";
  if (password.length < MIN_PASSWORD_LENGTH) {
    return fail(
      `The new password must be at least ${MIN_PASSWORD_LENGTH} characters.`,
    );
  }

  // The `profiles` row is read for the identity this function reports back —
  // the roster matches on `id`, and answering with the row the console knows is
  // what lets it say *which* account was changed. Missing is not fatal: the
  // login exists in `auth.users` even when its profile row does not (this
  // schema has no on-signup trigger).
  const { data: profile, error: profileError } = await admin
    .from("profiles")
    .select("id, email, full_name, role")
    .eq("id", id)
    .maybeSingle();
  if (profileError) {
    return fail(`Could not read that account: ${profileError.message}`, 500);
  }

  const { error: updateError } = await admin.auth.admin.updateUserById(id, {
    password,
  });
  if (updateError) {
    // A 404 means the login is gone: the roster is showing a stale row (the
    // account was deleted in another session, say), which is a different
    // answer from "the server refused".
    const missing = updateError.status === 404 ||
      /user\s+not\s+found/i.test(updateError.message);
    return missing
      ? fail("That account no longer exists — reload the list and try again.", 404)
      : fail(`Could not set the new password: ${updateError.message}`, 500);
  }

  // The name and address come from the profile row when there is one, and from
  // Auth itself otherwise, so the response always identifies the account the
  // password now belongs to.
  let email = profile?.email as string | undefined;
  if (!email) {
    const { data: authUser } = await admin.auth.admin.getUserById(id);
    email = authUser?.user?.email ?? undefined;
  }

  return json({
    id,
    email: email ?? null,
    full_name: (profile?.full_name as string | undefined) ?? null,
    role: (profile?.role as string | undefined) ?? null,
  });
});
