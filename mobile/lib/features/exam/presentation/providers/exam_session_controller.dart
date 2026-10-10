import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/services/offline_sync_service.dart';
import '../../../../core/utils/proctor_log.dart';
import '../../domain/entities/exam_submit_result.dart';
import '../../domain/entities/question.dart';
import '../../domain/repositories/exam_repository.dart';

/// How a request to close an attempt ended after the offline queues were
/// drained (see [ExamSessionController.prepareSubmit]).
enum SubmitGate {
  /// Everything the server needs is delivered; the attempt can be closed.
  ready,

  /// The queue still owes the server answers - show "waiting for a connection".
  pendingAnswers,

  /// Some answers were rejected permanently; the student must confirm.
  rejectedAnswers,
}

/// Outcome of [ExamSessionController.prepareSubmit]: the gate plus, for a
/// [SubmitGate.rejectedAnswers] result, how many answers the server refused.
class SubmitOutcome {
  const SubmitOutcome(this.gate, {this.rejectedCount = 0});

  final SubmitGate gate;
  final int rejectedCount;
}

/// Route-level identity of one exam session.
///
/// Everything that decides *which* session a provider instance belongs to,
/// folded into one value so `examSessionControllerProvider` can be a `family`
/// keyed by it. Equality matters: the page rebuilds with a fresh (but equal)
/// args object, and Riverpod must hand back the same controller.
@immutable
class ExamSessionArgs {
  const ExamSessionArgs({
    required this.examId,
    required this.submissionId,
    this.durationMinutes,
    this.startedAt,
    this.endsAt,
    this.clock,
  });

  final String examId;
  final String submissionId;
  final int? durationMinutes;
  final DateTime? startedAt;

  /// `exams.ends_at`: the paper's hard close, or null when it has no window.
  ///
  /// The server treats it as a cap ([resolveDeadline] mirrors `attempt_deadline()`
  /// in `schema.sql`), so an attempt started shortly before the close gets the
  /// remaining minutes and not a fresh `duration_minutes` — and the clock the
  /// student watches can never show time the server would refuse to accept an
  /// answer in.
  final DateTime? endsAt;

  final DateTime Function()? clock;

  @override
  bool operator ==(Object other) =>
      other is ExamSessionArgs &&
      other.examId == examId &&
      other.submissionId == submissionId &&
      other.durationMinutes == durationMinutes &&
      other.startedAt == startedAt &&
      other.endsAt == endsAt &&
      other.clock == clock;

  @override
  int get hashCode => Object.hash(
        examId,
        submissionId,
        durationMinutes,
        startedAt,
        endsAt,
        clock,
      );
}

/// Everything the exam session screen renders that is **not** owned by a
/// platform service.
///
/// The camera, the kiosk and the browser guards stay with the widget (they are
/// bound to its lifecycle and to `BuildContext`); the session *data* - the
/// question feed, the answers, the clock and the in-flight flags - lives here,
/// in one immutable snapshot the page watches.
@immutable
class ExamSessionState {
  const ExamSessionState({
    this.questions = const <Question>[],
    this.currentIndex = 0,
    this.answers = const <String, int>{},
    this.textAnswers = const <String, String>{},
    this.savedText = const <String, String>{},
    this.savedQuestions = const <String>{},
    this.markedForReview = const <String>{},
    this.savingText = false,
    this.remaining,
    this.loading = true,
    this.blockingError,
    this.offerSettings = false,
    this.submitting = false,
    this.timeUpPending = false,
    this.offlineSubmitPending = false,
  });

  final List<Question> questions;
  final int currentIndex;

  /// Selected option per question id, mirrored locally so a tap paints
  /// immediately (the RPC round-trip is not on the UI's critical path).
  final Map<String, int> answers;

  /// Free-text answers (fill-in-the-blank), keyed by question id.
  final Map<String, String> textAnswers;

