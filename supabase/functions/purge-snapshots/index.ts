// =====================================================================
// Edge Function: `purge-snapshots`
// =====================================================================
// Deletes proctor-snapshots objects older than the retention window and nulls
// the `proctoring_logs.snapshot_url` pointer to each, so the incident row
// survives and the photograph does not.
//
// WHY IT HAS TO BE A FUNCTION
//   `supabase/migrations/20261106090100_snapshot_retention.sql` also ships a SQL
//   purge (`public.purge_expired_snapshots`), because some deployments cannot
//   reach the Storage API from a function. SQL can only delete the
//   `storage.objects` *row*: Supabase's Storage API is what also removes the file
//   from the object store. On a hosted project a raw SQL delete is not merely
//   partial, it is refused outright: `storage.objects` carries the
//   `protect_delete` trigger (`storage.protect_delete()`), which raises
//       42501  Direct deletion from storage tables is not allowed
//   unless the session has set `storage.allow_delete_query = 'true'` - which the
//   Storage API does for itself and which the SQL function deliberately does not
//   do (it would strand the file behind a deleted row). So this function is the
//   supported path and the only one that runs on a hosted project; the SQL
//   function is the documented fallback for self-hosted deployments, and never
//   both on the same window, because a missing bookkeeping row makes the file
//   invisible to the Storage API for good.
//
//   Deploy with:  supabase functions deploy purge-snapshots
//   Deploy WITHOUT `--no-verify-jwt`: the platform's JWT check is not the
//   authorization decision here (that is the role check below), but leaving it on
//   means a forged or expired token is rejected before this code runs at all.
//
// REQUEST  POST
//   Authorization: Bearer <service_role key>         (a scheduled caller)
//   Authorization: Bearer <access token of an admin>  (a person, by hand)
//   { "older_than_days": 30, "dry_run": true }        both optional
//
// RESPONSE 200
//   { "bucket": "proctor-snapshots", "window_days": 30, "dry_run": false,
//     "folders": 12, "scanned": 340, "expired": 21, "removed": 21, "nulled": 21,
//     "kept_live": 4, "capped": false }
// RESPONSE 4xx / 5xx
//   { "error": "a sentence written for the operator" }
//
// WHO MAY CALL IT
//   The service-role key (a scheduler), or a signed-in account whose
//   `profiles.role` is `admin`. The role is read back through a client carrying
//   the caller's own token, so RLS filters it exactly as it would in the app and
//   the answer cannot come from the privileged client - the same two-key dance as
//   `admin-create-user`, `admin-delete-user` and `admin-reset-password`.
//
// WHAT IT DELIBERATELY KEEPS
//   * The incident row. Only `snapshot_url` is nulled: the violation type, the
//     strike weight, the time and the attempt all survive, which is the honest
//     record - "there was a still here, it expired".
//   * Every object whose folder is an attempt that is still `ongoing`, whatever
//     its age. A live sitting is exactly when a still matters, and an abandoned
//     attempt keeps its evidence; that is the safe failure direction and the same
//     guard the two row purges use.
//   * Anything newer than the window, by Storage's own `created_at`.
//
// WHAT IT DOES NOT DO
//   * It does not delete `proctoring_logs` rows, `exam_submissions`,
//     `proctor_heartbeats` or `profiles`. Row retention is the SQL purges' job.
//   * It does not schedule itself. Nothing here runs until somebody calls it: see
//     the README's "Scheduling the snapshot purge" for both routes (pg_cron +
//     `net.http_post`, or the dashboard's scheduled functions).
//   * It does not scan deeper than one folder level. The path convention is
//     `<submission_id>/<action_type>_<epoch-ms>.jpg` (schema.sql section 6), so
//     one level is the whole tree.
// The `npm:` specifier is what Deno resolves itself and what `npm-imports.d.ts`
// declares for the TypeScript checker; the other three functions import the same
// package the same way.
import { createClient } from "npm:@supabase/supabase-js@2";

type Role = "admin" | "lecturer" | "supervisor" | "student";

/** The bucket this function owns. Nothing else is in reach. */
const BUCKET = "proctor-snapshots";

/** The retention row this function reads its window from. */
const POLICY_ROW = "proctor_snapshots";

