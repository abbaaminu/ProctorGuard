'use strict';
// The face-sensor lab: runs the *real* web/proctor_face_detector.js inside a
// headless Chromium browser against a DOM shaped like Flutter's platform-view DOM,
// with synthetic cameras standing in for a phone, and checks the verdicts the
// detector speaks through window.proctorGuardFaceSignal.
//
//   node tool/face_lab/lab.js            # every scenario, table + exit code
//   node tool/face_lab/lab.js covered    # only scenarios whose label matches
//
// It needs Node 22+ (global WebSocket) and a Chromium-based browser - Edge or
// Chrome, whichever is installed; override with PG_LAB_BROWSER=<path to exe>.
// Nothing here ships: it is the only way to see a covered lens, a frozen preview
// or a preview that never delivers *without* a phone in front of a webcam.
//
// Why it exists: the detector's rules are numbers (a spread, a mean, a count of
// identical ticks), and numbers drift. A scenario that ends in the wrong verdict
// fails the run, so tuning the thresholds cannot silently stop catching a covered
// camera - the exact failure this lab was built to find.
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const HERE = __dirname;
const DETECTOR = path.resolve(HERE, '..', '..', 'web', 'proctor_face_detector.js');
// The model the app ships, served at the same relative path a student's browser
// asks for (`mediapipe/...`), so the `mediapipe` scenario runs the real files
// rather than a copy of them.
const MODEL_DIR = path.resolve(HERE, '..', '..', 'web', 'mediapipe');
const WEB_PORT = Number(process.env.PG_LAB_WEB_PORT || 8791);
const LAST_RUN = path.join(os.tmpdir(), 'pg_face_lab_last_run.json');

/// Where the browser is. Edge ships on every Windows box, Chrome is the other
/// Chromium a developer is likely to have, and PG_LAB_BROWSER covers the rest
/// (a Linux/macOS Chrome, a CI image).
function findBrowser() {
  const candidates = [
    process.env.PG_LAB_BROWSER,
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser'
  ];
  for (const candidate of candidates) {
    if (candidate && fs.existsSync(candidate)) return candidate;
  }
  throw new Error(
    'no Chromium browser found; set PG_LAB_BROWSER to msedge.exe or chrome.exe'
  );
}

const BROWSER = findBrowser();

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  // An ES module served as anything else is refused outright by the browser, and
  // the model would never load: the detector's own `import()` is a scenario too.
  '.mjs': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
  '.task': 'application/octet-stream',
  '.json': 'application/json; charset=utf-8'
};

