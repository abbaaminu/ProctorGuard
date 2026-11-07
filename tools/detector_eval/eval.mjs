#!/usr/bin/env node
/**
 * ProctorGuard detector evaluation.
 *
 *   node tools/detector_eval/eval.mjs --dry-run
 *   node tools/detector_eval/eval.mjs --labels labels.csv --clips clips/
 *
 * What it does, in one sentence: it replays labelled clips through the *real*
 * browser detector (mobile/web/proctor_face_detector.js, as it ships), feeds
 * every verdict it heard to a port of the app's own `WebFacePresenceMonitor`, and
 * scores the violations that monitor would have logged against the windows a
 * human labelled — per action, per tag, with recall, precision and a
 * false-positive rate the app would actually produce.
 *
 * What it will not do: measure the detector's frame verdicts. A hundred
 * `no_face` ticks in a row are one violation, and a clip is labelled with
 * violations. Scoring raw ticks would grade a detector nobody ships.
 *
 * Environment (flags win):
 *   PG_EVAL_BROWSER     msedge.exe / chrome.exe to drive      (else the usual installs)
 *   PG_EVAL_CLIPS       the folder of clips                  (else ./clips beside the labels)
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

import { clipsOf, parseLabels } from './lib/labels.mjs';
import { DEFAULT_RULES, judgeVerdicts, readAppRules } from './lib/judge.mjs';
import {
  DEFAULT_TOLERANCE_SECONDS,
  evaluateClip,
  resolveEnds,
  summarize,
} from './lib/match.mjs';
import {
  describeRules,
  evaluateThresholds,
  formatReport,
  toJsonReport,
} from './lib/report.mjs';
import { REPO, findBrowser, launchBrowser, replayClip, startServer } from './lib/replay.mjs';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const EXIT_CONFIG = 2;
const EXIT_THRESHOLD = 1;

/** A configuration the tool refuses to run with — as opposed to a failed result. */
class EvalError extends Error {
  constructor(message) {
    super(message);
    this.name = 'EvalError';
  }
}

const USAGE = `ProctorGuard detector evaluation

  node tools/detector_eval/eval.mjs [options]

  --labels <path>        the labelled windows CSV     (default ./labels.csv)
  --clips <dir>          the folder of clip files     (default ./clips beside the labels)
  --out <path>           write the JSON report
  --limit <n>            evaluate the first n clips only
  --tolerance <seconds>  slack around every window    (default 0.5)
  --grace <seconds>      ignore the first n seconds of each clip (default 0)
  --thresholds <path>    JSON rule overrides, e.g. {"yawDegrees": 20}
  --min-recall <f>       fail the run below this recall   (0.9 = 90%)
  --max-fpr <f>          fail the run above this FPR      (0.1 = 10%)
  --browser <path>       the Chromium binary to drive (env PG_EVAL_BROWSER)
  --timeout-ms <n>       per-clip cap on the replay  (default 180000)
  --headed               show the browser window
  --dry-run              read the labels, print what would be replayed, exit
  --quiet                no per-clip progress lines
  --help

--grace defaults to 0 because a clip is a labelled window, not the first five
seconds of an attempt; --grace 5 reproduces the app exactly, which is the
comparison worth making once.

Exit codes: 0 ok, 1 a threshold failed or a clip could not be replayed,
2 bad configuration (unreadable labels, missing clips or clips folder).
`;

const OPTIONS = {
  labels: { type: 'string' },
  clips: { type: 'string' },
  out: { type: 'string' },
  limit: { type: 'string' },
  tolerance: { type: 'string' },
  grace: { type: 'string' },
  thresholds: { type: 'string' },
  'min-recall': { type: 'string' },
  'max-fpr': { type: 'string' },
  browser: { type: 'string' },
  'timeout-ms': { type: 'string' },
  headed: { type: 'boolean', default: false },
  'dry-run': { type: 'boolean', default: false },
  quiet: { type: 'boolean', default: false },
  help: { type: 'boolean', default: false },
};

function readEnv(name) {
  const value = process.env[name];
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : undefined;
}

function numberFlag(raw, fallback, name, { min = 0, max = Number.POSITIVE_INFINITY } = {}) {
  if (raw === undefined) return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < min || value > max) {
    throw new EvalError(`--${name} must be a number between ${min} and ${max}, got "${raw}"`);
  }
  return value;
}

