/**
 * The labels file: one row per *window* of one clip.
 *
 * A window says what the app should have decided while that stretch of video was
 * playing — not what the detector should have said about every frame. That is the
 * unit the app itself uses (an episode, sustained and latched), so it is the unit
 * a clip is labelled in, and scoring frames against it would measure a cadence
 * nobody chose.
 *
 * ```
 * # clip,action,start,end,label,tags
 * clip,action,start,end,label,tags
 * 01-away-left.mp4,looking_away,2.5,6.0,1,lighting=bright;glasses=yes
 * 01-away-left.mp4,looking_away,0.0,2.0,0,lighting=bright;glasses=yes
 * 02-empty-chair.mp4,no_face,3.0,,1,lighting=dim
 * ```
 *
 *  * `label = 1` — the action is happening: the app should have reported it in
 *    (or within `--tolerance` of) this window, and reporting nothing is a miss.
 *  * `label = 0` — a hard negative: nothing of that action happens here, and a
 *    report inside it is a false positive. A glance, a blink, a head that turns
 *    and comes back: the negatives are where the false-positive rate comes from,
 *    so a clips folder with no `0` rows can only measure recall.
 *  * `end` may be blank, meaning "to the end of the clip" — resolved once the
 *    replay has read the clip's own duration.
 *  * `tags` is `key=value;key=value`, free-form, and is what the report segments
 *    by: `lighting=dim`, `glasses=yes`, `pair=male-2`. The same tags on every row
 *    of the same cohort is how a slice is compared across clips.
 *
 * `#` lines are comments, so the template can explain itself and a labeller can
 * leave a note next to a window that was hard to call.
 */

/** The verbs the app logs as violations. The judge speaks exactly these. */
export const ACTIONS = ['looking_away', 'no_face', 'multiple_faces'];

/** The columns, in order. `line` and `tags` are added by the parser. */
export const COLUMNS = ['clip', 'action', 'start', 'end', 'label', 'tags'];

const TAG_PATTERN = /^[A-Za-z0-9_.+-]+=[A-Za-z0-9_.+-]+$/;

/**
 * One CSV line → cells, honouring `"quoted, cells"` and `""` escapes.
 *
 * Only as much CSV as the format needs: a tags cell with a comma in it is quoted
 * by any spreadsheet that writes it, and a labeller who uses one should not get a
 * window labelled `glasses=yes` plus a stray unexplained column.
 */
export function splitCsvLine(line) {
  const cells = [];
  let cell = '';
  let quoted = false;
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    if (quoted) {
      if (character === '"') {
        if (line[index + 1] === '"') {
          cell += '"';
          index += 1;
        } else {
          quoted = false;
        }
      } else {
        cell += character;
      }
      continue;
    }
    if (character === '"') {
      quoted = true;
      continue;
    }
    if (character === ',') {
      cells.push(cell);
      cell = '';
      continue;
    }
    cell += character;
  }
  cells.push(cell);
  return cells.map((value) => value.trim());
}

/** One `start`/`end` cell → seconds, or a refusal that names the line. */
function seconds(value, line, column) {
  const number = Number(value);
  if (value === '' || !Number.isFinite(number) || number < 0) {
    throw new Error(`line ${line}: ${column} is not a number of seconds: "${value}"`);
  }
  return number;
}

/**
 * Parses the file.
 *
 * Every refusal names the line and the column, because the person fixing it is
 * holding the spreadsheet: a silent skip would drop a window out of the metrics
 * and quietly improve the score.
 *
 * @param {string} text
 * @param {{ actions?: string[] }} [options]
 * @returns {{ rows: object[], warnings: string[] }}
 */
export function parseLabels(text, { actions = ACTIONS } = {}) {
  const rows = [];
  const warnings = [];
  const known = new Set(actions);
  const lines = String(text).replace(/^\uFEFF/, '').split(/\r?\n/);
  let sawHeader = false;

  lines.forEach((raw, index) => {
    const line = index + 1;
    const trimmed = raw.trim();
    if (trimmed === '' || trimmed.startsWith('#')) return;

    const cells = splitCsvLine(raw);
    if (!sawHeader) {
      const header = cells.map((cell) => cell.toLowerCase());
      if (header.join(',') !== COLUMNS.join(',')) {
        throw new Error(
          `line ${line}: the header must be "${COLUMNS.join(',')}" (got "${cells.join(',')}")`,
        );
      }
      sawHeader = true;
      return;
    }

    if (cells.length !== COLUMNS.length) {
      throw new Error(
        `line ${line}: ${cells.length} columns, expected ${COLUMNS.length} (${COLUMNS.join(',')})` +
          (cells.length > COLUMNS.length ? ' — a comma inside `tags` has to be quoted' : ''),
      );
    }

    const [clip, action, startCell, endCell, labelCell, tagsCell] = cells;
    if (!clip) throw new Error(`line ${line}: clip is empty`);
    if (/[\\/]|^\.\.?$/.test(clip) || /^[A-Za-z]:/.test(clip)) {
      throw new Error(
        `line ${line}: clip must be a file name inside the clips folder, not a path: "${clip}"`,
      );
    }
    if (!known.has(action)) {
      throw new Error(
        `line ${line}: action "${action}" is not one this app logs (${actions.join(', ')})`,
      );
    }

    const start = seconds(startCell, line, 'start');
    const end = endCell === '' ? null : seconds(endCell, line, 'end');
    if (end !== null && end <= start) {
      throw new Error(`line ${line}: end (${end}s) must be after start (${start}s)`);
    }

    if (labelCell !== '0' && labelCell !== '1') {
      throw new Error(`line ${line}: label must be 0 (absent) or 1 (present), not "${labelCell}"`);
    }

    const tags = {};
    const tagList = [];
    if (tagsCell !== '') {
      for (const piece of tagsCell.split(';')) {
        const tag = piece.trim();
        if (tag === '') continue;
        if (!TAG_PATTERN.test(tag)) {
          throw new Error(`line ${line}: tag "${tag}" is not key=value (letters, digits, _.+-)`);
        }
        const [key, value] = tag.split('=');
        if (Object.prototype.hasOwnProperty.call(tags, key)) {
          throw new Error(`line ${line}: tag "${key}" is given twice`);
        }
        tags[key] = value;
        tagList.push(tag);
      }
    }

    rows.push({
      line,
      clip,
      action,
      start,
      end,
      label: labelCell === '1',
      tags,
      tagList,
    });
  });

  if (!sawHeader) {
    throw new Error(`no header row: expected ${COLUMNS.join(',')} (comments with # are allowed)`);
  }
  if (rows.length === 0) warnings.push('the labels file has a header but no windows');

  return { rows, warnings };
}

/**
 * The clips the labels mention, in the order they first appear.
 *
 * A clip is what a replay costs — one browser playback each — so this is the list
 * the runner works through, and its length is what `--limit` shortens.
 */
export function clipsOf(rows) {
  const seen = [];
  const known = new Set();
  for (const row of rows) {
    if (known.has(row.clip)) continue;
    known.add(row.clip);
    seen.push(row.clip);
  }
  return seen;
}

/** Every `key=value` tag in a row set, sorted, so a report's rows have an order. */
export function tagsOf(rows) {
  const tags = new Set();
  for (const row of rows) for (const tag of row.tagList) tags.add(tag);
  return [...tags].sort();
}
