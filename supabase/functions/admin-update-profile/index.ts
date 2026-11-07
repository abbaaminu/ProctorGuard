// =====================================================================
// Edge Function: `admin-update-profile`
// =====================================================================
// Corrects the academic labels — and the identity number — on an existing
// account.
//
// WHY IT IS NEEDED
//   `profiles.faculty / department / level` decide which published papers a
//   student is offered (`exams_select`, see
//   `supabase/migrations/academic_targeting.sql`): a paper aimed at
//   Science/Computer Science/300 is invisible to a student whose level is NULL or
//   was imported as "300 Level". Blank columns are therefore not cosmetic — they
//   are a lockout — and the `guard_profile_labels()` trigger stops the *student*
//   fixing them (`targeting_check.sql` (e) proves both halves). Somebody with the
//   roster has to be able to, and that is this endpoint.
//
// WHY IT HAS TO BE A FUNCTION
//   `profiles_admin_all` already lets an admin PATCH the row through PostgREST.
//   What it cannot do is validate: the columns are free text, so a typed
//   correction can store "computer science" beside a paper's "Computer Science"
//   and quietly fix nothing. The catalogue check happens here, server-side, where
//   it cannot be skipped by a hand-written request — and the service_role write
//   also covers accounts the admin's own policies cannot see.
//
//   Deploy with:  supabase functions deploy admin-update-profile
//   (JWT verification stays ON — the platform default. It establishes *who* is
//   asking; the role read below is what authorizes the write.)
//
// REQUEST  POST, `Authorization: Bearer <access token>`
//
//   One account:
//   { "id": "<profiles.id uuid>",
//     "faculty": "Science", "department": "Computer Science", "level": "300",
//     "matric_number": "CSC/2021/041", "staff_id": null }
//   `userId` / `accountId` / `profileId` are accepted as spellings of `id`, and
//   `matricNumber` / `staffId` of the two identity columns.
//
//   THE RULE FOR KEYS: a key that is *absent* leaves its column alone; a key that
//   is *present* is written. Present-and-blank (`null`, `""`) therefore CLEARS
//   the column, which is the case that matters — "we do not know this student's
//   level" has to be expressible, or a wrong value can only be swapped for
//   another wrong value. The console sends all five keys, so a save means what
//   the dialog showed.
//
//   A page of a corrections file — the same endpoint, one POST per page:
//   { "students": [ { "id": "...", "email": "ada@uni.test", "level": "300" },
//                   ... ] }
//   Same key rule per row (`email` is only echoed back in `failed`, so the widget
//   can say which line the server refused; `id` selects the row). At most
//   `MAX_BULK_CORRECTIONS` rows per call.
//
// RESPONSE 200
//   One account: the corrected row, in the shape the roster reads —
//   { "id": ..., "email": ..., "full_name": ..., "role": ...,
//     "faculty": ..., "department": ..., "level": ...,
//     "matric_number": ..., "staff_id": ... }
//   A page: { "updated": [ <the same row shape>, ... ],
//             "failed":  [ { "email": ..., "error": ... } ] }
//   A page answers 200 even when rows failed, exactly like `admin-create-user`:
//   the request was understood, and each refusal travels beside the rows written.
// RESPONSE 4xx / 5xx
//   { "error": "a sentence written for the administrator" }
//
// WHO MAY CALL IT
//   Admins only (`UPDATER_ROLES`), checked the same way as the other two admin
//   functions: the JWT is verified against the Auth server, the caller's own
//   `profiles.role` is read back through a client carrying the caller's token (so
//   RLS filters it), and only then is the service_role client used. An
//   authorization decision the caller reports about itself is not a decision.
//
// VALIDATION, NOT SPELLING POLICE
//   Every label is matched against the catalogue in `./catalogue.ts` and stored in
//   the catalogue's spelling; anything the catalogue does not name is refused
//   with the list it should have picked from, and a department is refused when it
//   sits under a different faculty than the one on the account. Free text stays in
//   the columns — an import may still store whatever the institution sent — but a
//   *corrected* label is one this build can compare.
import { createClient } from "npm:@supabase/supabase-js@2";

import {
  allDepartments,
  canonicalDepartment,
  canonicalFaculty,
  clean,
  FACULTY_NAMES,
  facultyOf,
  LEVELS,
  normaliseLevel,
} from "./catalogue.ts";

type Role = "admin" | "lecturer" | "supervisor" | "student";

/**
 * The roles allowed to correct academic labels.
 *
 * `admin` only, for the same reason `RESETTER_ROLES` is: the labels decide who
 * sits a paper, which is an administrative fact about a person, not a proctoring
 * observation. If a product decision ever widens this, add the role here *and*
 * reword the 403 below together — the Flutter suite mirrors that sentence.
 */
