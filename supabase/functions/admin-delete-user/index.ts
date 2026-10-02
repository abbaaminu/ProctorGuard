// Supabase Edge Function: `admin-delete-user`
//
// The only supported way to remove an account for good.
//
// A `profiles` row is not the account. The account is the `auth.users` row, and
// that table belongs to Supabase Auth, where only the service_role key reaches
// it. `schema.sql` says as much over `profiles_admin_all`: "deleting a profile
// row does not delete the auth account [...] Removing an account for good means
// calling Auth's admin API". A client-side DELETE of the row would be worse than
// useless — it would leave a login that still signs in but has no profile, which
// is the stranded half-account `admin-create-user` rolls back rather than leave
// behind — so all account cleanup happens here in a deliberate order:
//
//   1. preflight the submission ids whose image folders live in Storage;
//   2. `auth.admin.deleteUser(id)` — the root of the database graph, after which
//      the `profiles` row and everything the schema hangs off it cascades:
//      `exams` (`created_by`), their `questions`, every `exam_submissions` row
//      and the `proctoring_logs` under those attempts;
//   3. remove the image folders through the Storage API (Storage is not part of
//      the database cascade). A failure here is returned with the affected
//      submission folder so the remaining public object can be removed.
//
// Referential actions run outside row security, so the database graph unwinds
// in one statement and no policy can half-do it.
//
// Auth is deleted before the database cascade. If Storage cleanup fails after
// that point, the function reports the failed submission folder for remediation.
//
// Request  (POST, `Authorization: Bearer <the caller's access token>`):
//   { "id": "<uuid of the account to remove>" }   (`account_id` / `accountId` too)
//
// Response 200: { "id": ..., "email": ..., "full_name": ..., "role": ...,
//                 "removed": { "exams": 0, "submissions": 3 } }
// Response 4xx/5xx: { "error": "<message written for the administrator>" }
//
// WHAT IT REFUSES, and why each refusal is a sentence the console can show:
//   * 401 — no token, or one the Auth server will not confirm.
//   * 403 — a caller who is not an administrator, or one trying to delete the
//     account they are signed in with. That second rule is the console's own
//     self-demotion lock (`roleChangeVerdict`) seen from the other side: the
//     caller has just been proved an administrator, so deleting that row would
//     revoke the only page able to create its replacement, and the way back is
//     the SQL editor. It is also what keeps at least one administrator alive —
//     a second admin can be deleted, the last one cannot, by accident or by
//     design.
//   * 404 — the account is already gone. The fix is a reload, not a retry.
//   * 500 — a pre-flight read failed, so nothing was deleted. The counts below
//     are the part a browser cannot know on its own (the roster only lists
//     `profiles`), and an administrator is owed them *before* the write: if they
//     cannot be taken, this function refuses rather than destroy data it cannot
//     describe.
//
// Deploy with `supabase functions deploy admin-delete-user` — JWT verification
// stays ON (the default). It is not the authorization check, though: every
// signed-in user holds a valid JWT, so the role read below is what actually gates
// the deletion. The Flutter admin dashboard does not call this yet; the console's
// roster (`dashboard/src/hooks/useAccounts.ts`) is the client.

import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2";

/** `public.user_role` (schema.sql). Only the admin value is load-bearing here. */
type Role = "admin" | "lecturer" | "supervisor" | "student";

/**
 * The roles allowed to call this function — admin only, for the same reason
 * `admin-create-user` is: `profiles_admin_all` is admin-only, and removing an
 * account is the admin console's action. Widen it here *and* reword the 403 in
 * the same commit, or the sentence the console shows will describe a rule the
 * function no longer enforces.
 */
const DELETER_ROLES: readonly Role[] = ["admin"];

/**
 * A `profiles.id` / `auth.users.id`. Checked before the id reaches PostgREST or
 * Auth, because a `22P02` for a malformed uuid is not a sentence anyone can act
 * on — "expected the account's id" is.
 */
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

/** Every failure answers `{ error }` — the shape the console reads. */
function fail(message: string, status = 400): Response {
  return json({ error: message }, status);
}

/**
 * The first usable string among `keys`, trimmed — `""` when the body has none.
 *
 * `account_id` / `accountId` join `id` for the same reason `fullName` joins
 * `full_name` in `admin-create-user`: the three name one field, so all three are
 * understood rather than answering 400 over a spelling this function could have
 * read.
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

/** What an account owns, counted immediately before it is removed. */
interface RemovalScope {
  exams: number;
  submissions: number;
}

