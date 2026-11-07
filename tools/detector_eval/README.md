# Detector evaluation

Scores the face detector the app actually ships against clips a human has labelled,
and reports the numbers a proctoring decision rests on: **recall, precision and a
false-positive rate, per action and per tag**.

```bash
node tools/detector_eval/eval.mjs --dry-run          # is the corpus sane?
node tools/detector_eval/eval.mjs --labels labels.csv --clips clips/
```

No dependencies: Node 18+ and a Chromium browser. Nothing is installed, and nothing
is downloaded — the detector and the MediaPipe model come from `mobile/web/`.

## What it measures, and what it refuses to

The detector ticks about ten times a second and says `no_face`, `looking_away`,
`multiple_faces` or `centered`. The app does not log those ticks: `WebFacePresenceMonitor`
decides when a *run* of ticks has lasted long enough to be a violation, then latches
so the same episode is reported once.

So the unit of scoring is the **episode**, not the frame:

```
clip ──► real detector (browser) ──► tick stream ──► judge.mjs ──► violations
                                                                       │
labels.csv (windows a human marked) ───────────────► match.mjs ◄───────┘
                                                            │
                                                            ▼
                                              report.mjs: by action, by tag
```

- A violation inside a `label 1` window is a **hit**. One window is at most one hit,
  however many times it fired.
- A violation inside a `label 0` window is a **false positive**.
- A violation outside every window of its own action is a **stray**: listed, never
  scored. It is usually the detector being right about something nobody labelled.

Scoring raw ticks instead would grade a detector nobody ships, and would give a
flattering number to a detector that reports the same absence thirty times.

## The rules are read from the app, not restated here

`lib/judge.mjs` is a port of `WebFacePresenceMonitor`, and the numbers it applies
are parsed at runtime out of `mobile/lib/core/services/proctoring_thresholds.dart`
and `web_face_presence.dart`. Rename a constant and the tool refuses to run rather
than quietly scoring a different app. `test/judge.test.mjs` fails if
`DEFAULT_RULES` drifts from the Dart.

`--grace` defaults to **0**, because a clip is a labelled window rather than the
first seconds of an attempt. `--grace 5` reproduces the app exactly, which is worth
doing once: it is the only place this tool and the app are allowed to disagree.

## Labelling

Copy `labels.template.csv` to `labels.csv` and replace the example rows. One row per
window, not per frame:

| column | meaning |
| --- | --- |
| `clip` | file name inside `--clips`; no folders, no absolute paths |
| `action` | `looking_away`, `no_face` or `multiple_faces` |
| `start` | seconds from the start of the clip |
| `end` | seconds; blank means "to the end of the clip", read during replay |
| `label` | `1` the action happens here, `0` it does not |
| `tags` | `key=value;key=value`, free-form, and what the report segments by |

`#` starts a comment, and blank lines are ignored, so notes beside a hard call are
welcome. A row is refused, with its line number, if the action is not one of the
three, if a second runs backwards, if two `label 1` windows of one action overlap
(one episode cannot be two labels), or if `tags` is not `key=value`.

Practical advice, in the order it costs you a rerun:

1. **Label the calm stretches too.** `label 0` is the only source of a false-positive
   rate. A corpus of positives alone measures recall and nothing else, and a detector
   that reports constantly would score perfectly.
2. **Label episodes, not frames.** Mark the seconds the app *should* have reported,
   then stop. Not the frames the head turned on.
3. **Leave a gap between windows.** Windows of one action may not overlap; the
   tolerance below is what absorbs an honest disagreement about the boundary.
4. **Tag what you vary.** `lighting=dim`, `glasses=yes`, `skin=tone` are the slices
   that tell you whether the detector fails *everyone* or just some rooms. A tag
   with no `label 1` window shows recall as `—`, not `0%`.
5. **Keep clips short.** Twelve seconds is easier to label exactly than two minutes,
   and the replay cost is per clip, not per second.

## Reading the report

```
BY ACTION
slice         present  hit  miss  recall  absent  fp  fp/min  fpr  precision
------------  -------  ---  ----  ------  ------  --  ------  ---  ---------
looking_away        9    7     2   77.8%      14   1    0.43  7.1%      87.5%
```

- `present` / `hit` / `miss` / `recall` — labelled episodes and how many were found.
- `absent` / `fp` / `fpr` — negative windows and the share that produced a violation.
- `fp/min` — false positives per minute of negative footage, which is the number a
  student feels during an exam.
- `precision` — of the violations the app raised inside a window, the share that
  were labelled.

`—` means *not measured*: there was no denominator. It is never printed as `0.0%`,
because "we did not check" and "it failed" are different answers.

