/*
  ProctorGuard browser face detector.

  The web build cannot run the on-device engine (see
  lib/core/services/web_face_signal_source.dart), so the *detection* is this
  script's job and the *judgement* is Dart's: `WebFacePresenceMonitor` decides
  which detections are worth a violation, exactly as it does for a phone's
  ML Kit frames. This file only has to be a truthful sensor.

  Every tick (~350 ms) it answers one question - is there a face being proctored
  right now - and speaks the answer through `window.proctorGuardFaceSignal`
  (`WebFaceSignalSource.globalName`):

    * `no_face` when there is no usable picture of the student: the camera was
      closed (its track ended), blanked (the track was muted or disabled), the
      video was paused or is still opening, the picture is hidden, or the frame
      itself carries nothing - a covered lens, a blown-out frame, one flat colour,
      or the same picture three ticks running (a still image in place of a camera,
      a stalled decoder). A student can produce every one of those at the page's
      own layer, without touching a pixel of the app.
    * `no_face` again on each tick it still holds, because Dart's sustain is
      measured in time: one verdict is a dropped frame, two 350 ms apart are a
      covered camera. 350 ms is deliberately one tick more than the monitor's
      300 ms sustain, so the second tick is the strike and the first cannot be.
    * `no_face` for a preview that never shows a frame either, once it has been
      silent for [STALL_MS]: a camera that was blocked before this loop could see
      it live is still a camera nobody is being proctored by.
    * nothing at all while the page is hidden: a backgrounded tab is
      `app_minimized` from the web guard, and the browser's own throttling must not
      become a second strike.
    * `centered` when the frame is live and not blank and this page cannot measure
      a head pose: a live frame of the student's desk is the only evidence
      available, and it is what ends an absence episode. It is never a violation,
      but it is re-spoken about once a second while it holds
      ([CENTERED_REPEAT_MS]): an app told "somebody is there" once per episode
      cannot tell a working sensor from one that died after its first tick.
    * `pose:<yaw>,<pitch>` when a face model finds exactly one face and gives
      enough of it to measure. The angle is *measured*, and only the angle: Dart
      applies its own tolerances to it
      (`WebFacePresenceMonitor.offCenterYawDegrees`) and decides whether the head
      is off the screen. This is the only way a desktop web sitting can produce a
      `looking_away` at all - the app's own ML Kit does not run in a browser.
    * `multiple_faces` when that model counts more than one face. Reported on the
      tick it is seen; Dart latches it.

  It never says `looking_away` itself: a page may report what it saw, never what
  it is worth (`WebFaceMessages.posePrefix` exists for exactly that). And it never
  invents an angle: with no landmarks there is no pose, and `centered` is the most
  this script claims.

  Where the camera is: the preview `camera_web` renders is a `<video>` inside
  Flutter's platform-view DOM, so it is searched for through shadow roots. When no
  element in the document carries a live track - a self-view drawn as a canvas, a
  preview replaced after a route change, a host page this script cannot see into -
  the stream the app itself asked the browser for is watched instead, through an
  element of this script's own ([capturedVideo]). A sitting is never left unproctored
  because the app painted its camera somewhere unexpected.

  What measures the head: the browser's own Shape Detection API where it exists
  (`window.FaceDetector`, i.e. Chromium on ChromeOS and Android), and otherwise
  the model this build ships - MediaPipe's `FaceLandmarker`, compiled to
  WebAssembly and run on the GPU - for every desktop browser that has none:
  Windows, macOS and Linux Chromium, Firefox, Safari. The model is loaded lazily
  (only once a camera is live) from `web/mediapipe/`, i.e. from this app's own
  origin, so no CDN is trusted with an exam's page and the build works offline.
  When it cannot load at all - an air-gapped deployment without the assets, a
  browser without WebAssembly, a CSP without `'wasm-unsafe-eval'`, a machine
  whose WebGL is blocked outright - the page says `centered` for a live non-blank
  frame exactly as it did before the model existed, and a covered lens, a dead
  track, a frozen preview and a lost camera are all still `no_face`.

  Deliberately plain ES5-ish JavaScript with no build step and no `type="module"`:
  like the lockdown in index.html it is the part of the client a host may have to
  read or adapt, and Dart looks the hook up by name on `window`. The one nod to
  modern syntax is the dynamic `import()` that loads the model's ES module
  ([loadMediaPipe]), which a classic script is allowed to do.
*/
(function () {
  'use strict';

  if (window.ProctorGuardFaceDetector && window.ProctorGuardFaceDetector.installed) {
    // A page that includes this script twice gets one detector, not two loops
    // reporting the same face at twice the rate.
    return;
  }

  // --- The wire to Dart -----------------------------------------------------

  // Installed by `WebFaceSignalSource` while an attempt is being proctored and
  // removed when it ends. Absent means nothing is listening: this script stays
  // quiet and cheap rather than detecting into a closed attempt.
  var HOOK = 'proctorGuardFaceSignal';

  // The vocabulary of `WebFaceMessages`. Kept as literals so a contract test can
  // hold them against the Dart constants.
  var MESSAGES = {
    centered: 'centered',
    noFace: 'no_face',
    multipleFaces: 'multiple_faces',
    pose: 'pose:'
  };

  // --- The shipped face model -----------------------------------------------

  // Where the three assets of MediaPipe's FaceLandmarker live, relative to the
  // page: the build copies `web/` verbatim into `build/web/`, so these resolve
  // under whatever `--base-href` the deployment uses, and `<base href>` in
  // index.html is what makes a sub-path deployment work.
  //
  // A host that serves them from somewhere else - or that has no model to serve -
  // sets `window.proctorGuardMediaPipe` before this script loads: an object with
  // any of `module`, `wasm` and `model`, or `false` (or `'off'`) to run on the
  // browser's own detector alone. `module` is the ES module, `wasm` the directory
  // holding `vision_wasm_internal.{js,wasm}`, and `model` the `.task` file.
  var MEDIAPIPE = {
    module: 'mediapipe/vision_bundle.mjs',
    wasm: 'mediapipe/wasm',
    model: 'mediapipe/face_landmarker.task'
  };

  // --- Tuning ---------------------------------------------------------------

  // One tick more than `WebFacePresenceMonitor.sustain` (300 ms): the first
  // `no_face` opens the episode, the second leaves it older than the sustain.
  // Measured in wall time, not frames, because nothing guarantees this page's
  // frame rate.
  var INTERVAL_MS = 350;

  // How often a holding `centered` is said again while it holds. It is not
  // evidence and it is never a violation, but it is the only "the student is
  // there and this sensor is still watching" the page has, and Dart drops the
  // signal itself. Once a second keeps that state live upstream - and in the app's
  // log - without turning a three-per-second loop into a stream of no-ops. Dropped
  // entirely it is indistinguishable from a detector that died after its first
  // tick, which is what a silent browser sitting looked like before this.
  var CENTERED_REPEAT_MS = 1000;

  // The frame is sampled into a thumbnail, not read at full resolution: blank
  // detection is a question about the whole picture, and 48x36 is 1728 samples,
  // which is plenty for it and cheap enough to run three times a second.
  var SAMPLE_WIDTH = 48;
  var SAMPLE_HEIGHT = 36;

  // A frame with no structure at all - whatever its brightness - is a lens with
  // something over it: a hand, a sticker, a finger, a printed sheet, a closed
  // privacy shutter, or a camera pointed at a bare wall.
  //
  // Structure, not darkness, is the discriminator, and the numbers come from
  // measuring both cases at this thumbnail size: a covered lens lands at a
  // spread of 3-4 (auto-exposure pushes a covered lens to a grey-brown, not to
  // black - 35 mean luma in a lit room, 70 with light bleeding through), while a
  // dim room with a student in it keeps a spread of 12-20. The old rule only
  // fired below 18 mean luma, so a covered camera in a lit room was reported as
  // `centered` - a student being proctored with a hand over the lens.
  var FEATURELESS_SPREAD = 6;

  // Dim *and* nearly featureless: a covered lens, or a room with the lights off.
  // 90 is above every covered frame measured (35-75) and below a lit room.
  var DARK_MEAN = 90;
  var DARK_SPREAD = 12;

  // A camera pointed into a lamp: the picture exists, but there is no face in it.
  var BLOWN_MEAN = 250;
  var BLOWN_SPREAD = 6;

  // How many consecutive thumbnails may be byte-for-byte identical before the
  // "camera" is called a still image. Every real sensor is noisy, so three in a
  // row (about a second) is a photo held in front of the lens, a frozen decoder,
  // or a virtual camera looping a screenshot - never a student sitting still.
  var FROZEN_TICKS = 3;

  // How long a preview that exists but shows nothing is tolerated before it is
  // reported. It covers the camera that was blocked before the first tick could
  // see it live (a `seenLive` that never happened), and it is well past the
  // moment a camera needs to deliver its first frame.
  var STALL_MS = 5000;

  // How deep to walk through shadow roots when looking for the camera. Flutter
  // hosts each platform view under one (`flt-platform-view`), and a host page may
  // wrap the app in another; five is past anything either does and keeps a
  // pathological page from turning discovery into a full tree walk.
  var MAX_SHADOW_DEPTH = 5;

  // How many pose measurements the median is taken over. Landmark estimates
  // jitter by a pixel or two, and a jittered angle that crossed a tolerance would
  // be a warning a student did not earn: three readings (about a second) is the
  // shortest window one bad frame cannot move, and it is still far shorter than a
  // real look away.
  var POSE_WINDOW = 3;

  // Where the nose sits between the eyes on a face looking straight at the
  // screen, in units of the distance between the eyes. A proportion of the face,
  // so it survives a small or a large picture; the pitch is the deviation from it.
  // Rough by design - it is a second opinion, and it can never be the reason a
  // single frame is called a turned head (only a sustained one).
  var FRONTAL_NOSE_DROP = 0.6;

  // The landmarks of the shipped model's canonical mesh that carry a head pose:
  // the outer corner of each eye and the tip of the nose. The same three points
  // the Shape Detection path measures, which is why one [measurePose] serves both
  // (see [modelFace]).
  var FACE = {
    leftEyeOuter: 33,
    rightEyeOuter: 263,
    noseTip: 1
  };

  // How old the newest reading may be before it stops being evidence. This loop
  // is faster than this on any page that is decoding frames at all, so it is only
  // reached when the model stopped answering for longer than a tick - and a pose
  // taken from a frame nobody is looking at is not a pose.
  var MEDIAPIPE_STALE_MS = 1500;

  // How many inferences in a row may throw before the model is abandoned for the
  // rest of the page session. One is a frame the model did not like; three is a
  // runtime that is not coming back, and re-asking it every 350 ms would only
  // block the loop that has to keep watching the camera.
  var MEDIAPIPE_FAILURES = 3;

  // --- State ----------------------------------------------------------------

  var running = false;
  var timer = null;
  var busy = false;
  var generation = 0;
  var video = null;
  var seenLive = null;
  var lastVerdict = null;
  var lastVerdictAt = 0;
  var canvas = null;
  var context = null;
  var faceDetector = null;
  var faceDetectorChecked = false;

  // The stream the page itself asked the browser for, and the element this script
  // watches it with when no preview in the document carries it (see
  // [capturedVideo]). Both stay null on a page that never opens a camera.
  var capturedStream = null;
  var ownedVideo = null;

  // The last few pose readings, for the median that keeps landmark jitter out of
  // the verdict.
  var poseSamples = [];

  // The shipped face model, and what it last saw.
  //
  // `state` is `idle` until a live camera makes it worth loading, `loading` while
  // the module, the WebAssembly and the model file are being fetched, `ready` once
  // it can measure a frame, `failed` when it never will in this browser (the whole
  // of [giveUpMediaPipe]) and `off` when the host page turned it off. Only `ready`
  // makes [inspect] answer anything: every other state is "this page cannot
  // measure an angle", which is a `centered` and never a strike.
  var mediaPipe = {
    state: 'idle',
    landmarker: null,
    error: null,
    latest: null,
    latestAt: 0,
    element: null,
    frameAt: -1,
    stamp: 0,
    failures: 0
  };

  // The element this loop is watching, and since when it has shown nothing. A
  // preview that exists but never delivers a frame is reported after [STALL_MS].
  var watched = null;
  var inactiveSince = 0;

  // The previous thumbnail's bytes, and how many ticks in a row repeated them -
  // the whole of the "is this a live picture" question.
  var lastPixels = null;
  var frozenTicks = 0;

  // One warning per page session when a hook is installed but no preview can be
  // found: a missing <script>, a renamed platform view, or a preview the app never
  // built is then visible in a phone's remote devtools instead of silent.
  var warnedNoPreview = false;

  // --- Talking to Dart ------------------------------------------------------

  function drainHook() {
    var hook = window[HOOK];
    return typeof hook === 'function' ? hook : null;
  }

  /// Reports one verdict. A hook that throws must not stop the loop.
  function report(message) {
    // `no_face`, `multiple_faces` and a measured `pose:` are re-sent on every tick
    // they hold: Dart measures a sustain in time, and a cooldown from the last
    // sighting, so a deduplicated verdict is a strike that never lands. A repeated
    // `centered` is the one message that carries no new evidence - but it is also
    // the only "this student is still there, this sensor is still watching" the
    // page can say, so it is rate-limited instead of dropped.
    var now = Date.now();
    if (
      message === lastVerdict &&
      message === MESSAGES.centered &&
      now - lastVerdictAt < CENTERED_REPEAT_MS
    ) {
      return;
    }
    lastVerdict = message;
    lastVerdictAt = now;

    var hook = drainHook();
    if (!hook) return;
    try {
      hook(message);
    } catch (error) {
      // A host that broke its own hook still gets a working page.
    }
  }

  // --- A camera of this script's own ---------------------------------------

  /// Remembers the video streams the page asks the browser for.
  ///
  /// `camera_web` renders its preview through a platform view, and an app is free
  /// to hide, rebuild, resize or replace that preview at any moment. None of that
  /// changes the camera itself: the stream `getUserMedia` handed the page *is* the
  /// camera the student is being proctored by, whoever is drawing it and wherever
  /// they drew it. Wrapping the request at load time - before Flutter has booted
  /// and long before an exam opens a lens - is what makes that stream reachable
  /// when no `<video>` in the document carries it.
  ///
  /// The page's own promise is returned untouched and a rejection is handed
  /// straight back: this is an observer of the camera, not a gate on it.
  function watchPageCameras() {
    try {
      var devices = navigator.mediaDevices;
      if (!devices || typeof devices.getUserMedia !== 'function') return;
      if (devices.getUserMedia.proctorGuardWatched) return;
      var request = devices.getUserMedia.bind(devices);
      var watched = function (constraints) {
        var promise = request(constraints);
        if (!promise || typeof promise.then !== 'function') return promise;
        promise.then(
          function (stream) {
            rememberStream(stream);
          },
          function () {
            // A refused request is the attempt's own business, not this loop's.
          }
        );
        return promise;
      };
      watched.proctorGuardWatched = true;
      devices.getUserMedia = watched;
    } catch (error) {
      // A page that froze `mediaDevices` still has its own preview to watch.
    }
  }

  /// Keeps the newest stream that carries video, and drops the element built for
  /// the one before it.
  function rememberStream(stream) {
    if (!stream || typeof stream.getVideoTracks !== 'function') return;
    var tracks;
    try {
      tracks = stream.getVideoTracks();
    } catch (error) {
      return;
    }
    // An audio-only request - the microphone monitor - is not a camera, and must
    // not replace the one being watched.
    if (!tracks || !tracks.length) return;
    if (stream === capturedStream) return;
    capturedStream = stream;
    ownedVideo = null;
  }

  /// An element of this script's own, playing the page's camera stream.
  ///
  /// Deliberately never inserted into the document: the page already draws the
  /// student's camera somewhere, and a second visible copy would be a UI change
  /// this sensor has no business making. A detached, muted, `playsinline` video
  /// still decodes its stream, which is all `drawImage` needs.
  function capturedVideo() {
    if (!capturedStream) return null;
    var tracks;
    try {
      tracks = capturedStream.getVideoTracks();
    } catch (error) {
      tracks = null;
    }
    if (!tracks) return null;
    var delivering = false;
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i] && tracks[i].readyState === 'live') delivering = true;
    }
    // A stream the app has closed is not a camera any more, and inventing one
    // would be inventing an absence.
    if (!delivering) return null;

    if (!ownedVideo) {
      try {
        ownedVideo = document.createElement('video');
        ownedVideo.muted = true;
        ownedVideo.setAttribute('muted', '');
        ownedVideo.setAttribute('playsinline', '');
      } catch (error) {
        ownedVideo = null;
        return null;
      }
    }
    try {
      if (ownedVideo.srcObject !== capturedStream) {
        ownedVideo.srcObject = capturedStream;
      }
      // Re-asked every tick rather than once: a browser that refused autoplay
      // leaves the element paused, and a paused element is a picture nobody is
      // being proctored by.
      if (ownedVideo.paused && typeof ownedVideo.play === 'function') {
        var played = ownedVideo.play();
        if (played && typeof played.catch === 'function') {
          played.catch(function () {
            // The next tick asks again; `inactiveReason` reports the pause.
          });
        }
      }
    } catch (error) {
      return ownedVideo;
    }
    return ownedVideo;
  }

  /// Whether `element` is the detector's own (see [capturedVideo]).
  ///
  /// It is never in the document, so the "is it still connected / is it visible"
  /// checks do not apply to it: those exist to notice a *preview* the page stopped
  /// showing, and this script decides for itself whether to show its own.
  function isOwned(element) {
    return element !== null && element !== undefined && element === ownedVideo;
  }

  // --- Finding the camera ---------------------------------------------------

  /// Every `<video>` in `root`, including the ones inside shadow roots.
  ///
  /// `document.querySelector('video')` is not enough on this app: camera_web
  /// renders its preview through `platformViewRegistry`, so the element lives
  /// under Flutter's `flt-platform-view` - in the light DOM on the engine this
  /// app ships with, but inside a shadow root whenever the engine (or a host
  /// page) closes the tree off, and a closed root is invisible to any selector
  /// run against `document`.
  function videosUnder(root, depth) {
    var found = [];
    var direct;
    try {
      direct = root.querySelectorAll('video');
    } catch (error) {
      return found;
    }
    for (var i = 0; i < direct.length; i++) found.push(direct[i]);

    if (depth >= MAX_SHADOW_DEPTH) return found;

    var all;
    try {
      all = root.querySelectorAll('*');
    } catch (error) {
      return found;
    }
    for (var j = 0; j < all.length; j++) {
      var shadow = all[j].shadowRoot;
      if (!shadow) continue;
      var nested = videosUnder(shadow, depth + 1);
      for (var k = 0; k < nested.length; k++) found.push(nested[k]);
    }
    return found;
  }

  /// The camera stream behind a video, if it has one.
  function streamTracks(element) {
    var stream = element.srcObject;
    if (!stream || typeof stream.getVideoTracks !== 'function') return null;
    return stream.getVideoTracks();
  }

  /// Whether any track of a stream is still delivering frames.
  ///
  /// `readyState` is what a browser sets when the camera is closed, the device is
  /// unplugged or the OS revokes the grant; `enabled` and `muted` are what a page
  /// (or a student in devtools) flips to blank a track without ending it.
  function hasLiveTrack(element) {
    var tracks = streamTracks(element);
    if (!tracks) return false;
    for (var i = 0; i < tracks.length; i++) {
      var track = tracks[i];
      if (!track) continue;
      if (track.readyState !== 'live') continue;
      if (track.enabled === false) continue;
      if (track.muted) continue;
      return true;
    }
    return false;
  }

  /// The `<video>` currently being proctored, or null.
  ///
  /// Cached between ticks because the element outlives them, and re-found from
  /// scratch only when it leaves the document (a rebuilt preview, a re-opened
  /// camera). A video holding a live camera stream wins over any other `<video>`
  /// a host page happens to have.
  function findVideo() {
    // Fast path: the element the last tick watched is still connected and still
    // delivering, which is every tick of a working camera.
    if (video && (isOwned(video) || video.isConnected) && hasLiveTrack(video)) {
      return video;
    }

    video = null;

    var candidates = videosUnder(document, 0);
    var fallback = null;
    for (var i = 0; i < candidates.length; i++) {
      var candidate = candidates[i];
      if (!candidate || !candidate.isConnected) continue;
      if (hasLiveTrack(candidate)) {
        video = candidate;
        return video;
      }
      if (!fallback && candidate.srcObject) fallback = candidate;
    }

    // Nothing in the document carries a live track. The page's own camera is still
    // a camera - and a sitting whose preview this script cannot reach is the one
    // case that used to end in silence, with a student unproctored.
    video = fallback || capturedVideo();
    return video;
  }

  /// Whether an element (or any ancestor) is drawn as nothing.
  ///
  /// Style-based on purpose: a rect check would call a preview that is merely
  /// between layouts "hidden", and a resize is not a student hiding their camera.
  function isHidden(element) {
    var node = element;
    var depth = 0;
    while (node && node.nodeType === 1 && depth < 32) {
      var style = null;
      try {
        style = window.getComputedStyle(node);
      } catch (error) {
        style = null;
      }
      if (style) {
        if (style.display === 'none') return true;
        if (style.visibility === 'hidden' || style.visibility === 'collapse') return true;
        if (style.opacity !== '' && parseFloat(style.opacity) <= 0.05) return true;
      }
      if (node === document.body || node === document.documentElement) break;
      node = node.parentNode;
      depth++;
    }
    return false;
  }

  /// Why `element` cannot be showing the student right now, or null if it can.
  function inactiveReason(element) {
    if (!element) return 'detached';
    var owned = isOwned(element);
    if (!owned && !element.isConnected) return 'detached';
    if (element.readyState < 2) return 'no-frame-yet';
    if (element.paused) return 'paused';
    if (element.ended) return 'ended';
    if (!element.srcObject) return 'no-stream';
    var tracks = streamTracks(element);
    if (!tracks || tracks.length === 0) return 'no-video-track';
    if (!hasLiveTrack(element)) return 'track-stopped';
    if (!element.videoWidth || !element.videoHeight) return 'no-size';
    // An element this script owns has no ancestors to hide it, and it is never in
    // the document for a student to hide: the style walk is about the preview.
    if (!owned && isHidden(element)) return 'hidden';
    return null;
  }

  // --- Reading the frame ----------------------------------------------------

  /// Mean brightness of the frame and how much it varies, or null when the frame
  /// cannot be read (a tainted canvas, a decoder that is not ready).
  ///
  /// `trackRepeat` is false for a diagnostic read: asking the detector what it sees
  /// must not count as a frame of the loop that decides whether the picture is
  /// moving.
  ///
  /// Null is not evidence: an unreadable frame is reported as nothing rather than
  /// as an absent student, or a browser that refuses `getImageData` for its own
  /// reasons would accuse every student running on it.
  function sampleFrame(element, trackRepeat) {
    try {
      if (!canvas) {
        canvas = document.createElement('canvas');
        canvas.width = SAMPLE_WIDTH;
        canvas.height = SAMPLE_HEIGHT;
        context = canvas.getContext('2d', { willReadFrequently: true });
      }
      if (!context) return null;

      context.drawImage(element, 0, 0, SAMPLE_WIDTH, SAMPLE_HEIGHT);
      var pixels = context.getImageData(0, 0, SAMPLE_WIDTH, SAMPLE_HEIGHT).data;
      var count = 0;
      var total = 0;
      var totalSquares = 0;
      for (var i = 0; i < pixels.length; i += 4) {
        // Rec. 709 luma, which is what "how bright is this" means for a camera.
        var luma = 0.2126 * pixels[i] + 0.7152 * pixels[i + 1] + 0.0722 * pixels[i + 2];
        total += luma;
        totalSquares += luma * luma;
        count++;
      }
      if (count === 0) return null;

      var mean = total / count;
      var variance = totalSquares / count - mean * mean;
      return {
        mean: mean,
        spread: Math.sqrt(variance > 0 ? variance : 0),
        frozen: trackRepeat === false ? false : trackFrozen(pixels)
      };
    } catch (error) {
      return null;
    }
  }

  /// Whether this thumbnail is the same picture as the last one, counted.
  ///
  /// Byte-for-byte on purpose: every real sensor is noisy, so a live camera never
  /// repeats a frame exactly, while a photo in front of the lens, a stalled
  /// decoder or a virtual camera looping a screenshot repeats it forever. This is
  /// the one check that catches a *bright* fake - a still frame of a face has all
  /// the structure and brightness of the real thing.
  function trackFrozen(pixels) {
    var repeat = lastPixels !== null;
    if (repeat) {
      for (var i = 0; i < pixels.length; i++) {
        if (pixels[i] !== lastPixels[i]) {
          repeat = false;
          break;
        }
      }
    }
    if (repeat) {
      frozenTicks++;
    } else {
      frozenTicks = 0;
      lastPixels = new Uint8ClampedArray(pixels);
    }
    return frozenTicks + 1 >= FROZEN_TICKS;
  }

  /// Whether a readable frame holds no picture of anything.
  ///
  /// Four ways a camera can be "on" without showing a student, in the order they
  /// are cheapest to be sure about:
  ///
  ///  * `frozen` - the same thumbnail as the last one, three ticks running: a
  ///    still image or a dead decoder, whatever it is a picture of;
  ///  * featureless at any brightness - a lens with something over it, or a camera
  ///    pointed at a blank surface;
  ///  * dim *and* featureless - a covered lens in a lit room (auto-exposure lifts
  ///    it to a grey-brown) or a room with the lights off;
  ///  * blown out - a camera pointed into a lamp.
  function frameIsBlank(sample) {
    if (!sample) return false;
    if (sample.frozen) return true;
    if (sample.spread <= FEATURELESS_SPREAD) return true;
    if (sample.mean <= DARK_MEAN && sample.spread <= DARK_SPREAD) return true;
    if (sample.mean >= BLOWN_MEAN && sample.spread <= BLOWN_SPREAD) return true;
    return false;
  }

  // --- Reading the face, when the browser can -------------------------------

  /// A `FaceDetector`, or null on the browsers that ship none (Firefox and Safari
  /// do not, and neither does Chromium on Windows: its Shape Detection API is a
  /// ChromeOS/Android feature).
  function detector() {
    if (faceDetectorChecked) return faceDetector;
    faceDetectorChecked = true;
    try {
      var Constructor = window.FaceDetector;
      if (typeof Constructor !== 'function') return faceDetector;
      try {
        faceDetector = new Constructor({ fastMode: true, maxDetectedFaces: 2 });
      } catch (error) {
        faceDetector = new Constructor();
      }
    } catch (error) {
      faceDetector = null;
    }
    return faceDetector;
  }

  /// A promise for what a face model saw in this frame - `{ faces, yaw, pitch }` -
  /// or null when this page has no model that can look at all.
  ///
  /// Two providers, in the order they are trusted: the browser's own Shape
  /// Detection API ([inspectNative]) and, for every browser that ships none, the
  /// model this build carries ([inspectWithMediaPipe]). A page never runs both.
  function inspect(element) {
    var engine = detector();
    if (engine && typeof engine.detect === 'function') return inspectNative(engine, element);
    return inspectWithMediaPipe(element);
  }

  /// A promise for what the Shape Detection API saw in this frame.
  ///
  /// `yaw`/`pitch` stay null when a face was counted but no landmarks came with
  /// it: a count is not an angle, and an angle is the only thing Dart cannot
  /// derive from a count.
  ///
  /// The promise resolves to null (not to a zero-face reading) when the detector
  /// itself fails: a model that threw did not look, and "did not look" is not "no
  /// one is there".
  function inspectNative(engine, element) {
    try {
      var detection = engine.detect(element);
      if (!detection || typeof detection.then !== 'function') return null;
      return detection.then(
        function (faces) {
          if (!faces) return { faces: 0, yaw: null, pitch: null };
          var pose = faces.length === 1 ? measurePose(faces[0]) : null;
          return {
            faces: faces.length,
            yaw: pose ? pose.yaw : null,
            pitch: pose ? pose.pitch : null
          };
        },
        function () {
          return null;
        }
      );
    } catch (error) {
      return null;
    }
  }

  /// The points of one landmark group (`'eye'`, `'nose'`, `'mouth'`), or null.
  function landmarkPoints(face, type) {
    var groups = face && face.landmarks;
    if (!groups || !groups.length) return null;
    for (var i = 0; i < groups.length; i++) {
      var group = groups[i];
      if (!group || group.type !== type) continue;
      var points = group.locations;
      if (points && points.length) return points;
    }
    return null;
  }

  /// Yaw and pitch in degrees for one face, or null when the model gave nothing to
  /// measure them from.
  ///
  /// Only the landmarks are used: a bounding box says where a face *is*, never
  /// where it is pointing. The angle is a *proportion of the face* - how far the
  /// nose has swung from the midpoint between the eyes, in units of the distance
  /// between them - so it needs no calibration per camera, per resolution or per
  /// student, and a face at the edge of the frame measures the same as one in the
  /// middle.
  ///
  /// Yaw is the arcsine of that swing (a nose that has reached the far eye is
  /// about ninety degrees round). Pitch is the nose's drop below the eye line
  /// against where it sits on a face looking at the screen
  /// ([FRONTAL_NOSE_DROP]): an approximation, reported as one - and it is Dart's
  /// tolerance, never this script, that decides whether either angle matters.
  function measurePose(face) {
    var eyes = landmarkPoints(face, 'eye');
    var nose = landmarkPoints(face, 'nose');
    if (!eyes || eyes.length < 2 || !nose || !nose.length) return null;
    var left = eyes[0];
    var right = eyes[eyes.length - 1];
    var tip = nose[0];
    if (!left || !right || !tip) return null;

    var spanX = right.x - left.x;
    var spanY = right.y - left.y;
    var span = Math.sqrt(spanX * spanX + spanY * spanY);
    if (!(span > 0)) return null;

    var midX = (left.x + right.x) / 2;
    var midY = (left.y + right.y) / 2;

    var offset = (tip.x - midX) / (span / 2);
    if (offset > 1) offset = 1;
    if (offset < -1) offset = -1;

    return {
      yaw: (Math.asin(offset) * 180) / Math.PI,
      pitch: (FRONTAL_NOSE_DROP - (tip.y - midY) / span) * 100
    };
  }

  /// The median of the last [POSE_WINDOW] readings, per axis.
  ///
  /// One bad frame cannot move a median, which is the point: a landmark model's
  /// jitter must never become a warning, while a real turn holds for far longer
  /// than three ticks.
  function smoothedPose(yaw, pitch) {
    poseSamples.push({ yaw: yaw, pitch: pitch });
    while (poseSamples.length > POSE_WINDOW) poseSamples.shift();
    var yaws = [];
    var pitches = [];
    for (var i = 0; i < poseSamples.length; i++) {
      yaws.push(poseSamples[i].yaw);
      pitches.push(poseSamples[i].pitch);
    }
    return { yaw: median(yaws), pitch: median(pitches) };
  }

  function median(values) {
    var sorted = values.slice().sort(function (a, b) {
      return a - b;
    });
    var middle = Math.floor(sorted.length / 2);
    if (sorted.length % 2) return sorted[middle];
    return (sorted[middle - 1] + sorted[middle]) / 2;
  }

  /// The wire form of a measured pose: `pose:<yaw>,<pitch>` degrees to one
  /// decimal, the vocabulary of `WebFaceMessages.posePrefix`.
  function poseMessage(pose) {
    return MESSAGES.pose + pose.yaw.toFixed(1) + ',' + pose.pitch.toFixed(1);
  }

  /// Radians as degrees, unrounded: the message rounds, the geometry does not.
  function toDegrees(radians) {
    return (radians * 180) / Math.PI;
  }

  // --- The model this build ships -------------------------------------------
  //
  // MediaPipe's FaceLandmarker, for every browser without a Shape Detection API of
  // its own. It is the same class of sensor as the one above - it counts faces and
  // locates a face's features - with one thing the Shape Detection API never gives
  // a page: a head pose solved in 3D against a canonical face.

  /// Where the model's assets are, honouring a host page's override, or null when
  /// this page asked not to load a model at all.
  function mediaPipeConfig() {
    var chosen = window.proctorGuardMediaPipe;
    if (chosen === false || chosen === 'off') return null;
    if (!chosen || typeof chosen !== 'object') return MEDIAPIPE;
    return {
      module: typeof chosen.module === 'string' ? chosen.module : MEDIAPIPE.module,
      wasm: typeof chosen.wasm === 'string' ? chosen.wasm : MEDIAPIPE.wasm,
      model: typeof chosen.model === 'string' ? chosen.model : MEDIAPIPE.model
    };
  }

  /// Starts loading the model, once per page session, on the first tick that has a
  /// live camera to show it.
  ///
  /// Lazy on purpose: the landing page, the login form and every route that never
  /// opens a lens pay nothing for a model they will not use, and a browser with a
  /// Shape Detection API of its own never fetches it at all.
  function ensureMediaPipe() {
    if (mediaPipe.state !== 'idle') return;
    var config = mediaPipeConfig();
    if (!config) {
      mediaPipe.state = 'off';
      return;
    }
    if (typeof window.WebAssembly !== 'object' || !window.WebAssembly) {
      // An older browser, or a CSP that never granted 'wasm-unsafe-eval': the
      // model cannot run at all, and saying so once beats failing to compile it
      // on every tick.
      giveUpMediaPipe('no-webassembly');
      return;
    }
    mediaPipe.state = 'loading';
    loadMediaPipe(config).then(
      function (landmarker) {
        if (mediaPipe.state !== 'loading') return;
        mediaPipe.landmarker = landmarker;
        mediaPipe.state = 'ready';
      },
      function (error) {
        giveUpMediaPipe(error && error.message ? error.message : String(error));
      }
    );
  }

  /// A path the model needs, as an absolute URL on this page's own origin.
  ///
  /// `import('mediapipe/vision_bundle.mjs')` is *not* a relative specifier as far
  /// as a browser is concerned: anything that does not begin with `.`, `..` or `/`
  /// is a bare specifier - the syntax an import map exists to redirect - and a
  /// page without one fails with "Failed to resolve module specifier". Resolving
  /// against `document.baseURI` first is what turns a plain path into a module a
  /// page can load, and it keeps working wherever the app is served from: the
  /// root, a sub-path, behind a reverse proxy.
  function assetUrl(specifier) {
    try {
      return new URL(specifier, document.baseURI).href;
    } catch (error) {
      // Something the URL parser did not like: hand it over untouched and let the
      // loader report the real problem in its own words.
      return specifier;
    }
  }

  /// The model as a promise: a `FaceLandmarker` ready to look at frames, or a
  /// rejection that [ensureMediaPipe] turns into "this page measures no angles".
  ///
  /// `import()` is how a classic script gets an ES module on demand - no build
  /// step, no `type="module"` tag, no bundler - and the specifier resolves against
  /// this app's own origin, so the module comes from the same place the page did:
  /// `script-src 'self'` covers it, `connect-src 'self'` covers the model file,
  /// and nothing about an exam's page depends on a CDN being reachable, allowed or
  /// honest.
  ///
  /// `'wasm-unsafe-eval'` - already in index.html's policy for CanvasKit - is what
  /// compiling the model's WebAssembly needs. The loader script the bundle injects
  /// is same-origin, so no `'unsafe-eval'` is involved anywhere.
  function loadMediaPipe(config) {
    return Promise.resolve()
      .then(function () {
        return import(assetUrl(config.module));
      })
      .then(function (vision) {
        var resolver = vision && vision.FilesetResolver;
        var Landmarker = vision && vision.FaceLandmarker;
        if (
          !resolver ||
          typeof resolver.forVisionTasks !== 'function' ||
          typeof Landmarker !== 'function' ||
          typeof Landmarker.createFromOptions !== 'function'
        ) {
          throw new Error('the vision module exported no FaceLandmarker');
        }
        return Promise.resolve(resolver.forVisionTasks(assetUrl(config.wasm))).then(function (fileset) {
          var options = {
            baseOptions: { modelAssetPath: assetUrl(config.model), delegate: 'GPU' },
            // `VIDEO`, which is this API's streaming mode in a browser: the bundle
            // has no `LIVE_STREAM` running mode at all (only `IMAGE` and `VIDEO`),
            // and `VIDEO` is the one that keeps a tracker between calls and
            // processes the newest decoded frame - exactly what [pumpMediaPipe]
            // hands it, once per tick, for as long as the camera is live.
            runningMode: 'VIDEO',
            // Two, not one: `multiple_faces` is a verdict Dart wants, and a model
            // that stopped at the first face could never report it.
            numFaces: 2,
            outputFaceBlendshapes: false,
            outputFacialTransformationMatrixes: true
          };
          return Landmarker.createFromOptions(fileset, options).then(null, function () {
            // No usable WebGL - a headless runner, a blocklisted driver, a kiosk
            // with hardware acceleration switched off - so the GPU delegate cannot
            // be created. The same model on the CPU is slower and just as truthful.
            options.baseOptions.delegate = 'CPU';
            return Landmarker.createFromOptions(fileset, options);
          });
        });
      });
  }

  /// Gives up on the model for the rest of the page session.
  ///
  /// One failure is enough. A model that will not load in this browser will not
  /// load on the next tick either, and retrying it every 350 ms would be a
  /// download storm on a school network. The loop is untouched: a covered lens, a
  /// frozen preview, a dead track and a preview that never opened are all still
  /// judged by the pixels and the camera element, and a live non-blank frame is
  /// still `centered` - the page this app served on desktop browsers before the
  /// model existed.
  function giveUpMediaPipe(reason) {
    mediaPipe.state = 'failed';
    mediaPipe.landmarker = null;
    mediaPipe.latest = null;
    mediaPipe.latestAt = 0;
    mediaPipe.error = reason;
    try {
      if (window.console && typeof window.console.warn === 'function') {
        window.console.warn(
          'ProctorGuard: head-pose model unavailable (' +
            reason +
            '); presence, covered-lens and frozen-preview checks continue without it'
        );
      }
    } catch (error) {
      // A console that refuses to log is not a reason to break the loop.
    }
  }

  /// A promise for what the shipped model saw in this frame, or null when it is
  /// not (yet) able to look.
  ///
  /// Null while the model is still downloading, after it gave up, and on a page
  /// that turned it off. Each of those is "this page cannot measure an angle right
  /// now", which [tick] already answers with `centered` - the answer this app gave
  /// on a desktop browser before the model existed.
  function inspectWithMediaPipe(element) {
    ensureMediaPipe();
    if (mediaPipe.state !== 'ready') return null;
    pumpMediaPipe(element);
    if (!mediaPipe.latest) return null;
    // A reading from a frame nobody is serving any more is not evidence about this
    // moment. This loop is faster than [MEDIAPIPE_STALE_MS] on any page decoding
    // frames at all, so reaching it means the model stopped answering.
    if (Date.now() - mediaPipe.latestAt > MEDIAPIPE_STALE_MS) return null;
    return Promise.resolve(mediaPipe.latest);
  }

  /// Shows the model the newest frame, and keeps what it saw.
  ///
  /// In `VIDEO` mode the call returns the reading directly, so there is no callback
  /// to wait for and no window in which two frames are being measured at once. It
  /// is skipped when the element has not decoded a new frame since the last call:
  /// asking the tracker the same question twice only burns a GPU pass.
  function pumpMediaPipe(element) {
    if (mediaPipe.state !== 'ready' || !mediaPipe.landmarker) return;
    var width = element.videoWidth;
    var height = element.videoHeight;
    if (!width || !height) return;
    if (mediaPipe.element !== element) {
      // A different preview than the one the last reading came from: a face seen
      // in the old one says nothing about the new one.
      mediaPipe.element = element;
      mediaPipe.frameAt = -1;
      mediaPipe.latest = null;
      mediaPipe.latestAt = 0;
    }
    if (element.currentTime === mediaPipe.frameAt) return;
    mediaPipe.frameAt = element.currentTime;
    // Monotonic by construction: the model rejects a timestamp that does not
    // advance, and two ticks can land in the same millisecond.
    var stamp = Date.now();
    if (stamp <= mediaPipe.stamp) stamp = mediaPipe.stamp + 1;
    mediaPipe.stamp = stamp;
    try {
      var result = mediaPipe.landmarker.detectForVideo(element, stamp);
      mediaPipe.latest = mediaPipeReading(result, width, height);
      mediaPipe.latestAt = Date.now();
      mediaPipe.failures = 0;
    } catch (error) {
      // The frame was not readable, or the runtime died. Losing a tick is not
      // evidence about the student; losing three is a model this page cannot use.
      mediaPipe.latest = null;
      mediaPipe.latestAt = 0;
      mediaPipe.failures++;
      if (mediaPipe.failures >= MEDIAPIPE_FAILURES) {
        giveUpMediaPipe('inference-failed: ' + (error && error.message ? error.message : error));
      }
    }
  }

  /// What the model saw, in the shape the Shape Detection path answers with:
  /// `{ faces, yaw, pitch }`, the angles null when a face came back without one.
  function mediaPipeReading(result, width, height) {
    var faces = result && result.faceLandmarks ? result.faceLandmarks : null;
    if (!faces || !faces.length) return { faces: 0, yaw: null, pitch: null };
    var pose =
      faces.length === 1 ? landmarkPose(faces[0], result.facialTransformationMatrixes, width, height) : null;
    return {
      faces: faces.length,
      yaw: pose ? pose.yaw : null,
      pitch: pose ? pose.pitch : null
    };
  }

  /// Yaw and pitch in degrees for one face of the shipped model, or null when that
  /// face carries neither a pose matrix nor the landmarks a pose can be measured
  /// from.
  ///
  /// Two routes, in the order they can be trusted:
  ///
  ///  * `facialTransformationMatrixes` - the head pose the model solves in 3D
  ///    against its canonical face from all 478 landmarks. This is the accurate
  ///    route, and the reason the model is worth 13 MB of assets.
  ///  * the landmarks themselves, through the same [measurePose] the Shape
  ///    Detection path uses, when a build returns no matrix. One definition of
  ///    "yaw" for both providers, so Dart's tolerance means the same thing on
  ///    either.
  function landmarkPose(landmarks, matrices, width, height) {
    var pose = matrixPose(matrices && matrices.length ? matrices[0] : null);
    if (pose) return pose;
    return measurePose(modelFace(landmarks, width, height));
  }

  /// One face of the shipped model, dressed as the landmark groups the Shape
  /// Detection path uses, so [measurePose] can measure it too. The indices are the
  /// model's canonical mesh ([FACE]): the outer corner of each eye and the tip of
  /// the nose - the same three points, in the same words.
  function modelFace(landmarks, width, height) {
    if (!landmarks) return null;
    var left = normalizedPoint(landmarks[FACE.leftEyeOuter], width, height);
    var right = normalizedPoint(landmarks[FACE.rightEyeOuter], width, height);
    var tip = normalizedPoint(landmarks[FACE.noseTip], width, height);
    if (!left || !right || !tip) return null;
    return {
      landmarks: [
        { type: 'eye', locations: [left, right] },
        { type: 'nose', locations: [tip] }
      ]
    };
  }

  /// A normalized landmark - `x` and `y` in 0..1 of the frame - as the pixel it
  /// names, which is the unit the Shape Detection API answers in and therefore the
  /// unit [measurePose] measures in.
  function normalizedPoint(point, width, height) {
    if (!point) return null;
    if (typeof point.x !== 'number' || typeof point.y !== 'number') return null;
    if (!isFinite(point.x) || !isFinite(point.y)) return null;
    return {
      x: point.x * width,
      y: point.y * height,
      z: typeof point.z === 'number' && isFinite(point.z) ? point.z * width : 0
    };
  }

  /// Yaw and pitch in degrees from the head-pose matrix the model solved, or null
  /// when it returned none.
  ///
  /// The matrix is 4x4 and column-major - `Matrix.data` is how this API flattens an
  /// OpenGL-style matrix - so element (row, column) is at `column * 4 + row`. It is
  /// the head's rotation, so with the decomposition R = Ry(yaw) * Rx(pitch) *
  /// Rz(roll):
  ///
  ///     pitch = asin(-R[1][2])        yaw = atan2(R[0][2], R[2][2])
  ///
  /// The sign of both depends on which way the model's camera axes point, and it is
  /// deliberately not corrected for: Dart judges `abs(yaw)` and `abs(pitch)`
  /// (see `WebFacePresenceMonitor.offCenterYawDegrees`), so a mirrored angle is the
  /// same evidence, while inventing a sign convention here would be a claim this
  /// file cannot check against a real face.
  ///
  /// One limit is real: with the head at ninety degrees up or down the two axes
  /// collapse and yaw is not observable. That is reported as zero rather than as a
  /// number invented to fill the message.
  function matrixPose(matrix) {
    var data = matrix && matrix.data;
    if (!data || data.length < 16) return null;

    function at(row, column) {
      var value = data[column * 4 + row];
      return typeof value === 'number' && isFinite(value) ? value : null;
    }

    var m02 = at(0, 2);
    var m12 = at(1, 2);
    var m22 = at(2, 2);
    if (m02 === null || m12 === null || m22 === null) return null;

    var sinPitch = -m12;
    if (sinPitch > 1) sinPitch = 1;
    if (sinPitch < -1) sinPitch = -1;
    var cosine = Math.sqrt(1 - sinPitch * sinPitch);
    return {
      yaw: cosine < 1e-6 ? 0 : toDegrees(Math.atan2(m02, m22)),
      pitch: toDegrees(Math.asin(sinPitch))
    };
  }

  // --- The loop -------------------------------------------------------------

  function schedule() {
    if (!running || timer !== null) return;
    timer = window.setTimeout(function () {
      timer = null;
      tick();
    }, INTERVAL_MS);
  }

  /// Forgets the frame this loop was reading.
  ///
  /// Called between attempts and on [stop]: the next attempt must not inherit
  /// "the last three thumbnails were identical" - or the read time of a stall -
  /// from the previous one.
  function resetEpisode() {
    lastPixels = null;
    frozenTicks = 0;
    watched = null;
    inactiveSince = 0;
    poseSamples = [];
    // The model's last reading goes with them. The model itself stays loaded: an
    // attempt that ends and another that starts minutes later should not pay for
    // 13 MB of WebAssembly twice.
    mediaPipe.latest = null;
    mediaPipe.latestAt = 0;
    mediaPipe.element = null;
    mediaPipe.frameAt = -1;
  }

  /// Says, once per page session, that an attempt is running with no preview in
  /// reach.
  ///
  /// It is the one failure with no verdict to speak: a page that forgot the
  /// `<script>`, a renamed platform view, a preview the app never built, and an
  /// app that drew its self-view with something other than a `<video>` all look
  /// identical from here - and all of them leave a browser student unproctored.
  /// A console line is what a phone's remote devtools can read.
  function warnNoPreview() {
    try {
      if (window.console && window.console.warn) {
        window.console.warn(
          'ProctorGuard: an attempt is open and no camera preview can be found ' +
            '(no <video> element with a live track). Web face detection is inactive ' +
            'for this sitting. Check that proctor_face_detector.js is loaded and that ' +
            'the camera preview is on screen.'
        );
      }
    } catch (error) {
      // A host page without a console is still proctored by the rest of the app.
    }
  }

  /// Ends one tick: releases the guard, speaks the verdict (if any), and queues
  /// the next tick. Every path out of [tick] goes through here, so no early
  /// return can stall the loop.
  ///
  /// `session` is the loop generation the tick started in. A tick whose face
  /// detection resolves after [stop] (or after a stop/start pair) is stale: it
  /// must neither report into a closed attempt nor free the guard of the tick
  /// that now owns it.
  function finished(message, session) {
    if (session !== generation) return;
    busy = false;
    if (!running) return;
    if (message) report(message);
    schedule();
  }

  function tick() {
    if (!running || busy) return;

    // Nothing is listening between attempts: no DOM discovery, no sampling, no
    // pixels read. The timer stays, so the next attempt in this page session is
    // covered without a reload.
    if (!drainHook()) {
      resetEpisode();
      lastVerdict = null;
      schedule();
      return;
    }

    // A page that is not on screen is not being watched by this loop: the browser
    // throttles its timers and a suspended preview keeps its last frame, while
    // leaving the exam surface is already `app_minimized` from the web guard. One
    // act, one strike - and never a `no_face` for a camera the student was not
    // there to uncover.
    if (document.visibilityState === 'hidden') {
      lastVerdict = null;
      schedule();
      return;
    }

    var session = generation;
    busy = true;
    try {
      var element = findVideo();
      if (!element) {
        // A page with no camera element at all - the login screen, a mock
        // session, a host that replaced the preview. There is nothing to judge,
        // and no absence to accuse anyone of.
        seenLive = null;
        watched = null;
        inactiveSince = 0;
        lastVerdict = null;
        if (!warnedNoPreview) {
          warnedNoPreview = true;
          warnNoPreview();
        }
        finished(null, session);
        return;
      }

      if (inactiveReason(element)) {
        // A camera this page has shown a live frame of is evidence the moment it
        // goes dark. A preview that has never shown a frame gets [STALL_MS] first:
        // a camera the app opened and could not feed is a camera problem the
        // attempt reports on its own terms, but a preview that stays black for five
        // seconds mid-exam is a camera that was taken away - the one case `seenLive`
        // on its own would never report, because it was blocked before the first
        // tick could see it live.
        if (watched !== element || !inactiveSince) {
          watched = element;
          inactiveSince = Date.now();
        }
        var stalled = Date.now() - inactiveSince >= STALL_MS;
        finished(seenLive === element || stalled ? MESSAGES.noFace : null, session);
        return;
      }

      // Seen live: from here on, this element going dark is evidence.
      seenLive = element;
      watched = element;
      inactiveSince = 0;

      var sample = sampleFrame(element);
      if (frameIsBlank(sample)) {
        finished(MESSAGES.noFace, session);
        return;
      }

      var detection = inspect(element);
      if (!detection) {
        // No model can look at this frame: this browser has no Shape Detection
        // API, and the shipped model is still loading, gave up, or was turned off
        // by the host page. The frame is live and carries a picture of something,
        // which is as much as this page can honestly say without a model; it ends
        // an absence episode and can never start one.
        finished(MESSAGES.centered, session);
        return;
      }

      detection.then(
        function (reading) {
          // A detector that threw did not look: no evidence either way.
          if (!reading) {
            finished(null, session);
            return;
          }
          if (reading.faces === 0) {
            // No face is no pose, and the samples of the last one must not be
            // waiting to be reported when the student comes back.
            poseSamples = [];
            finished(MESSAGES.noFace, session);
            return;
          }
          if (reading.faces > 1) {
            poseSamples = [];
            finished(MESSAGES.multipleFaces, session);
            return;
          }
          if (reading.yaw === null || reading.pitch === null) {
            // One face, but this model gave no landmarks to measure. A count is
            // still the whole of "someone is in front of the camera", and Dart
            // cannot judge an angle nobody measured.
            poseSamples = [];
            finished(MESSAGES.centered, session);
            return;
          }
          var pose = smoothedPose(reading.yaw, reading.pitch);
          // The angles, not a verdict: whether 20 degrees is a look away is this
          // app's rule (`WebFacePresenceMonitor.offCenterYawDegrees`), applied to
          // the same numbers the on-device engine produces, rather than a
          // threshold this script guessed at and cannot be audited on.
          finished(poseMessage(pose), session);
        },
        function () {
          finished(null, session);
        }
      ).then(null, function () {
        // A reading this loop could not apply - a shape the model should never
        // produce, a bug in the measurement - must not leave the tick guard held:
        // one tick is lost, never the loop.
        finished(null, session);
      });
    } catch (error) {
      // A detector that throws is a detector with no evidence: the tick is lost,
      // the loop is not.
      finished(null, session);
    }
  }

  // --- The host-facing surface ---------------------------------------------

  function start(options) {
    if (running) return;
    var interval = options && options.intervalMs;
    if (typeof interval === 'number' && interval >= 100 && interval <= 10000) {
      INTERVAL_MS = interval;
    }
    running = true;
    generation++;
    schedule();
  }

  function stop() {
    running = false;
    busy = false;
    generation++;
    resetEpisode();
    if (timer !== null) {
      window.clearTimeout(timer);
      timer = null;
    }
  }

  window.ProctorGuardFaceDetector = {
    installed: true,

    /// Starts polling. Idempotent, and cheap while no attempt is open (the loop
    /// skips its work until Dart installs the hook).
    start: start,

    /// Stops polling. The hook is left alone: it belongs to Dart.
    stop: stop,

    isRunning: function () {
      return running;
    },

    /// One tick now, for a host that wants to check its own wiring.
    poll: function () {
      if (running) tick();
    },

    /// The last verdict spoken, for diagnostics (`null` before the first one).
    lastVerdict: function () {
      return lastVerdict;
    },

    /// The element currently being watched, for diagnostics.
    video: function () {
      return findVideo();
    },

    /// Everything this loop knows, for a host or a proctor wiring up a browser
    /// build: why the last tick said what it said, in plain words.
    ///
    /// `ProctorGuardFaceDetector.diagnostics()` in a phone's remote devtools is the
    /// quickest way to answer "why is nothing being flagged": no `hook` means the
    /// attempt's Dart side is not listening, `video: null` means no preview was
    /// found, `reason` names the state the preview is in, and `lastVerdict` says
    /// what the page last told the app.
    ///
    /// `faceModel` names the sensor that measured the head - `native` for the
    /// browser's Shape Detection API, `mediapipe` for the shipped model, `none` for
    /// a page that can count nothing but pixels - and `modelState`/`modelError` say
    /// why the shipped model is not ready when it is not (`idle` until a camera is
    /// live, `loading`, `off` for a host that disabled it, `failed` with the reason
    /// it gave up). `model: false` with `faceModel: 'none'` is the page that can
    /// only say "a picture, not a blank one"; `captured` says the camera came from
    /// the page's own request because no preview in the document carried it.
    diagnostics: function () {
      var element = findVideo();
      var sample = element && !inactiveReason(element) ? sampleFrame(element, false) : null;
      var tracks = element ? streamTracks(element) : null;
      var engine = detector();
      var native = !!(engine && typeof engine.detect === 'function');
      return {
        installed: true,
        running: running,
        intervalMs: INTERVAL_MS,
        hook: !!drainHook(),
        lastVerdict: lastVerdict,
        video: element
          ? {
              id: element.id || null,
              owned: isOwned(element),
              width: element.videoWidth,
              height: element.videoHeight,
              paused: element.paused,
              readyState: element.readyState,
              source: element.srcObject ? 'srcObject' : element.currentSrc || null,
              tracks: tracks
                ? tracks.map(function (track) {
                    return track.readyState + (track.muted ? '/muted' : '') + (track.enabled ? '' : '/disabled');
                  })
                : []
            }
          : null,
        reason: element ? inactiveReason(element) : 'no-preview',
        sample: sample
          ? { mean: Math.round(sample.mean), spread: Math.round(sample.spread), frozen: sample.frozen }
          : null,
        model: native || mediaPipe.state === 'ready',
        faceModel: native ? 'native' : mediaPipe.state === 'ready' ? 'mediapipe' : 'none',
        modelState: mediaPipe.state,
        modelError: mediaPipe.error,
        captured: capturedStream
          ? capturedStream.getVideoTracks().length
          : 0,
        pose:
          lastVerdict && lastVerdict.indexOf(MESSAGES.pose) === 0
            ? lastVerdict.substring(MESSAGES.pose.length)
            : null,
        visible: document.visibilityState
      };
    }
  };

  // The page's own camera request is remembered from the moment this script
  // loads, before Flutter boots: by the time an exam opens a lens, the request
  // that opens it is already being watched, and its stream is reachable even
  // when the preview that draws it is not (see [watchPageCameras]).
  watchPageCameras();

  // Polling starts with the page, before Flutter has booted: the loop skips its
  // work until the hook appears, which covers the attempt from its first frame.
  // The alternative - starting on an event this page does not own - would race
  // the boot and miss the beginning of a sitting.
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      start();
    });
  } else {
    start();
  }
})();
