import 'dart:async';
import 'dart:js_interop';
// The hook is installed on `window` by name, exactly as the bootstrap reporter
// in `web_guards_web.dart` is: `dart:js_interop_unsafe`'s `setProperty`.
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'web_face_signal_source.dart';

/// Creates the DOM-backed source. Reached through [WebFaceSignalSource]'s
/// factory, so this file is only compiled into a web build (see the conditional
/// import there).
WebFaceSignalSource createWebFaceSignalSource() => WebFaceSignalSourceImpl();

/// Publishes a host detector's verdicts as a Dart stream.
///
/// The hook is a *global function* rather than a DOM event on purpose: a
/// detector is usually third-party JavaScript that already has a callback of its
/// own, and one call — `window.proctorGuardFaceSignal('looking_away')` — is the
/// smallest thing a host has to add. It is also the same shape as the reporter
/// `WebGuards` installs for the lockdown, so the page has one convention for
/// "the browser tells the app something".
///
/// Nothing is trusted on the way in beyond its type: the string is trimmed and
/// lowercased, an empty or non-string argument is ignored, and the vocabulary
/// itself is checked by [WebFacePresenceMonitor] — a page cannot hand this app a
/// violation, only a detection, and a detection still has to be sustained before
/// it becomes one.
class WebFaceSignalSourceImpl implements WebFaceSignalSource {
  WebFaceSignalSourceImpl() {
    _sink = _handleMessage.toJS;
    try {
      _window.setProperty(WebFaceSignalSource.globalName.toJS, _sink);
      _installed = true;
    } catch (_) {
      // A host page that has frozen `window` (or runs the app inside something
      // that hides it): no bridge, and `isSupported` stays false so the page
      // does not wait for signals that cannot arrive.
      _installed = false;
    }
  }

  /// [web.window] as a plain [JSObject]: the receiver the
  /// `dart:js_interop_unsafe` name lookups are declared on.
  JSObject get _window => web.window;

  final StreamController<String> _messages =
      StreamController<String>.broadcast();

  /// The exported Dart callback, kept so [dispose] removes exactly this one
  /// (an anonymous `.toJS` could not be un-set, and a second session would
  /// export a second closure).
  late final JSFunction _sink;

  bool _installed = false;
  bool _disposed = false;

  @override
  bool get isSupported => _installed;

  @override
  Stream<String> get messages => _messages.stream;

  /// One host call: `proctorGuardFaceSignal('no_face')`.
  ///
  /// The argument is taken as `JSAny?` rather than `JSString` so that a detector
  /// passing a number (a frame counter, say) is ignored here instead of throwing
  /// a type error back into the host's page, where it would look like this app
  /// broke.
  void _handleMessage(JSAny? message) {
    if (_disposed || !message.isA<JSString>()) return;
    final text = (message as JSString).toDart.trim().toLowerCase();
    if (text.isEmpty) return;
    // A detection that arrived after the stream closed (dispose is synchronous,
    // the host's call may not be) has nowhere to go and nothing to say about an
    // exam that has ended.
    if (_messages.isClosed) return;
    _messages.add(text);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_installed) {
      try {
        _window.setProperty(WebFaceSignalSource.globalName.toJS, null);
      } catch (_) {
        // Same as the constructor: not ours to insist on.
      }
      _installed = false;
    }
    unawaited(_messages.close());
  }
}