/**
 * The window used when the policy row is missing. Matches the seed in
 * `20261106090100_snapshot_retention.sql` and `ProctorConsentConfig` in the app -
 * the number the consent notice quotes, so a project that lost its policy row
 * still deletes what it promised to delete.
 */
const DEFAULT_WINDOW_DAYS = 30;

/**
 * Objects deleted per run. A backlog bigger than this is finished by the next
 * run rather than by one request that outlives the platform's wall clock; the
 * response says `capped: true` so an operator knows to run it again.
 */
const MAX_OBJECTS = 2000;

/** Folders listed per run - a bound on the scan, not on the deletions. */
const MAX_FOLDERS = 2000;

/** Storage's own page size. */
const LIST_LIMIT = 1000;

/** `storage.remove()` and PostgREST `in (...)` both get their ids in batches. */
const BATCH = 100;

/** The roles allowed to run this by hand. */
const PURGE_ROLES: readonly Role[] = ["admin"];

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Builds CORS response headers that honour the ALLOWED_ORIGIN environment
 * variable, exactly as the three admin functions do. The variable holds a
 * comma-separated list of permitted origins; when the request Origin is in that
 * list it is echoed back and `Vary: Origin` is added. If the variable is unset
 * the function keeps the previous wide-open behaviour and logs a warning, so
 * existing deployments do not break before they configure it.
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

/** Every failure answers `{ error }` — the shape the operator reads. */
function fail(
  message: string,
  status = 400,
  headers?: Record<string, string>,
): Response {
  return json({ error: message }, status, headers);
}

/** One entry from `storage.list()`: a file (`id` set) or a folder (`id` null). */
type StorageEntry = {
  name: string;
  id: string | null;
  created_at?: string | null;
};

/**
 * The half of `StorageFileApi.list` this function uses.
 *
 * Declared structurally because `SupabaseClient`'s generic parameters do not
 * survive a helper's parameter type (`ReturnType<typeof createClient>` is
 * `SupabaseClient<any, "public", "public", ...>` and is not assignable to the
 * package's default instantiation). The cast at the call site is
 * `as unknown as StorageLister` and is safe by construction: it names exactly the
 * `list(prefix, { limit, offset, sortBy })` signature Storage ships.
 */
type StorageLister = {
  list: (
    prefix: string,
    options: {
      limit: number;
      offset: number;
      sortBy: { column: "name"; order: "asc" };
    },
  ) => Promise<{
    data: StorageEntry[] | null;
    error: { message: string } | null;
  }>;
};


/** Equal-length comparison in constant time, for the service-role key. */
function constantTimeEquals(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i += 1) {
    diff |= left.charCodeAt(i) ^ right.charCodeAt(i);
  }
  return diff === 0;
}

/** A number from the request body, or NaN when it is not one. */
function numberField(payload: Record<string, unknown>, key: string): number {
  const value = payload[key];
  if (typeof value === "number") return value;
  if (typeof value === "string" && value.trim() !== "") return Number(value);
  return Number.NaN;
}

/** `chunk([...], 100)` — the batching `remove()` and `in (...)` both need. */
function chunk<T>(items: readonly T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    out.push(items.slice(i, i + size));
  }
  return out;
}


/**
 * Every entry under `prefix`, paged until Storage stops returning a full page.
 *
 * `sortBy` is fixed so the offsets are stable while the purge is deleting from
 * the same tree: without an explicit order Storage may return rows in a
 * different order per page, and a delete during the scan would then silently skip
 * objects rather than report them.
 */
async function listAll(
  lister: StorageLister,
  prefix: string,
  limit: number,
): Promise<StorageEntry[]> {
  const out: StorageEntry[] = [];
  for (let offset = 0; out.length < limit; offset += LIST_LIMIT) {
    const { data, error } = await lister.list(prefix, {
      limit: LIST_LIMIT,
      offset,
      sortBy: { column: "name", order: "asc" },
    });
    if (error) {
      throw new Error(`${prefix === "" ? "/" : prefix}: ${error.message}`);
    }
    const page = data ?? [];
    out.push(...page);
    if (page.length < LIST_LIMIT) break;
  }
  return out;
}

