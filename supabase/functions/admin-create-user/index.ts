// Supabase Edge Function: `admin-create-user`
//
// The only supported way to mint an account that is not a student.
// `profiles_insert_self_student` (schema.sql) deliberately lets a client create
// nothing but `role='student'`, so provisioning a lecturer, a supervisor or a
// second admin has to happen server-side, where the service_role key can bypass
// RLS *and* write the matching `auth.users` row. That is this function's whole
// job: verify the caller, create the auth account, write its role row, and never
// leave one without the other.
//
// Request  (POST, `Authorization: Bearer <the caller's access token>`):
//   { "email": "ada@uni.test", "password": "Temp123!", "full_name": "Dr. Ada
//     Nwosu", "role": "lecturer" }
//   `fullName` is accepted as a spelling of `full_name` — see `stringField`.
//
// Response 200: { "id": "<uuid>", "email": ..., "full_name": ..., "role": ... }
// Response 4xx/5xx: { "error": "<message written for the administrator>" }
//
// WHERE THE ROLES LIVE — `public.profiles.role`, typed by the `public.user_role`
// enum. There is no separate `user_roles` table in this schema: the migration
// whose name mentions roles (supabase/migrations/add_user_roles_and_profiles.sql)
// is the one that introduced the *enum* and renamed `users` -> `profiles`, and
// one row per account is exactly what keeps `profiles.role` the single column
// every policy in schema.sql asks `is_admin()` / `is_staff()` about. So the role
// is written to that row here rather than duplicated into a second table.
//
// Every requirement this function is expected to meet is visible in one read:
//   * CORS: CORS_HEADERS answers the OPTIONS preflight (origin, headers, methods).
//   * Clients: `createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
//     auth: { persistSession: false } })` — no session is ever kept, because no
//     request here is the service account signing itself in.
//   * Auth: the Bearer token is verified with `auth.getUser(token)`, which asks
//     the Auth server — a hand-forged JWT cannot get past it (401 otherwise).
//   * RBAC: the caller's own role row is read back under RLS and checked against
//     CREATOR_ROLES (403 otherwise).
//   * Creation: `auth.admin.createUser()`, then the role row, rolled back
//     together if the second half fails.
//
// The Flutter admin dashboard (`mobile/lib/features/admin/...`) is the client;
// `mobile/test/schema_contract_test.dart` pins the two halves of this contract
// together so a rename on one side fails the suite instead of at runtime.
//
// Deploy with `supabase functions deploy admin-create-user` — JWT verification
// stays ON (the default). It is not the authorization check, though: any signed
// in user has a valid JWT, so the creator-role check below is what actually
// gates the account creation.

import { createClient } from "npm:@supabase/supabase-js@2";

/** The `public.user_role` enum, in its declaration order (see schema.sql). */
const ROLES = ["admin", "lecturer", "supervisor", "student"] as const;
type Role = (typeof ROLES)[number];

/**
 * The minimum Supabase Auth will accept by default. Kept in step with the
 * client-side validator so the dashboard's message and the API's agree.
 */
const MIN_PASSWORD_LENGTH = 6;

/**
 * The roles allowed to call this function.
 *
 * `admin` only, deliberately. `profiles_admin_all` (schema.sql) is admin-only and
 * the admin dashboard is the only screen in either app that manages accounts, so
 * a supervisor calling this function would be the one path by which an invigilator
 * could mint an account — including a second admin — which is exactly the tier
 * the schema separates. If a product decision ever widens it, add the role here
 * *and* reword the 403 below together; the Flutter suite mirrors that sentence.
 */