const UPDATER_ROLES: readonly Role[] = ["admin"];

/**
 * The rows one corrections page may carry. Pinned to the Flutter client's
 * `AdminUserRepository.maxStudentPageSize` by
 * `mobile/test/schema_contract_test.dart`: a page the client builds has to be a
 * page this function accepts.
 */
const MAX_BULK_CORRECTIONS = 50;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The academic label columns, in the order the console offers them. */
const LABEL_COLUMNS = ["faculty", "department", "level"] as const;

/** The identity numbers, each with the spellings a JavaScript client sends. */
const IDENTITY_COLUMNS: ReadonlyArray<readonly [string, ...string[]]> = [
  ["matric_number", "matricNumber"],
  ["staff_id", "staffId"],
];

/** Every `profiles` column this function can write. */
const PROFILE_COLUMNS: readonly string[] = [
  ...LABEL_COLUMNS,
  ...IDENTITY_COLUMNS.map(([column]) => column),
];

/**
 * The columns a corrected row is read back as. `created_at` is left out on
 * purpose: this is the answer to a write, and the roster's tile does not reorder
 * itself over it.
 *
 * Written out rather than built from [PROFILE_COLUMNS] because `.select()`
 * reads this as a *literal* type to type its answer; a computed string would
 * type every row as an error.
 */
const ROW_SELECT =
  "id, email, full_name, role, faculty, department, level, matric_number, staff_id";

/**
 * Builds CORS response headers that honour the ALLOWED_ORIGIN environment
 * variable.  The variable holds a comma-separated list of permitted origins;
 * when the request Origin is in that list it is echoed back and `Vary: Origin`
 * is added.  If the variable is unset the function keeps the previous
 * wide-open behaviour (all origins allowed) and logs a warning, so existing
 * deployments do not break before they configure it.
 *
 * The no-argument version always returns the fallback (or the first allowed
 * origin when configured) and is used by `json()` / `fail()` for error paths
 * where the request object is not threaded through.
 */
function corsHeaders(request?: Request): Record<string, string> {
  const raw = Deno.env.get("ALLOWED_ORIGIN");
  const requestOrigin = request?.headers.get("Origin") ?? null;

  const baseHeaders: Record<string, string> = {
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };

  if (!raw) {
    console.warn(
      "ALLOWED_ORIGIN is not set \u2014 falling back to Access-Control-Allow-Origin: *."
      + " Set this variable to a comma-separated list of allowed origins.",
    );
    return { ...baseHeaders, "Access-Control-Allow-Origin": "*" };
  }

  const allowed = raw.split(",").map((s) => s.trim()).filter(Boolean);
  const origin = requestOrigin && allowed.includes(requestOrigin)
    ? requestOrigin
    : (allowed.length > 0 ? allowed[0] : "null");

  return {
    ...baseHeaders,
    "Access-Control-Allow-Origin": origin,
    "Vary": "Origin",
  };
}

function json(
  body: unknown,
  status = 200,
  headers?: Record<string, string>,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(),
      ...headers,
      "Content-Type": "application/json",
    },
  });
}

/** Every failure answers `{ error }` — the shape the Flutter client reads. */
function fail(
  message: string,
  status = 400,
  headers?: Record<string, string>,
): Response {
  return json({ error: message }, status, headers);
}

/**
 * One cell of a request, read as text — `null` when it says nothing.
 *
 * Numbers are read too: a spreadsheets-to-JSON pipeline happily sends
 * `{"level": 300}` and coercing it is kinder than silently clearing the column.
 * Anything else (`{}`, `[]`, `true`) says nothing and is treated as blank, which
 * the key rule above turns into "clear" — the one reading that never stores a
 * value nobody can compare.
 */
function cell(value: unknown): string | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return clean(String(value));
  }
  return clean(value);
}

/**
 * The columns a body states, and only those.
 *
 * Absent keys stay absent — that is what "leave this column alone" means on the
 * wire — while a present key is carried through as text or `null`, so the caller
 * can tell "clear it" from "not mentioned". Both the column's own name and a
 * JavaScript client's camelCase spelling are accepted, since either names the
 * same field.
 */
function statedLabels(payload: Record<string, unknown>): Record<string, string | null> {
  const stated: Record<string, string | null> = {};
  for (const column of LABEL_COLUMNS) {
    if (column in payload) stated[column] = cell(payload[column]);
  }
  for (const [column, ...aliases] of IDENTITY_COLUMNS) {
    const key = [column, ...aliases].find((name) => name in payload);
    if (key !== undefined) stated[column] = cell(payload[key]);
  }
  return stated;
}

