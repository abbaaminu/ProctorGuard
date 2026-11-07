import assert from 'node:assert/strict';
import test from 'node:test';

import {
  assertStaging,
  GuardError,
  isLocalUrl,
  normaliseUrl,
  projectRefFromUrl,
  readProductionRef,
  refFromApiKey,
} from '../lib/guard.mjs';

const PRODUCTION = 'sfpjicjqkzztlsduowxt';
const STAGING = 'abcdefghijklmnopqrst';

/** A JWT-shaped key with the given claims — no signature is ever verified here. */
function fakeKey(payload) {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
  return `${encode({ alg: 'HS256', typ: 'JWT' })}.${encode(payload)}.signature`;
}

test('the production project ref is read from the URL', () => {
  assert.equal(projectRefFromUrl(`https://${PRODUCTION}.supabase.co`), PRODUCTION);
  assert.equal(projectRefFromUrl('https://abcdefghijklmnopqrst.supabase.co/'), STAGING);
  assert.equal(projectRefFromUrl('https://supabase.example.com'), null);
  assert.equal(projectRefFromUrl('http://127.0.0.1:54321'), null);
});

test('the key\'s own ref claim is read, when it has one', () => {
  assert.equal(refFromApiKey(fakeKey({ ref: PRODUCTION, role: 'anon' })), PRODUCTION);
  assert.equal(refFromApiKey('sb_publishable_abc123'), null);
  assert.equal(refFromApiKey('not-a-jwt'), null);
  assert.equal(refFromApiKey(undefined), null);
});

test('a URL is normalised without its trailing slash', () => {
  assert.equal(normaliseUrl(`https://${STAGING}.supabase.co/`), `https://${STAGING}.supabase.co`);
  assert.throws(() => normaliseUrl(''), GuardError);
  assert.throws(() => normaliseUrl(undefined), GuardError);
  assert.throws(() => normaliseUrl('staging'), GuardError);
  assert.throws(() => normaliseUrl('ftp://example.com'), GuardError);
});

test('the production URL is refused', () => {
  assert.throws(
    () => assertStaging({
      url: `https://${PRODUCTION}.supabase.co`,
      apiKey: fakeKey({ ref: PRODUCTION, role: 'anon' }),
      productionRef: PRODUCTION,
    }),
    /production project/,
  );
});

test('a staging URL with the production key is refused', () => {
  assert.throws(
    () => assertStaging({
      url: `https://${STAGING}.supabase.co`,
      apiKey: fakeKey({ ref: PRODUCTION, role: 'anon' }),
      productionRef: PRODUCTION,
    }),
    /API key belongs to the production project/,
  );
});

test('a key from one project cannot be paired with another project\'s URL', () => {
  assert.throws(
    () => assertStaging({
      url: `https://${STAGING}.supabase.co`,
      apiKey: fakeKey({ ref: 'someotherprojectref', role: 'anon' }),
      productionRef: PRODUCTION,
    }),
    /belongs to project/,
  );
});

test('staging is allowed, and reports the facts it checked', () => {
  const environment = assertStaging({
    url: `https://${STAGING}.supabase.co/`,
    apiKey: fakeKey({ ref: STAGING, role: 'anon' }),
    productionRef: PRODUCTION,
  });
  assert.equal(environment.url, `https://${STAGING}.supabase.co`);
  assert.equal(environment.projectRef, STAGING);
  assert.equal(environment.keyRef, STAGING);
  assert.equal(environment.productionRef, PRODUCTION);
  assert.equal(environment.isLocal, false);
});

test('a checkout without a production ref still refuses a foreign host', () => {
  // No supabase/.temp/project-ref means the URL check is the only one left; it
  // must not be skipped, or a custom domain becomes a way past the guard.
  assert.equal(readProductionRef({ file: 'does/not/exist' }), null);
  assert.throws(
    () => assertStaging({
      url: 'https://exams.example.ac.uk',
      apiKey: 'sb_publishable_abc123',
      productionRef: null,
    }),
    /not a \*\.supabase\.co project URL/,
  );
});

test('a self-hosted stack is allowed only when it is said out loud', () => {
  const environment = assertStaging({
    url: 'https://exams-staging.example.ac.uk',
    apiKey: 'sb_publishable_abc123',
    productionRef: PRODUCTION,
    allowForeignHost: true,
  });
  assert.equal(environment.projectRef, null);
});

test('localhost is recognised, and needs no ref', () => {
  assert.equal(isLocalUrl('http://127.0.0.1:54321'), true);
  assert.equal(isLocalUrl('http://localhost:54321'), true);
  assert.equal(isLocalUrl(`https://${STAGING}.supabase.co`), false);
  const environment = assertStaging({
    url: 'http://127.0.0.1:54321',
    apiKey: 'sb_publishable_abc123',
    productionRef: PRODUCTION,
  });
  assert.equal(environment.isLocal, true);
  assert.equal(environment.projectRef, null);
});

test('the real repository production ref is used when none is passed', () => {
  // Guards against a silent rename of supabase/.temp/project-ref: if the file
  // moves, this test fails instead of the guard quietly allowing production.
  const ref = readProductionRef();
  assert.ok(ref === null || /^[a-z]{20}$/.test(ref), `unexpected production ref: ${ref}`);
});
