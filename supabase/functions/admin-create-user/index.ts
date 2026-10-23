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
//     Nwosu", "role": "lecturer", "faculty": "Science", "department": "Computer
//     Science", "level": null }
//   `fullName` is accepted as a spelling of `full_name` — see `stringField`. The
//   three academic keys are optional and simply become that profile's columns.
//
//   Bulk roster import — the same endpoint, one POST per page of a CSV:
//   { "students": [ { "email": ..., "full_name": ..., "faculty": ...,
//                     "department": ..., "level": ... }, ... ] }
//   Every row becomes a `role='student'` account with a generated temporary
//   password; the body cannot ask for another role. At most
//   `MAX_BULK_STUDENTS` rows per call.
//
// Response 200: { "id": "<uuid>", "email": ..., "full_name": ..., "role": ...,
//                 "faculty"?: ..., "department"?: ..., "level"?: ... }
//   The academic keys are present only when the profile row carries them; a
//   Flutter client from before them ignores the extra keys.
//   Bulk: { "created": [ { ...row, "temporary_password": ... } ],
//           "failed":  [ { "email": ..., "error": ... } ] }
//   A bulk call answers 200 even when rows failed: each row's reason travels in
//   `failed` so the widget can list it beside the rows that were created.
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
// The Flutter admin console (`mobile/lib/features/admin/...`) is the client;
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
 * client-side validator so the admin form's message and the API's agree.
 */
const MIN_PASSWORD_LENGTH = 6;

/**
 * The roles allowed to call this function.
 *
 * `admin` only, deliberately. `profiles_admin_all` (schema.sql) is admin-only and
 * the Flutter admin console is the account-management screen, so
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

/**
 * The academic metadata a `profiles` row may carry, in the order the console
 * offers it: which faculty, which department, which level.
 *
 * They are free text in the schema (see the comment on `public.profiles`), and
 * here they are simply forwarded: a lecturer's profile says "Science / Computer
 * Science", a student's says the same three labels, and `exams_select` compares
 * them. Nothing validates the spelling, because the labels are the institution's
 * own and a bulk CSV may well know them better than this function does.
 */
const ACADEMIC_FIELDS = ["faculty", "department", "level"] as const;

/**
 * The rows of one bulk request. Pinned to the Flutter client's
 * `AdminUserRepository.maxStudentPageSize` by
 * `mobile/test/schema_contract_test.dart`: a page the client builds has to be a
 * page this function accepts.
 */
const MAX_BULK_STUDENTS = 50;

/** The academic keys of `payload` that are present and non-empty. */
function academicFields(
  payload: Record<string, unknown>,
): Record<string, string> {
  const academic: Record<string, string> = {};
  for (const field of ACADEMIC_FIELDS) {
    const value = stringField(payload, field);
    // Omitted rather than sent as `null`: the columns are nullable and an empty
    // cell in a CSV means "not stated", which is what NULL already says.
    if (value.length > 0) academic[field] = value;
  }
  return academic;
}

/**
 * A password for an account nobody will be asked to type one for: `Pg-`, twelve
 * base64url characters, then `9!`.
 *
 * The fixed tail is what guarantees a digit and a symbol, so the value still
 * satisfies a project that has tightened the Auth password policy beyond the
 * default `MIN_PASSWORD_LENGTH`. It is handed back in the response for the
 * administrator to distribute, which is the only way an imported student ever
 * learns it.
 */