/** The Dart that states the rules, read from the repo rather than restated here. */
function readDartSources() {
  const read = (relative) => {
    const path = join(REPO, 'mobile', 'lib', 'core', 'services', relative);
    if (!existsSync(path)) throw new EvalError(`cannot read ${relative} — is this the app repo?`);
    return readFileSync(path, 'utf8');
  };
  return {
    thresholdsSource: read('proctoring_thresholds.dart'),
    presenceSource: read('web_face_presence.dart'),
  };
}

/**
 * `--thresholds` — a JSON object of rule overrides.
 *
 * A key the judge does not have is refused: a typo that silently scored the
 * default rule would produce a confident number about a question nobody asked.
 */
function readRuleOverrides(path) {
  if (!path) return {};
  let raw;
  try {
    raw = readFileSync(path, 'utf8');
  } catch (error) {
    throw new EvalError(`cannot read --thresholds at ${path} (${error.code ?? error.message})`);
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new EvalError(`--thresholds at ${path} is not JSON`);
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new EvalError(`--thresholds at ${path} must be a JSON object of rule overrides`);
  }
  const unknown = Object.keys(parsed).filter((key) => !(key in DEFAULT_RULES));
  if (unknown.length > 0) {
    throw new EvalError(
      `--thresholds at ${path}: unknown rule(s) ${unknown.join(', ')} — ` +
        `known: ${Object.keys(DEFAULT_RULES).join(', ')}`,
    );
  }
  for (const [key, value] of Object.entries(parsed)) {
    if (!Number.isFinite(value) || value < 0) {
      throw new EvalError(`--thresholds at ${path}: ${key} must be a non-negative number`);
    }
  }
  return parsed;
}

/** The labels file, with every refusal carrying the reason the parser gave. */
function loadLabels(path) {
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch (error) {
    throw new EvalError(
      `cannot read the labels at ${path} (${error.code ?? error.message}). ` +
        'COPY labels.template.csv first — it documents every column.',
    );
  }
  try {
    return parseLabels(text);
  } catch (error) {
    // The parser's message already names the line and the column; the file name is
    // the only thing it cannot know.
    throw new EvalError(`${path}: ${error.message}`);
  }
}

/**
 * The clips the labels name, checked against the folder before anything is
 * launched.
 *
 * A missing file found after a browser is open costs a timeout and reports as a
 * detector failure; found here it costs one line and says exactly what is missing.
 */
function checkClips(clips, clipsDir) {
  const missing = clips.filter((clip) => !existsSync(join(clipsDir, clip)));
  if (missing.length > 0) {
    throw new EvalError(
      `${missing.length} labelled clip(s) are not in ${clipsDir}: ${missing.slice(0, 10).join(', ')}` +
        (missing.length > 10 ? `, … ${missing.length - 10} more` : ''),
    );
  }
}

/** What `--dry-run` prints: everything a run would do, and nothing it would send. */
function printDryRun({ labelsPath, clipsDir, clips, rows, rules, tolerance, browser, timeoutMs }) {
  const windows = rows.filter((row) => clips.includes(row.clip));
  const positives = windows.filter((row) => row.label).length;
  const lines = [];
  lines.push('ProctorGuard detector evaluation — dry run, nothing replayed');
  lines.push('');
  lines.push(`labels      ${labelsPath}`);
  lines.push(`clips       ${clipsDir}`);
  lines.push(`browser     ${browser}`);
  lines.push(`rules       ${describeRules(rules)}`);
  lines.push(`tolerance   ±${tolerance}s`);
  lines.push(`timeout     ${Math.round(timeoutMs / 1000)}s per clip`);
  lines.push('');
  lines.push(`${clips.length} clip(s), ${windows.length} window(s) (${positives} present, ${windows.length - positives} absent):`);
  for (const clip of clips) {
    const own = windows.filter((row) => row.clip === clip);
    const present = own.filter((row) => row.label).length;
    const actions = [...new Set(own.map((row) => row.action))].join('+');
    lines.push(`  ${clip.padEnd(34)} ${String(present).padStart(3)}/${String(own.length).padEnd(3)} ${actions}`);
  }
  lines.push('');
  if (positives === 0) {
    lines.push('  No present window: this run can measure false positives and nothing else.');
  }
  if (windows.length === positives) {
    lines.push('  No absent window: this run can measure recall and nothing else — a false-');
    lines.push('  positive rate needs label-0 rows around the episodes.');
  }
  lines.push('');
  lines.push('Re-run without --dry-run to replay them through the browser detector.');
  return lines.join('\n');
}

