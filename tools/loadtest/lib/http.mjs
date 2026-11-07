/**
 * The smallest HTTP client that can speak to PostgREST and GoTrue, with the
 * measurement built in rather than bolted on.
 *
 * Rules it keeps:
 *
 *   * **no retries.** A load test that retries measures the retry policy, not
 *     the server. A 429 is a result: it is counted, and the report shows it.
 *   * **no throwing on status.** Every response is a value, so a session can
 *     tell "the paper is closed" (403) from "you are going too fast" (429) and
 *     stop for the right reason.
 *   * **a per-request timeout**, because a saturating PostgREST pool answers by
 *     *not* answering, and a run that hangs is indistinguishable from one that
 *     is merely slow.
 */

export const DEFAULT_TIMEOUT_MS = 20_000;

export class HttpClient {
  constructor({ baseUrl, apiKey, recorder, timeoutMs = DEFAULT_TIMEOUT_MS }) {
    if (typeof baseUrl !== 'string' || baseUrl === '') throw new Error('HttpClient needs a baseUrl');
    if (typeof apiKey !== 'string' || apiKey === '') throw new Error('HttpClient needs an apiKey');
    if (recorder === undefined || recorder === null) throw new Error('HttpClient needs a recorder');
    this.baseUrl = baseUrl.replace(/\/+$/, '');
    this.apiKey = apiKey;
    this.recorder = recorder;
    this.timeoutMs = timeoutMs;
  }

  /**
   * @param {string} op      metric label for this call, e.g. 'answer'
   * @param {string} path    path below the base URL, e.g. '/rest/v1/rpc/submit_exam'
   * @param {object} [options]
   * @param {'GET'|'POST'|'PATCH'|'DELETE'} [options.method]
   * @param {string} [options.token]  the student's access token
   * @param {unknown} [options.body]  JSON-encoded when present
   * @param {Record<string,string>} [options.headers]
   * @returns {Promise<{ ok: boolean, status: number, data: any, text: string, error?: string }>}
   */
  async call(op, path, { method = 'GET', token, body, headers = {} } = {}) {
    const requestHeaders = {
      apikey: this.apiKey,
      'Content-Type': 'application/json',
      Accept: 'application/json',
      ...headers,
    };
    if (token !== undefined && token !== null) {
      requestHeaders.Authorization = `Bearer ${token}`;
    }

    const startedAt = performance.now();
    let response;
    let text = '';
    try {
      response = await fetch(`${this.baseUrl}${path}`, {
        method,
        headers: requestHeaders,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
      text = await response.text();
    } catch (error) {
      const durationMs = performance.now() - startedAt;
      const message = error?.name === 'TimeoutError' || error?.name === 'AbortError'
        ? `timeout after ${this.timeoutMs}ms`
        : `${error?.name ?? 'Error'}: ${error?.message ?? String(error)}`;
      // Status 0 is "no HTTP answer at all" — a refused connection, a DNS
      // failure, or the timeout above. It is counted as an error, and the
      // network layer's own words are kept for the failure list.
      this.recorder.record(op, { durationMs, status: 0, error: message });
      return { ok: false, status: 0, data: null, text: '', error: message };
    }

    const durationMs = performance.now() - startedAt;
    let data = null;
    if (text !== '') {
      try {
        data = JSON.parse(text);
      } catch {
        data = null;
      }
    }

    this.recorder.record(op, {
      durationMs,
      status: response.status,
      body: response.ok ? undefined : text,
    });

    return { ok: response.ok, status: response.status, data, text };
  }

  /** The PostgREST error `message` when there is one, for a one-line report. */
  static errorMessage(result) {
    if (result === null || result === undefined) return 'no response';
    if (typeof result.error === 'string') return result.error;
    const data = result.data;
    if (data !== null && typeof data === 'object') {
      if (typeof data.message === 'string') return data.message;
      if (typeof data.error_description === 'string') return data.error_description;
      if (typeof data.msg === 'string') return data.msg;
    }
    if (typeof result.text === 'string' && result.text !== '') return result.text.slice(0, 200);
    return `HTTP ${result.status}`;
  }
}
