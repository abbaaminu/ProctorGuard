/**
 * The one guardrail that has to be impossible to forget: **this script must
 * never send an exam's worth of traffic at production.**
 *
 * A load test is not a read-only probe. Every session signs a real account in,
 * creates a real attempt row, writes answers, heartbeats, violations and a
 * submission — on the free plan that is enough to fill the database, blow the
 * egress allowance and lock the project for the actual students. There is no
 * "dry" version of `submit_exam()` to fall back on, so the refusal has to
 * happen before the first request.
 *
 * Three cheap, independent facts are checked, because each one alone can be
 * wrong:
 *
 *   * the URL's project ref, when the host is `<ref>.supabase.co`;
 *   * the `ref` claim inside the API key — Supabase's anon and service_role
 *     JWTs carry `{"ref":"<project>"}`, so a staging URL pasted together with
 *     the *production* key still fails;
 *   * the two agreeing with each other, so a key from another project cannot
 *     quietly authorise writes against the URL under test.
 *
 * Anything that is not recognisably either local or a Supabase host is refused
 * unless `LOADTEST_ALLOW_FOREIGN_HOST=1` says the reader has a self-hosted
 * staging stack in mind — the failure mode of guessing is too expensive.
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export class GuardError extends Error {
  constructor(message) {
    super(message);
    this.name = 'GuardError';
  }
}

/** Where the Supabase CLI records the linked project, by repo convention. */
export const DEFAULT_PROJECT_REF_FILE = fileURLToPath(
  new URL('../../../supabase/.temp/project-ref', import.meta.url),
);

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '0.0.0.0', '::1', '[::1]', 'host.docker.internal']);

/** Strips a trailing slash so `${base}/rest/v1` never becomes a double slash. */
export function normaliseUrl(raw) {
  if (typeof raw !== 'string') throw new GuardError('LOADTEST_URL is required (the staging project URL)');
  const trimmed = raw.trim();
  if (trimmed === '') throw new GuardError('LOADTEST_URL is required (the staging project URL)');
  let parsed;
  try {
    parsed = new URL(trimmed);
  } catch {
    throw new GuardError(`LOADTEST_URL "${raw}" is not a URL`);
  }
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
    throw new GuardError(`LOADTEST_URL must be http(s), got ${parsed.protocol}`);
  }
  return trimmed.replace(/\/+$/, '');
}

export function isLocalUrl(url) {
  const host = new URL(url).hostname.toLowerCase();
  return LOCAL_HOSTS.has(host) || host.endsWith('.localhost');
}

/**
 * The project ref a Supabase URL names, or `null` for a host that is not
 * `<ref>.supabase.co` (a custom domain, a self-hosted stack, a local CLI).
 */
export function projectRefFromUrl(url) {
  const host = new URL(url).hostname.toLowerCase();
  const suffix = '.supabase.co';
  if (!host.endsWith(suffix)) return null;
  const ref = host.slice(0, -suffix.length);
  return ref === '' || ref.includes('.') ? null : ref;
}

/**
 * The `ref` claim of a Supabase API key, or `null`.
 *
 * Both key families are handled: the JWT-shaped `anon`/`service_role` keys carry
 * the payload, and the newer `sb_publishable_…`/`sb_secret_…` keys carry no
 * claims at all — in which case the URL is the only evidence, and the URL check
 * has to be enough.
 */
export function refFromApiKey(key) {
  if (typeof key !== 'string') return null;
  const parts = key.trim().split('.');
  if (parts.length !== 3) return null;
  try {
    const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
    return typeof payload?.ref === 'string' && payload.ref !== '' ? payload.ref : null;
  } catch {
    return null;
  }
}

/**
 * The production project ref, from `supabase/.temp/project-ref` by default.
 *
 * Returns `null` when the file is absent — a checkout that has never run
 * `supabase link` — rather than failing: refusing every run because a local file
 * is missing would train the reader to bypass the guard. The URL and key checks
 * still apply, and the report says which facts were available.
 */
export function readProductionRef({ file = DEFAULT_PROJECT_REF_FILE } = {}) {
  try {
    const text = readFileSync(file, 'utf8').trim();
    return text === '' ? null : text;
  } catch {
    return null;
  }
}

/**
 * Refuses anything that looks like production. Returns the facts it checked so
 * the report can print them instead of asking the reader to trust it.
 *
 * @returns {{ url: string, projectRef: string|null, keyRef: string|null, productionRef: string|null, isLocal: boolean }}
 */
export function assertStaging({ url, apiKey, productionRef, allowForeignHost = false }) {
  const normalised = normaliseUrl(url);
  const isLocal = isLocalUrl(normalised);
  const projectRef = projectRefFromUrl(normalised);
  const keyRef = refFromApiKey(apiKey);

  if (!isLocal && !allowForeignHost) {
    if (!new URL(normalised).protocol.startsWith('https')) {
      throw new GuardError('a non-local LOADTEST_URL must be https');
    }
    if (projectRef === null) {
      throw new GuardError(
        `LOADTEST_URL "${normalised}" is not a *.supabase.co project URL. ` +
          'Set LOADTEST_ALLOW_FOREIGN_HOST=1 only if that host is a self-hosted staging stack — ' +
          'nothing here can tell it apart from production.',
      );
    }
  }

  const production = typeof productionRef === 'string' && productionRef.trim() !== ''
    ? productionRef.trim().toLowerCase()
    : null;

  if (production !== null) {
    if (projectRef !== null && projectRef.toLowerCase() === production) {
      throw new GuardError(
        `refusing to run: LOADTEST_URL is the production project (${projectRef}). ` +
          'Create a separate Supabase project for staging; this script writes attempts, ' +
          'answers, violations and submissions.',
      );
    }
    if (keyRef !== null && keyRef.toLowerCase() === production) {
      throw new GuardError(
        `refusing to run: the API key belongs to the production project (${keyRef}), whatever ` +
          'LOADTEST_URL says. Use the staging project\'s own anon key.',
      );
    }
  }

  if (keyRef !== null && projectRef !== null && keyRef !== projectRef) {
    throw new GuardError(
      `the API key belongs to project ${keyRef} but LOADTEST_URL is project ${projectRef}. ` +
        'Pair a staging URL with that project\'s own key.',
    );
  }

  return {
    url: normalised,
    projectRef,
    keyRef,
    productionRef: production,
    isLocal,
  };
}
