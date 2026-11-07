/**
 * The report: what a reviewer reads, and what a reviewer files.
 *
 * Fixed-width text on stdout, the same numbers as JSON behind `--out`. The order
 * is deliberate — the rules first (a score means nothing without the thresholds
 * that produced it), then per action, then per tag, then the strays, then the
 * verdicts. If a run went wrong the reader should learn *which* slice is weak from
 * the first screenful.
 */

import { byAction, byTag, summarize } from './match.mjs';

const NUM = (value, digits = 0) =>
  value === null || value === undefined ? '—' : value.toFixed(digits);
const PCT = (value) =>
  value === null || value === undefined ? '—' : `${(value * 100).toFixed(1)}%`;

function pad(text, width, align = 'left') {
  const value = String(text);
  if (value.length >= width) return value;
  const fill = ' '.repeat(width - value.length);
  return align === 'right' ? `${fill}${value}` : `${value}${fill}`;
}

function table(headers, rows, aligns) {
  const widths = headers.map((header, index) =>
    Math.max(String(header).length, ...rows.map((row) => String(row[index]).length), 1),
  );
  const line = (cells) =>
    cells
      .map((cell, index) => pad(cell, widths[index], aligns?.[index] ?? 'left'))
      .join('  ')
      .trimEnd();
  return [line(headers), line(widths.map((width) => '-'.repeat(width))), ...rows.map(line)].join(
    '\n',
  );
}

/** The rules in one line, so a scored run can be reproduced from its own output. */
export function describeRules(rules) {
  return [
    `yaw > ${rules.yawDegrees}°`,
    `pitch > ${rules.pitchDegrees}°`,
    `immediate > ${rules.immediateYawDegrees}°`,
    `sustain ${rules.sustainMs}ms`,
    `grace ${rules.graceMs}ms`,
    `two-face re-arm ${rules.multipleFacesCooldownMs}ms`,
  ].join(', ');
}

const RATE_HEADERS = [
  'slice',
  'present',
  'hit',
  'miss',
  'recall',
  'absent',
  'fp',
  'fp/min',
  'fpr',
  'precision',
];

const RATE_ALIGNS = [
  'left',
  'right',
  'right',
  'right',
  'right',
  'right',
  'right',
  'right',
  'right',
  'right',
];

function rateRows(rows) {
  return rows.map((row) => [
    row.tag ?? row.action,
    NUM(row.positives),
    NUM(row.hits),
    NUM(row.misses),
    PCT(row.recall),
    NUM(row.negatives),
    NUM(row.falsePositives),
    NUM(row.falsePositivesPerMinute, 2),
    PCT(row.fpr),
    PCT(row.precision),
  ]);
}

/**
 * @param {object} report
 * @param {string} report.labelsPath
 * @param {string[]} report.clips       every clip the labels mention
 * @param {string[]} report.replayed    the clips this run actually played
 * @param {object[]} report.segments    every clip's evaluateClip().segments, concatenated
 * @param {{clip:string, action:string, t:number}[]} report.strays
 * @param {object} report.rules         from judge.readAppRules()
 * @param {number} report.tolerance     seconds around each window
 * @param {{name:string, ok:boolean, detail:string}[]} [report.verdicts]
 * @param {string[]} [report.warnings]
 * @param {string} [report.startedAt]
 * @param {number} [report.durationSeconds]
 */