const CREATOR_ROLES: readonly Role[] = ["admin"];

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
 * Exists for `full_name` / `fullName`: the column and the Flutter client spell it
 * `full_name`, while a hand-written request or a JavaScript client reaching for
 * camelCase spells it `fullName`. Both name the same field, so both are accepted
 * rather than answering 400 over a spelling this function could have understood.
 * (The password is read directly, never through here: its spaces are its own.)
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
  // The dashboard (a browser) preflights any cross-origin POST; the mobile app
  // does not, but answering costs nothing and keeps one function usable from
  // both apps.
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

  // Two clients on purpose. `caller` carries the anon key plus the caller's JWT,
  // so everything it does is filtered by RLS exactly as it would be in the apps
  // — that is what makes the role check trustworthy. `admin` carries the
  // service_role key and is only touched after that check has passed.
  const caller = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Verifies the token's signature and expiry against the Auth server; a
  // hand-forged JWT cannot get past this. `caller.auth.getUser(token)` and
  // `admin.auth.getUser(token)` are the same Auth-server call — the anon client
  // does it because the role read that follows then stays RLS-filtered too.
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
  // A signed-in student, lecturer or supervisor lands here, and so does an
  // account whose `profiles` row has not been written yet: this schema has no
  // on-signup trigger, so a row is written once — by the client at signup (via
  // `profiles_insert_self_student`) or by this function for accounts it creates.
  const callerRole = callerProfile?.role as Role | undefined;
  if (!callerRole || !CREATOR_ROLES.includes(callerRole)) {
    return fail("Only an administrator can create accounts.", 403);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return fail("Expected a JSON body.");
  }

  // `email` and `full_name` go through `stringField` (which also accepts the
  // camelCase `fullName`); the password is taken verbatim, since leading or
  // trailing spaces are part of it and trimming would silently change it.
  const email = stringField(payload, "email").toLowerCase();
  const password = typeof payload.password === "string" ? payload.password : "";
  const fullName = stringField(payload, "full_name", "fullName");
  const role = payload.role as Role;

  // Validated here as well as on the client: the function is reachable by
  // anyone holding an admin token, so it cannot assume the form was used.
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return fail("Enter a valid email address.");
  }
  if (password.length < MIN_PASSWORD_LENGTH) {
    return fail(
      `The temporary password must be at least ${MIN_PASSWORD_LENGTH} characters.`,
    );
  }
  if (fullName.length === 0) {
    return fail("Enter the person's full name.");
  }
  if (!ROLES.includes(role)) {
    return fail(`Unknown role. Use one of: ${ROLES.join(", ")}.`);
  }

  const { data: created, error: createError } = await admin.auth.admin
    .createUser({
      email,
      password,
      // Confirmed up front: the administrator hands this temporary password
      // over directly, so an email round-trip would only delay the account.
      email_confirm: true,
      user_metadata: { name: fullName, created_by: callerData.user.id },
    });

  if (createError || !created.user) {
    const message = createError?.message ?? "Could not create the account.";
    const duplicate = /already|registered|exists/i.test(message);
    return fail(
      duplicate ? `${email} already has an account.` : message,
      duplicate ? 409 : 400,
    );
  }

  // The new account's role row — the "user roles" write. It goes to
  // `public.profiles` (one row per account, `role` typed by the `public.user_role`
  // enum), not to a second roles table, so `profiles.role` stays the single value
  // every policy in schema.sql trusts. Written with the service_role key:
  // `profiles_insert_self_student` would reject any role but 'student'.
  const { error: insertError } = await admin.from("profiles").insert({
    id: created.user.id,
    role,
    full_name: fullName,
    email,
  });

  if (insertError) {
    // An auth account without a profile row would strand its owner on the
    // gate's error screen, so roll it back rather than leave a half-created
    // account behind. If even the rollback fails, say so — that row can only be
    // removed by hand from the Authentication tab.
    const { error: rollbackError } = await admin.auth.admin.deleteUser(
      created.user.id,
    );
    const suffix = rollbackError
      ? ` The half-created account could not be removed either (${rollbackError.message}) — delete it under Authentication → Users.`
      : " The account was rolled back, so nothing was created.";
    return fail(
      `Could not write the profile row: ${insertError.message}${suffix}`,
      500,
    );
  }

  // 200, with the created account — the same four keys the Flutter
  // `ManagedAccount.fromMap` reads back.
  return json({ id: created.user.id, email, full_name: fullName, role });
});
