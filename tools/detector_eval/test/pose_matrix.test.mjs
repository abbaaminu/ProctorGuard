/**
 * The pose matrix.
 *
 * `matrixPose()` in `mobile/web/proctor_face_detector.js` is the accurate route to
 * yaw and pitch: MediaPipe solves the head's rotation in 3D against its canonical
 * face and hands back a 4x4 matrix, and the detector reads two elements out of it.
 * It is also the quietest place in the detector to be wrong — read the same matrix
 * with the wrong stride, or row-major where the API flattens column-major, and
 * nothing looks broken: a level head still reads level, a turned head still reads
 * *some* angle, and the first evidence is a strike on a student who was looking at
 * the paper. A matrix in a log has no visible handedness either, so this cannot be
 * spotted by reading output.
 *
 * So the matrices here are built from angles that are known in advance —
 * R = Ry(yaw) · Rx(pitch) · Rz(roll) — flattened the way `Matrix.data` flattens an
 * OpenGL-style matrix (column-major: element (row, column) at `column * 4 + row`),
 * and the answer is compared with the angles that went in.
 *
 * What this cannot settle is which of the model's axes it calls yaw: that needs a
 * real face on a real camera. The *sign* of the pitch is different — it is a
 * convention now, because Dart applies a signed tolerance to it (20° down against
 * 15° up, `WebFacePresenceMonitor.downwardPitchDegrees`) — so the second half of this
 * file measures a synthetic face through the landmark route and checks the two routes
 * report a chin down the same way. A real face has still never been put in front of
 * either route, which is why the app's signed rule only ever *widens*.
 *
 * `matrixPose` is not exported — the detector is one IIFE — so it is sliced out of
 * the shipped file rather than copied here, the way `page.test.mjs` reads its
 * inline script. A copy would keep passing after the original changed.
 */

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const source = readFileSync(
  new URL('../../../mobile/web/proctor_face_detector.js', import.meta.url),
  'utf8',
);

/// One top-level function of the detector, by name, braces balanced.
function sliced(name) {
  const start = source.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `the detector still defines ${name}()`);
  let depth = 0;
  for (let i = source.indexOf('{', start); i < source.length; i += 1) {
    if (source[i] === '{') depth += 1;
    else if (source[i] === '}') {
      depth -= 1;
      if (depth === 0) return source.slice(start, i + 1);
    }
  }
  assert.fail(`${name}() is not balanced`);
}

const toDegrees = new Function(`${sliced('toDegrees')}; return toDegrees;`)();
const matrixPose = new Function('toDegrees', `${sliced('matrixPose')}; return matrixPose;`)(
  toDegrees,
);

/// The detector's own idea of where a frontal nose sits, so the synthetic faces
/// below are built on the same proportion the measurement uses rather than a copy of
/// its number.
const frontalNoseDrop = new Function(
  `${/var FRONTAL_NOSE_DROP = [^;]+;/.exec(source)[0]}; return FRONTAL_NOSE_DROP;`,
)();

const measurePose = new Function(
  'FRONTAL_NOSE_DROP',
  `${sliced('landmarkPoints')}; ${sliced('measurePose')}; return measurePose;`,
)(frontalNoseDrop);

// --- building the matrices ---------------------------------------------------

const radians = (degrees) => (degrees * Math.PI) / 180;

const multiply = (a, b) =>
  a.map((row, r) => row.map((_, c) => row.reduce((sum, _, k) => sum + a[r][k] * b[k][c], 0)));

const about = {
  y: (angle) => [
    [Math.cos(angle), 0, Math.sin(angle)],
    [0, 1, 0],
    [-Math.sin(angle), 0, Math.cos(angle)],
  ],
  x: (angle) => [
    [1, 0, 0],
    [0, Math.cos(angle), -Math.sin(angle)],
    [0, Math.sin(angle), Math.cos(angle)],
  ],
  z: (angle) => [
    [Math.cos(angle), -Math.sin(angle), 0],
    [Math.sin(angle), Math.cos(angle), 0],
    [0, 0, 1],
  ],
};