/// The policy a student's browser actually runs under, read out of the page that
/// ships it - never copied here, so the lab cannot pass against a policy the app
/// no longer has. A model that only loads on an unpolicied page is a model no
/// student has: `script-src 'self'` has to cover the module, `connect-src 'self'`
/// the wasm and the model, and only `'wasm-unsafe-eval'` permits the compile.
function appPolicy() {
  const html = fs.readFileSync(path.resolve(HERE, '..', '..', 'web', 'index.html'), 'utf8');
  const match = /Content-Security-Policy"[^>]*content="([^"]+)"/.exec(html);
  return match ? match[1] : null;
}

function serve() {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    let file;
    if (url.pathname === '/detector.js') {
      file = DETECTOR;
    } else if (url.pathname.startsWith('/mediapipe/')) {
      file = path.join(MODEL_DIR, url.pathname.slice('/mediapipe/'.length));
    } else {
      file = path.join(HERE, url.pathname);
    }
    // `+` reads as a space in a query string; the harness puts it back too.
    const scenario = (url.searchParams.get('s') || '').replace(/ /g, '+');
    const policy = scenario.indexOf('+csp') >= 0 ? appPolicy() : null;
    fs.readFile(file, (err, body) => {
      if (err) {
        res.writeHead(404);
        res.end('not found: ' + file);
        return;
      }
      const headers = {
        'Content-Type': MIME[path.extname(file)] || 'application/octet-stream',
        'Cache-Control': 'no-store'
      };
      if (policy) headers['Content-Security-Policy'] = policy;
      res.writeHead(200, headers);
      res.end(body);
    });
  });
  return new Promise((resolve) => server.listen(WEB_PORT, '127.0.0.1', () => resolve(server)));
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function pageTarget(cdpPort) {
  let last = [];
  for (let i = 0; i < 60; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${cdpPort}/json/list`)).json();
      last = list.map((t) => t.type + ' ' + t.url);
      const page = list.find((t) => t.type === 'page');
      if (page) return page;
    } catch (e) {
      /* browser not listening yet */
    }
    await sleep(150);
  }
  throw new Error('no page target; saw ' + JSON.stringify(last));
}

function connect(wsUrl) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    let nextId = 1;
    const pending = new Map();
    ws.addEventListener('message', (event) => {
      const msg = JSON.parse(event.data);
      if (msg.id && pending.has(msg.id)) {
        const { resolve: done, reject: fail } = pending.get(msg.id);
        pending.delete(msg.id);
        if (msg.error) fail(new Error(JSON.stringify(msg.error)));
        else done(msg.result);
      }
    });
    ws.addEventListener('error', reject);
    ws.addEventListener('open', () =>
      resolve({
        send(method, params) {
          const id = nextId++;
          return new Promise((done, fail) => {
            pending.set(id, { resolve: done, reject: fail });
            ws.send(JSON.stringify({ id, method, params: params || {} }));
          });
        },
        async evaluate(expression) {
          const result = await this.send('Runtime.evaluate', {
            expression,
            returnByValue: true,
            awaitPromise: true
          });
          if (result.exceptionDetails) {
            const detail = result.exceptionDetails;
            const text = detail.exception
              ? detail.exception.description || detail.exception.value
              : detail.text;
            throw new Error('evaluate failed: ' + text);
          }
          return result.result.value;
        },
        close() {
          ws.close();
        }
      })
    );
  });
}

async function launch(scenario, cdpPort) {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-face-lab-'));
  const child = spawn(
    BROWSER,
    [
      '--headless=new',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-extensions',
      '--mute-audio',
      '--autoplay-policy=no-user-gesture-required',
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      `--user-data-dir=${profile}`,
      `--remote-debugging-port=${cdpPort}`,
      `http://127.0.0.1:${WEB_PORT}/harness.html?s=${scenario}`
    ],
    { stdio: 'ignore' }
  );
  return { child, profile };
}

function killTree(pid) {
  try {
    spawn('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore' });
  } catch (e) {
    /* the browser may already be gone */
  }
}

async function runScenario(scenario, actions, options) {
  const cdpPort = options.port;
  const { child, profile } = await launch(scenario, cdpPort);
  let cdp;
  try {
    const page = await pageTarget(cdpPort);
    cdp = await connect(page.webSocketDebuggerUrl);
    await cdp.send('Runtime.enable');
    await cdp.send('Page.enable');
    await cdp.send('Page.navigate', {
      url: `http://127.0.0.1:${WEB_PORT}/harness.html?s=${scenario}`
    });
    await sleep(1500);
    // Most scenarios need a camera that is actually delivering before the
    // interesting moment happens; the ones that do not say so.
    if (options.waitLive !== false) {
      for (let i = 0; i < 40; i++) {
        const live = await cdp.evaluate(
          'JSON.stringify(!!(window.__stats && window.__stats() && window.__stats().mean > 1))'
        );
        if (live === 'true') break;
        await sleep(250);
      }
    }
    const before = await cdp.evaluate('JSON.stringify(window.__state())');
    for (const action of actions) {
      if (action.paint) await cdp.evaluate(`window.__paint(${JSON.stringify(action.paint)}); true`);
      if (action.js) await cdp.evaluate(action.js);
      await sleep(action.wait || 0);
    }
    // A model has to be fetched, compiled and loaded before it can be judged: the
    // model scenarios say what they are waiting for instead of guessing a delay.
    if (options.waitFor) {
      const deadline = Date.now() + (options.waitForMs || 20000);
      let reached = false;
      while (Date.now() < deadline) {
        if (await cdp.evaluate(options.waitFor)) {
          reached = true;
          break;
        }
        await sleep(250);
      }
      if (!reached) throw new Error('timed out waiting for: ' + options.waitFor);
    }
    await sleep(options.settle || 2500);
    const after = await cdp.evaluate('JSON.stringify(window.__state())');
    return { scenario, before: JSON.parse(before), after: JSON.parse(after) };
  } catch (error) {
    if (cdp) {
      const probe = async (label, expr) => {
        try {
          console.log('DEBUG ' + label + ':', await cdp.evaluate(expr));
        } catch (e) {
          console.log('DEBUG ' + label + ' failed:', e.message);
        }
      };
      await probe('errors', 'JSON.stringify(window.__errors || "no __errors")');
      await probe('stateType', 'typeof window.__state');
      await probe('href', 'location.href + " ready=" + document.readyState');
      await probe('state', 'JSON.stringify(window.__state && window.__state())');
      await probe('stub', 'JSON.stringify({frames: window.__stubFrames, options: window.__stubOptions, wasm: window.__stubWasmPath})');
      await probe('diag', 'JSON.stringify(window.ProctorGuardFaceDetector && window.ProctorGuardFaceDetector.diagnostics())');
    }
    throw error;
  } finally {
    if (cdp) cdp.close();
    killTree(child.pid);
    await sleep(400);
    try {
      fs.rmSync(profile, { recursive: true, force: true });
    } catch (e) {
      /* a locked profile is not worth failing over */
    }
  }
}

