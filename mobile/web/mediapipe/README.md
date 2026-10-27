# The shipped head-pose model

The files in this directory are MediaPipe's **FaceLandmarker** for the web, copied
verbatim from npm so a desktop browser can measure a head pose without a native
`window.FaceDetector` (see `web/proctor_face_detector.js`, section "The model this
build ships"). Nothing here is modified, minified further, or rebuilt: the hashes
below are the published ones.

| File | Bytes | Upstream |
| --- | --- | --- |
| `vision_bundle.mjs` | 136 870 | `https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.14/vision_bundle.mjs` |
| `wasm/vision_wasm_internal.js` | 209 826 | `https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.14/wasm/vision_wasm_internal.js` |
| `wasm/vision_wasm_internal.wasm` | 9 423 986 | `https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.14/wasm/vision_wasm_internal.wasm` |
| `face_landmarker.task` | 3 758 596 | `https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task` |

```
vision_bundle.mjs              sha256 e77f281f9619150d937023c355bae170e9120e3b9e43f1e23a2a7bee07197669
wasm/vision_wasm_internal.js   sha256 9440cf0cc0cea21800e31581ec32aeedcc5fbf9df4509796bbc7d3f99e52ab9c
wasm/vision_wasm_internal.wasm sha256 f82a8e6c05e08a44cc9f9e7ec5f845935bcbb1b1500ebe8c2f4812fb4e2917dc
face_landmarker.task           sha256 64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff
```

`@mediapipe/tasks-vision` 0.10.14 is the version the typings and the bundle agree
on: `FilesetResolver.forVisionTasks(basePath)` resolves
`<basePath>/vision_wasm_internal.js` and `.wasm` at runtime, after testing the
browser for WebAssembly SIMD (`wasm_nosimd_internal.*` is the fallback name).
Both current Chromium, Firefox and Safari builds pass that test, which is why only
the SIMD pair is vendored - a browser that failed it would fall back to a
`no_face`-free `centered`, not to a broken page (see the failure rules in
`proctor_face_detector.js`).

## Why it is vendored rather than loaded from a CDN

`web/index.html` pins the page to one origin (`script-src 'self'`,
`connect-src 'self'`) so that neither an injected script nor a compromised
dependency can exfiltrate frames, answers or the session token. Loading a face
model from jsDelivr would put a third-party host inside every exam page and would
break the app on an air-gapped or filtered school network. These four files are
copied into `build/web` with every other file under `web/` and served from the
same origin as the app - the build ships no PWA cache, so they are fetched once
and then cached by the browser's own HTTP cache - and cost nothing until an exam
opens a camera, because the loader runs on the first tick with a live preview.

## How the detector uses them

* Loaded lazily, once per page session, on the first tick with a live camera - and
  never at all in a browser whose own `window.FaceDetector` works (Chromium on
  ChromeOS/Android).
* `runningMode: 'VIDEO'` at `delegate: 'GPU'` (WebGL), retried on the CPU when the
  GPU delegate cannot be created. The browser bundle of this API has no
  `LIVE_STREAM` mode; `VIDEO` is its streaming mode, and the detector drives it one
  frame per tick from its polling loop.
* Results feed `pose:<yaw>,<pitch>` through `window.proctorGuardFaceSignal`. A
  missing file, a browser without WebAssembly, or a policy without
  `'wasm-unsafe-eval'` leaves presence, covered-lens and frozen-preview detection
  working exactly as they did before the model existed.

A host that serves these assets from another path (or ships none) sets
`window.proctorGuardMediaPipe = { module, wasm, model }` - or `false` - before
`proctor_face_detector.js` loads.

## Updating

1. Pick the new `@mediapipe/tasks-vision` version, download the four files above
   from the same paths, and replace them.
2. Update the table and hashes here.
3. Run `node --check web/proctor_face_detector.js`, `flutter test
   test/web_face_detector_contract_test.dart`, and
   `node tool/face_lab/lab.js mediapipe` (in `mobile/`) - the last one loads the
   real module in a headless browser, once on a plain page and once under the
   policy `web/index.html` ships (`mediapipe+csp`, sent as a header and read out of
   that page), and fails if the model cannot be created, if the policy refuses a
   single byte of it, or if the page starts throwing.

## Licence

MediaPipe is Apache-2.0 (`https://github.com/google-ai-edge/mediapipe`), and the
FaceLandmarker task bundle and model card are distributed under the same licence. A
build that redistributes this directory outside the project must ship that licence
with it; nothing in this app modifies these files.