  /// What the server (or the durable cache) has confirmed, so the UI can tell
  /// "typed" from "stored".
  final Map<String, String> savedText;

  /// Question ids whose answer is stored - either shape. Drives the
  /// "N answered" count and the submit dialog's summary.
  final Set<String> savedQuestions;

  /// In-flight guard for a text autosave (one at a time).
  final bool savingText;

  /// Time left on the attempt; null when no duration was supplied.
  final Duration? remaining;

  final bool loading;

  /// Set when the session cannot be proctored at all, or the question feed
  /// failed to load. Both are blocking states with a retry.
  final String? blockingError;

  /// True when [blockingError] is a permission problem the student can fix in
  /// the OS settings.
  final bool offerSettings;

  /// In-flight guard for the final submit (double taps, retry storms).
  final bool submitting;

  /// True when the clock ran out but the server has not acknowledged yet.
  final bool timeUpPending;

  /// True when the student asked to submit but the queue still owes the server
  /// answers.
  final bool offlineSubmitPending;

  /// Question ids the student flagged for another look ("Mark for review").
  ///
  /// Local to the attempt and deliberately not an answer: marking is the student
  /// telling *themselves* to come back, so it is not sent to the server and not
  /// graded. It survives navigation, which is the whole point — the review grid
  /// shows it, and the submit dialog counts it, so "I was going to return to 7"
  /// is still true after five questions have gone by.
  final Set<String> markedForReview;

  ExamSessionState copyWith({
    List<Question>? questions,
    int? currentIndex,
    Map<String, int>? answers,
    Map<String, String>? textAnswers,
    Map<String, String>? savedText,
    Set<String>? savedQuestions,
    Set<String>? markedForReview,
    bool? savingText,
    Duration? remaining,
    bool clearRemaining = false,
    bool? loading,
    String? blockingError,
    bool clearBlockingError = false,
    bool? offerSettings,
    bool? submitting,
    bool? timeUpPending,
    bool? offlineSubmitPending,
  }) =>
      ExamSessionState(
        questions: questions ?? this.questions,
        currentIndex: currentIndex ?? this.currentIndex,
        answers: answers ?? this.answers,
        textAnswers: textAnswers ?? this.textAnswers,
        savedText: savedText ?? this.savedText,
        savedQuestions: savedQuestions ?? this.savedQuestions,
        markedForReview: markedForReview ?? this.markedForReview,
        savingText: savingText ?? this.savingText,
        remaining: clearRemaining ? null : (remaining ?? this.remaining),
        loading: loading ?? this.loading,
        blockingError:
            clearBlockingError ? null : (blockingError ?? this.blockingError),
        offerSettings: offerSettings ?? this.offerSettings,
        submitting: submitting ?? this.submitting,
        timeUpPending: timeUpPending ?? this.timeUpPending,
        offlineSubmitPending: offlineSubmitPending ?? this.offlineSubmitPending,
      );
}

/// Owns one exam session's data, clock and offline-sync orchestration.
///
/// This is the piece `exam_taking_page.dart` used to carry inline: the
/// question feed, the answer maps, the countdown that closes the attempt, and
/// the "is the queue drained enough to submit?" rule. Splitting it out gives
/// the timer and the sync triggers one home (and one teardown) and leaves the
/// page with the two things that genuinely need `BuildContext`: binding the
/// platform services and rendering.
class ExamSessionController extends StateNotifier<ExamSessionState> {
  ExamSessionController(this._ref, {required this.args})
      : _clock = args.clock ?? DateTime.now,
        super(const ExamSessionState());

  final Ref _ref;
  final ExamSessionArgs args;

  /// The clock the countdown reads (see [ExamSessionArgs.clock]).
  final DateTime Function() _clock;

  /// Invoked when the exam clock reaches zero. The page owns submission — it is
  /// the only thing that can navigate and prompt — so the controller only says
  /// *when*, never *what*.
  VoidCallback? onTimeUp;

