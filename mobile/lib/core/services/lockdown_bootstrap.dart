import 'lockdown_bootstrap_stub.dart'
    if (dart.library.js_interop) 'lockdown_bootstrap_web.dart' as impl;

/// The one signal `web/index.html`'s pre-boot lockdown script needs from Dart.
///
/// The lockdown is split three ways: the script in `web/index.html` blocks
/// clipboard, context-menu and developer-tools shortcuts from the moment the page
/// loads - before Flutter exists, which is a window a determined student can act
/// in on a reload - and [WebGuards] (`web_guards_web.dart`) arms it for the
/// length of one attempt. What connects them is this call: until it happens the
/// script keeps blocking *everything* it sees, and from it on the page belongs to
/// the app, so the login form's own text fields get their clipboard and their
/// right-click back and only an armed exam takes them away again.
///
/// Not part of [WebGuards] because it is a startup concern: it has to be called
/// from `main()`, before any page - and therefore before any exam - exists. The
/// script keeps whatever it denied until then queued for the first exam that arms
/// the lockdown in this page session, so calling this early loses no evidence; it
/// only stops fresh interference.
///
/// Platform split is the same conditional import as [WebGuards]: only a web build
/// gets the DOM half, everything else is a no-op.
abstract class LockdownBootstrap {
  /// Picks the implementation for the platform this code was compiled for.
  factory LockdownBootstrap() => impl.createLockdownBootstrap();

  /// True when `index.html` published the bootstrap script's globals - i.e. when
  /// there is a lockdown to release. False on every non-web platform, for a host
  /// that ships its own `index.html` without the script, and in VM widget tests.
  bool get isSupported;

  /// Tells the page's bootstrap script that the app is running.
  ///
  /// A no-op when [isSupported] is false, and never throws: a startup path that
  /// fails here would cost the whole app for the sake of a browser guard.
  void markAppBooted();
}