interface RemovalPlan {
  removed: RemovalScope;
  snapshotSubmissionIds: string[];
}

/** Both clients `createClient` builds share this type; named once for the helper. */
type ServiceClient = SupabaseClient;

/**
 * How many rows one page of a paged read asks for.
 *
 * A *request*, not a guarantee: PostgREST answers with at most its `max rows`
 * setting however much is asked for. The read below therefore advances by what
 * actually arrived, which is what makes it converge whatever that setting is on
 * this project.
 */
const PAGE_SIZE = 1000;

/**
 * How many exam ids travel in one `in (...)` filter.
 *
 * A uuid is 36 characters, so this is about 3.7 kB of request line - comfortably
 * inside what the API's proxy accepts, and large enough that even a lecturer with
 * hundreds of exams needs a handful of requests rather than hundreds of them.
 */
const ID_CHUNK = 100;

/**
 * Every exam id this account created, read page by page.
 *
 * `expected` is the API's own count of them (`removalScope` reads it first with
 * `head: true`, so no rows are fetched to get it) and is what the loop runs to:
 * asking for one page is not the same as being done. Pages are ordered so a range
 * can neither repeat nor skip a row between requests, and a page that comes back
 * empty while the count says there is more means the set moved under the read.
 * That is answered as an error rather than as a short list, because a short list
 * becomes a short *submission* count below, and this function refuses to describe
 * a deletion it cannot count.
 */
async function ownedExamIds(
  client: ServiceClient,
  id: string,
  expected: number,
): Promise<string[] | { error: string }> {
  const ids: string[] = [];
  while (ids.length < expected) {
    const { data, error } = await client
      .from("exams")
      .select("id")
      .eq("created_by", id)
      .order("id")
      .range(ids.length, ids.length + PAGE_SIZE - 1);
    if (error) return { error: error.message };
    const page = (data as { id: string }[] | null) ?? [];
    if (page.length === 0) {
      return { error: "the list of exams changed while it was being read" };
    }
    ids.push(...page.map((exam) => exam.id));
  }
  return ids;
}

/** Submission folders whose independently stored snapshots must be removed. */
async function snapshotSubmissionIds(
  client: ServiceClient,
  id: string,
  examIds: string[],
  expectedOwnAttempts: number,
): Promise<string[] | { error: string }> {
  const submissionIds = new Set<string>();

  let ownOffset = 0;
  for (let offset = 0;; offset += PAGE_SIZE) {
    const { data, error } = await client
      .from("exam_submissions")
      .select("id")
      .eq("student_id", id)
      .order("id")
      .range(offset, offset + PAGE_SIZE - 1);
    if (error) return { error: error.message };
    const page = (data as { id: string }[] | null) ?? [];
    page.forEach(({ id }) => submissionIds.add(id));
    ownOffset += page.length;
    if (page.length < PAGE_SIZE) break;
  }
  if (ownOffset !== expectedOwnAttempts) {
    return { error: "the list of student attempts changed while it was being read" };
  }

  for (let start = 0; start < examIds.length; start += ID_CHUNK) {
    const examChunk = examIds.slice(start, start + ID_CHUNK);
    const { count: expectedAttempts, error: countError } = await client
      .from("exam_submissions")
      .select("id", { count: "exact", head: true })
      .in("exam_id", examChunk);
    if (countError) return { error: countError.message };

    let examOffset = 0;
    for (let offset = 0;; offset += PAGE_SIZE) {
      const { data, error } = await client
        .from("exam_submissions")
        .select("id")
        .in("exam_id", examChunk)
        .order("id")
        .range(offset, offset + PAGE_SIZE - 1);
      if (error) return { error: error.message };
      const page = (data as { id: string }[] | null) ?? [];
      page.forEach(({ id }) => submissionIds.add(id));
      examOffset += page.length;
      if (page.length < PAGE_SIZE) break;
    }
    if (examOffset !== (expectedAttempts ?? 0)) {
      return { error: "the list of exam attempts changed while it was being read" };
    }
  }

  return [...submissionIds];
}

/**
 * Remove the image files stored outside the database cascade. Collect each
 * folder's full listing before deleting so offset pagination cannot skip files.
 */