  /// Surfaces a transient message (a snackbar) without the controller knowing
  /// about `BuildContext`.
  void Function(String message)? onMessage;

  OfflineSyncService? _sync;
  Timer? _countdown;

  String get _submissionId => args.submissionId;
  ExamRepository get _exams => _ref.read(examRepositoryProvider);

  /// Local-first: hydrate the durable cache and paint what the device already
  /// holds, before the server is asked anything.
  ///
  /// A resumed attempt (crash, refresh, an offline stretch) therefore shows the
  /// answers that were typed before the app was killed even when the server is
  /// unreachable.
  Future<void> hydrateCache() async {
    final sync = _ref.read(offlineSyncServiceProvider);
    _sync = sync;
    await sync.ensureHydrated();
    _restoreCachedAnswers(sync);
  }

  /// `putIfAbsent` throughout, so a retry of the bootstrap can never overwrite
  /// what the student has changed since.
  void _restoreCachedAnswers(OfflineSyncService sync) {
    final choices = sync.cachedChoices(_submissionId);
    final texts = sync.cachedText(_submissionId);
    if (choices.isEmpty && texts.isEmpty) return;

    final answers = Map<String, int>.of(state.answers);
    final textAnswers = Map<String, String>.of(state.textAnswers);
    final savedText = Map<String, String>.of(state.savedText);
    final saved = Set<String>.of(state.savedQuestions);

    choices.forEach((id, value) => answers.putIfAbsent(id, () => value));
    texts.forEach((id, value) {
      textAnswers.putIfAbsent(id, () => value);
      // "Saved" here means durably stored on this device; the queue owns the
      // server copy, and the banner reports that part. Hiding a restored answer
      // behind "Not saved yet" would tell the student their typing was lost when
      // it was not.
      savedText.putIfAbsent(id, () => value);
    });
    saved
      ..addAll(choices.keys)
      ..addAll(texts.keys);

    state = state.copyWith(
      answers: answers,
      textAnswers: textAnswers,
      savedText: savedText,
      savedQuestions: saved,
    );
  }

  /// Loads the question feed, turning a failure into a blocking state with a
  /// retry instead of leaving the page on its spinner forever (this screen has
  /// no back button to escape with).
  Future<void> loadQuestions() async {
    try {
      final questions = await _exams.getQuestions(args.examId);
      if (!mounted) return;
      state = state.copyWith(
        questions: questions,
        currentIndex:
            state.currentIndex >= questions.length ? 0 : state.currentIndex,
        loading: false,
      );
    } catch (error) {
      proctorLog('ProctorGuard: could not load questions: $error');
      if (!mounted) return;
      state = state.copyWith(
        loading: false,
        blockingError: 'Could not load the questions for this exam. Check '
            'your connection and tap Try again.',
      );
    }
  }

