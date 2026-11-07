/**
 * The report: what an operator reads after the run, and what they paste into a
 * ticket. Fixed-width text on stdout, the same numbers as JSON behind `--out`.
 *
 * Layout rule: the totals come first (error rate, then p50/p95/p99), then the
 * per-operation table, then every 429 and 5xx status, then a handful of raw
 * failures. If a run went wrong the reader should learn *what* from the first
 * screenful, and *why* from the samples below it.
 */

const MS = (value) => `${Math.round(value)}ms`;
const PCT = (value) => `${(value * 100).toFixed(2)}%`;

function pad(text, width, align = 'left') {
  const value = String(text);
  if (value.length >= width) return value;
  const fill = ' '.repeat(width - value.length);
  return align === 'right' ? `${fill}${value}` : `${value}${fill}`;
}

function table(headers, rows, aligns) {
  const widths = headers.map((header, index) => {
    const cellWidths = rows.map((row) => String(row[index]).length);
    return Math.max(String(header).length, ...cellWidths);
  });
  const line = (cells) => cells
    .map((cell, index) => pad(cell, widths[index], aligns?.[index] ?? 'left'))
    .join('  ')
    .trimEnd();
  return [
    line(headers),
    line(widths.map((width) => '-'.repeat(width))),
    ...rows.map(line),
  ].join('\n');
}

function statusLabel(status) {
  if (status === 0) return 'transport failure (refused, DNS, timeout)';
  if (status === 429) return 'rate limited by Supabase';
  if (status === 401 || status === 403) return 'auth/RLS refusal';
  if (status === 409) return 'unique violation (attempt already exists)';
  if (status >= 500) return 'server error';
  if (status >= 200 && status < 300) return 'ok';
  return '';
}

function describeGuard(environment) {
  if (environment.isLocal) return 'local target — production ref not applicable';
  if (environment.productionRef === null) return 'URL and key checked; no production ref on disk to compare';
  if (environment.projectRef === null) return 'foreign host allowed by LOADTEST_ALLOW_FOREIGN_HOST';
  return `staging (${environment.projectRef}) is not production (${environment.productionRef})`;
}

/**
 * @param {object} run
 * @param {object} run.environment   from assertStaging: url, projectRef, keyRef, productionRef, isLocal
 * @param {object[]} run.stages      parsed stages
 * @param {object} run.summary       Recorder#summarise()
 * @param {object} run.sessions      aggregated session outcomes
 * @param {object} run.config        the effective settings
 * @param {string} run.startedAt     ISO timestamp
 * @param {number} run.durationSeconds wall-clock length of the run
 */
