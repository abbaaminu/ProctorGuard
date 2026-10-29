import 'dart:async';
import 'dart:convert';

import '../utils/proctor_log.dart';

import '../../features/exam/domain/repositories/exam_repository.dart';
import '../../features/proctoring/domain/entities/violation.dart';
import '../../features/proctoring/domain/repositories/proctoring_repository.dart';
import 'key_value_store.dart';
import 'network_status.dart';

/// One answer the student has given that the server has not confirmed yet.
///
/// Exactly one of [selectedOption] / [text] is set: this is the durable form of
/// `merge_submission_answer` versus `merge_submission_text_answer`.
class PendingAnswer {
  const PendingAnswer({
    required this.submissionId,
    required this.questionId,
    required this.updatedAt,
    this.selectedOption,
    this.text,
    this.rejected = false,
  });

  final String submissionId;
  final String questionId;

  /// Set for a multiple-choice answer, null for a typed one.
  final int? selectedOption;

  /// Set for a fill-in-the-blank answer, null for a choice.
  final String? text;

  final DateTime updatedAt;

  /// A permanent server rejection; retained locally for an explicit warning
  /// instead of retrying a closed or expired attempt forever.
  final bool rejected;

  bool get isText => text != null;

  PendingAnswer markRejected() => PendingAnswer(
    submissionId: submissionId,
    questionId: questionId,
    updatedAt: updatedAt,
    selectedOption: selectedOption,
    text: text,
    rejected: true,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'submission_id': submissionId,
    'question_id': questionId,
    if (selectedOption != null) 'selected_option': selectedOption,
    if (text != null) 'text': text,
    if (rejected) 'rejected': true,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  /// Returns null for a row that is not a usable answer, so one corrupt entry
  /// can never cost the whole queue.
  static PendingAnswer? fromJson(Map<String, dynamic> json) {
    final submissionId = json['submission_id'];
    final questionId = json['question_id'];
    final option = json['selected_option'];
    final text = json['text'];
    if (submissionId is! String || questionId is! String) return null;
    if (option is! int && text is! String) return null;

    return PendingAnswer(
      submissionId: submissionId,
      questionId: questionId,
      selectedOption: option is int ? option : null,
      text: text is String ? text : null,
      rejected: json['rejected'] == true,
      updatedAt:
          DateTime.tryParse(json['updated_at'] as String? ?? '')?.toLocal() ??
          DateTime.now(),
    );
  }
}

/// One violation waiting for a network that can deliver it.
class PendingViolation {
  PendingViolation({
    required this.submissionId,
    required this.violation,
    this.attempts = 0,
  });

  final String submissionId;
  final Violation violation;

  /// How many delivery attempts have already failed, for diagnostics (the
  /// server never sees it).
  int attempts;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'submission_id': submissionId,
    'violation': violation.toJson(),
    'attempts': attempts,
  };

  static PendingViolation? fromJson(Map<String, dynamic> json) {
    final submissionId = json['submission_id'];
    final raw = json['violation'];
    if (submissionId is! String || raw is! Map) return null;

    try {
      return PendingViolation(
        submissionId: submissionId,
        violation: Violation.fromJson(Map<String, dynamic>.from(raw)),
        attempts: json['attempts'] as int? ?? 0,
      );
    } catch (error) {
      // An unknown action_type (schema drift) or a mangled row: dropping it is
      // the only safe answer - logging it as a different violation would put
      // false evidence in front of a supervisor.
      proctorLog('ProctorGuard: dropping unreadable queued violation: $error');
      return null;
    }
  }
}

/// The server's ruling for one violation, as returned by `register_violation`.
class ViolationRuling {
  const ViolationRuling({
    required this.submissionId,
    required this.violation,
    required this.warningCount,
    required this.disqualified,
  });

  final String submissionId;
  final Violation violation;

  /// Authoritative strike count for the attempt.
  final int warningCount;