  /// Enforces `args.durationMinutes` (capped by `args.endsAt`).
  ///
  /// The deadline is anchored on the submission's `started_at` rather than
  /// "now", so a resumed attempt (crash, refresh, reconnect) keeps counting down
  /// from where it left off — and one that is already past its deadline is
  /// submitted on the first tick instead of being given a fresh hour.
  void startCountdown() {
    final deadline = resolveDeadline(
      now: _clock(),
      durationMinutes: args.durationMinutes,
      startedAt: args.startedAt,
      endsAt: args.endsAt,
    );
    if (deadline == null) return;

    _countdown?.cancel();
    // The ticker is installed *before* the first tick: that tick is what submits
    // an attempt which resumes past its deadline, and it cancels the ticker it
    // finds. Creating the ticker afterwards used to re-arm the submission once a
    // second for as long as the page stayed on screen.
    _countdown = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickCountdown(deadline),
    );
    _tickCountdown(deadline);
  }

  /// The instant an attempt's countdown runs to, or null when it has no
  /// duration to enforce.
  ///
  /// This is the client's reading of the server's `attempt_deadline()`
  /// (`schema.sql`): `started_at + duration_minutes`, **capped by the paper's
  /// own `ends_at`**. Both bounds have to be applied here, not just the
  /// duration, or a paper that closes at 17:00 would show a student who started
  /// at 16:50 a full hour of countdown while every answer the RPC received
  /// after 17:00 was refused — the visible clock would outlast the window the
  /// server enforces. `least()` on the server and this cap are the same rule,
  /// so the two can never disagree.
  ///
  /// Pure and static on purpose: it is the one place the client and the server
  /// answer "how long have I got?", and pinning it here lets a test hold both
  /// clocks still instead of racing a real timer.
  static DateTime? resolveDeadline({
    required DateTime now,
    required int? durationMinutes,
    required DateTime? startedAt,
    required DateTime? endsAt,
  }) {
    if (durationMinutes == null || durationMinutes <= 0) return null;

    final byDuration = (startedAt ?? now).add(
      Duration(minutes: durationMinutes),
    );
    // `ends_at` is a hard close on the server (`least()` in `attempt_deadline()`),
    // so the earlier of the two is the deadline. A null `ends_at` is an
    // unscheduled paper and leaves the duration alone, exactly as
    // `coalesce(ends_at, 'infinity')` does.
    if (endsAt != null && endsAt.isBefore(byDuration)) return endsAt;

    return byDuration;
  }


  void _tickCountdown(DateTime deadline) {
    if (!mounted) return;

    final remaining = deadline.difference(_clock());
    state = state.copyWith(
      remaining: remaining.isNegative ? Duration.zero : remaining,
    );

    if (!remaining.isNegative && remaining != Duration.zero) return;

    // Time is up: submit without asking. `submit_exam` is idempotent, so a
    // double fire (a slow tick while the first call is in flight) is harmless.
    stopCountdown();
    onTimeUp?.call();
  }

  /// Cancels the countdown. Called by the page on submit, on a forced exit and
  /// on teardown.
  void stopCountdown() {
    _countdown?.cancel();
    _countdown = null;
  }

  /// Records a multiple-choice tap: paint, persist, advance.
  Future<void> selectOption(int optionIndex) async {
    final question = state.questions[state.currentIndex];

    // Paint first: nothing below is allowed to gate the tap feedback.
    state = state.copyWith(
      answers: <String, int>{...state.answers, question.id: optionIndex},
    );

    try {
      // Local first: this resolves once the answer is durable on the device, so
      // a dropped connection no longer costs the student the choice they made.
      await _persistChoice(question.id, optionIndex);
    } catch (error) {
      // Only reachable without a queue (see [_persistChoice]). Grading reads the
      // *server* copy, so stay on the question instead of advancing past the
      // only chance to save it.
      proctorLog('ProctorGuard: answer autosave failed: $error');
      onMessage?.call(
        'Could not save that answer. Check your connection and tap your choice '
        'again.',
      );
      return;
    }

    if (!mounted) return;
    final saved = Set<String>.of(state.savedQuestions)..add(question.id);
    state = state.copyWith(
      savedQuestions: saved,
      currentIndex: state.currentIndex < state.questions.length - 1
          ? state.currentIndex + 1
          : state.currentIndex,
    );
  }

  /// Records a true/false tap: paint, persist the word, advance.
  ///
  /// The answer travels the *text* path (`merge_submission_text_answer`), because
  /// that is what a true/false row's key is compared against — the word 'true' or
  /// 'false', not an option index — and it is therefore also what
  /// `submit_exam()` reads when the attempt closes.
  Future<void> selectTrueFalse(bool value) async {
    final question = state.questions[state.currentIndex];
    final word = value ? 'true' : 'false';

    // Paint first, exactly as a multiple-choice tap does: nothing below is
    // allowed to gate the tap feedback.
    state = state.copyWith(
      textAnswers: <String, String>{...state.textAnswers, question.id: word},
    );

    try {
      await _persistText(question.id, word);
    } catch (error) {
      // Only reachable without a queue (see [_persistText]). Grading reads the
      // *server* copy, so stay on the question instead of advancing past the
      // only chance to save it.
      proctorLog('ProctorGuard: answer autosave failed: $error');
      onMessage?.call(
        'Could not save that answer. Check your connection and tap again.',
      );
      return;
    }

    if (!mounted) return;
    final saved = Set<String>.of(state.savedQuestions)..add(question.id);
    state = state.copyWith(
      savedText: <String, String>{...state.savedText, question.id: word},
      savedQuestions: saved,
      currentIndex: state.currentIndex < state.questions.length - 1
          ? state.currentIndex + 1
          : state.currentIndex,
    );
  }

  /// Durable write for a multiple-choice answer.
  ///
  /// The queue is the normal path: it stores the answer locally and syncs it in
  /// the background, reporting a failure through the banner instead of throwing.
  /// Without one (a host that wired no offline layer) this is the old
  /// straight-to-SQL call, whose failure is again shown to the student.
  Future<void> _persistChoice(String questionId, int optionIndex) {
    final sync = _sync;
    if (sync == null) {
      return _exams.saveAnswer(
        submissionId: _submissionId,
        questionId: questionId,
        selectedOption: optionIndex,
      );
    }
    return sync.cacheChoice(
      submissionId: _submissionId,
      questionId: questionId,
      selectedOption: optionIndex,
    );
  }

  /// Durable write for a fill-in-the-blank answer: "Save & next", the keyboard's
  /// done action, and the flush before submitting all go through here.
  Future<void> _persistText(String questionId, String text) {
    final sync = _sync;
    if (sync == null) {
      return _exams.saveTextAnswer(
        submissionId: _submissionId,
        questionId: questionId,
        answer: text,
      );
    }
    return sync.cacheText(
      submissionId: _submissionId,
      questionId: questionId,
      text: text,
    );
  }

  /// Mirrors a keystroke into the local cache, with **no** network write: an
  /// answer that is still being typed has to survive the app being killed too,
  /// but the server does not need every character.
  void cacheDraftText(String questionId, String value) {
    state = state.copyWith(
      textAnswers: <String, String>{...state.textAnswers, questionId: value},
    );
    _sync?.cacheTextDraft(
      submissionId: _submissionId,
      questionId: questionId,
      text: value,
    );
  }

  /// Saves the free-text answer [questionId] through the local-first queue.
  ///
  /// Returns whether the answer is now durable. [advance] moves to the next
  /// question *after* the local write, so a failure (no queue and no network)
  /// still keeps the student on the question with their text intact.
  Future<bool> saveTextAnswer(String questionId, {bool advance = false}) async {
    if (state.savingText || !mounted) return false;

    final text = state.textAnswers[questionId] ?? '';
    state = state.copyWith(savingText: true);

    try {
      await _persistText(questionId, text);
    } catch (error) {
      proctorLog('ProctorGuard: text answer save failed: $error');
      if (!mounted) return false;
      state = state.copyWith(savingText: false);
      onMessage?.call(
        'Could not save that answer. Check your connection and tap Save again.',
      );
      return false;
    }

    if (!mounted) return false;
    final saved = Set<String>.of(state.savedQuestions)..add(questionId);
    state = state.copyWith(
      savingText: false,
      savedText: <String, String>{...state.savedText, questionId: text},
      savedQuestions: saved,
      currentIndex: advance && state.currentIndex < state.questions.length - 1
          ? state.currentIndex + 1
          : state.currentIndex,
    );
    return true;
  }

  /// Writes the current typed answer if the cache does not have it yet. Called
  /// before navigating away and before closing the attempt: grading reads the
  /// server copy, and the queue is what gets it there.
  ///
  /// Covers both typed shapes (fill in the blank and essay); a true/false answer
  /// is written on the tap, so there is nothing unsaved here for it.
  Future<bool> flushTextAnswer() async {
    if (!mounted) return true;

    final question = state.questions[state.currentIndex];
    if (!question.usesTextAnswer) return true;

    final text = state.textAnswers[question.id] ?? '';
    if (state.savedText[question.id] == text) return true;
    return saveTextAnswer(question.id);
  }

  /// Moves to [index], persisting the current text answer first.
  Future<void> goTo(int index) async {
    if (index < 0 || index >= state.questions.length) return;
    await flushTextAnswer();
    if (!mounted) return;
    state = state.copyWith(currentIndex: index);
  }

  /// Adds [questionId] to the review list, or takes it off.
  ///
  /// Purely local and synchronous: marking is a note to self, not an answer, so
  /// there is nothing to persist and nothing that can fail. It is ignored while
  /// the attempt is closing (the paper must not change under a submit in flight)
  /// and for an id that is not in this paper, so a stale tile cannot put an
  /// unknown id in the grid.
  void toggleMarkForReview(String questionId) {
    if (!mounted) return;
    if (state.submitting) return;
    if (!state.questions.any((question) => question.id == questionId)) return;

    // Copied, not mutated: `ExamSessionState` is handed around as a value and
    // the same set instance must not change under a widget that already read it.
    final marked = Set<String>.of(state.markedForReview);
    if (!marked.remove(questionId)) marked.add(questionId);

    state = state.copyWith(markedForReview: marked);
  }

  /// Runs the pre-submit gate: drain the queues, then decide whether the
  /// attempt can be closed.
  ///
  /// [acknowledged] is set when the student has already seen (and accepted) the
  /// warning that some answers were rejected, so the gate does not raise it a
  /// second time.
  Future<SubmitOutcome> prepareSubmit({
    required bool timeUp,
    bool acknowledged = false,
  }) async {
    final sync = _sync;
    if (sync == null) return const SubmitOutcome(SubmitGate.ready); // no queue

    await sync.flush();
    if (!mounted) return const SubmitOutcome(SubmitGate.pendingAnswers);

    final rejected = sync.rejectedAnswerCountFor(_submissionId);
    if (rejected > 0 && !acknowledged) {
      state = state.copyWith(submitting: false, timeUpPending: timeUp);
      return SubmitOutcome(SubmitGate.rejectedAnswers, rejectedCount: rejected);
    }

    // Only *answers* hold the attempt open: grading reads the server's copy of
    // them. A queued violation is delivered - and still counted - after the
    // attempt closes, so blocking an otherwise finished student on evidence
    // delivery would let one refused log row strand them for good.
    if (!sync.state.hasPendingAnswers) {
      await _drainViolationsBeforeClose(sync);
      return const SubmitOutcome(SubmitGate.ready);
    }
    if (!mounted) return const SubmitOutcome(SubmitGate.pendingAnswers);

    state = state.copyWith(
      submitting: false,
      timeUpPending: timeUp,
      offlineSubmitPending: !timeUp,
    );
    return const SubmitOutcome(SubmitGate.pendingAnswers);
  }

  /// One last, backoff-free push of the violation queue, while the session
  /// screen is still alive to make it.
  ///
  /// Best-effort by design: evidence that cannot be delivered is a weaker
  /// console signal, but it is not the student's to fix and no retry they can
  /// perform would change it — which is why the hold above is on answers only.
  Future<void> _drainViolationsBeforeClose(OfflineSyncService sync) async {
    final queued = sync.state.pendingViolations;
    if (queued == 0) return;

    await sync.retryNow();

    final left = sync.state.pendingViolations;
    if (left > 0) {
      // Never silently: this is the one proctoring signal that can be missing
      // from a closed attempt's audit, and a support engineer has to be able to
      // see that it was the connection and not the session.
      proctorLog(
        'ProctorGuard: $left of $queued proctoring log(s) still queued as the '
        'attempt closes - they will be delivered on the next connection.',
      );
    }
  }

  /// The "waiting for a connection" screen's retry: drain the queue and report
  /// whether the attempt can now be submitted (the page then calls `submit`).
  ///
  /// Returns false while the queue still owes the server answers.
  Future<bool> retryOfflineSubmit() async {
    state = state.copyWith(offlineSubmitPending: false, submitting: false);

    final sync = _sync;
    if (sync != null) await sync.flush();
    if (!mounted) return false;

    if (sync != null && sync.state.hasPendingAnswers) {
      state = state.copyWith(offlineSubmitPending: true);
      return false;
    }
    return true;
  }

  /// A best-effort push of the queue, used when the OS brings the exam back to
  /// the foreground — the mobile equivalent of the browser's `online` event.
  Future<void> retrySyncNow() async {
    await _sync?.retryNow();
  }

  void markSubmitting() => state = state.copyWith(submitting: true);

  /// Whether a submit is already in flight — the double-tap guard the page reads
  /// before opening the confirmation dialog.
  bool get isSubmitting => state.submitting;

  /// The paper as loaded, read-only.
  ///
  /// The page needs it for the instant result: the sum of [Question.points] is the
  /// "of 10" beside the mark the server returned, and whether any question is an
  /// essay is what decides between showing that mark and saying "still to be
  /// marked". Both are the *same* facts grading uses server-side, so the two
  /// cannot disagree.
  List<Question> get questions => state.questions;

  /// Closes the attempt server-side. `submit_exam` grades and is idempotent, so
  /// a retry after a dropped connection is safe.
  ///
  /// The returned [ExamSubmitResult] is the server's own answer
  /// (`result_status`, `final_score`) — the page hands it to the portal, which is
  /// where an attempt with no essay on it is shown its mark straight away.
  Future<ExamSubmitResult> submitToServer() =>
      _exams.submitExam(_submissionId);

  /// Drops the drafts for this attempt: the server owns the answers now.
  ///
  /// Queued violations are deliberately kept (see `clearSession`).
  Future<void> clearSession() async {
    await _sync?.clearSession(_submissionId);
  }

  /// Stops the clock once the server has accepted the submission.
  void onSubmitted() => stopCountdown();

  /// Puts the session back into a retryable state after a failed submit.
  void onSubmitFailed({required bool timeUp}) => state = state.copyWith(
        submitting: false,
        timeUpPending: timeUp,
        offlineSubmitPending: !timeUp,
      );

  /// The student declined to submit the answers the server rejected: return to
  /// the question, with the retry/exit screen when the clock ran out.
  void abortSubmit({required bool timeUp}) =>
      state = state.copyWith(submitting: false, timeUpPending: timeUp);

  /// Ends the bootstrap in the blocking-error state (see
  /// [ExamSessionState.blockingError]); [offerSettings] adds the "Open settings"
  /// action for a permission the student has to fix in the OS.
  void failStart(String message, {bool offerSettings = false}) =>
      state = state.copyWith(
        loading: false,
        blockingError: message,
        offerSettings: offerSettings,
      );

  /// Clears the blocking state so a retry shows the spinner again.
  void resetForRetry() => state = state.copyWith(
        clearBlockingError: true,
        offerSettings: false,
        loading: true,
      );

  @override
  void dispose() {
    _countdown?.cancel();
    _countdown = null;
    super.dispose();
  }
}

/// One controller per exam session, keyed by [ExamSessionArgs] and torn down
/// with the exam-taking page.
final examSessionControllerProvider = StateNotifierProvider.autoDispose
    .family<ExamSessionController, ExamSessionState, ExamSessionArgs>(
  (ref, args) => ExamSessionController(ref, args: args),
);
