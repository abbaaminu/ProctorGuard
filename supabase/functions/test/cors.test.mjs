// The CORS contract of the five Edge Functions, tested against `_shared/cors.ts`.
//
// Run from `supabase/functions/`: `npm test` (`node --test "test/*.test.mjs"`).
// The helper is TypeScript and reads the Deno runtime's environment, so this
// file shims `Deno.env` before importing it; Node 22 strips the types as it
// loads the `.ts` file, and nothing else of Deno is reachable from that module,
// which is why the contract can be tested here without Deno, without a deployed
// project, and without touching Supabase.
//
// Both halves are pinned:
//   * unset (or empty) `ALLOWED_ORIGIN` -> no `Access-Control-Allow-Origin` at
//     all, and one warning per response. That is the fix: `*` let any page call
//     an admin function from a browser and read the reply.
//   * set `ALLOWED_ORIGIN` -> exactly the headers the functions sent before, so
//     a configured deployment does not change behaviour.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const FUNCTIONS_DIR = join(dirname(fileURLToPath(import.meta.url)), "..");

/** `ALLOWED_ORIGIN` as the helper sees it; each test rewrites this. */
const denoEnv = new Map();
globalThis.Deno = { env: { get: (name) => denoEnv.get(name) } };

const { corsHeaders } = await import("../_shared/cors.ts");

const ALLOW_ORIGIN = "access-control-allow-origin";

/**
 * Calls the helper once with `ALLOWED_ORIGIN` set to `configured` (or removed,
 * when it is `undefined`) and returns the headers plus whatever it warned.
 *
 * `origin` is the request's own `Origin` header: a string sends it, `null` sends
 * a request *without* one (a non-browser caller), and `undefined` calls the
 * no-argument form the error paths use.
 */
function answer({ configured, origin } = {}) {
  if (configured === undefined) denoEnv.delete("ALLOWED_ORIGIN");
  else denoEnv.set("ALLOWED_ORIGIN", configured);

  const request = origin === undefined ? undefined : new Request(
    "https://function.example/",
    { method: "OPTIONS", headers: origin === null ? {} : { Origin: origin } },
  );

  const warnings = [];
  const realWarn = console.warn;
  console.warn = (...args) => {
    warnings.push(args.map((arg) => String(arg)).join(" "));
  };
  try {
    return { headers: corsHeaders(request), warnings };
  } finally {
    console.warn = realWarn;
  }
}

/** Every spelling of the header, so a stray `*` cannot hide behind casing. */
function allowOriginHeaders(headers) {
  return Object.entries(headers).filter(([name]) =>
    name.toLowerCase() === ALLOW_ORIGIN
  );
}

test("an unset ALLOWED_ORIGIN sends no allow-origin header and warns", () => {
  const { headers, warnings } = answer({ origin: "https://evil.example" });

  assert.deepEqual(
    allowOriginHeaders(headers),
    [],
    "no Access-Control-Allow-Origin may be sent when the variable is unset",
  );
  assert.equal(headers["Access-Control-Allow-Methods"], "POST, OPTIONS");
  assert.match(headers["Access-Control-Allow-Headers"], /authorization/);

  assert.equal(warnings.length, 1, "one warning per response");
  assert.match(warnings[0], /ALLOWED_ORIGIN is not set/);
  assert.doesNotMatch(
    warnings[0],
    /Allow-Origin: \*/,
    "the warning must not promise the wildcard it replaced",
  );
});

test("an unset ALLOWED_ORIGIN omits the header on the error path too", () => {
  const { headers, warnings } = answer();

  assert.deepEqual(allowOriginHeaders(headers), []);
  assert.equal(warnings.length, 1);
});

test("an empty ALLOWED_ORIGIN is treated as unset", () => {
  const { headers, warnings } = answer({
    configured: "",
    origin: "https://console.example.com",
  });

  assert.deepEqual(allowOriginHeaders(headers), []);
  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /ALLOWED_ORIGIN is not set/);
});

test("a configured origin is echoed back with Vary: Origin", () => {
  const { headers, warnings } = answer({
    configured: "https://console.example.com",
    origin: "https://console.example.com",
  });

  assert.equal(
    headers["Access-Control-Allow-Origin"],
    "https://console.example.com",
  );
  assert.equal(headers["Vary"], "Origin");
  assert.deepEqual(warnings, [], "a configured deployment logs nothing");
});

test("any origin in the list is echoed, and spaces after commas are trimmed", () => {
  const { headers } = answer({
    configured: "https://console.example.com, https://admin.example.com",
    origin: "https://admin.example.com",
  });

  assert.equal(
    headers["Access-Control-Allow-Origin"],
    "https://admin.example.com",
  );
  assert.equal(headers["Vary"], "Origin");
});

test("an unlisted origin still gets the first configured origin", () => {
  const { headers } = answer({
    configured: "https://console.example.com,https://admin.example.com",
    origin: "https://evil.example",
  });

  assert.equal(
    headers["Access-Control-Allow-Origin"],
    "https://console.example.com",
  );
  assert.equal(headers["Vary"], "Origin");
});

test("the no-argument form answers with the first configured origin", () => {
  const { headers } = answer({
    configured: "https://console.example.com,https://admin.example.com",
  });

  assert.equal(
    headers["Access-Control-Allow-Origin"],
    "https://console.example.com",
  );
});

test("a request without an Origin header gets the first configured origin", () => {
  const { headers } = answer({
    configured: "https://console.example.com",
    origin: null,
  });

  assert.equal(
    headers["Access-Control-Allow-Origin"],
    "https://console.example.com",
  );
});

// Unchanged on purpose: a variable that *is* set but names no origin answers
// `null`, exactly as it did before this helper was shared. Only an absent or
// empty variable changes the contract.
test("a set-but-empty list keeps answering null", () => {
  const { headers, warnings } = answer({
    configured: " , ",
    origin: "https://console.example.com",
  });

  assert.equal(headers["Access-Control-Allow-Origin"], "null");
  assert.deepEqual(warnings, []);
});

const FUNCTIONS = [
  "admin-create-user",
  "admin-delete-user",
  "admin-reset-password",
  "admin-update-profile",
  "purge-snapshots",
];

test("all five functions import the shared helper and keep no copy", () => {
  for (const name of FUNCTIONS) {
    const source = readFileSync(join(FUNCTIONS_DIR, name, "index.ts"), "utf8");

    assert.match(
      source,
      /import \{ corsHeaders \} from "\.\.\/_shared\/cors\.ts";/,
      `${name} imports the shared helper`,
    );
    assert.doesNotMatch(
      source,
      /function corsHeaders\(/,
      `${name} defines no corsHeaders of its own`,
    );
    assert.ok(
      source.includes("corsHeaders(request)"),
      `${name} answers the OPTIONS preflight with the request's Origin`,
    );
    assert.doesNotMatch(
      source,
      /"Access-Control-Allow-Origin": "\*"/,
      `${name} never sends a wildcard origin`,
    );
  }
});