export function formatReport({
  labelsPath,
  clips,
  replayed,
  segments,
  strays,
  rules,
  tolerance,
  verdicts = [],
  warnings = [],
  startedAt,
  durationSeconds,
}) {
  const lines = [];
  const rule = '='.repeat(78);

  lines.push(rule);
  lines.push('ProctorGuard detector evaluation');
  lines.push(rule);
  lines.push(`labels        ${labelsPath}`);
  lines.push(`clips         ${replayed.length} replayed of ${clips.length} labelled`);
  lines.push(`rules         ${describeRules(rules)}`);
  lines.push(`tolerance     ±${tolerance}s around every window`);
  if (startedAt) lines.push(`started       ${startedAt}`);
  if (Number.isFinite(durationSeconds)) {
    lines.push(`wall clock    ${Math.round(durationSeconds)}s for ${replayed.length} clip(s)`);
  }
  const positives = segments.filter((segment) => segment.positive).length;
  lines.push(
    `windows       ${segments.length} (${positives} present, ${segments.length - positives} absent)`,
  );
  lines.push('');

  lines.push('BY ACTION');
  lines.push(table(RATE_HEADERS, rateRows(byAction(segments, strays)), RATE_ALIGNS));
  lines.push('');

  lines.push('BY TAG');
  lines.push(table(RATE_HEADERS, rateRows(byTag(segments)), RATE_ALIGNS));
  lines.push('');
  lines.push('  A window tagged twice counts in both rows. An absent-only tag shows recall as —,');
  lines.push('  because there was nothing to recall and 0% would read as a failure.');
  lines.push('');

  lines.push(`STRAYS   ${strays.length} detection(s) outside every labelled window of their action`);
  if (strays.length > 0) {
    for (const stray of strays.slice(0, 10)) {
      lines.push(`  ${pad(stray.clip, 28)} ${pad(stray.action, 15)} t=${stray.t.toFixed(2)}s`);
    }
    if (strays.length > 10) lines.push(`  … ${strays.length - 10} more in the JSON report`);
    lines.push('  A stray is reported, not scored: it may be the detector being right about');
    lines.push('  something nobody labelled. Label it, or widen the window it fell outside.');
  }
  lines.push('');

  if (warnings.length > 0) {
    lines.push('WARNINGS');
    for (const warning of warnings) lines.push(`  ${warning}`);
    lines.push('');
  }

  if (verdicts.length > 0) {
    lines.push('THRESHOLDS');
    for (const verdict of verdicts) {
      lines.push(`  ${verdict.ok ? 'PASS' : 'FAIL'}  ${verdict.name}   (${verdict.detail})`);
    }
    lines.push('');
  }

  lines.push(rule);
  return lines.join('\n');
}

/**
 * Threshold verdicts, the same shape the load test uses: an absent flag is not a
 * threshold of zero, so nothing is asserted unless the operator asked for it.
 *
 * @param {ReturnType<typeof summarize>} total
 * @param {{ minRecall?: number, maxFpr?: number }} thresholds
 * @returns {{ name: string, ok: boolean, detail: string }[]}
 */
export function evaluateThresholds(total, { minRecall, maxFpr } = {}) {
  const verdicts = [];
  if (Number.isFinite(minRecall)) {
    verdicts.push({
      name: `recall >= ${PCT(minRecall)}`,
      ok: total.recall !== null && total.recall >= minRecall,
      detail: `recall was ${PCT(total.recall)}`,
    });
  }
  if (Number.isFinite(maxFpr)) {
    verdicts.push({
      name: `fpr <= ${PCT(maxFpr)}`,
      ok: total.fpr !== null && total.fpr <= maxFpr,
      detail: `fpr was ${PCT(total.fpr)}`,
    });
  }
  return verdicts;
}

/** The JSON report: the same facts, nothing pre-formatted. */
export function toJsonReport({
  labelsPath,
  clips,
  replayed,
  segments,
  strays,
  rules,
  tolerance,
  verdicts = [],
  warnings = [],
  startedAt,
  durationSeconds,
}) {
  return {
    generatedAt: new Date().toISOString(),
    startedAt: startedAt ?? null,
    durationSeconds: Number.isFinite(durationSeconds) ? Math.round(durationSeconds) : null,
    labelsPath,
    clips,
    replayed,
    rules,
    tolerance,
    total: summarize(segments),
    byAction: byAction(segments, strays),
    byTag: byTag(segments),
    strays,
    warnings,
    verdicts,
  };
}
