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
    * `centered` when the frame is live and not blank and the browser has no face
      model: a live frame of the student's desk is the only evidence available,
      and it is what ends an absence episode. It is never a violation.
    * `multiple_faces` when a face model (the Shape Detection API) actually counts
      more than one face. Reported on the tick it is seen; Dart latches it.

  It never says `looking_away`: a head pose is something a model measures, and a
  page that can measure one may say so itself (`WebFaceMessages.lookingAway`).
  Guessing an angle from a bounding box would be inventing evidence.

  Deliberately plain ES5-ish JavaScript with no build step and no `type="module"`:
  like the lockdown in index.html it is the part of the client a host may have to
  read or adapt, and Dart looks the hook up by name on `window`.
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
    multipleFaces: 'multiple_faces'
  };

  // --- Tuning ---------------------------------------------------------------

  // One tick more than `WebFacePresenceMonitor.sustain` (300 ms): the first
  // `no_face` opens the episode, the second leaves it older than the sustain.
  // Measured in wall time, not frames, because nothing guarantees this page's
  // frame rate.
  var INTERVAL_MS = 350;

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

  // --- State ----------------------------------------------------------------

  var running = false;
  var timer = null;
  var busy = false;
  var generation = 0;
  var video = null;
  var seenLive = null;
  var lastVerdict = null;
  var canvas = null;
  var context = null;
  var faceDetector = null;
  var faceDetectorChecked = false;

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
    // `no_face` and `multiple_faces` are re-sent every tick they hold (Dart
    // measures a sustain in time, and a cooldown from the last sighting), but a
    // repeated `centered` carries nothing: it only ends an episode, and an
    // episode ends once.
    if (message === lastVerdict && message === MESSAGES.centered) return;
    lastVerdict = message;

    var hook = drainHook();
    if (!hook) return;
    try {
      hook(message);
    } catch (error) {
      // A host that broke its own hook still gets a working page.
    }
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
    if (video && video.isConnected && hasLiveTrack(video)) return video;

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
    video = fallback;
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
    if (!element || !element.isConnected) return 'detached';
    if (element.readyState < 2) return 'no-frame-yet';
    if (element.paused) return 'paused';
    if (element.ended) return 'ended';
    if (!element.srcObject) return 'no-stream';
    var tracks = streamTracks(element);
    if (!tracks || tracks.length === 0) return 'no-video-track';
    if (!hasLiveTrack(element)) return 'track-stopped';
    if (!element.videoWidth || !element.videoHeight) return 'no-size';
    if (isHidden(element)) return 'hidden';
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

  // --- Counting faces, when the browser can ---------------------------------

  /// A `FaceDetector`, or null on the browsers that ship none (Firefox and Safari
  /// do not; Chromium has it behind the Shape Detection flag).
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

  /// A promise for the number of faces in the frame, or null when this browser
  /// cannot count them.
  ///
  /// The promise resolves to null (not 0) when the detector itself fails: a model
  /// that threw did not look, and "did not look" is not "no one is there".
  function countFaces(element) {
    var engine = detector();
    if (!engine || typeof engine.detect !== 'function') return null;
    try {
      var detection = engine.detect(element);
      if (!detection || typeof detection.then !== 'function') return null;
      return detection.then(
        function (faces) {
          return faces ? faces.length : 0;
        },
        function () {
          return null;
        }
      );
    } catch (error) {
      return null;
    }
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

      var detection = countFaces(element);
      if (!detection) {
        // No face model in this browser. The frame is live and carries a picture
        // of something, which is as much as this page can honestly say without
        // one; it ends an absence episode and can never start one.
        finished(MESSAGES.centered, session);
        return;
      }

      detection.then(
        function (faces) {
          if (faces === null) finished(null, session);
          else if (faces === 0) finished(MESSAGES.noFace, session);
          else if (faces > 1) finished(MESSAGES.multipleFaces, session);
          else finished(MESSAGES.centered, session);
        },
        function () {
          finished(null, session);
        }
      );
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
    diagnostics: function () {
      var element = findVideo();
      var sample = element && !inactiveReason(element) ? sampleFrame(element, false) : null;
      return {
        installed: true,
        running: running,
        intervalMs: INTERVAL_MS,
        hook: !!drainHook(),
        lastVerdict: lastVerdict,
        video: element
          ? {
              id: element.id || null,
              width: element.videoWidth,
              height: element.videoHeight,
              paused: element.paused,
              readyState: element.readyState,
              source: element.srcObject ? 'srcObject' : element.currentSrc || null,
              tracks: streamTracks(element)
                ? streamTracks(element).map(function (track) {
                    return track.readyState + (track.muted ? '/muted' : '') + (track.enabled ? '' : '/disabled');
                  })
                : []
            }
          : null,
        reason: element ? inactiveReason(element) : 'no-preview',
        sample: sample
          ? { mean: Math.round(sample.mean), spread: Math.round(sample.spread), frozen: sample.frozen }
          : null,
        visible: document.visibilityState
      };
    }
  };

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