function summarize(result) {
  // A scenario that threw before it could read the page has no state to show;
  // the failure line under it is the whole story.
  const before = result.before || { verdicts: [] };
  const after = result.after || { verdicts: [] };
  const tail = (state) => {
    const v = (state.verdicts || []).slice(-3).map((x) => x.v);
    return v.length ? v.join(',') : '(nothing)';
  };
  const s = after.stats || {};
  const d = after.diag || {};
  return [
    (result.ok ? 'PASS' : 'FAIL') + ' ' + result.scenario.padEnd(22),
    'before=' + tail(before).padEnd(22),
    'after=' + tail(after).padEnd(22),
    'reason=' + String(d.reason).padEnd(13),
    'model=' + String(d.faceModel) + '/' + String(d.modelState),
    'mean=' + s.mean + ' spread=' + s.spread + ' dark=' + s.darkFraction,
    'errors=' + (after.errors || []).length
  ].join(' ');
}

/// The verdict a scenario actually ended on, or null.
function lastVerdict(result) {
  const verdicts = result.after.verdicts || [];
  return verdicts.length ? verdicts[verdicts.length - 1].v : null;
}

/// `pose:<yaw>,<pitch>` as numbers, or null when the last verdict was not one.
function parsePose(verdict) {
  const match = /^pose:(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)$/.exec(String(verdict));
  return match ? { yaw: Number(match[1]), pitch: Number(match[2]) } : null;
}

/// What a scenario has to end in. `silence` means no verdict at all - the
/// detector must find nothing to say when there is neither a preview nor a hook
/// worth speaking through.
function verdictHolds(result, want) {
  const last = lastVerdict(result);
  if (want === 'silence') return (result.after.verdicts || []).length === 0;
  return last === want;
}

/// A map of expected values (`{ faceModel: 'mediapipe' }`) held against what a
/// scenario actually carried, as a failure message or null.
function heldExactly(want, got, label) {
  for (const key of Object.keys(want)) {
    const actual = got ? got[key] : undefined;
    if (actual !== want[key]) return `wanted ${label}.${key} = ${want[key]}, got ${actual}`;
  }
  return null;
}

