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
      itself carries nothing - a covered lens (near-black), a blown-out frame, or
      one flat colour (a fake or stalled stream). A student can produce every one
      of those at the page's own layer, without touching a pixel of the app.
    * `no_face` again on each tick it still holds, because Dart's sustain is
      measured in time: one verdict is a dropped frame, two 350 ms apart are a
      covered camera. 350 ms is deliberately one tick more than the monitor's
      300 ms sustain, so the second tick is the strike and the first cannot be.
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

  // Mean luma of a frame with the lens covered by a hand, a sticker or a closed
  // privacy shutter, and how much noise such a frame may carry on top.
  var DARK_LUMA = 18;
  var DARK_SPREAD = 10;

  // A frame of one flat colour with almost no variation: a blanked stream, a
  // stalled decoder, or a page feeding a still image in place of the camera. A
  // real room never looks like this - a face in frame alone is more contrast
  // than this - so it costs nothing in false positives.
  var FLAT_SPREAD = 2;

  // A camera pointed into a lamp: the picture exists, but there is no face in it.
  var BLOWN_LUMA = 250;
  var BLOWN_SPREAD = 6;

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
    if (video && video.isConnected) return video;
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
  /// Null is not evidence: an unreadable frame is reported as nothing rather than
  /// as an absent student, or a browser that refuses `getImageData` for its own
  /// reasons would accuse every student running on it.
  function sampleFrame(element) {
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
      return { mean: mean, spread: Math.sqrt(variance > 0 ? variance : 0) };
    } catch (error) {
      return null;
    }
  }

  /// Whether a readable frame holds no picture of anything.
  function frameIsBlank(sample) {
    if (!sample) return false;
    if (sample.spread <= FLAT_SPREAD) return true;
    if (sample.mean >= BLOWN_LUMA && sample.spread <= BLOWN_SPREAD) return true;
    return sample.mean <= DARK_LUMA && sample.spread <= DARK_SPREAD;
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
        lastVerdict = null;
        finished(null, session);
        return;
      }

      if (inactiveReason(element)) {
        // Only a camera this page has actually shown a live frame of can be
        // accused of having gone dark. A preview that never opened (a retry that
        // did not take, a permission that was never granted) is a camera problem
        // the attempt already reports on its own terms, not a student covering
        // the lens.
        finished(seenLive === element ? MESSAGES.noFace : null, session);
        return;
      }

      // Seen live: from here on, this element going dark is evidence.
      seenLive = element;

      if (frameIsBlank(sampleFrame(element))) {
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
