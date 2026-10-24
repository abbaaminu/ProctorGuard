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

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8' };

function serve() {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    const file = url.pathname === '/detector.js' ? DETECTOR : path.join(HERE, url.pathname);
    fs.readFile(file, (err, body) => {
      if (err) {
        res.writeHead(404);
        res.end('not found: ' + file);
        return;
      }
      res.writeHead(200, {
        'Content-Type': MIME[path.extname(file)] || 'application/octet-stream',
        'Cache-Control': 'no-store'
      });
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
  const tail = (state) => {
    const v = state.verdicts.slice(-3).map((x) => x.v);
    return v.length ? v.join(',') : '(nothing)';
  };
  const s = result.after.stats || {};
  const d = result.after.diag || {};
  return [
    (result.ok ? 'PASS' : 'FAIL') + ' ' + result.scenario.padEnd(16),
    'before=' + tail(result.before).padEnd(22),
    'after=' + tail(result.after).padEnd(22),
    'reason=' + String(d.reason).padEnd(13),
    'mean=' + s.mean + ' spread=' + s.spread + ' dark=' + s.darkFraction,
    'visible=' + d.visible,
    'sample=' + JSON.stringify(d.sample)
  ].join(' ');
}

/// What a scenario has to end in. `silence` means no verdict at all - the
/// detector must find nothing to say when there is neither a preview nor a hook
/// worth speaking through.
function verdictHolds(result, want) {
  const verdicts = result.after.verdicts || [];
  const last = verdicts.length ? verdicts[verdicts.length - 1].v : null;
  if (want === 'silence') return verdicts.length === 0;
  return last === want;
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
        waitLive: item.waitLive
      });
      result.scenario = label;
      result.ok = verdictHolds(result, item.expect);
      if (!result.ok) {
        const want = item.expect;
        const got = (result.after.verdicts || []).slice(-1)[0];
        result.failure = `wanted ${want}, got ${got ? got.v : 'nothing'}`;
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