  /// True once the backend has flipped the attempt to `disqualified`.
  final bool disqualified;
}

/// How proctoring violations reach the backend.
///
/// The notifier talks to this rather than to `ProctoringRepository` directly so
/// that "delivered" and "queued, will retry" are two explicit outcomes instead of
/// a swallowed exception:
///  * `log` returns a [ViolationRuling] when the server answered;
///  * `log` returns null when the row was queued for a later attempt;
///  * [deferredRulings] then carries the ruling of anything the queue delivered
///    late, so a strike (or a disqualification) that happened while the network
///    was down still reaches the session.
abstract class ViolationOutbox {
  /// How long one delivery attempt may take before the row counts as undelivered.
  ///
  /// A request that never answers is worse than one that fails: a failure queues
  /// the row for a retry two seconds later, while a hang leaves the strike in
  /// neither state — not delivered, not queued — for as long as the socket feels
  /// like it, and a third strike that has not reached the server is an attempt that
  /// has not been stopped. Ten seconds is far longer than a healthy
  /// `register_violation` round trip and well inside a supervisor's patience.
  ///
  /// Timing out is safe to replay: the RPC is idempotent per `client_event_id`, so
  /// a row that *did* land before the timeout expires inserts nothing the second
  /// time and never becomes two strikes.
  static const Duration deliveryTimeout = Duration(seconds: 10);

  Future<ViolationRuling?> log({
    required String submissionId,
    required Violation violation,
  });

  /// Rulings for violations that were queued and delivered later. Never fires
  /// for a live call.
  Stream<ViolationRuling> get deferredRulings;
}

/// Straight-through delivery with no queue: the behaviour the notifier had
/// before the offline layer existed.
///
/// Used when a host wires no [OfflineSyncService] (unit tests, and any embedding
/// of the notifier that does not need durability). A failed call is logged and
/// reported as "not delivered" - the local strike count still stands, exactly as
/// before.
class DirectViolationOutbox implements ViolationOutbox {
  DirectViolationOutbox(
    this._repository, {
    this.deliveryTimeout = ViolationOutbox.deliveryTimeout,
  });

  final ProctoringRepository _repository;

  /// See [ViolationOutbox.deliveryTimeout]. A straight-through outbox has no queue
  /// behind it, so a hang here also means the ruling that would have ended the
  /// attempt never arrives; the timeout turns that into the "not delivered"
  /// outcome the caller already knows how to handle.
  final Duration deliveryTimeout;

  @override
  Future<ViolationRuling?> log({
    required String submissionId,
    required Violation violation,
  }) async {
    try {
      final result = await _repository
          .logViolation(submissionId: submissionId, violation: violation)
          .timeout(deliveryTimeout);
      return ViolationRuling(
        submissionId: submissionId,
        violation: violation,
        warningCount: result.warningCount,
        disqualified: result.disqualified,
      );
    } catch (error) {
      proctorLog(
        'ProctorGuard: violation delivery failed (no queue attached): $error',
      );
      return null;
    }
  }

  @override
  Stream<ViolationRuling> get deferredRulings =>
      const Stream<ViolationRuling>.empty();
}

/// What the exam chrome renders about local work that has not reached the
/// server: the banner, and whether it is safe to close the attempt.
class SyncState {
  const SyncState({
    this.online = true,
    this.pendingAnswers = 0,
    this.rejectedAnswers = 0,
    this.pendingViolations = 0,
    this.syncing = false,
    this.lastSyncedAt,
    this.lastError,
  });

  /// Last known connectivity. Flips to false as soon as a delivery attempt
  /// fails, so a dropped connection shows up even on a platform with no
  /// online/offline event.
  final bool online;

  final int pendingAnswers;
  final int rejectedAnswers;
  final int pendingViolations;

  /// True while a delivery pass is in flight.
  final bool syncing;

  /// When the queue last emptied.
  final DateTime? lastSyncedAt;