async function main(argv) {
  const { values } = parseArgs({ args: argv, options: OPTIONS, allowPositionals: false });
  if (values.help) {
    process.stdout.write(USAGE);
    return 0;
  }

  // ---- Configuration, all of it resolved before a browser exists -----------
  const labelsPath = resolve(values.labels ?? resolve(SCRIPT_DIR, 'labels.csv'));
  const clipsDir = resolve(
    values.clips ?? readEnv('PG_EVAL_CLIPS') ?? join(dirname(labelsPath), 'clips'),
  );
  const tolerance = numberFlag(values.tolerance, DEFAULT_TOLERANCE_SECONDS, 'tolerance', {
    max: 30,
  });
  const limit = numberFlag(values.limit, undefined, 'limit', { min: 1 });
  const timeoutMs = numberFlag(values['timeout-ms'], 180000, 'timeout-ms', { min: 5000 });
  const thresholds = {
    minRecall: numberFlag(values['min-recall'], undefined, 'min-recall', { max: 1 }),
    maxFpr: numberFlag(values['max-fpr'], undefined, 'max-fpr', { max: 1 }),
  };
  const browserPath = values.browser ?? readEnv('PG_EVAL_BROWSER');

  const { rows, warnings: labelWarnings } = loadLabels(labelsPath);
  const allClips = clipsOf(rows);
  if (allClips.length === 0) {
    throw new EvalError(`${labelsPath} has no windows — there is nothing to evaluate`);
  }
  const clips = limit === undefined ? allClips : allClips.slice(0, limit);
  checkClips(clips, clipsDir);

  // The app's thresholds, read from the Dart that states them, then whatever the
  // operator overrode. `--grace` is an override too: 0 is a decision, and so is 5.
  const rules = {
    ...readAppRules(readDartSources()),
    // Not the app's value: a clip here is a labelled window, so the startup grace
    // that stops a camera warning at login would swallow the opening of every
    // window in the file. `--grace 5` puts the app's own behaviour back.
    graceMs: 0,
    ...readRuleOverrides(values.thresholds),
  };
  const graceSeconds = numberFlag(values.grace, undefined, 'grace');
  if (graceSeconds !== undefined) rules.graceMs = Math.round(graceSeconds * 1000);

  if (values['dry-run']) {
    const browser = (() => {
      try {
        return findBrowser(browserPath);
      } catch (error) {
        return `(none: ${error.message})`;
      }
    })();
    process.stdout.write(
      `${printDryRun({
        labelsPath,
        clipsDir,
        clips,
        rows,
        rules,
        tolerance,
        browser,
        timeoutMs,
      })}\n`,
    );
    return 0;
  }

  // ---- The run -------------------------------------------------------------
  const startedAt = new Date().toISOString();
  const runStart = performance.now();
  const segments = [];
  const strays = [];
  const durations = {};
  const warnings = [...labelWarnings];
  const notes = new Set();
  const replayFailures = [];

  const server = await startServer({ clipsDir });
  let browser = null;
  try {
    browser = await launchBrowser({ browserPath, headed: values.headed, timeoutMs: 30000 });
    let index = 0;
    for (const clip of clips) {
      index += 1;
      let result;
      try {
        result = await replayClip(browser, { origin: server.origin, clip, timeoutMs });
      } catch (error) {
        // One unplayable file must not throw away the other clips' work — a corpus
        // of forty clips should not be lost to the forty-first. It is a failed
        // replay, it is warned about by name, and the run ends at exit 1.
        replayFailures.push(clip);
        warnings.push(String(error?.message ?? error));
        if (!values.quiet) {
          process.stdout.write(
            `[${String(index).padStart(String(clips.length).length)}/${clips.length}] ` +
              `${clip.padEnd(34)} could not be replayed\n`,
          );
        }
        continue;
      }

      if (Number.isFinite(result.duration) && result.duration > 0) {
        durations[clip] = result.duration;
      }
      if (result.timedOut) {
        replayFailures.push(clip);
        warnings.push(`${clip}: the replay did not finish — its windows are scored on what it reported`);
      }
      for (const error of result.errors.slice(0, 3)) warnings.push(`${clip}: ${error}`);
      if (result.frames === 0) {
        warnings.push(`${clip}: the preview delivered no frames at all`);
      }
      // A page that could not measure a head pose still says `centered`, so it can
      // never produce a `looking_away`. Saying that once, in the report, is the
      // difference between "the detector is blind" and "the harness is blind".
      if (result.model !== 'mediapipe' && result.model !== 'native') {
        notes.add(
          `the page measured no head pose (face model: ${result.model}, state: ${result.modelState}) — ` +
            'looking_away recall on this run measures the harness, not the detector',
        );
      }
      if (result.reason) {
        notes.add(`the last tick saw no usable picture (${result.reason})`);
      }

      const actions = judgeVerdicts(result.verdicts, rules);
      const own = rows.filter((row) => row.clip === clip);
      let resolved;
      try {
        resolved = resolveEnds(own, durations);
      } catch (error) {
        throw new EvalError(`${clip}: ${error.message} — give the window an end, or make the clip play`);
      }

      let scored;
      try {
        scored = evaluateClip(resolved, actions, { tolerance });
      } catch (error) {
        throw new EvalError(`${error.message}`);
      }
      segments.push(...scored.segments);
      for (const stray of scored.strays) strays.push({ clip, ...stray });

      if (!values.quiet) {
        const hits = scored.segments.filter((segment) => segment.hit).length;
        const present = scored.segments.filter((segment) => segment.positive).length;
        const fps = result.duration ? (result.frames / result.duration).toFixed(1) : '?';
        process.stdout.write(
          `[${String(index).padStart(String(clips.length).length)}/${clips.length}] ` +
            `${clip.padEnd(34)} ${(result.duration ?? 0).toFixed(1)}s ` +
            `${String(result.verdicts.length).padStart(4)} verdicts ` +
            `${String(actions.length).padStart(3)} violation(s) ` +
            `${hits}/${present} hits  ${fps}fps  ${result.model}\n`,
        );
      }
    }
  } finally {
    if (browser) await browser.close();
    await server.close();
  }


  // ---- The report ----------------------------------------------------------
  const durationSeconds = (performance.now() - runStart) / 1000;
  const total = summarize(segments, strays);
  const verdicts = evaluateThresholds(total, thresholds);

  // Two warnings that only matter once the run is over: a folder with no
  // negatives cannot produce a false-positive rate, and reporting 0.0% for one
  // would be the most misleading number this tool could print.
  if (total.negatives === 0) {
    warnings.push(
      'no label-0 windows were replayed, so precision and the false-positive rate ' +
        'are not measured — add absent windows around each episode',
    );
  }
  if (total.positives === 0) {
    warnings.push('no label-1 windows were replayed, so recall is not measured');
  }

  const report = {
    labelsPath,
    clips: allClips,
    // Only the clips whose replay actually produced a result: a clip that could not
    // be played is in `warnings`, and counting it here would overstate the corpus.
    replayed: clips.filter((clip) => !replayFailures.includes(clip)),
    segments,
    strays,
    rules,
    tolerance,
    verdicts,
    warnings: [...warnings, ...notes],
    startedAt,
    durationSeconds,
  };

  process.stdout.write(`\n${formatReport(report)}\n`);

  if (values.out !== undefined) {
    const outPath = resolve(values.out);
    mkdirSync(dirname(outPath), { recursive: true });
    writeFileSync(`${outPath}`, `${JSON.stringify(toJsonReport(report), null, 2)}\n`, 'utf8');
    process.stdout.write(`JSON report: ${outPath}\n`);
  }

  const failed = verdicts.some((verdict) => !verdict.ok) || replayFailures.length > 0;
  if (replayFailures.length > 0) {
    process.stdout.write(
      `\n${replayFailures.length} clip(s) could not be replayed: ${replayFailures.join(', ')}\n` +
        'The scores above are over the clips that could; re-run those before quoting them.\n',
    );
  }
  return failed ? EXIT_THRESHOLD : 0;
}

main(process.argv.slice(2))
  .then((code) => {
    process.exit(code);
  })
  .catch((error) => {
    process.stderr.write(`\nerror: ${error?.message ?? String(error)}\n\n`);
    if (error instanceof EvalError) {
      process.stderr.write('Run with --help for the options. Nothing was replayed.\n');
    }
    process.exit(EXIT_CONFIG);
  });