async function main() {
  const server = await serve();
  const only = process.argv[2];
  const scenarios = [
    // A lit room with a student in it: the only shape that may pass as `centered`.
    { name: 'canvas', actions: [], settle: 1500, expect: 'centered' },
    // The bug this lab exists for: a hand, a sticker or a closed shutter. Dim and
    // featureless, but auto-exposure lifts it well off black.
    {
      name: 'canvas',
      label: 'canvas+covered',
      actions: [{ paint: 'covered', wait: 900 }],
      expect: 'no_face'
    },
    {
      name: 'canvas',
      label: 'canvas+coveredLit',
      actions: [{ paint: 'coveredBright', wait: 900 }],
      expect: 'no_face'
    },
    // A dim room with a student in it is *not* a cover: it has structure, so the
    // page may not accuse anyone of it.
    {
      name: 'canvas',
      label: 'canvas+dimscene',
      actions: [{ paint: 'dimscene', wait: 900 }],
      expect: 'centered'
    },
    {
      name: 'canvas',
      label: 'canvas+white',
      actions: [{ paint: 'white', wait: 900 }],
      expect: 'no_face'
    },
    {
      name: 'canvas',
      label: 'canvas+dark',
      actions: [{ paint: 'dark', wait: 900 }],
      expect: 'no_face'
    },
    // A still image in place of a camera: bright, detailed, and unchanging.
    { name: 'frozen', actions: [], settle: 2500, expect: 'no_face' },
    { name: 'live', actions: [], settle: 1500, expect: 'centered' },
    {
      name: 'canvas',
      label: 'live+stop',
      actions: [{ js: 'window.__video.srcObject.getVideoTracks()[0].stop()', wait: 900 }],
      expect: 'no_face',
      expectReason: 'track-stopped'
    },
    {
      name: 'canvas',
      label: 'live+mute',
      actions: [{ js: 'window.__video.srcObject.getVideoTracks()[0].enabled = false', wait: 900 }],
      expect: 'no_face'
    },
    {
      name: 'canvas',
      label: 'live+pause',
      actions: [{ js: 'window.__video.pause()', wait: 900 }],
      expect: 'no_face',
      expectReason: 'paused'
    },
    {
      name: 'canvas',
      label: 'live+hidden',
      actions: [{ js: "window.__wrapper.style.display = 'none'", wait: 900 }],
      expect: 'no_face',
      expectReason: 'hidden'
    },
    // The app's own camera, drawn somewhere this script cannot see: the <video>
    // is never in the document, so the only way to proctor this sitting is the
    // stream the page itself asked the browser for.
    {
      name: 'capture',
      actions: [],
      expect: 'centered',
      expectOwned: true
    },
    // A measured head pose, from a stand-in for the Shape Detection API: frontal,
    // turned to where Dart's tolerance has to decide, and the two count verdicts
    // around it. This is the path a browser `looking_away` comes from.
    {
      name: 'pose',
      actions: [{ js: 'window.__look(0); true', wait: 900 }],
      expectRegex: /^pose:/,
      expectPose: { yaw: 0, pitch: 0, tolerance: 3 }
    },
    {
      name: 'pose',
      label: 'pose+turn',
      actions: [{ js: 'window.__look(40); true', wait: 1200 }],
      expectRegex: /^pose:/,
      expectPose: { yaw: 40, pitch: 0, tolerance: 5 }
    },
    {
      name: 'pose',
      label: 'pose+two',
      actions: [{ js: 'window.__faces(2); true', wait: 900 }],
      expect: 'multiple_faces'
    },
    {
      name: 'pose',
      label: 'pose+none',
      actions: [{ js: 'window.__faces(0); true', wait: 900 }],
      expect: 'no_face'
    },
    // ---- The model the app ships, on a browser that has none --------------
    //
    // MediaPipe's FaceLandmarker, WebAssembly and all, out of `web/mediapipe/`:
    // the *real* module, the real wasm and the real model, imported by the
    // detector's own lazy `import()`. The lab's camera paints a drawn face, so the
    // whole path - fetch, compile, load, one inference per tick, a solved head
    // pose - is proven by a `pose:` coming out the other end. The angles are only
    // near zero: a cartoon face is not a student's, and how much a model trusts it
    // is the model's business, not this lab's.
    {
      name: 'mediapipe',
      actions: [],
      waitFor: "window.ProctorGuardFaceDetector.diagnostics().faceModel === 'mediapipe'",
      waitForMs: 60000,
      settle: 2500,
      expectRegex: /^pose:/,
      expectPose: { yaw: 0, pitch: 0, tolerance: 15 },
      expectDiag: { faceModel: 'mediapipe', modelState: 'ready' },
      expectNoErrors: true
    },
    // ...and the same load under the policy index.html actually serves, which is
    // the only environment a student's browser is in. The lab sends that policy as
    // a header, read from the page itself. This is the scenario that catches a
    // model the CSP refuses - a module `script-src 'self'` does not cover, a wasm
    // compile no directive allows - which would otherwise surface as a page that
    // quietly answers `centered` in production and passes every other test here.
    {
      name: 'mediapipe+csp',
      actions: [],
      waitFor: "window.ProctorGuardFaceDetector.diagnostics().faceModel === 'mediapipe'",
      waitForMs: 60000,
      settle: 2500,
      expectRegex: /^pose:/,
      expectPose: { yaw: 0, pitch: 0, tolerance: 15 },
      expectDiag: { faceModel: 'mediapipe', modelState: 'ready' },
      expectNoErrors: true
    },
    // A model that is not on the server at all - an air-gapped deployment, a host
    // that moved the assets, a policy that blocks the module. The page has to give
    // up once, keep every check it had before the model existed, and raise nothing:
    // a rejected import that nobody catches is an unhandled rejection in the
    // student's console and, on some hosts, an error report.
    {
      name: 'mediapipe+absent',
      actions: [],
      waitFor: "window.ProctorGuardFaceDetector.diagnostics().modelState === 'failed'",
      waitForMs: 20000,
      settle: 2500,
      expect: 'centered',
      expectDiag: { faceModel: 'none', modelState: 'failed' },
      expectNoErrors: true
    },
    // A head turned 40 degrees and tipped 10, through the pose matrix: the angles
    // Dart's `looking_away` is decided from on a desktop browser. The stand-in
    // module records what it was asked for, so this also pins the running mode,
    // the delegate and the face budget the detector configures.
    {
      name: 'mediapipe+turn',
      actions: [{ js: 'window.__look(40, 10); true', wait: 900 }],
      waitFor: 'window.__stubFrames > 0',
      waitForMs: 15000,
      settle: 1500,
      expectRegex: /^pose:/,
      expectPose: { yaw: 40, pitch: 10, tolerance: 2 },
      expectStub: { runningMode: 'VIDEO', delegate: 'GPU', numFaces: 2, matrices: true }
    },
    // The same turn with the matrix withheld: the landmark fallback has to measure
    // it from the two eyes and the nose, which is the one definition of "yaw" both
    // providers share.
    {
      name: 'mediapipe+landmarks',
      actions: [{ js: 'window.__look(40, 0); true', wait: 900 }],
      waitFor: 'window.__stubFrames > 0',
      waitForMs: 15000,
      settle: 1500,
      expectRegex: /^pose:/,
      expectPose: { yaw: 40, pitch: 0, tolerance: 5 }
    },
    // A machine with no usable WebGL: the GPU delegate is refused, and the same
    // model has to come up on the CPU rather than leave the page without one.
    {
      name: 'mediapipe+gpuFallback',
      actions: [{ js: 'window.__look(40, 10); true', wait: 900 }],
      waitFor: 'window.__stubFrames > 0',
      waitForMs: 15000,
      settle: 1500,
      expectRegex: /^pose:/,
      expectPose: { yaw: 40, pitch: 10, tolerance: 2 },
      expectStub: { delegate: 'CPU' }
    },
    {
      name: 'mediapipe+two',
      actions: [{ js: 'window.__faces(2); true', wait: 900 }],
      waitFor: 'window.__stubFrames > 0',
      waitForMs: 15000,
      settle: 1500,
      expect: 'multiple_faces'
    },
    {
      name: 'mediapipe+none',
      actions: [{ js: 'window.__faces(0); true', wait: 900 }],
      waitFor: 'window.__stubFrames > 0',
      waitForMs: 15000,
      settle: 1500,
      expect: 'no_face'
    },
    // A camera blocked before the first frame ever arrived: reported once the
    // preview has been silent longer than STALL_MS, not before.
    {
      name: 'dead',
      actions: [],
      waitLive: false,
      settle: 6500,
      expect: 'no_face',
      expectReason: 'no-frame-yet'
    },
    // No preview at all is a missing element, not an absent student: the detector
    // says nothing and leaves the camera problem to the attempt.
    {
      name: 'novideo',
      actions: [],
      waitLive: false,
      settle: 1500,
      expect: 'silence',
      expectReason: 'no-preview'
    }
  ];
  const results = [];
  const failures = [];
  // A `+csp` scenario is only meaningful if there is a policy to send; a regex
  // that quietly stopped matching index.html would turn it back into a plain pass.
  if (scenarios.some((item) => (item.label || item.name).indexOf('+csp') >= 0) && !appPolicy()) {
    console.log('web/index.html no longer declares a Content-Security-Policy meta tag');
    process.exit(1);
  }
  let index = 0;
  for (const item of scenarios) {
    const label = item.label || item.name;
    index++;
    if (only && !label.includes(only)) continue;
    let result = { scenario: label, ok: false, failure: 'did not run' };
    try {
      result = await runScenario(item.name, item.actions, {
        port: 9300 + index,
        settle: item.settle,
        waitLive: item.waitLive,
        waitFor: item.waitFor,
        waitForMs: item.waitForMs
      });
      result.scenario = label;
      const got = lastVerdict(result);
      // A measured pose is a verdict in two parts: the shape of the message
      // (`expectRegex`) and the numbers in it (`expectPose`).
      if (item.expectRegex) {
        result.ok = item.expectRegex.test(String(got));
        if (!result.ok) result.failure = `wanted ${item.expectRegex}, got ${got || 'nothing'}`;
      } else {
        result.ok = verdictHolds(result, item.expect);
        if (!result.ok) result.failure = `wanted ${item.expect}, got ${got || 'nothing'}`;
      }
      if (result.ok && item.expectPose) {
        const pose = parsePose(got);
        const tolerance = item.expectPose.tolerance || 5;
        const off =
          !pose ||
          Math.abs(pose.yaw - item.expectPose.yaw) > tolerance ||
          Math.abs(pose.pitch - item.expectPose.pitch) > tolerance;
        if (off) {
          result.ok = false;
          result.failure =
            `wanted yaw ~${item.expectPose.yaw} pitch ~${item.expectPose.pitch}, got ${got}`;
        }
      }
      if (result.ok && item.expectOwned) {
        const video = (result.after.diag || {}).video;
        if (!video || !video.owned) {
          result.ok = false;
          result.failure =
            'wanted the page\'s own captured camera (owned video), got ' +
            (video ? 'a preview element' : 'no video at all');
        }
      }
      // Which sensor answered, and what it was configured with: a model that
      // loaded but was asked for the wrong mode would measure the wrong thing.
      if (result.ok && item.expectDiag) {
        const failure = heldExactly(item.expectDiag, result.after.diag, 'diagnostics()');
        if (failure) {
          result.ok = false;
          result.failure = failure;
        }
      }
      if (result.ok && item.expectStub) {
        const failure = heldExactly(item.expectStub, result.after.stub, 'model options');
        if (failure) {
          result.ok = false;
          result.failure = failure;
        }
      }
      // A model that fails must fail quietly: no page error, no unhandled
      // rejection, nothing for a proctor to debug on a student's screen.
      if (result.ok && item.expectNoErrors) {
        const errors = result.after.errors || [];
        if (errors.length) {
          result.ok = false;
          result.failure = 'the page raised: ' + errors.join('; ');
        }
      }
      const reason = (result.after.diag || {}).reason;
      if (result.ok && item.expectReason && reason !== item.expectReason) {
        result.ok = false;
        result.failure = `wanted reason ${item.expectReason}, got ${reason}`;
      }
    } catch (e) {
      result.failure = 'threw: ' + e.message;
    }
    results.push(result);
    if (!result.ok) failures.push(label + ': ' + result.failure);
    console.log(summarize(result));
    if (!result.ok) console.log('     ' + result.failure);
  }
  fs.writeFileSync(LAST_RUN, JSON.stringify(results, null, 2));
  server.close();
  if (failures.length) {
    console.log('');
    console.log(failures.length + ' scenario(s) failed; full state in ' + LAST_RUN);
    process.exit(1);
  }
  console.log('');
  console.log('all ' + results.length + ' scenarios behaved; full state in ' + LAST_RUN);
  process.exit(0);
}

main();
