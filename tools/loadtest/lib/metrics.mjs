/**
 * Latency and error bookkeeping for the staging load test.
 *
 * Two decisions worth stating, because a percentile is only comparable to
 * another percentile when both were computed the same way:
 *
 *   1. Percentiles are **linearly interpolated** over the sorted sample (the
 *      same definition as numpy's default and Excel's `PERCENTILE.INC`), not
 *      "nearest rank". With 500 students a run produces tens of thousands of
 *      samples per operation, so the two agree to the millisecond; writing the
 *      definition down is what stops a later change from silently moving p99.
 *
 *   2. Every request is recorded, including the failed ones, and the failure is
 *      *also* counted separately. A p95 latency computed only over HTTP 200s
 *      hides exactly the case the test exists to find: the server answering
 *      quickly with 429 while the slow, honest requests queue behind it.
 */

/** A growable set of latency samples with O(n log n) percentile lookup. */
export class SampleSet {
  #values = [];
  #sorted = null;

  add(value) {
    if (!Number.isFinite(value) || value < 0) {
      throw new RangeError(`latency sample must be a finite, non-negative number, got ${value}`);
    }
    this.#values.push(value);
    this.#sorted = null;
  }

  get count() {
    return this.#values.length;
  }

  /** Sorted copy, recomputed only when a sample was added since it was built. */
  sorted() {
    if (this.#sorted === null) {
      this.#sorted = Float64Array.from(this.#values).sort();
    }
    return this.#sorted;
  }

  mean() {
    if (this.#values.length === 0) return 0;
    let total = 0;
    for (const value of this.#values) total += value;
    return total / this.#values.length;
  }

  max() {
    const sorted = this.sorted();
    return sorted.length === 0 ? 0 : sorted[sorted.length - 1];
  }

  /** `p` is a percentage in [0, 100]. Returns 0 for an empty set, never NaN. */
  percentile(p) {
    if (!Number.isFinite(p) || p < 0 || p > 100) {
      throw new RangeError(`percentile must be between 0 and 100, got ${p}`);
    }
    const sorted = this.sorted();
    const n = sorted.length;
    if (n === 0) return 0;
    if (n === 1) return sorted[0];

    const rank = (n - 1) * (p / 100);
    const lower = Math.floor(rank);
    const upper = Math.ceil(rank);
    if (lower === upper) return sorted[lower];
    const weight = rank - lower;
    return sorted[lower] * (1 - weight) + sorted[upper] * weight;
  }
}

function truncate(text, limit) {
  if (typeof text !== 'string') return text ?? null;
  return text.length <= limit ? text : `${text.slice(0, limit)}…`;
}

/**
 * Collects one sample per HTTP request, grouped by the *operation* the session
 * was performing (`auth`, `answer`, `heartbeat`, …) and in total.
 *
 * Grouping by operation is what makes a p99 actionable: a single p99 over the
 * whole run is nearly always the sign-in burst, and a sign-in storm is a
 * different problem from a slow `submit_exam`.
 */
export class Recorder {
  constructor({ maxFailures = 50 } = {}) {
    this.overall = new SampleSet();
    this.ops = new Map();
    this.statusCounts = new Map();
    this.failures = [];
    this.maxFailures = maxFailures;
    this.requests = 0;
    this.errors = 0;
  }

  #op(name) {
    let entry = this.ops.get(name);
    if (entry === undefined) {
      entry = { name, latency: new SampleSet(), count: 0, errors: 0 };
      this.ops.set(name, entry);
    }
    return entry;
  }

  /**
   * @param {string} op        operation label, e.g. 'answer'
   * @param {object} result
   * @param {number} result.durationMs wall-clock time of the request
   * @param {number} result.status     HTTP status, or 0 for a transport failure
   * @param {string} [result.error]    transport error message, when status is 0
   * @param {string} [result.body]     response body, kept only for failures
   */
  record(op, { durationMs, status, error, body }) {
    this.requests += 1;
    this.overall.add(durationMs);

    const entry = this.#op(op);
    entry.count += 1;
    entry.latency.add(durationMs);

    this.statusCounts.set(status, (this.statusCounts.get(status) ?? 0) + 1);

    if (status < 200 || status >= 300) {
      this.errors += 1;
      entry.errors += 1;
      if (this.failures.length < this.maxFailures) {
        this.failures.push({ op, status, durationMs: Math.round(durationMs), error: error ?? null, body: truncate(body, 300) });
      }
    }
  }

  /** Count of responses carrying one exact status code. */
  statusCount(status) {
    return this.statusCounts.get(status) ?? 0;
  }

  /** Count of responses with any 5xx status. */
  serverErrors() {
    let total = 0;
    for (const [status, count] of this.statusCounts) {
      if (status >= 500) total += count;
    }
    return total;
  }

  summarise() {
    const ops = [...this.ops.values()]
      .map((entry) => ({
        op: entry.name,
        count: entry.count,
        errors: entry.errors,
        errorRate: entry.count === 0 ? 0 : entry.errors / entry.count,
        p50: entry.latency.percentile(50),
        p95: entry.latency.percentile(95),
        p99: entry.latency.percentile(99),
        max: entry.latency.max(),
        mean: entry.latency.mean(),
      }))
      // Busiest first: a reader looking for the slowest thing should not have to
      // scroll past the ten least-used operations.
      .sort((a, b) => b.count - a.count || a.op.localeCompare(b.op));

    return {
      requests: this.requests,
      errors: this.errors,
      errorRate: this.requests === 0 ? 0 : this.errors / this.requests,
      p50: this.overall.percentile(50),
      p95: this.overall.percentile(95),
      p99: this.overall.percentile(99),
      max: this.overall.max(),
      mean: this.overall.mean(),
      tooManyRequests: this.statusCount(429),
      serverErrors: this.serverErrors(),
      statuses: [...this.statusCounts.entries()].sort((a, b) => a[0] - b[0]),
      ops,
      failures: this.failures,
    };
  }
}