/// R = Ry(yaw) · Rx(pitch) · Rz(roll) — the composition the detector's comment
/// names, with roll applied first.
function rotation(yaw, pitch, roll) {
  return multiply(
    multiply(about.y(radians(yaw)), about.x(radians(pitch))),
    about.z(radians(roll)),
  );
}

/// The 3x3 rotation as the 16 numbers a pose matrix carries, column-major, with an
/// optional uniform scale: `Matrix.data` is free to hold one, and the angles must
/// not change with it.
function flattened(rotation3x3, scale = 1) {
  const rows = rotation3x3.map((row) => [...row, 0]);
  rows.push([0, 0, 0, 1]);
  const data = new Array(16);
  rows.forEach((row, r) => row.forEach((value, c) => {
    data[c * 4 + r] = value * scale;
  }));
  return { data };
}

/// The same numbers as a row-major array — the layout the detector does not use.
function flattenedRowMajor(rotation3x3) {
  const rows = rotation3x3.map((row) => [...row, 0]);
  rows.push([0, 0, 0, 1]);
  return { data: rows.flat() };
}

function assertAngles(actual, expected, tolerance = 1e-9) {
  assert.ok(actual !== null, 'an angle was measured');
  assert.ok(
    Math.abs(actual.yaw - expected.yaw) <= tolerance,
    `yaw ${actual.yaw} is ${expected.yaw}`,
  );
  assert.ok(
    Math.abs(actual.pitch - expected.pitch) <= tolerance,
    `pitch ${actual.pitch} is ${expected.pitch}`,
  );
}

// --- the readings ------------------------------------------------------------

test('a level, forward-facing head reads 0/0', () => {
  assertAngles(matrixPose(flattened(rotation(0, 0, 0))), { yaw: 0, pitch: 0 });
});

test('yaw is read as yaw, in both directions', () => {
  assertAngles(matrixPose(flattened(rotation(30, 0, 0))), { yaw: 30, pitch: 0 });
  assertAngles(matrixPose(flattened(rotation(-30, 0, 0))), { yaw: -30, pitch: 0 });
});

test('pitch is read as pitch, in both directions', () => {
  assertAngles(matrixPose(flattened(rotation(0, 20, 0))), { yaw: 0, pitch: 20 });
  assertAngles(matrixPose(flattened(rotation(0, -20, 0))), { yaw: 0, pitch: -20 });
});

test('roll alone moves neither angle', () => {
  // The third column of Ry·Rx·Rz is the third column of Ry·Rx — neither formula
  // touches anything a roll can change, which is why a tilted head is not a turn.
  assertAngles(matrixPose(flattened(rotation(0, 0, 60))), { yaw: 0, pitch: 0 });
});

test('yaw and pitch stay independent when both are present', () => {
  assertAngles(matrixPose(flattened(rotation(-25, 10, 40))), { yaw: -25, pitch: 10 });
});

test('a scaled matrix is the same rotation', () => {
  // Both formulas are ratios (atan2 of two elements, one element clamped and
  // asin'd), so a matrix carrying a scale cannot change the angles it reports.
  assertAngles(matrixPose(flattened(rotation(40, 0, 0), 3.7)), { yaw: 40, pitch: 0 });
});

test('at ninety degrees of pitch, yaw is reported 0 rather than invented', () => {
  // The two axes collapse there and yaw is not observable. The detector says 0,
  // which the app reads as centred: an angle that is measured, never a guess.
  assertAngles(matrixPose(flattened(rotation(35, 90, 0))), { yaw: 0, pitch: 90 });
});