async function removeSnapshots(
  client: ServiceClient,
  submissionIds: string[],
): Promise<string | null> {
  const bucket = client.storage.from("proctor-snapshots");

  for (const submissionId of submissionIds) {
    const names: string[] = [];
    for (let offset = 0;; offset += PAGE_SIZE) {
      const { data, error } = await bucket.list(submissionId, {
        limit: PAGE_SIZE,
        offset,
      });
      if (error) return `${submissionId}: ${error.message}`;
      const page = data ?? [];
      names.push(
        ...page
          .filter((file) => file.id !== null)
          .map((file) => `${submissionId}/${file.name}`),
      );
      if (page.length < PAGE_SIZE) break;
    }

    for (let start = 0; start < names.length; start += ID_CHUNK) {
      const { error } = await bucket.remove(names.slice(start, start + ID_CHUNK));
      if (error) return `${submissionId}: ${error.message}`;
    }
  }

  return null;
}

/**
 * What deleting this account will take with it, counted before it happens.
 *
 * The console cannot work this out for itself: its roster reads `profiles`, and
 * the things that die with a row live in tables that page never loads. So the
 * count belongs here, where one request can see the whole graph:
 *
 *   * `exams.created_by` cascades, so every exam the account created goes — with
 *     its `questions` and every `exam_submissions` row hanging off it;
 *   * `exam_submissions.student_id` cascades too, which is the student case: an
 *     account that submitted attempts of its own.
 *
 * A staff account may also have taken one of its own exams, so submission ids
 * are deduplicated before reporting the number of rows removed.
 *
 * A read that fails answers `{ error }` instead of a guess, and the caller refuses
 * the whole deletion on it: reporting "0 exams" for a lecturer whose exams were
 * never read would be a lie told by the one screen whose job is to say what
 * happened.
 *
 * Every figure here is taken by the API itself (`count: "exact"` with
 * `head: true`), never by fetching rows and counting them: PostgREST answers a
 * read with at most its `max rows` setting however much is asked for, so a
 * lecturer owning more exams than that limit would have the surplus missing from
 * *both* figures below. The exam ids are read only for the second figure, a page
 * at a time (`ownedExamIds`), and only ever sent back in chunks.
 */
async function removalScope(
  client: ServiceClient,
  id: string,
): Promise<RemovalPlan | { error: string }> {
  // The count is taken by the API, not by counting rows: `head: true` asks for no
  // rows at all, and `count: "exact"` is PostgREST's own count for the whole
  // filtered set - so a lecturer with more exams than the API's `max rows` setting
  // still gets the true figure.
  const { count: ownedExams, error: examError } = await client
    .from("exams")
    .select("id", { count: "exact", head: true })
    .eq("created_by", id);
  if (examError) return { error: examError.message };

  const { count: ownAttempts, error: ownError } = await client
    .from("exam_submissions")
    .select("id", { count: "exact", head: true })
    .eq("student_id", id);
  if (ownError) return { error: ownError.message };

  // The other half: the attempts of exams this account created, whatever
  // candidate sat them. They are reached through the exam ids, read a page at a
  // time by `ownedExamIds` and sent back in chunks, because those ids are the one
  // thing here that has no upper bound: `in (...)` travels in the request line,
  // and a list that overran it could only fail - or, worse, be served truncated.
  const examIds = await ownedExamIds(client, id, ownedExams ?? 0);
  if (!Array.isArray(examIds)) return examIds;

  const snapshotIds = await snapshotSubmissionIds(
    client,
    id,
    examIds,
    ownAttempts ?? 0,
  );
  if (!Array.isArray(snapshotIds)) return snapshotIds;

  return {
    removed: {
      exams: ownedExams ?? 0,
      submissions: snapshotIds.length,
    },
    snapshotSubmissionIds: snapshotIds,
  };
}