  /// Why the last delivery pass did not finish, if it did not.
  final String? lastError;

  int get pending => pendingAnswers + pendingViolations;

  bool get hasPending => pending > 0;
  bool get hasRejectedAnswers => rejectedAnswers > 0;

  /// Whether an answer the *grader* will read is still owed to the server.
  ///
  /// Answers and evidence are not the same promise. An answer has to reach the
  /// server before the attempt closes, because grading reads the server's copy;
  /// a queued violation is still delivered - and still counted - afterwards
  /// (`register_violation` reports the final state of an already closed attempt
  /// rather than raising). Whoever decides whether an attempt may end asks this
  /// question, not [hasPending]: one log row the server refuses must not be able
  /// to strand a student whose work is otherwise finished.
  bool get hasPendingAnswers => pendingAnswers > 0;

  bool get isSynced => pending == 0 && !hasRejectedAnswers;

  /// The headline the exam banner shows: the work is safe on this device but has
  /// not reached the server.
  String get label {
    if (hasRejectedAnswers) {
      final answerNoun = rejectedAnswers == 1 ? 'answer was' : 'answers were';
      return '$rejectedAnswers $answerNoun not accepted before the attempt closed.';
    }
    return online ? 'Syncing your answers...' : 'Offline - syncing locally';
  }

  @override
  String toString() =>
      'SyncState(online: $online, answers: $pendingAnswers, '
      'rejectedAnswers: $rejectedAnswers, violations: $pendingViolations, '
      'syncing: $syncing)';
}

/// Local-first answer cache, durable retry queues and violation delivery for one
/// app run.
///
/// The contract it exists to guarantee, in order of importance:
///
///  1. **An answer is never lost.** Every tap and every "Save & next" is written
///     to the device *first* ([KeyValueStore]) and only then pushed to Supabase.
///     A network failure moves the write into a queue instead of returning an
///     error to the student, and the queue is replayed when the connection comes
///     back (the `online` event on web, the resume hook on mobile, or the retry
///     backoff in between).
///  2. **A violation is never lost either, and never double-counted.** A
///     `register_violation` call that fails is queued with the client-minted
///     `clientEventId` of that one event, so replaying it inserts the row or
///     nothing at all - see the unique index in `supabase/schema.sql`.
///  3. **The student always knows where their work is.** [changes] streams a
///     [SyncState] for the "Offline - syncing locally" banner, and [state] is the
///     same thing read synchronously by the submit gate.
///
/// One instance serves the whole app (see `offlineSyncServiceProvider`): a queue
/// written during one exam must still be there when the same attempt is resumed
/// after a crash, a refresh or a sign-out round trip.
///
/// Timers only ever run while [hasPending] is true: an idle session schedules
/// nothing, which keeps `flutter test` free of "a Timer is still pending" and a
/// finished exam free of background work.
class OfflineSyncService implements ViolationOutbox {
  OfflineSyncService({
    required ExamRepository exams,
    required ProctoringRepository proctoring,
    required KeyValueStore store,
    NetworkStatus? network,
    this.minRetryDelay = const Duration(seconds: 2),
    this.maxRetryDelay = const Duration(seconds: 60),
    this.maxQueuedViolations = 200,
    this.deliveryTimeout = ViolationOutbox.deliveryTimeout,
    DateTime Function()? clock,
  }) {
    _exams = exams;
    _proctoring = proctoring;
    _store = store;
    _network = network;
    _now = clock ?? DateTime.now;
    // Never zero: a zero-delay backoff would spin the event loop (and every widget
    // test's `pumpAndSettle`) for as long as the network stayed down.
    _retryDelay = minRetryDelay;

    final probe = _network;
    if (probe != null) {
      _online = probe.isOnline;
      _networkSub = probe.changes.listen(_handleNetworkChange);
    }
  }

  /// First retry delay, doubled after every failed pass.
  final Duration minRetryDelay;

  /// Ceiling for the backoff.
  final Duration maxRetryDelay;