Deno.serve(async (request: Request): Promise<Response> => {
  // Browser clients preflight cross-origin POSTs; answering also keeps this
  // function usable from a dashboard "invoke" button.
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
    return fail(
      "Supply the service-role key, or sign in as an administrator.",
      401,
    );
  }

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Two ways in, and the difference matters:
  //   * the service-role key - what a scheduler sends; it is compared against
  //     the project's own key in constant time, so nothing else can present it;
  //   * an administrator's access token - verified against the Auth server and
  //     then resolved to `profiles.role` through a client carrying that token, so
  //     RLS (and not this function) says who the caller is. The privileged client
  //     is only touched after that answers.
  const isServiceCall = constantTimeEquals(token, serviceKey);
  if (!isServiceCall) {
    const caller = createClient(url, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    });

    const { data: callerData, error: callerError } = await caller.auth.getUser(
      token,
    );
    if (callerError || !callerData.user) {
      return fail("That session is no longer valid \u2014 sign in again.", 401);
    }

    const { data: callerProfile, error: profileError } = await caller
      .from("profiles")
      .select("role")
      .eq("id", callerData.user.id)
      .maybeSingle();
    if (profileError) {
      return fail(`Could not check your role: ${profileError.message}`, 500);
    }
    const callerRole = callerProfile?.role as Role | undefined;
    if (!callerRole || !PURGE_ROLES.includes(callerRole)) {
      return fail(
        "Only an administrator (or a scheduler holding the service-role key) can purge snapshots.",
        403,
      );
    }
  }


  let payload: Record<string, unknown> = {};
  const rawBody = await request.text();
  if (rawBody.trim() !== "") {
    try {
      const parsed: unknown = JSON.parse(rawBody);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        payload = parsed as Record<string, unknown>;
      } else {
        return fail("Expected a JSON object body.");
      }
    } catch {
      return fail("Expected a JSON body.");
    }
  }

  const dryRun = payload.dry_run === true;

  // The window comes from `retention_policies` unless the caller states one, so
  // the number the consent notice quotes is the number the job enforces. A body
  // override is for the "what would 7 days delete?" question, not for policy.
  let windowDays = numberField(payload, "older_than_days");
  if (!Number.isFinite(windowDays)) {
    const { data: policy, error: policyError } = await admin
      .from("retention_policies")
      .select("retention_days")
      .eq("table_name", POLICY_ROW)
      .eq("enabled", true)
      .maybeSingle();
    if (policyError) {
      return fail(
        `Could not read the ${POLICY_ROW} retention policy: ${policyError.message}`,
        500,
      );
    }
    windowDays = typeof policy?.retention_days === "number"
      ? policy.retention_days
      : DEFAULT_WINDOW_DAYS;
  }
  // A zero or negative window would mean "delete every still, including the one
  // from the sitting happening now". Refused rather than clamped, exactly as the
  // SQL twin refuses it: an operator who passes 0 has a bug.
  if (!Number.isFinite(windowDays) || windowDays <= 0) {
    return fail("older_than_days must be a number greater than zero.");
  }

  const cutoff = Date.now() - windowDays * 24 * 60 * 60 * 1000;

  // ---- 1. What is out there, one folder level deep --------------------
  let folders: string[];
  let rootFiles: StorageEntry[];
  try {
    const root = await listAll(
      admin.storage.from(BUCKET) as unknown as StorageLister,
      "",
      MAX_FOLDERS + LIST_LIMIT,
    );
    folders = root.filter((entry) => entry.id === null).map((e) => e.name);
    // Objects at the bucket root are not part of the path convention; they are
    // counted as scanned and never deleted, because nothing names their attempt.
    rootFiles = root.filter((entry) => entry.id !== null);
  } catch (error) {
    return fail(
      `Could not list the ${BUCKET} bucket: ${
        error instanceof Error ? error.message : String(error)
      }`,
      500,
    );
  }

  const capped = folders.length > MAX_FOLDERS;
  if (capped) folders = folders.slice(0, MAX_FOLDERS);

  type Candidate = { path: string; folder: string; created: number };
  const candidates: Candidate[] = [];
  let scanned = rootFiles.length;

  for (const folder of folders) {
    let files: StorageEntry[];
    try {
      files = await listAll(
        admin.storage.from(BUCKET) as unknown as StorageLister,
        folder,
        MAX_OBJECTS * 2,
      );
    } catch (error) {
      return fail(
        `Could not list ${folder}: ${
          error instanceof Error ? error.message : String(error)
        }`,
        500,
      );
    }
    scanned += files.length;
    for (const file of files) {
      // A nested folder inside a submission folder is not part of the
      // convention; it is scanned and left alone.
      if (file.id === null) continue;
      const created = Date.parse(file.created_at ?? "");
      if (!Number.isFinite(created) || created >= cutoff) continue;
      candidates.push({ path: `${folder}/${file.name}`, folder, created });
    }
  }

  // ---- 2. Which of their attempts are still running -------------------
  // The same guard the row purges use: an `ongoing` attempt keeps its evidence,
  // whatever the calendar says. One query per batch of folders, and a folder that
  // resolves to nothing (orphaned by a reset) is not protected - there is no
  // sitting left to protect.
  //
  // Only the folders that actually hold a candidate are asked about: a bucket with
  // ten thousand finished attempts should cost one query, not a hundred.
  const folderIds = [
    ...new Set(candidates.map((c) => c.folder).filter((f) => UUID_PATTERN.test(f))),
  ];
  const live = new Set<string>();
  for (const batch of chunk(folderIds, BATCH)) {
    const { data, error } = await admin
      .from("exam_submissions")
      .select("id,status")
      .in("id", batch);
    if (error) {
      return fail(
        `Could not read the attempts behind these snapshots: ${error.message}`,
        500,
      );
    }
    for (const row of data ?? []) {
      if (row.status === "ongoing") live.add(row.id as string);
    }
  }

  const expired = candidates.filter((c) => !live.has(c.folder));
  const keptLive = candidates.length - expired.length;
  const cappedObjects = expired.length > MAX_OBJECTS;
  const targets = cappedObjects ? expired.slice(0, MAX_OBJECTS) : expired;


  if (dryRun) {
    return json({
      bucket: BUCKET,
      window_days: windowDays,
      dry_run: true,
      folders: folders.length,
      scanned,
      expired: expired.length,
      removed: 0,
      nulled: 0,
      kept_live: keptLive,
      capped: capped || cappedObjects,
    });
  }

  // ---- 3. Remove the files, then blank the pointers -------------------
  // In this order, and for the same reason the SQL twin writes in the opposite
  // order: a pointer nulled before the file is gone hides evidence that still
  // exists, while a file removed before its pointer is nulled is retried on the
  // next run. Removal can fail (Storage refuses silently, exactly as RLS does
  // elsewhere), so only what Storage confirms is written back to the log.
  const removedPaths = new Set<string>();
  for (const batch of chunk(targets, BATCH)) {
    const { data, error } = await admin
      .storage.from(BUCKET)
      .remove(batch.map((c) => c.path));
    if (error) {
      return fail(`Storage refused the delete: ${error.message}`, 500);
    }
    for (const object of data ?? []) {
      const name = object.name as string;
      // Storage answers with each object's full key (`<folder>/<file>`); older
      // versions answer with the file name alone. Both are resolved back to the
      // path this function asked for, so the pointer update below always matches
      // what `proctoring_logs.snapshot_url` stores.
      const match = batch.find((c) => c.path === name) ??
        batch.find((c) => c.path.endsWith(`/${name}`) || c.path === `${name}`);
      if (match) removedPaths.add(match.path);
    }
  }

  const paths = [...removedPaths];

  // The pointer is the object *path*, not a URL (schema.sql section 6), so it is
  // matched directly. One `update` per batch: PostgREST puts the ids in the URL.
  let nulled = 0;
  for (const batch of chunk(paths, BATCH)) {
    const { data, error } = await admin
      .from("proctoring_logs")
      .update({ snapshot_url: null })
      .in("snapshot_url", batch)
      .select("id");
    if (error) {
      // The files are already gone. Reporting the failure is the point: the
      // incidents keep a pointer to a photograph that no longer exists, and an
      // operator has to know rather than read a tidy "removed: N" response.
      return fail(
        `${paths.length} snapshot(s) removed but the incident pointers could `
          + `not be cleared: ${error.message}`,
        500,
      );
    }
    nulled += (data ?? []).length;
  }

  return json({
    bucket: BUCKET,
    window_days: windowDays,
    dry_run: false,
    folders: folders.length,
    scanned,
    expired: expired.length,
    removed: paths.length,
    nulled,
    kept_live: keptLive,
    capped: capped || cappedObjects,
  });
});