`STRAYS` lists what fell outside every window of its action, with clip and time, so
the labels can be fixed. A run with strays is not a failed run — it is a corpus with
a gap in it.

## Flags

| flag | default | meaning |
| --- | --- | --- |
| `--labels <path>` | `./labels.csv` | the labelled windows CSV |
| `--clips <dir>` | `./clips` beside the labels | the folder of clip files |
| `--out <path>` | — | write the JSON report |
| `--limit <n>` | all | evaluate the first n clips |
| `--tolerance <s>` | `0.5` | slack around every window |
| `--grace <s>` | `0` | ignore the first n seconds of each clip |
| `--thresholds <path>` | — | JSON rule overrides, e.g. `{"yawDegrees": 20}` |
| `--min-recall <f>` | — | fail the run below this recall |
| `--max-fpr <f>` | — | fail the run above this FPR |
| `--browser <path>` | auto | the Chromium binary to drive |
| `--timeout-ms <n>` | `180000` | per-clip cap on the replay |
| `--headed` | off | show the browser window |
| `--dry-run` | off | read the labels, print the plan, exit |
| `--quiet` | off | no per-clip progress lines |

Environment: `PG_EVAL_BROWSER` (as `--browser`), `PG_EVAL_CLIPS` (as `--clips`).
Flags win. `--tolerance` exists because a label boundary and a detector tick are both
honest to about half a second; it never widens a window into another one of the same
action — the nearest window owns the detection.

`--thresholds` takes the same names as the Dart constants. An unknown key is a
refusal, not a typo that silently does nothing, and `--min-recall`/`--max-fpr` turn
the run into a check that can fail a pipeline.

## Exit codes

| code | meaning |
| --- | --- |
| `0` | ran, and every threshold asked for passed |
| `1` | a threshold failed, or a clip could not be replayed |
| `2` | bad configuration: unreadable or malformed labels, missing clips, no browser |

A clip that could not be replayed fails the run rather than being skipped: a corpus
that silently shrinks is a corpus that flatters the detector.

## Layout

```
eval.mjs              the CLI: config → replay → judge → match → report
labels.template.csv   documented columns and illustrative rows
lib/labels.mjs        CSV parsing and refusal, with line numbers
lib/replay.mjs        HTTP server, browser launch, per-clip replay over CDP
lib/judge.mjs         the port of WebFacePresenceMonitor, rules read from the Dart
lib/match.mjs         windows vs violations: hits, false positives, strays
lib/report.mjs        fixed-width tables, threshold verdicts, JSON
page/eval.html        builds the DOM Flutter builds; plays the clip as a camera
test/*.test.mjs       node --test, no browser needed
```

Tests: `node --test "tools/detector_eval/test/*.test.mjs"`.

The replay drives the browser the way the app does: the clip is turned into a live
camera with `captureStream()` and handed to the detector through `srcObject`, because
the detector refuses a `<video src>` (`inactiveReason` says `no-stream`). Verdicts are
stamped with the clip's own `currentTime`, never with wall time, so a slow machine
moves the evidence and the timeline together instead of inventing a look-away.

## Consent, and what is not in this repo

**No real images are bundled.** `labels.template.csv` names clips that are not here,
and the tests use generated scenarios rather than footage — a corpus of faces is not
something a repository ships, and not something to collect casually.

If you build a corpus:

- Record consent for *this* purpose, from every person who appears, including the
  second person in a `multiple_faces` clip. A bystander has not agreed to anything.
- Keep the consent record outside the repo, and keep the footage out of it too
  (`.gitignore` the `clips/` folder).
- Prefer colleagues and synthetic scenes over students. An evaluation corpus drawn
  from real exam recordings is a different project with a different ethics process.
- Include the conditions that fail: dim rooms, glasses, head coverings, a range of
  skin tones, seated slouches. A corpus of well-lit faces facing forward measures
  demonstration, not detection.
- Delete the clips when the evaluation is published, and keep the labels: they are
  the record, and they carry no one's face.

## Known limits

- Needs a browser that can decode the clips and run MediaPipe; there is no fallback
  that pretends. No browser is a refusal, not a skipped run that reads as a pass.
- The judge scores what the app *logs*, not what a human watching the video would
  say the student was doing. A detector can be wrong about the frame and right about
  the log.
- Timing-dependent by nature: a machine too slow to play the clip in real time will
  change which ticks the app sees. `--timeout-ms` caps the damage; it does not undo
  it.
- No footage ships with the repo, so the first run against real clips is a manual
  one. What has been exercised automatically is the plumbing: the page's script
  compiles, the server serves the detector and the model, the browser launches and
  reports, and a clip the browser cannot decode fails the run instead of vanishing
  into the score.