  /// Upper bound on the violation queue, oldest dropped first: a device that has
  /// been offline for hours must not grow an unbounded row.
  final int maxQueuedViolations;

  /// How long one attempt at delivering a queued or fresh violation may take (see
  /// [ViolationOutbox.deliveryTimeout]).
  ///
  /// Injectable so a test can prove the queue keeps moving past a server that
  /// accepts the connection and then says nothing.
  final Duration deliveryTimeout;

  /// How many rows may fail inside one delivery pass before the pass gives up on
  /// the rest of the queue.
  ///
  /// A pass stops at a failure because a failed write *almost always* means the
  /// connection is gone - but "almost" is not "always": a server can keep
  /// refusing one row (a schema change, a question an exam edit removed, an
  /// attempt a supervisor reset) while accepting every other one. Stopping dead
  /// on that row used to hold up everything queued behind it for good, including
  /// evidence logged minutes later. A device that is genuinely offline still
  /// fails this many rows inside the same tick and leaves the pass just as
  /// promptly.
  static const int maxPassFailures = 3;

  late final ExamRepository _exams;
  late final ProctoringRepository _proctoring;
  late final KeyValueStore _store;
  late final NetworkStatus? _network;
  late final DateTime Function() _now;

  static const String _choiceDraftKey = 'draft.choices';
  static const String _textDraftKey = 'draft.text';
  static const String _answerQueueKey = 'queue.answers';
  static const String _violationQueueKey = 'queue.violations';

  final Map<String, Map<String, int>> _choiceDrafts =
      <String, Map<String, int>>{};
  final Map<String, Map<String, String>> _textDrafts =
      <String, Map<String, String>>{};
  final List<PendingAnswer> _answers = <PendingAnswer>[];
  final List<PendingViolation> _violations = <PendingViolation>[];

  final StreamController<SyncState> _changes =
      StreamController<SyncState>.broadcast();
  final StreamController<ViolationRuling> _deferredRulings =
      StreamController<ViolationRuling>.broadcast();

  StreamSubscription<bool>? _networkSub;
  Future<void>? _hydration;
  Future<void>? _inFlight;
  Timer? _retryTimer;
  Duration _retryDelay = Duration.zero;
  bool _flushing = false;
  bool _flushAgain = false;
  bool _disposed = false;
  bool _online = true;
  DateTime? _lastSyncedAt;
  String? _lastError;

  /// Queue state for the banner and the submit gate.
  SyncState get state => SyncState(
    online: _online,
    pendingAnswers: _answers.where((answer) => !answer.rejected).length,
    rejectedAnswers: _answers.where((answer) => answer.rejected).length,
    pendingViolations: _violations.length,
    syncing: _flushing,
    lastSyncedAt: _lastSyncedAt,
    lastError: _lastError,
  );

  /// Emits the current [SyncState] on every change; read [state] first for the
  /// value that happened before a listener attached.
  Stream<SyncState> get changes => _changes.stream;

  /// True while anything is waiting for the network.
  bool get hasPending =>
      _answers.any((answer) => !answer.rejected) || _violations.isNotEmpty;

  int rejectedAnswerCountFor(String submissionId) => _answers
      .where((answer) => answer.submissionId == submissionId && answer.rejected)
      .length;

  /// Number of violations still waiting to be delivered, for diagnostics.
  int get pendingViolations => _violations.length;

  /// Loads the queues and the drafts from the device.
  ///
  /// Idempotent and safe to call from several places: the exam screen awaits it
  /// before it paints, so a resumed attempt shows the answers that were typed
  /// before the app was killed even when the server is unreachable.
  Future<void> ensureHydrated() => _hydration ??= _readFromDisk();

  /// Answers already given for [submissionId], by question id (choice shape).
  Map<String, int> cachedChoices(String submissionId) =>
      Map<String, int>.unmodifiable(
        _choiceDrafts[submissionId] ?? const <String, int>{},
      );