export function formatReport({ environment, stages, summary, sessions, config, startedAt, durationSeconds, verdicts = [] }) {
  const lines = [];
  const rule = '='.repeat(78);

  lines.push(rule);
  lines.push('ProctorGuard staging load test');
  lines.push(rule);
  lines.push(`target        ${environment.url}`);
  lines.push(`project ref   ${environment.projectRef ?? (environment.isLocal ? 'local (no project ref)' : 'not a *.supabase.co host')}`);
  lines.push(`production    ${environment.productionRef ?? 'not found (supabase/.temp/project-ref missing)'}`);
  lines.push(`key ref       ${environment.keyRef ?? 'not a JWT (publishable key, or not a Supabase key)'}`);
  lines.push(`guard         ${describeGuard(environment)}`);
  lines.push(`started       ${startedAt}`);
  lines.push(`duration      ${Math.round(durationSeconds)}s   ramp ${stages.map((s) => `${s.target}:${Math.round(s.seconds)}s`).join(', ')}`);
  lines.push(
    `traffic       answer/${config.answerEverySeconds}s  heartbeat/${config.heartbeatEverySeconds}s  ` +
      `violations ${config.violationsPerMinute}/min (${config.violationType})  session ${config.sessionSeconds}s`,
  );
  lines.push('');

  lines.push('TOTALS');
  lines.push(table(
    ['requests', 'errors', 'error rate', 'p50', 'p95', 'p99', 'mean', 'max'],
    [[
      summary.requests,
      summary.errors,
      PCT(summary.errorRate),
      MS(summary.p50),
      MS(summary.p95),
      MS(summary.p99),
      MS(summary.mean),
      MS(summary.max),
    ]],
    ['right', 'right', 'right', 'right', 'right', 'right', 'right', 'right'],
  ));
  lines.push('');

  lines.push('SESSIONS');
  lines.push(table(
    ['started', 'submitted', 'failed', 'peak concurrent', 'expected peak'],
    [[
      sessions.started,
      sessions.submitted,
      sessions.failed,
      sessions.peakConcurrency,
      sessions.expectedPeak,
    ]],
    ['right', 'right', 'right', 'right', 'right'],
  ));
  lines.push(
    `client work   answers ${sessions.answers}   heartbeats ${sessions.heartbeats} ` +
      `(throttled ${sessions.heartbeatsThrottled}, duplicate ${sessions.heartbeatsDuplicated})   ` +
      `violations ${sessions.violations}`,
  );
  if (sessions.reasons.length > 0) {
    lines.push('');
    lines.push('why sessions ended early (most frequent first):');
    for (const [reason, count] of sessions.reasons) {
      lines.push(`  ${String(count).padStart(5)}x  ${reason}`);
    }
  }
  lines.push('');

  lines.push('BY OPERATION');
  const rows = summary.ops.map((op) => [
    op.op,
    op.count,
    op.errors,
    PCT(op.errorRate),
    MS(op.p50),
    MS(op.p95),
    MS(op.p99),
    MS(op.max),
  ]);
  if (rows.length > 0) {
    lines.push(table(
      ['operation', 'count', 'errors', 'error rate', 'p50', 'p95', 'p99', 'max'],
      rows,
      ['left', 'right', 'right', 'right', 'right', 'right', 'right', 'right'],
    ));
  } else {
    lines.push('  (no requests recorded)');
  }
  lines.push('');

  lines.push('STATUS CODES');
  if (summary.statuses.length === 0) {
    lines.push('  (none)');
  } else {
    const statusRows = summary.statuses.map(([status, count]) => [
      status === 0 ? 'no answer' : status,
      count,
      statusLabel(status),
    ]);
    lines.push(table(['status', 'count', 'note'], statusRows, ['right', 'right', 'left']));
  }
  lines.push('');
  lines.push(`429 (rate limited): ${summary.tooManyRequests}    5xx (server): ${summary.serverErrors}`);
  if (summary.tooManyRequests > 0) {
    lines.push('  429s are counted as errors on purpose: the free plan answers them before it');
    lines.push('  breaks, and they are the first sign the ramp went past what the project allows.');
  }
  if (summary.serverErrors > 0) {
    lines.push('  5xx: check the project\'s Postgres and Edge logs for the same window before');
    lines.push('  reading the latency numbers — a 500 that returns in 20 ms is still a 500.');
  }

  if (summary.failures.length > 0) {
    lines.push('');
    lines.push(`FIRST ${summary.failures.length} FAILURES`);
    for (const failure of summary.failures) {
      const word = failure.status === 0 ? 'NONET' : failure.status;
      lines.push(
        `  ${String(word).padStart(5)}  ${pad(failure.op, 14)} ${MS(failure.durationMs).padStart(7)}  ` +
          `${failure.body ?? failure.error ?? ''}`,
      );
    }
  }

  if (verdicts.length > 0) {
    lines.push('');
    lines.push('THRESHOLDS');
    for (const verdict of verdicts) {
      lines.push(`  ${verdict.ok ? 'PASS' : 'FAIL'}  ${verdict.name}  (${verdict.detail})`);
    }
  }

  lines.push('');
  lines.push(rule);
  return lines.join('\n');
}

/**
 * Threshold verdicts, k6-style: the run fails (non-zero exit) when either number
 * is worse than the flag said. An absent flag means "no threshold", not "0".
 *
 * @returns {{ name: string, ok: boolean, detail: string }[]}
 */
export function evaluateThresholds(summary, { p95Ms, errorRate, maxServerErrors, maxTooManyRequests }) {
  const verdicts = [];
  if (Number.isFinite(p95Ms)) {
    verdicts.push({
      name: `p95 < ${p95Ms}ms`,
      ok: summary.p95 < p95Ms,
      detail: `p95 was ${MS(summary.p95)}`,
    });
  }
  if (Number.isFinite(errorRate)) {
    verdicts.push({
      name: `error rate < ${PCT(errorRate)}`,
      ok: summary.errorRate < errorRate,
      detail: `error rate was ${PCT(summary.errorRate)}`,
    });
  }
  if (Number.isFinite(maxServerErrors)) {
    verdicts.push({
      name: `5xx <= ${maxServerErrors}`,
      ok: summary.serverErrors <= maxServerErrors,
      detail: `${summary.serverErrors} server errors`,
    });
  }
  if (Number.isFinite(maxTooManyRequests)) {
    verdicts.push({
      name: `429 <= ${maxTooManyRequests}`,
      ok: summary.tooManyRequests <= maxTooManyRequests,
      detail: `${summary.tooManyRequests} rate-limited responses`,
    });
  }
  return verdicts;
}

/** The JSON report written by `--out`: the same facts, nothing pre-formatted. */
export function toJsonReport({ environment, stages, summary, sessions, config, startedAt, durationSeconds, verdicts }) {
  return {
    generatedAt: new Date().toISOString(),
    startedAt,
    durationSeconds: Math.round(durationSeconds),
    environment,
    stages,
    config,
    summary,
    sessions: { ...sessions, reasons: sessions.reasons.map(([reason, count]) => ({ reason, count })) },
    verdicts,
  };
}