test("a value past asin's domain is clamped, not NaN", () => {
  // Element (1, 2) is -sin(pitch), so anything below -1 is noise around a head
  // thrown fully back. Unclamped it would be NaN, and a NaN angle would compare
  // false against every tolerance and silently report nothing.
  const noisy = flattened(rotation(0, 0, 0));
  noisy.data[2 * 4 + 1] = -1.0000001;
  assertAngles(matrixPose(noisy), { yaw: 0, pitch: 90 }, 1e-6);
});

test('the layout is not free: read row-major, the same head turns the other way', () => {
  // Proof that the column-major assumption is load-bearing rather than cosmetic:
  // Flutter's `Matrix.data` flattens column-major, and with the rows swapped the
  // 20° pitch above reads as -20°.
  const rowMajor = matrixPose(flattenedRowMajor(rotation(0, 20, 0)));
  assert.ok(rowMajor !== null, 'the row-major array is still a 4x4');
  assert.ok(
    Math.abs(rowMajor.pitch - 20) > 1,
    `row-major would read pitch 20 as ${rowMajor.pitch}, not as the pose that was built`,
  );
});

test('no matrix, a short one, or a non-numeric element answers null', () => {
  // Null is the detector's "cannot measure" and the app treats it as centred, so it
  // must not be reachable by arithmetic on a matrix that is not there.
  assert.equal(matrixPose(null), null);
  assert.equal(matrixPose({ data: [1, 2, 3] }), null);

  const nonNumeric = flattened(rotation(0, 0, 0));
  nonNumeric.data[2 * 4] = 'x';
  assert.equal(matrixPose(nonNumeric), null);
});

// --- the landmark route, and the sign the two routes share -------------------

/// A synthetic face with the eyes 0.2 apart and the nose [drop] × that distance
/// below the eye line, in image coordinates (y grows downwards).
///
/// `drop === frontalNoseDrop` is a face looking straight at the screen - the
/// proportion `measurePose` subtracts - so more is a chin down and less a chin up,
/// exactly as a photograph would read.
function faceWithNoseDrop(drop) {
  return {
    landmarks: [
      {
        type: 'eye',
        locations: [
          { x: 0.4, y: 0.4 },
          { x: 0.6, y: 0.4 },
        ],
      },
      {
        type: 'nose',
        locations: [{ x: 0.5, y: 0.4 + drop * 0.2 }],
      },
    ],
  };
}

test('a face looking straight at the screen reads level, from its landmarks', () => {
  const pose = measurePose(faceWithNoseDrop(frontalNoseDrop));
  assert.ok(pose !== null, 'two eyes and a nose are measurable');
  assertAngles(pose, { yaw: 0, pitch: 0 });
});

test('both routes call a chin down positive, which is the sign Dart reads', () => {
  // Dart applies a *signed* tolerance to the pitch - 20° down against 15° up
  // (`WebFacePresenceMonitor.downwardPitchDegrees`) - so a route that reported the
  // opposite sign would put the browser's five degrees of forgiveness on the wrong
  // direction, and nothing but a real head would ever show it. The matrix route's
  // convention is asserted above (a positive pitch sends the face's forward vector
  // below the horizon); this is the landmark route agreeing with it.
  const down = measurePose(faceWithNoseDrop(frontalNoseDrop + 0.2));
  assert.ok(down !== null, 'a chin down is measurable');
  assert.ok(down.pitch > 0, `a chin down read ${down.pitch}, which is the wrong sign`);
  assert.ok(Math.abs(down.pitch - 20) <= 1e-9, `a chin down read ${down.pitch}, not 20`);

  const up = measurePose(faceWithNoseDrop(frontalNoseDrop - 0.2));
  assert.ok(up !== null, 'a chin up is measurable');
  assert.ok(up.pitch < 0, `a chin up read ${up.pitch}, which is the wrong sign`);
  assert.ok(Math.abs(up.pitch + 20) <= 1e-9, `a chin up read ${up.pitch}, not -20`);

  // The same head through the matrix route: pitch 20 is the same direction.
  assertAngles(matrixPose(flattened(rotation(0, 20, 0))), { yaw: 0, pitch: 20 });
});