Deno.serve(async (request: Request): Promise<Response> => {
  // The dashboard is a browser, so it preflights any cross-origin POST; answering
  // costs nothing and keeps this function usable from the Flutter app too.
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

  // Two clients, exactly as in `admin-create-user`: `caller` carries the caller's
  // JWT, so the role read below is RLS-filtered and cannot be spoofed, while
  // `admin` carries the service_role key and is only touched once that check has
  // passed.
  const caller = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Confirms the token's signature and expiry against the Auth server, so a
  // hand-forged JWT cannot get past this.
  const { data: callerData, error: callerError } = await caller.auth.getUser(
    token,
  );
  if (callerError || !callerData.user) {
    return fail("That session is no longer valid — sign in again.", 401);
  }

  // `profiles_select_own_or_staff` lets the caller read their own row, so the
  // value that decides this answer never comes from the privileged client.
  const { data: callerProfile, error: callerProfileError } = await caller
    .from("profiles")
    .select("role")
    .eq("id", callerData.user.id)
    .maybeSingle();
  if (callerProfileError) {
    return fail(`Could not check your role: ${callerProfileError.message}`, 500);
  }
  const callerRole = callerProfile?.role as Role | undefined;
  if (!callerRole || !DELETER_ROLES.includes(callerRole)) {
    return fail("Only an administrator can delete accounts.", 403);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return fail("Expected a JSON body.");
  }

  const id = stringField(payload, "id", "account_id", "accountId");
  if (!UUID_PATTERN.test(id)) {
    return fail("Expected the account's id (a uuid).");
  }

  // Read from the verified token, never from the body: a caller cannot nominate
  // somebody else as "me" and walk into this branch.
  if (id === callerData.user.id) {
    return fail(
      "You cannot delete the account you are signed in with. Ask another administrator.",
      403,
    );
  }

  // The row, read with the service key: it supplies the identity the response
  // reports and the counts below. A missing row is deliberately *not* a 404 yet —
  // this function's job is the login, and an account with no profile row (a
  // half-created account, or one whose row was removed by hand) is exactly the
  // stranded thing an operator reaches for this function to remove.
  const { data: target, error: targetError } = await admin
    .from("profiles")
    .select("id, email, full_name, role")
    .eq("id", id)
    .maybeSingle();
  if (targetError) {
    return fail(`Could not read that account: ${targetError.message}`, 500);
  }

  let identity: {
    email: string | null;
    full_name: string | null;
    role: string | null;
  } = {
    email: target?.email ?? null,
    full_name: target?.full_name ?? null,
    role: target?.role ?? null,
  };
  if (!target) {
    // No profile row: ask Auth whether the login exists at all before answering
    // "no longer exists", so a stranded login can still be removed from here.
    const { data: stranded, error: strandedError } = await admin.auth.admin
      .getUserById(id);
    if (strandedError || !stranded.user) {
      return fail(
        "That account no longer exists — reload the list and try again.",
        404,
      );
    }
    identity = {
      email: stranded.user.email ?? null,
      full_name: (stranded.user.user_metadata?.name as string | undefined) ??
        null,
      role: null,
    };
  }

  const plan = await removalScope(admin, id);
  if ("error" in plan) {
    return fail(
      `Could not count what deleting this account would remove: ${plan.error}. Nothing was deleted.`,
      500,
    );
  }

  // Step 1 of the cascade, and the only step that can fail alone: the login. If
  // this refuses, not one other row has been touched.
  const { error: deleteError } = await admin.auth.admin.deleteUser(id);
  if (deleteError) {
    const alreadyGone = /not found|does not exist/i.test(deleteError.message);
    return fail(
      alreadyGone
        ? "That account no longer exists — reload the list and try again."
        : `Could not delete the account: ${deleteError.message}`,
      alreadyGone ? 404 : 500,
    );
  }

  const snapshotError = await removeSnapshots(
    admin,
    plan.snapshotSubmissionIds,
  );
  if (snapshotError) {
    return fail(
      `The login was deleted, but its proctoring snapshots could not be removed: ${snapshotError}. Remove the reported submission folder from the proctor-snapshots bucket.`,
      500,
    );
  }

  // Steps 2 and 3 are the foreign keys' work, and they run outside row security.
  // Read the row back rather than assume it went: on a project whose `profiles`
  // table predates that FK the row would survive, and a profile row with no login
  // is an account the roster lists but nobody can use.
  const { data: leftover } = await admin
    .from("profiles")
    .select("id")
    .eq("id", id)
    .maybeSingle();
  if (leftover) {
    const { error: rowError } = await admin
      .from("profiles")
      .delete()
      .eq("id", id);
    if (rowError) {
      return fail(
        `The login was deleted, but its profile row could not be removed: ${rowError.message} — delete it in the SQL editor.`,
        500,
      );
    }
  }

  // 200 with what went with it: the sentence the console confirms with.
  return json({ id, ...identity, removed: plan.removed });
});