  /// Answers already given for [submissionId], by question id (text shape).
  Map<String, String> cachedText(String submissionId) =>
      Map<String, String>.unmodifiable(
        _textDrafts[submissionId] ?? const <String, String>{},
      );

  // --- Local-first writes (requirement 1) -------------------------------

  /// Caches a multiple-choice answer and queues it for the server.
  ///
  /// Awaited by the tap handler, and its completion means "durable on this
  /// device" - not "acknowledged by Supabase". The round-trip happens in the
  /// background, which is why an offline exam keeps advancing normally.
  Future<void> cacheChoice({
    required String submissionId,
    required String questionId,
    required int selectedOption,
  }) => _cache(
    PendingAnswer(
      submissionId: submissionId,
      questionId: questionId,
      selectedOption: selectedOption,
      updatedAt: _now(),
    ),
  );

  /// Caches a fill-in-the-blank answer ("Save & next", the keyboard's done
  /// action, or the flush before submitting) and queues it for the server.
  Future<void> cacheText({
    required String submissionId,
    required String questionId,
    required String text,
  }) => _cache(
    PendingAnswer(
      submissionId: submissionId,
      questionId: questionId,
      text: text,
      updatedAt: _now(),
    ),
  );

  /// Mirrors a keystroke into the durable cache **without** queueing a network
  /// write: an unsaved field has to survive the app being killed, but the server
  /// does not need every character.
  void cacheTextDraft({
    required String submissionId,
    required String questionId,
    required String text,
  }) {
    _textDrafts.putIfAbsent(
      submissionId,
      () => <String, String>{},
    )[questionId] = text;
    // Deliberately not awaited: a keystroke must never wait on a disk write, and
    // the value is in memory either way.
    unawaited(_persistDrafts());
  }

  Future<void> _cache(PendingAnswer answer) async {
    if (answer.isText) {
      _textDrafts.putIfAbsent(
        answer.submissionId,
        () => <String, String>{},
      )[answer.questionId] = answer.text!;
    } else {
      _choiceDrafts.putIfAbsent(
        answer.submissionId,
        () => <String, int>{},
      )[answer.questionId] = answer.selectedOption!;
    }
    await _persistDrafts();

    // One queued row per question: re-answering replaces the pending value
    // instead of sending a stale one first.
    _answers.removeWhere(
      (existing) =>
          existing.submissionId == answer.submissionId &&
          existing.questionId == answer.questionId,
    );
    _answers.add(answer);

    await _persistAnswers();
    _notify();
    await _scheduleFlush();
  }

  /// Drops everything cached for an attempt the server has already accepted.
  ///
  /// Queued **violations** are kept on purpose: they belong to the session that
  /// just ended, and `register_violation` reports the final state for a closed
  /// attempt instead of raising, so delivering them late is still correct.
  Future<void> clearSession(String submissionId) async {
    _choiceDrafts.remove(submissionId);
    _textDrafts.remove(submissionId);
    _answers.removeWhere((pending) => pending.submissionId == submissionId);

    await _persistDrafts();
    await _persistAnswers();
    _notify();
  }

  // --- Delivery ----------------------------------------------------------

  /// Pushes everything that is waiting, in order. Safe to call at any time:
  /// concurrent calls collapse into the pass that is already running.
  Future<void> flush() async {
    if (_disposed) return;
    final inFlight = _inFlight;
    if (inFlight != null) {
      _flushAgain = true;
      return inFlight;
    }

    final run = _runPasses();
    _inFlight = run;
    try {
      await run;
    } finally {
      _inFlight = null;
    }
  }

  /// The moment a connection usually comes back (a browser `online` event, or the
  /// OS bringing the exam app to the foreground): drop the backoff and try now.
  Future<void> retryNow() async {
    if (_disposed) return;
    _cancelRetry();
    _retryDelay = minRetryDelay;
    await flush();
  }