function temporaryPassword(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(9));
  const body = btoa(String.fromCharCode(...bytes))
    .replace(/[+/=]/g, "")
    .slice(0, 12);
  return `Pg-${body}9!`;
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

  /** The academic columns of one request, as the profile row stores them. */
  type Academic = { faculty?: string; department?: string; level?: string };

  /** A profile row as this function answers it. */
  type AccountRow = {
    id: string;
    email: string;
    full_name: string;
    role: Role;
    faculty?: string;
    department?: string;
    level?: string;
  };

  type Created = { account: AccountRow; password: string };
  type Refused = { refused: true; status: number; error: string };

  /**
   * Creates one account: the `auth.users` row first, then the `profiles` row
   * every policy in schema.sql reads.
   *
   * Both or neither. The profile row cannot outlive its auth user (its `id`
   * references `auth.users`) and an auth user without a profile row would strand
   * its owner on the gate's error screen — so a failed insert deletes the user
   * again and says so if even that fails.
   *
   * Written with the service_role client: `profiles_insert_self_student` would
   * reject any role but 'student'.
   */
  async function createOne(input: {
    email: string;
    password: string;
    fullName: string;
    role: Role;
    academic: Academic;
  }): Promise<Created | Refused> {
    const { data: created, error: createError } = await admin.auth.admin
      .createUser({
        email: input.email,
        password: input.password,
        // Confirmed up front: the administrator hands this temporary password
        // over directly, so an email round-trip would only delay the account.
        email_confirm: true,
        user_metadata: {
          name: input.fullName,
          created_by: callerData.user!.id,
        },
      });

    if (createError || !created.user) {
      const message = createError?.message ?? "Could not create the account.";
      const duplicate = /already|registered|exists/i.test(message);
      return {
        refused: true,
        status: duplicate ? 409 : 400,
        error: duplicate ? `${input.email} already has an account.` : message,
      };
    }

    const { error: insertError } = await admin.from("profiles").insert({
      id: created.user.id,
      role: input.role,
      full_name: input.fullName,
      email: input.email,
      // Absent keys stay absent: the columns are nullable, and NULL is exactly
      // "no academic metadata stated", which is also what the scoped policies in
      // schema.sql read as "no narrowing".
      ...input.academic,
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
      return {
        refused: true,
        status: 500,
        error: `Could not write the profile row: ${insertError.message}${suffix}`,
      };
    }

    return {
      account: {
        id: created.user.id,
        email: input.email,
        full_name: input.fullName,
        role: input.role,
        ...input.academic,
      },
      password: input.password,
    };
  }

  /**
   * The bulk branch: `{ "students": [ ... ] }` — one POST for a page of a
   * roster CSV (the Flutter `BulkStudentUploadWidget`).
   *
   * Every row is a **student**, whatever the body says: this is the class-list
   * import, and an upload cannot be the way a lecturer account is minted. Each
   * row is created on its own, so one duplicate e-mail does not stop the class —
   * it comes back in `failed` with the same sentence a single creation would
   * have answered, for the administrator to correct and re-upload.
   */
  async function createMany(
    rows: unknown[],
  ): Promise<Response> {
    if (rows.length === 0) {
      return fail("The upload was empty.");
    }
    if (rows.length > MAX_BULK_STUDENTS) {
      return fail(`Send at most ${MAX_BULK_STUDENTS} students per request.`);
    }

    const created: Array<AccountRow & { temporary_password: string }> = [];
    const failed: Array<{ email: string; error: string }> = [];

    for (const raw of rows) {
      const row = (raw ?? {}) as Record<string, unknown>;
      const email = stringField(row, "email").toLowerCase();
      const fullName = stringField(row, "full_name", "fullName");

      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
        failed.push({
          email: email.length > 0 ? email : "(blank)",
          error: "Enter a valid email address.",
        });
        continue;
      }
      if (fullName.length === 0) {
        failed.push({ email, error: "Enter the person's full name." });
        continue;
      }

      const outcome = await createOne({
        email,
        fullName,
        password: temporaryPassword(),
        role: "student",
        academic: academicFields(row),
      });
      if ("refused" in outcome) {
        failed.push({ email, error: outcome.error });
        continue;
      }
      created.push({
        ...outcome.account,
        temporary_password: outcome.password,
      });
    }

    // 200 even when some rows failed: the request was understood, and the
    // per-row reasons travel in `failed` where the widget lists them next to the
    // rows it did create.
    return json({ created, failed });
  }

  // A roster import (`{ students: [...] }`) is the same work done once per row,
  // so it reuses `createOne` below; the single-account form below is the same
  // call with one row and a password the administrator typed.
  if (Array.isArray(payload.students)) {
    return await createMany(payload.students);
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

  const outcome = await createOne({
    email,
    password,
    fullName,
    role,
    academic: academicFields(payload),
  });
  if ("refused" in outcome) {
    return fail(outcome.error, outcome.status);
  }

  // 200, with the created account — the same four keys the Flutter
  // `ManagedAccount.fromMap` reads back, followed by the academic ones when the
  // profile row carries them (a client from before them ignores the extra keys).
  return json(outcome.account);
});
