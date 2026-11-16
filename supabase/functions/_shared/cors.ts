/**
 * The CORS headers every Edge Function in this folder answers with.
 *
 * One file, because there are five functions (`admin-create-user`,
 * `admin-delete-user`, `admin-reset-password`, `admin-update-profile`,
 * `purge-snapshots`) that have to answer identically: a fix applied to four of
 * them is the kind of drift that shows up only as "the console works but the
 * purge is blocked by the browser". Supabase bundles this file into each
 * function that imports it, so a deployment still ships one self-contained
 * bundle per function, and `npm run typecheck` covers it like any other source.
 *
 * `ALLOWED_ORIGIN` holds a comma-separated list of permitted origins. When the
 * request's own `Origin` is in that list it is echoed back, together with
 * `Vary: Origin` so a proxy cannot hand one origin's cached answer to another.
 *
 * When `ALLOWED_ORIGIN` is unset - or set to the empty string - **no**
 * `Access-Control-Allow-Origin` header is sent at all, and a warning is logged.
 * It used to answer `*`, which let any page on the internet call an admin
 * function from a browser and read the reply. With no allow-origin header the
 * browser refuses to hand the response to the page, so an unconfigured
 * deployment fails closed for the console; callers that are not browsers (a
 * scheduler presenting the service-role key, `curl`, the native app) never
 * consult CORS and are unaffected. Setting the variable is therefore a
 * deployment prerequisite, not an optimisation: `supabase functions deploy`
 * does not set it for you (README.md, "Production checklist").
 *
 * The allow-origin header decides only who may *read* an answer. The platform's
 * JWT check and the role check inside each function run exactly as before, so a
 * refused origin cannot reach a code path a permitted one could not; and a
 * server that answers without the header still ran the request, which is why
 * the log line matters as much as the missing header.
 *
 * The no-argument form - `json()` / `fail()` on error paths, where the request
 * object is not threaded through - answers with the first configured origin, so
 * an error carries the same allow-origin a success would have. The OPTIONS
 * preflight passes the request, so it echoes the actual `Origin`.
 */
export function corsHeaders(request?: Request): Record<string, string> {
  const raw = Deno.env.get("ALLOWED_ORIGIN");
  const requestOrigin = request?.headers.get("Origin") ?? null;

  const baseHeaders: Record<string, string> = {
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };

  if (!raw) {
    console.warn(
      "ALLOWED_ORIGIN is not set \u2014 sending no Access-Control-Allow-Origin header,"
        + " so a browser cannot read this function's response."
        + " Set this variable to a comma-separated list of allowed origins.",
    );
    return baseHeaders;
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
