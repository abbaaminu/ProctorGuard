'use strict';
// A stand-in for MediaPipe's vision bundle, for the face-sensor lab only
// (see lab.js and harness.html). Nothing ships this.
//
// It exports the two names `web/proctor_face_detector.js` uses, with the same
// shapes, so a lab run can exercise the whole model path - the dynamic `import()`,
// `forVisionTasks`, `createFromOptions`, `detectForVideo` in VIDEO mode, a facial
// transformation matrix and the pose read off it - without a 13 MB WebAssembly
// download and without a real face in front of a synthetic camera.
//
// What it answers with comes from `window.__model`, which the harness owns:
//
//   faces   how many faces to report (0, 1, 2, ...)
//   yaw     the head's yaw in degrees, for the matrix and for the landmarks
//   pitch   the head's pitch in degrees, for the matrix
//   matrix  false to return no pose matrix, so the detector has to fall back to
//           measuring the landmarks themselves
//   failGpu true to reject the first `createFromOptions` (the GPU delegate), which
//           is what a machine with no usable WebGL does
//
// The matrix is built the way the API documents it: 4x4, column-major, so element
// (row, column) sits at `column * 4 + row`. It is Ry(yaw) * Rx(pitch) * Rz(0), the
// decomposition the detector reverses, so a scenario can assert the angles it
// produces instead of trusting them.

const RADIANS = Math.PI / 180;

/// `Ry(yaw) * Rx(pitch)`, flattened column-major, with a translation that a real
/// solve would carry and this stub keeps at the origin.
function poseMatrix(yaw, pitch) {
  const cy = Math.cos(yaw * RADIANS);
  const sy = Math.sin(yaw * RADIANS);
  const cp = Math.cos(pitch * RADIANS);
  const sp = Math.sin(pitch * RADIANS);
  // Row by row, as [row][column].
  const rows = [
    [cy, sy * sp, sy * cp, 0],
    [0, cp, -sp, 0],
    [-sy, cy * sp, cy * cp, 0],
    [0, 0, 0, 1]
  ];
  const data = new Array(16);
  for (let column = 0; column < 4; column++) {
    for (let row = 0; row < 4; row++) data[column * 4 + row] = rows[row][column];
  }
  return { rows: 4, columns: 4, data };
}

/// The canonical mesh points the detector reads ([FACE] in
/// proctor_face_detector.js): the outer corner of each eye and the tip of the nose,
/// normalized to the frame the way the real model reports them. The nose swings
/// with yaw by the same proportion `measurePose` uses, so the landmark-only path
/// measures the angle this stub was told to show.
function faceLandmarks(element, yaw) {
  const width = (element && element.videoWidth) || 640;
  const height = (element && element.videoHeight) || 480;
  const left = { x: width * 0.39, y: height * 0.42 };
  const right = { x: width * 0.61, y: height * 0.42 };
  const span = right.x - left.x;
  const midX = (left.x + right.x) / 2;
  const midY = (left.y + right.y) / 2;
  const swing = Math.sin(yaw * RADIANS) * (span / 2);
  const points = [];
  for (let i = 0; i < 478; i++) points.push({ x: 0.5, y: 0.5, z: 0 });
  const put = (index, x, y) => {
    points[index] = { x: x / width, y: y / height, z: 0 };
  };
  put(33, left.x, left.y);
  put(263, right.x, right.y);
  put(1, midX + swing, midY + span * 0.6);
  return points;
}

function model() {
  return Object.assign({ faces: 1, yaw: 0, pitch: 0, matrix: true, failGpu: false }, window.__model || {});
}

/// The two names the detector imports, with the *shape* the real API has: both are
/// classes with static factories, and the detector checks that before it calls
/// them (`typeof Landmarker !== 'function'` is a bundle it cannot use).
export class FilesetResolver {
  static forVisionTasks(basePath) {
    window.__stubWasmPath = basePath;
    return Promise.resolve({
      wasmLoaderPath: basePath + '/vision_wasm_internal.js',
      wasmBinaryPath: basePath + '/vision_wasm_internal.wasm'
    });
  }
}

export class FaceLandmarker {
  static createFromOptions(fileset, options) {
    const state = model();
    const delegate = options && options.baseOptions ? options.baseOptions.delegate : null;
    window.__stubOptions = {
      delegate: delegate,
      runningMode: options ? options.runningMode : null,
      numFaces: options ? options.numFaces : null,
      matrices: options ? options.outputFacialTransformationMatrixes : null,
      modelAssetPath: options && options.baseOptions ? options.baseOptions.modelAssetPath : null
    };
    if (state.failGpu && delegate !== 'CPU') {
      return Promise.reject(new Error('stub: no WebGL context for the GPU delegate'));
    }
    return Promise.resolve({
      options: options,
      detectForVideo(element, timestamp) {
        const now = model();
        window.__stubFrames = (window.__stubFrames || 0) + 1;
        window.__stubTimestamp = timestamp;
        const faces = [];
        for (let i = 0; i < now.faces; i++) faces.push(faceLandmarks(element, now.yaw));
        return {
          faceLandmarks: faces,
          faceBlendshapes: [],
          facialTransformationMatrixes:
            now.matrix && faces.length ? [poseMatrix(now.yaw, now.pitch)] : []
        };
      },
      close() {}
    });
  }
}