/**
 * The catalogue's reading of the labels a body states, or the sentence that
 * refuses them.
 *
 * [current] is the row as it stands, so a correction that names one column is
 * checked against the pair it will *produce* rather than against the pair it
 * leaves behind: moving a student to `Science` while their department stays
 * `Accounting` would store a cohort that exists nowhere, and `exams_select` would
 * then never match them to a paper in either faculty.
 *
 * Values come back in the catalogue's spelling (`"science"` → `"Science"`), so a
 * correction is also how a label imported with the wrong capital is tidied.
 */
function canonicalLabels(
  stated: Record<string, string | null>,
  current: Record<string, string | null> = {},
): { patch: Record<string, string | null> } | { error: string } {
  const patch: Record<string, string | null> = { ...stated };

  const facultyStated = "faculty" in stated;
  const departmentStated = "department" in stated;
  const faculty = facultyStated ? stated.faculty : (current.faculty ?? null);
  const department = departmentStated
    ? stated.department
    : (current.department ?? null);

  if (facultyStated && stated.faculty !== null) {
    const canonical = canonicalFaculty(stated.faculty);
    if (canonical === null) {
      return {
        error: `"${stated.faculty}" is not a faculty in the catalogue. ` +
          `Use one of: ${FACULTY_NAMES.join(", ")}.`,
      };
    }
    patch.faculty = canonical;
  }

  if (departmentStated && stated.department !== null) {
    const canonical = canonicalDepartment(stated.department);
    if (canonical === null) {
      return {
        error: `"${stated.department}" is not a department in the catalogue. ` +
          `Use one of: ${allDepartments().join(", ")}.`,
      };
    }
    const owner = facultyOf(canonical);
    if (owner !== null && faculty !== null && owner !== faculty) {
      return {
        error: `${canonical} sits under ${owner}, not ${faculty} — ` +
          `pick a department of ${faculty}.`,
      };
    }
    patch.department = canonical;
  } else if (facultyStated && stated.faculty !== null && department !== null) {
    // The faculty moved but no department was named: the stored one has to be in
    // the new faculty, or the correction would leave the pair split across two.
    const owner = facultyOf(department);
    if (owner !== null && owner !== patch.faculty) {
      return {
        error: `The department on that account (${department}) sits under ` +
          `${owner} — name a ${patch.faculty} department as well.`,
      };
    }
  }

  if ("level" in stated && stated.level !== null) {
    const canonical = normaliseLevel(stated.level);
    if (canonical === null) {
      return {
        error: `"${stated.level}" is not a level. ` +
          `Use one of: ${LEVELS.join(", ")}.`,
      };
    }
    patch.level = canonical;
  }

  return { patch };
}

/**
 * The first usable string among `keys`, trimmed — `""` when the body has none.
 *
 * Exists for `id` / `userId` / `accountId` / `profileId` and for the `email` a
 * corrections row echoes back: the column's own spelling is what the roster
 * sends, while a hand-written request or a JavaScript client reaching for
 * camelCase spells it differently. Both name the same field, so both are
 * accepted rather than answering 400 over a spelling this function could have
 * understood.
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
 * The one sentence a correction failure ends with, when the profile table is
 * older than this feature.
 *
 * `column "matric_number" of relation "profiles" does not exist` is what a
 * project that has not applied the migrations answers, and naming the file that
 * adds the column is more use than the raw PostgREST sentence.
 */
function missingColumnHint(message: string): string | null {
  if (!/column .* does not exist/i.test(message)) return null;
  const column = PROFILE_COLUMNS.find((name) => message.includes(name));
  return column === undefined
    ? null
    : `This project has not applied the academic-label migrations yet — ` +
      `\`${column}\` is missing from \`profiles\`. Run ` +
      `supabase/migrations/academic_targeting.sql first.`;
}