  Future<void> _runPasses() async {
    _flushing = true;
    _notify();

    var passes = 0;
    do {
      _flushAgain = false;
      await _drain();
      passes++;
      // A write that landed while a pass was running must not wait for the
      // backoff; the pass cap keeps a fast typist from starving the UI task.
    } while (_flushAgain && hasPending && passes < 3 && !_disposed);

    _flushing = false;
    if (hasPending) {
      _scheduleRetry();
    } else {
      _retryDelay = minRetryDelay;
      _cancelRetry();
    }
    _notify();
  }

  /// One delivery attempt per queued row: **evidence first**, then answers.
  ///
  /// The order is the latency contract. A queued violation is a strike that has
  /// already happened and whose late arrival can still disqualify the attempt (see
  /// `ProctoringNotifier`'s deferred-ruling handler), while a queued answer is
  /// idempotent and can be re-sent at any time. Draining answers first meant the
  /// evidence waited behind every keystroke the student had made while offline -
  /// on a flaky connection, a queue of answers was enough for the violation to
  /// miss the whole pass.
  ///
  /// The pass stops after [maxPassFailures] failures rather than at the first
  /// one: a connection that is down fails that many rows inside the same tick,
  /// while a single row the server keeps refusing no longer holds up the rows
  /// behind it (see [maxPassFailures]).
  Future<void> _drain() async {
    var deliveredAny = false;
    var failures = 0;

    // One write per pass rather than one per row. Each `_persist*` re-encodes the
    // whole queue and writes it through the store, and the store is the slowest
    // thing in a pass whose entire job is to be quick: a queue of ten answers used
    // to rewrite the document ten times before the pass was over. The flags are
    // flushed in `finally`, so a pass that gives up early still leaves the queue
    // on disk exactly as it stands in memory.
    var answersDirty = false;
    var violationsDirty = false;

    try {
      for (final pending in List<PendingViolation>.of(_violations)) {
        if (_disposed) return;
        pending.attempts++;
        violationsDirty = true;
        try {
          final result = await _proctoring
              .logViolation(
                submissionId: pending.submissionId,
                violation: pending.violation,
              )
              .timeout(deliveryTimeout);
          _violations.remove(pending);
          deliveredAny = true;
          // The session may still be on screen: hand it the ruling, so a third
          // strike that landed while the network was down can still end the
          // attempt (see ProctoringNotifier's deferred-ruling handler).
          _deferredRulings.add(
            ViolationRuling(
              submissionId: pending.submissionId,
              violation: pending.violation,
              warningCount: result.warningCount,
              disqualified: result.disqualified,
            ),
          );
        } catch (error) {
          proctorLog('ProctorGuard: violation still queued ($error)');
          _offline('Could not deliver a proctoring log yet.');
          if (++failures >= maxPassFailures) return;
        }
      }

      for (final pending in List<PendingAnswer>.of(_answers)) {
        if (_disposed) return;
        if (pending.rejected) continue;
        try {
          if (pending.isText) {
            await _exams.saveTextAnswer(
              submissionId: pending.submissionId,
              questionId: pending.questionId,
              answer: pending.text!,
            );
          } else {
            await _exams.saveAnswer(
              submissionId: pending.submissionId,
              questionId: pending.questionId,
              selectedOption: pending.selectedOption!,
            );
          }
        } on AnswerWriteRejected {
          final index = _answers.indexOf(pending);
          if (index != -1) _answers[index] = pending.markRejected();
          answersDirty = true;
          _lastError =
              'Some answers were not accepted because this attempt is no longer writable.';
          _online = true;
          _notify();
          continue;
        } catch (error) {
          proctorLog('ProctorGuard: answer still queued ($error)');
          _offline('Could not sync your answers yet.');
          // The row stays queued either way; only the *pass* gives up, and only
          // after [maxPassFailures] rows have failed in it.
          if (++failures >= maxPassFailures) return;
          continue;
        }

        _answers.remove(pending);
        deliveredAny = true;
        answersDirty = true;
      }
    } finally {
      if (violationsDirty) await _persistViolations();
      if (answersDirty) await _persistAnswers();
    }

    // Only a pass that finished cleanly proves the connection is back: one that
    // delivered *and* failed is still a device with something stuck, and the
    // banner has to keep saying so.
    if (deliveredAny && failures == 0) {
      _lastSyncedAt = _now();
      _lastError = null;
      _online = true;
    }
  }

