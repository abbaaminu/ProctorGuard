/**
 * Plays a clip through the *real* detector, in a real browser.
 *
 * The detector is `mobile/web/proctor_face_detector.js` as it ships, served from
 * this tool's own little HTTP server together with the MediaPipe assets it loads
 * lazily — the same relative paths a student's browser asks for, so an evaluation
 * cannot pass against a copy of the detector or a model from somewhere else.
 *
 * The page (`page/eval.html`) builds the DOM Flutter builds, plays the clip into a
 * `<video>` and hands the detector that stream through `srcObject`, which is what
 * the detector insists on (`inactiveReason` says `no-stream` for a `<video src>`):
 * a file is turned into a live camera with `captureStream()`, so the detector is
 * looking at what it would look at during an attempt.
 *
 * Every verdict is stamped with the *clip's own* `currentTime`, never with wall
 * time. A dropped frame then moves the evidence and the timeline together,
 * instead of a slow machine inventing a look-away that never happened.
 *
 * Nothing here decides anything: it collects `{ message, t }` and hands them to
 * `lib/judge.mjs`, which is the port of the app's own monitor.
 */

import { spawn } from 'node:child_process';
import { createReadStream } from 'node:fs';
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { extname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const TOOL = resolve(HERE, '..');
export const REPO = resolve(TOOL, '..', '..');
export const DETECTOR_PATH = join(REPO, 'mobile', 'web', 'proctor_face_detector.js');
export const MODEL_DIR = join(REPO, 'mobile', 'web', 'mediapipe');
const PAGE_DIR = join(TOOL, 'page');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
  '.task': 'application/octet-stream',
  '.json': 'application/json; charset=utf-8',
  '.mp4': 'video/mp4',
  '.m4v': 'video/mp4',
  '.webm': 'video/webm',
  '.mov': 'video/quicktime',
  '.mkv': 'video/x-matroska',
};

/**
 * Where the browser is: `PG_EVAL_BROWSER`, then the usual Chromium installs.
 *
 * A detector evaluation needs a browser that can decode the clips and run the
 * model, so there is no fallback that pretends: no browser is a refusal, not a
 * skipped run that reads as a pass.
 */
export function findBrowser(explicit) {
  const candidates = [
    explicit,
    process.env.PG_EVAL_BROWSER,
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
  ];
  for (const candidate of candidates) {
    if (candidate && existsSync(candidate)) return candidate;
  }
  throw new Error(
    'no Chromium browser found; set PG_EVAL_BROWSER to msedge.exe or chrome.exe ' +
      '(the detector needs a browser that can run MediaPipe and decode the clips)',
  );
}


function safeJoin(root, relative) {
  const target = resolve(root, `.${sep}${relative}`);
  if (target !== root && !target.startsWith(root + sep)) return null;
  return target;
}

function serveFile(req, res, path, cacheControl = 'no-store') {
  if (!existsSync(path) || !statSync(path).isFile()) {
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('not found');
    return;
  }
  const size = statSync(path).size;
  const headers = {
    'content-type': MIME[extname(path).toLowerCase()] ?? 'application/octet-stream',
    // The detector fetches the model and the wasm bundle; a clip is fetched by the
    // video element with byte ranges. Both need this, and it is the only header
    // either one cannot do without.
    'accept-ranges': 'bytes',
    ...(cacheControl ? { 'cache-control': cacheControl } : {}),
  };

  const range = req.headers.range;
  const match = typeof range === 'string' ? /^bytes=(\d*)-(\d*)$/.exec(range.trim()) : null;
  if (match && (match[1] !== '' || match[2] !== '')) {
    let start = match[1] === '' ? size - Number(match[2]) : Number(match[1]);
    let end = match[1] === '' || match[2] === '' ? size - 1 : Number(match[2]);
    if (!Number.isFinite(start) || start < 0) start = 0;
    if (!Number.isFinite(end) || end >= size) end = size - 1;
    if (start > end) {
      res.writeHead(416, { 'content-range': `bytes */${size}` });
      res.end();
      return;
    }
    res.writeHead(206, {
      ...headers,
      'content-range': `bytes ${start}-${end}/${size}`,
      'content-length': end - start + 1,
    });
    createReadStream(path, { start, end }).pipe(res);
    return;
  }

  res.writeHead(200, { ...headers, 'content-length': size });
  createReadStream(path).pipe(res);
}

/**
 * The one server a run needs: the page, the shipped detector, the model assets and
 * the clips — the four things the page asks for, answered from their real
 * locations so nothing is copied into place for the evaluation.
 *
 * @returns {Promise<{ origin: string, close: () => Promise<void> }>}
 */