Deno.serve(async (request: Request): Promise<Response> => {
  // Browser clients preflight cross-origin POSTs; answering also keeps this
  // function usable from every supported client.
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(request) });
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
  // exactly as it would be in the app — that is what makes the role check
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
  // A signed-in student lands here too — which is the point: `guard_profile_labels`
  // would refuse their write anyway, and this refuses it with a sentence they can
  // act on (ask an administrator).
  const callerRole = callerProfile?.role as Role | undefined;
  if (!callerRole || !UPDATER_ROLES.includes(callerRole)) {
    return fail("Only an administrator can change academic labels.", 403);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return fail("Expected a JSON body.");
  }

  type Refused = { refused: true; status: number; error: string };
  type Corrected = { row: Record<string, unknown> };

  /**
   * Writes one account's stated columns, and answers with the row as it now
   * stands.
   *
   * The row is read first for two reasons: a correction that names one column has
   * to be validated against the pair it produces (see [canonicalLabels]), and a
   * row that no longer exists has to be told apart from a refused write — "reload
   * the list" is a different instruction from "pick a faculty".
   *
   * Written with the service_role client: `guard_profile_labels()` permits it (the
   * function has already established that the caller is an administrator), and it
   * keeps working on accounts an admin's own policies might not reach.
   */
  async function correctOne(
    id: string,
    stated: Record<string, string | null>,
  ): Promise<Corrected | Refused> {
    const { data: current, error: readError } = await admin
      .from("profiles")
      .select(ROW_SELECT)
      .eq("id", id)
      .maybeSingle();
    if (readError) {
      return {
        refused: true,
        status: 500,
        error: missingColumnHint(readError.message) ??
          `Could not read that account: ${readError.message}`,
      };
    }
    if (!current) {
      // The roster is showing a row that is gone — deleted in another session,
      // say. Reported as such: the correction was fine, the account was not.
      return {
        refused: true,
        status: 404,
        error: "That account no longer exists — reload the list and try again.",
      };
    }

    const checked = canonicalLabels(stated, {
      faculty: (current.faculty as string | null) ?? null,
      department: (current.department as string | null) ?? null,
    });
    if ("error" in checked) {
      return { refused: true, status: 400, error: checked.error };
    }

    // An empty patch is a body that named none of the five columns: a request to
    // change nothing, which is a mistake worth naming rather than a 200 that
    // suggests something happened.
    if (Object.keys(checked.patch).length === 0) {
      return {
        refused: true,
        status: 400,
        error: "Name at least one label to change.",
      };
    }

    const { data: updated, error: updateError } = await admin
      .from("profiles")
      .update(checked.patch)
      .eq("id", id)
      .select(ROW_SELECT)
      .maybeSingle();
    if (updateError) {
      return {
        refused: true,
        status: 500,
        error: missingColumnHint(updateError.message) ??
          `Could not save the correction: ${updateError.message}`,
      };
    }
    if (!updated) {
      // PostgREST answers no row when nothing was written. With the service_role
      // client that only happens when the row went away between the read and the
      // write, so it is the same instruction as above.
      return {
        refused: true,
        status: 404,
        error: "That account no longer exists — reload the list and try again.",
      };
    }

    return { row: updated as unknown as Record<string, unknown> };
  }

  // A page of a corrections file — the same work once per row, so it reuses
  // `correctOne`. Each row's reason travels in `failed`, exactly as in
  // `admin-create-user`'s roster import: one bad line does not lose the page.
  if (Array.isArray(payload.students)) {
    const rows = payload.students as unknown[];
    if (rows.length > MAX_BULK_CORRECTIONS) {
      return fail(
        `Send at most ${MAX_BULK_CORRECTIONS} students per request.`,
      );
    }

    const updated: Array<Record<string, unknown>> = [];
    const failed: Array<{ email: string; error: string }> = [];

    for (const raw of rows) {
      const row = (raw ?? {}) as Record<string, unknown>;
      const id = stringField(row, "id", "userId", "accountId", "profileId");
      // Only a label for the failure line: `id` selects the row, because two
      // students can share an address in a badly kept roster and an `email`
      // match would then be a coin toss.
      const email = stringField(row, "email");
      const label = email.length > 0 ? email : (id.length > 0 ? id : "(blank)");

      if (!UUID_PATTERN.test(id)) {
        failed.push({
          email: label,
          error: "Each row needs the account's id (a uuid).",
        });
        continue;
      }

      const outcome = await correctOne(id, statedLabels(row));
      if ("refused" in outcome) {
        failed.push({ email: label, error: outcome.error });
        continue;
      }
      updated.push(outcome.row);
    }

    // 200 even when some rows failed: the request was understood, and the widget
    // lists each refusal next to the rows that were written.
    return json({ updated, failed });
  }

  const id = stringField(payload, "id", "userId", "accountId", "profileId");
  // Checked before it reaches the table: PostgREST answers a bare `22P02`
  // ("invalid input syntax for type uuid") for an id it cannot parse, which reads
  // like a database fault rather than a malformed request.
  if (!UUID_PATTERN.test(id)) {
    return fail("Expected the account's id (a uuid).");
  }

  const outcome = await correctOne(id, statedLabels(payload));
  if ("refused" in outcome) {
    return fail(outcome.error, outcome.status);
  }

  // 200, with the corrected row — the keys the roster's `ManagedAccount.fromMap`
  // reads, with the cleared columns answered as null rather than omitted, so the
  // tile redraws without the label the administrator just removed.
  return json(outcome.row);
});