  /// Marks the queue as blocked by the network, so the banner switches to
  /// "Offline - syncing locally".
  void _offline(String reason) {
    _lastError = reason;
    _online = false;
    _notify();
  }

  Future<void> _scheduleFlush() {
    if (_flushing) {
      _flushAgain = true;
      return _inFlight ?? Future<void>.value();
    }
    return flush();
  }

  void _scheduleRetry() {
    if (_disposed || !hasPending || _retryTimer != null) return;

    final delay = _retryDelay;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(flush());
    });

    final next = delay * 2;
    _retryDelay = next > maxRetryDelay ? maxRetryDelay : next;
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _handleNetworkChange(bool online) {
    if (_disposed) return;
    _online = online;
    _notify();
    // Faster than waiting out the backoff, which is the whole point of listening.
    if (online && hasPending) unawaited(retryNow());
  }

  // --- ViolationOutbox ---------------------------------------------------

  @override
  Future<ViolationRuling?> log({
    required String submissionId,
    required Violation violation,
  }) async {
    try {
      final result = await _proctoring
          .logViolation(
            submissionId: submissionId,
            violation: violation,
          )
          .timeout(deliveryTimeout);
      _lastError = null;
      _lastSyncedAt = _now();
      _online = true;
      _notify();
      return ViolationRuling(
        submissionId: submissionId,
        violation: violation,
        warningCount: result.warningCount,
        disqualified: result.disqualified,
      );
    } catch (error) {
      proctorLog(
        'ProctorGuard: violation queued for retry '
        '(${violation.type.dbValue}): $error',
      );
      _violations.add(
        PendingViolation(submissionId: submissionId, violation: violation),
      );
      _trimViolations();
      await _persistViolations();
      _offline('Could not deliver a proctoring log yet.');
      // A fresh violation is the one row in this queue whose late delivery can
      // still end the attempt, so it must not inherit the backoff the answer queue
      // has grown to: a device that has been offline for ten minutes is sitting on
      // the 60 s ceiling, and evidence that arrives a minute late is evidence the
      // supervisor reads after the student has already finished. Re-arming at the
      // floor keeps a *new* strike a couple of seconds away from its first retry,
      // while the delay still doubles from there if the network stays down.
      _retryDelay = minRetryDelay;
      _cancelRetry();
      _scheduleRetry();
      // An identity-breaking strike ("nobody in front of the camera", a second
      // face, a virtual lens) is the one row here whose late arrival can still end
      // the attempt, and the student is standing in front of a paper that is now
      // being held shut (see `ProctoringNotifier`'s critical types). One immediate
      // pass costs a single background request and turns a lone dropped connection
      // into a delivery within the same second; if the network really is gone that
      // pass fails too, and the timer armed above takes over from there.
      if (violation.type.isCritical) unawaited(flush());
      return null;
    }
  }

  @override
  Stream<ViolationRuling> get deferredRulings => _deferredRulings.stream;

  /// Keeps the oldest rows out of an unbounded queue (see [maxQueuedViolations]).
  ///
  /// Returns how many rows it dropped, so [_readFromDisk] can write a trimmed queue
  /// back: rows queued by a build with a larger bound (or by one that predates the
  /// bound) are already on disk, and the cap has to hold on the way in as well as on
  /// the way out.
  int _trimViolations() {
    var dropped = 0;
    while (_violations.length > maxQueuedViolations) {
      final oldest = _violations.removeAt(0);
      dropped++;
      proctorLog(
        'ProctorGuard: violation queue full - dropped '
        '${oldest.violation.type.dbValue} from ${oldest.submissionId}',
      );
    }
    return dropped;
  }

  // --- Persistence -------------------------------------------------------

  Future<void> _readFromDisk() async {
    final answers = _jsonList(
      await _store.read(_answerQueueKey),
    ).map(PendingAnswer.fromJson).whereType<PendingAnswer>().toList();
    final violations = _jsonList(
      await _store.read(_violationQueueKey),
    ).map(PendingViolation.fromJson).whereType<PendingViolation>().toList();

    _answers
      ..clear()
      ..addAll(answers);
    _violations
      ..clear()
      ..addAll(violations);
    // The bound is applied on the way in: a device can be carrying a queue written
    // by a build with a bigger bound, and that oversized file is the thing the cap
    // exists to prevent. Rewriting it here means the next launch starts bounded too.
    if (_trimViolations() > 0) await _persistViolations();

    _choiceDrafts
      ..clear()
      ..addAll(await _readChoiceDrafts());
    _textDrafts
      ..clear()
      ..addAll(await _readTextDrafts());

    _notify();
  }

  /// `{submissionId: {questionId: optionIndex}}`.
  Future<Map<String, Map<String, int>>> _readChoiceDrafts() async {
    final decoded = _jsonMap(await _store.read(_choiceDraftKey));
    return decoded.map(
      (submissionId, questions) => MapEntry(
        submissionId,
        questions is Map
            ? questions.map(
                (questionId, option) =>
                    MapEntry(questionId.toString(), option is int ? option : 0),
              )
            : <String, int>{},
      ),
    );
  }

  /// `{submissionId: {questionId: text}}`.
  Future<Map<String, Map<String, String>>> _readTextDrafts() async {
    final decoded = _jsonMap(await _store.read(_textDraftKey));
    return decoded.map(
      (submissionId, questions) => MapEntry(
        submissionId,
        questions is Map
            ? questions.map(
                (questionId, text) =>
                    MapEntry(questionId.toString(), text?.toString() ?? ''),
              )
            : <String, String>{},
      ),
    );
  }

  Map<String, dynamic> _jsonMap(String? raw) {
    if (raw == null || raw.isEmpty) return const <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, dynamic>{};
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    } catch (error) {
      proctorLog('ProctorGuard: dropping an unreadable cached draft ($error)');
      return const <String, dynamic>{};
    }
  }

  List<Map<String, dynamic>> _jsonList(String? raw) {
    if (raw == null || raw.isEmpty) return const <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <Map<String, dynamic>>[];
      return decoded
          .whereType<Map<Object?, Object?>>()
          .map(Map<String, dynamic>.from)
          .toList();
    } catch (error) {
      proctorLog('ProctorGuard: dropping an unreadable offline queue ($error)');
      return const <Map<String, dynamic>>[];
    }
  }

  Future<void> _persistDrafts() async {
    await _store.write(_choiceDraftKey, jsonEncode(_choiceDrafts));
    await _store.write(_textDraftKey, jsonEncode(_textDrafts));
  }

  Future<void> _persistAnswers() => _store.write(
    _answerQueueKey,
    jsonEncode(_answers.map((answer) => answer.toJson()).toList()),
  );

  Future<void> _persistViolations() => _store.write(
    _violationQueueKey,
    jsonEncode(_violations.map((pending) => pending.toJson()).toList()),
  );

  void _notify() {
    if (_changes.isClosed) return;
    _changes.add(state);
  }

  /// Releases the retry timer, the listeners and both streams. Safe to call
  /// twice; the service is unusable afterwards.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelRetry();
    await _networkSub?.cancel();
    _networkSub = null;
    _network?.dispose();
    if (!_deferredRulings.isClosed) await _deferredRulings.close();
    if (!_changes.isClosed) await _changes.close();
  }
}