export async function startServer({ clipsDir }) {
  const clips = resolve(clipsDir);
  if (!existsSync(clips)) throw new Error(`clips directory not found: ${clipsDir}`);
  if (!existsSync(DETECTOR_PATH)) throw new Error(`detector not found: ${DETECTOR_PATH}`);

  const server = createServer((req, res) => {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const pathname = decodeURIComponent(url.pathname);

    if (pathname === '/' || pathname === '/index.html') {
      serveFile(req, res, join(PAGE_DIR, 'eval.html'));
      return;
    }
    if (pathname === '/health') {
      res.writeHead(200, { 'content-type': 'text/plain' });
      res.end('ok');
      return;
    }
    if (pathname === '/detector.js') {
      serveFile(req, res, DETECTOR_PATH);
      return;
    }
    if (pathname.startsWith('/mediapipe/')) {
      const target = safeJoin(MODEL_DIR, pathname.slice('/mediapipe/'.length));
      if (!target) {
        res.writeHead(403, { 'content-type': 'text/plain' });
        res.end('forbidden');
        return;
      }
      // Cached, unlike everything else: a run plays a dozen clips through one
      // browser, and re-downloading a 3.7 MB model for each of them would make the
      // wall clock a measurement of the model, not of the detector.
      serveFile(req, res, target, null);
      return;
    }
    if (pathname.startsWith('/clip/')) {
      const target = safeJoin(clips, pathname.slice('/clip/'.length));
      if (!target) {
        res.writeHead(403, { 'content-type': 'text/plain' });
        res.end('forbidden');
        return;
      }
      serveFile(req, res, target);
      return;
    }
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('not found');
  });

  await new Promise((resolvePromise, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolvePromise);
  });

  const { port } = server.address();
  return {
    origin: `http://127.0.0.1:${port}`,
    close: () =>
      new Promise((resolvePromise) => {
        server.closeAllConnections?.();
        server.close(() => resolvePromise());
      }),
  };
}


/**
 * A CDP client over Node's own `WebSocket` — the tool takes no dependencies, and
 * every driver it could have used would be a dependency in a repo that has none.
 */
async function connect(wsUrl) {
  const ws = new WebSocket(wsUrl);
  const pending = new Map();
  const listeners = [];
  let nextId = 1;
  let closed = false;

  await new Promise((resolvePromise, reject) => {
    ws.addEventListener('open', resolvePromise, { once: true });
    ws.addEventListener('error', () => reject(new Error(`cannot connect to ${wsUrl}`)), {
      once: true,
    });
  });

  ws.addEventListener('message', (event) => {
    let message;
    try {
      message = JSON.parse(event.data);
    } catch {
      return;
    }
    if (message.id !== undefined && pending.has(message.id)) {
      const { resolve: resolvePromise, reject } = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) reject(new Error(message.error.message ?? JSON.stringify(message.error)));
      else resolvePromise(message.result);
      return;
    }
    for (const listener of listeners) listener(message);
  });

  ws.addEventListener('close', () => {
    closed = true;
    for (const { reject } of pending.values()) reject(new Error('devtools connection closed'));
    pending.clear();
  });

  const send = (method, params = {}) => {
    if (closed) return Promise.reject(new Error('devtools connection closed'));
    const id = nextId++;
    return new Promise((resolvePromise, reject) => {
      pending.set(id, { resolve: resolvePromise, reject });
      ws.send(JSON.stringify({ id, method, params }));
    });
  };

  return {
    send,
    onEvent: (listener) => listeners.push(listener),
    close: () => {
      try {
        ws.close();
      } catch {
        /* already gone */
      }
    },
  };
}

/**
 * Starts the browser with a throwaway profile and its own debugging port.
 *
 * `--autoplay-policy=no-user-gesture-required` is what lets `play()` run without a
 * click. Without it every clip would sit at frame zero and score as a perfect
 * miss — the sort of silent zero this tool exists to avoid.
 */
export async function launchBrowser({ browserPath, headed = false, timeoutMs = 30000 } = {}) {
  const executable = findBrowser(browserPath);
  const userDataDir = mkdtempSync(join(tmpdir(), 'pg-detector-eval-'));
  const args = [
    '--remote-debugging-port=0',
    `--user-data-dir=${userDataDir}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-extensions',
    '--autoplay-policy=no-user-gesture-required',
    '--mute-audio',
    '--window-size=1280,720',
    ...(headed ? [] : ['--headless=new']),
    'about:blank',
  ];

  const child = spawn(executable, args, { stdio: 'ignore', windowsHide: true });
  const portFile = join(userDataDir, 'DevToolsActivePort');
  const deadline = Date.now() + timeoutMs;

  let port = null;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`browser exited with code ${child.exitCode} before opening a debugging port`);
    }
    if (existsSync(portFile)) {
      const [first] = readFileSync(portFile, 'utf8').split(/\r?\n/);
      const parsed = Number(first);
      if (Number.isFinite(parsed) && parsed > 0) {
        port = parsed;
        break;
      }
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  }
  if (port === null) {
    child.kill();
    throw new Error(`browser did not open a debugging port within ${timeoutMs}ms`);
  }

  let target = null;
  while (Date.now() < deadline && !target) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/list`);
      const targets = await response.json();
      target = targets.find((entry) => entry.type === 'page' && entry.webSocketDebuggerUrl) ?? null;
    } catch {
      /* the port file can appear before the endpoint answers */
    }
    if (!target) await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  }
  if (!target) {
    child.kill();
    throw new Error('browser is running but exposes no page target to connect to');
  }

  const cdp = await connect(target.webSocketDebuggerUrl);
  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');

  return {
    cdp,
    executable,
    async close() {
      try {
        await cdp.send('Browser.close');
      } catch {
        /* the browser may already be gone */
      }
      cdp.close();
      if (child.exitCode === null) {
        if (process.platform === 'win32') {
          spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore' });
        } else {
          child.kill('SIGKILL');
        }
      }
      for (let attempt = 0; attempt < 20; attempt += 1) {
        try {
          rmSync(userDataDir, { recursive: true, force: true });
          return;
        } catch {
          await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
        }
      }
    },
  };
}

/**
 * Navigates to the page for one clip and waits for it to report.
 *
 * A timeout is not an exception here: it comes back as a result with `timedOut`
 * and whatever the page had collected, so one bad clip costs one clip and the
 * runner can fail at the end with the other scores intact. A clip that never
 * reports is exactly the kind of finding an evaluation should print.
 *
 * The one exception is `window.__fatal` — a clip the browser cannot decode, or a
 * preview it refuses to play. There is nothing to salvage from a file that is not
 * video, so it throws and `eval.mjs` records it as a clip that could not be
 * replayed.
 *
 * @param {Awaited<ReturnType<typeof launchBrowser>>} browser
 * @param {{ origin: string, clip: string, timeoutMs?: number, pollMs?: number }} options
 * @returns {Promise<{ clip: string, duration: number|null, verdicts: object[],
 *   frames: number, model: string, errors: string[], timedOut: boolean }>}
 */
export async function replayClip(browser, { origin, clip, timeoutMs = 180000, pollMs = 250 } = {}) {
  const url = `${origin}/?clip=${encodeURIComponent(clip)}&maxtime=${Math.round(timeoutMs / 1000)}`;
  await browser.cdp.send('Page.navigate', { url });

  const deadline = Date.now() + timeoutMs;
  const probe = `(() => {
    if (window.__result) return JSON.stringify(window.__result);
    if (window.__fatal) return JSON.stringify({ fatal: String(window.__fatal) });
    return null;
  })()`;

  while (Date.now() < deadline) {
    let payload = null;
    try {
      const { result } = await browser.cdp.send('Runtime.evaluate', {
        expression: probe,
        returnByValue: true,
        awaitPromise: false,
      });
      payload = typeof result?.value === 'string' ? result.value : null;
    } catch {
      /* the page may be mid-navigation; the next poll will see it */
    }
    if (payload) {
      const parsed = JSON.parse(payload);
      if (parsed.fatal) throw new Error(`${clip}: ${parsed.fatal}`);
      return {
        clip,
        duration: Number.isFinite(parsed.duration) ? parsed.duration : null,
        verdicts: Array.isArray(parsed.verdicts) ? parsed.verdicts : [],
        frames: Number.isFinite(parsed.frames) ? parsed.frames : 0,
        model: typeof parsed.model === 'string' ? parsed.model : 'unknown',
        modelState: typeof parsed.modelState === 'string' ? parsed.modelState : 'unknown',
        modelError: typeof parsed.modelError === 'string' ? parsed.modelError : null,
        reason: typeof parsed.reason === 'string' ? parsed.reason : null,
        errors: Array.isArray(parsed.errors) ? parsed.errors.map(String) : [],
        timedOut: parsed.complete === false,
      };
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, pollMs));
  }

  // Salvage whatever the page managed to collect, so the failure has evidence in it.
  let partial = {};
  try {
    const { result } = await browser.cdp.send('Runtime.evaluate', {
      expression: 'JSON.stringify(window.__partial ?? {})',
      returnByValue: true,
    });
    partial = result?.value ? JSON.parse(result.value) : {};
  } catch {
    /* the tab is gone; an empty salvage is still a finding */
  }

  return {
    clip,
    duration: Number.isFinite(partial.duration) ? partial.duration : null,
    verdicts: Array.isArray(partial.verdicts) ? partial.verdicts : [],
    frames: Number.isFinite(partial.frames) ? partial.frames : 0,
    model: typeof partial.model === 'string' ? partial.model : 'unknown',
    modelState: 'unknown',
    modelError: null,
    reason: null,
    errors: [
      ...(Array.isArray(partial.errors) ? partial.errors.map(String) : []),
      `no result after ${Math.round(timeoutMs / 1000)}s`,
    ],
    timedOut: true,
  };
}
