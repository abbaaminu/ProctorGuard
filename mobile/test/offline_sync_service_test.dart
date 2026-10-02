import 'dart:async';
import 'dart:convert';

import 'package:exam_proctor/core/services/key_value_store.dart';
import 'package:exam_proctor/core/services/network_status.dart';
import 'package:exam_proctor/core/services/offline_sync_service.dart';
import 'package:exam_proctor/core/utils/uuid.dart';
import 'package:exam_proctor/features/exam/domain/entities/exam.dart';
import 'package:exam_proctor/features/exam/domain/entities/question.dart';
import 'package:exam_proctor/features/exam/domain/entities/submission.dart';
import 'package:exam_proctor/features/exam/domain/repositories/exam_repository.dart';
import 'package:exam_proctor/features/proctoring/domain/entities/violation.dart';
import 'package:exam_proctor/features/proctoring/domain/repositories/proctoring_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// The offline layer (requirement 1 and the retry half of requirement 4):
///
///  * an answer is durable *before* anything is attempted over the network, and a
///    dead network never costs it;
///  * the queue drains by itself - on demand, on the retry backoff, or when the
///    connectivity probe reports the connection is back;
///  * a violation queued while offline is replayed with the **same** event id, so
///    `register_violation`'s dedupe turns a retry into one strike rather than two.
void main() {
  group('answer cache', () {
    late _FlakyExamRepository exams;
    late _FlakyProctoringRepository proctoring;
    late InMemoryKeyValueStore store;
    late OfflineSyncService sync;

    setUp(() {
      exams = _FlakyExamRepository();
      proctoring = _FlakyProctoringRepository();
      store = InMemoryKeyValueStore();
      sync = _service(exams: exams, proctoring: proctoring, store: store);
    });

    tearDown(() => sync.dispose());

    test('a tapped answer is durable before the network is asked', () async {
      exams.online = false;

      await sync.cacheChoice(
        submissionId: 'sub-1',
        questionId: 'q-1',
        selectedOption: 2,
      );

      // The tap resolved, the answer is readable back, and the banner knows there
      // is work waiting.
      expect(sync.cachedChoices('sub-1')['q-1'], 2);
      expect(sync.state.pendingAnswers, 1);
      expect(sync.state.online, isFalse);
      expect(sync.state.hasPending, isTrue);
      expect(sync.state.label, 'Offline - syncing locally');
      expect(exams.optionAnswers, isEmpty, reason: 'nothing reached the server');
    });

    test('the queue drains when the connection comes back', () async {
      exams.online = false;
      await sync.cacheText(
        submissionId: 'sub-1',
        questionId: 'q-2',
        text: 'HTTP',
      );
      expect(sync.state.pendingAnswers, 1);

      exams.online = true;
      await sync.retryNow();

      expect(exams.textAnswers, <String>['q-2=HTTP']);
      expect(sync.state.isSynced, isTrue);
      expect(sync.state.online, isTrue);
      expect(sync.state.lastSyncedAt, isNotNull);
    });

    test('a failed delivery is retried by the backoff, with no help', () async {
      exams.online = false;
      sync = _service(
        exams: exams,
        proctoring: proctoring,
        store: store,
        minRetryDelay: const Duration(milliseconds: 10),
      );

      await sync.cacheChoice(
        submissionId: 'sub-1',
        questionId: 'q-1',
        selectedOption: 1,
      );
      expect(sync.state.pendingAnswers, 1);

      exams.online = true;
      // No retryNow: the timer alone has to notice.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(exams.optionAnswers, <String>['q-1=1']);
      expect(sync.state.hasPending, isFalse);
    });

    test('a row the server keeps refusing does not block the rows behind it',
        () async {
      // The head of the queue is poison: every write for this question fails.
      // That is what a schema change, or a question an exam edit removed, looks
      // like from here - and it must not cost the answers queued behind it.
      exams.rejectQuestionId = 'q-1';

      await sync.cacheChoice(
        submissionId: 'sub-1',
        questionId: 'q-1',
        selectedOption: 1,
      );
      await sync.cacheText(
        submissionId: 'sub-1',
        questionId: 'q-2',
        text: 'HTTP',
      );

      await sync.retryNow();

      expect(exams.textAnswers, <String>['q-2=HTTP'],
          reason: 'the rest of the queue still drains');
      expect(exams.optionAnswers, isEmpty);
      expect(sync.state.pendingAnswers, 1,
          reason: 'only the refused row is still owed');
      expect(sync.state.online, isFalse,
          reason: 'a pass that delivered and failed is not a connection that is back');
    });

    test('a permanent server rejection is retained as a warning, not retried',
        () async {
      exams.rejectPermanentlyQuestionId = 'q-1';

      await sync.cacheChoice(
        submissionId: 'sub-1',
        questionId: 'q-1',
        selectedOption: 2,
      );

      expect(sync.state.pendingAnswers, 0);
      expect(sync.state.rejectedAnswers, 1);
      expect(sync.state.hasPending, isFalse);
      expect(sync.state.hasRejectedAnswers, isTrue);
      expect(sync.rejectedAnswerCountFor('sub-1'), 1);
      expect(sync.state.label, contains('not accepted'));
      expect(exams.permanentRejections, 1);

      await sync.dispose();
      final relaunched =
          _service(exams: exams, proctoring: proctoring, store: store);
      addTearDown(relaunched.dispose);
      await relaunched.ensureHydrated();

      expect(relaunched.state.rejectedAnswers, 1);
      await relaunched.retryNow();
      expect(exams.permanentRejections, 1,
          reason: 'a terminal rejection is not retried after restoration');
    });

    test('re-answering replaces the pending row instead of queueing twice',
        () async {
      exams.online = false;
      await sync.cacheChoice(
        submissionId: 'sub-1',
        questionId: 'q-1',
        selectedOption: 1,
      );
      await sync.cacheChoice(
        submissionId: 'sub-1',
        questionId: 'q-1',
        selectedOption: 3,
      );

      expect(sync.state.pendingAnswers, 1, reason: 'one row per question');
      expect(sync.cachedChoices('sub-1')['q-1'], 3);

      exams.online = true;
      await sync.retryNow();

      expect(exams.optionAnswers, <String>['q-1=3'],
          reason: 'the stale value is never sent');
    });

    test('a keystroke is cached without queueing a network write', () async {
      sync.cacheTextDraft(
        submissionId: 'sub-1',
        questionId: 'q-2',
        text: 'HyperText',
      );

      expect(sync.cachedText('sub-1')['q-2'], 'HyperText');
      expect(sync.state.hasPending, isFalse);
      expect(exams.textAnswers, isEmpty);
    });

    test('a fresh service on the same device restores drafts and queue',
        () async {
      exams.online = false;
      await sync.cacheChoice(
        submissionId: 'sub-1',
        questionId: 'q-1',
        selectedOption: 2,
      );
      await sync.cacheText(
        submissionId: 'sub-1',
        questionId: 'q-2',
        text: 'TCP',
      );
      await sync.dispose();

      // The app is killed and restarted over the same storage.
      final relaunched = _service(exams: exams, proctoring: proctoring, store: store);
      addTearDown(relaunched.dispose);
      await relaunched.ensureHydrated();

      expect(relaunched.cachedChoices('sub-1'), <String, int>{'q-1': 2});
      expect(relaunched.cachedText('sub-1'), <String, String>{'q-2': 'TCP'});
      expect(relaunched.state.pendingAnswers, 2, reason: 'both are still owed');

      exams.online = true;
      await relaunched.retryNow();
      expect(exams.optionAnswers, <String>['q-1=2']);
      expect(exams.textAnswers, <String>['q-2=TCP']);
    });

    test('clearSession drops the attempt, clearSession keeps violations',
        () async {
      proctoring.online = false;
      await sync.cacheChoice(
        submissionId: 'sub-1',
        questionId: 'q-1',
        selectedOption: 1,
      );
      await sync.log(
        submissionId: 'sub-1',
        violation: _violation(ViolationType.appMinimized),
      );

      await sync.clearSession('sub-1');

      expect(sync.cachedChoices('sub-1'), isEmpty);
      expect(sync.state.pendingAnswers, 0);
      expect(sync.state.pendingViolations, 1,
          reason: 'evidence for a closed attempt is still delivered');
    });

    test('corrupt storage is dropped, not fatal', () async {
      await store.write('queue.answers', '{not json');
      await store.write('draft.text', jsonEncode(<String, dynamic>{'sub-1': 5}));

      final recovered = _service(exams: exams, proctoring: proctoring, store: store);
      addTearDown(recovered.dispose);

      await recovered.ensureHydrated();
      expect(recovered.state.hasPending, isFalse);
      expect(recovered.cachedText('sub-1'), isEmpty);
    });
  });
  group('violation outbox (requirement 4)', () {
    late _FlakyExamRepository exams;
    late _FlakyProctoringRepository proctoring;
    late OfflineSyncService sync;

    setUp(() {
      exams = _FlakyExamRepository();
      proctoring = _FlakyProctoringRepository();
      sync = _service(exams: exams, proctoring: proctoring);
    });

    tearDown(() => sync.dispose());

    test('a violation that cannot be delivered is queued, not lost', () async {
      proctoring.online = false;
      final violation = Violation(
        type: ViolationType.lookingAway,
        timestamp: DateTime.utc(2026, 3, 4, 9, 15),
        clientEventId: uuidV4(),
      );

      final ruling = await sync.log(submissionId: 'sub-1', violation: violation);

      expect(ruling, isNull, reason: 'null is "queued", not "delivered"');
      expect(sync.state.pendingViolations, 1);
      expect(sync.state.online, isFalse);
      expect(proctoring.violations, isEmpty);
    });

    test('the retry replays the same event id and reports the ruling', () async {
      proctoring.online = false;
      final violation = Violation(
        type: ViolationType.noFace,
        timestamp: DateTime.utc(2026, 3, 4, 9, 15),
        clientEventId: 'e2f4c2f0-1a2b-4c3d-8e9f-0123456789ab',
      );
      await sync.log(submissionId: 'sub-1', violation: violation);

      final rulings = <ViolationRuling>[];
      final subscription = sync.deferredRulings.listen(rulings.add);
      addTearDown(subscription.cancel);

      proctoring.online = true;
      proctoring.warningCount = 2;
      await sync.retryNow();
      await pumpEventQueue(); // broadcast delivery is asynchronous

      expect(proctoring.violations, hasLength(1));
      // Same id as the live attempt: that is what the server's `on conflict`
      // dedupe needs so a retry is one strike, not two.
      expect(proctoring.violations.single.clientEventId,
          'e2f4c2f0-1a2b-4c3d-8e9f-0123456789ab');
      expect(proctoring.violations.single.timestamp, violation.timestamp);

      expect(rulings.single.submissionId, 'sub-1');
      expect(rulings.single.warningCount, 2);
      expect(rulings.single.disqualified, isFalse);
      expect(sync.state.pendingViolations, 0);
    });

    test('a third strike delivered late still ends the attempt', () async {
      proctoring.online = false;
      await sync.log(
        submissionId: 'sub-1',
        violation: _violation(ViolationType.multipleFaces),
      );

      final rulings = <ViolationRuling>[];
      final subscription = sync.deferredRulings.listen(rulings.add);
      addTearDown(subscription.cancel);

      proctoring
        ..online = true
        ..warningCount = 3
        ..disqualifyAt = 3;
      await sync.retryNow();
      await pumpEventQueue(); // broadcast delivery is asynchronous

      expect(rulings.single.disqualified, isTrue);
      expect(rulings.single.warningCount, 3);
    });

    test('the queue is bounded, newest evidence kept', () async {
      proctoring.online = false;
      sync = _service(
        exams: exams,
        proctoring: proctoring,
        maxQueuedViolations: 2,
      );

      for (var i = 0; i < 4; i++) {
        await sync.log(
          submissionId: 'sub-1',
          violation: Violation(
            type: ViolationType.audioNoise,
            timestamp: DateTime.utc(2026, 3, 4, 9, 15, i),
            clientEventId: uuidV4(),
          ),
        );
      }

      expect(sync.state.pendingViolations, 2);
    });

    test('a queue restored from disk is bounded to the cap in force', () async {
      final store = InMemoryKeyValueStore();
      proctoring.online = false;
      sync = _service(exams: exams, proctoring: proctoring, store: store);

      // Four rows are written while the bound is the default 200...
      for (var i = 0; i < 4; i++) {
        await sync.log(
          submissionId: 'sub-1',
          violation: Violation(
            type: ViolationType.audioNoise,
            timestamp: DateTime.utc(2026, 3, 4, 9, 15, i),
            clientEventId: uuidV4(),
          ),
        );
      }
      await sync.dispose();

      // ...and the app comes back on a build with a tighter bound, the way it would
      // after a release that lowers the cap.
      final relaunched = _service(
        exams: exams,
        proctoring: proctoring,
        store: store,
        maxQueuedViolations: 2,
      );
      addTearDown(relaunched.dispose);
      await relaunched.ensureHydrated();

      expect(relaunched.state.pendingViolations, 2,
          reason: 'the cap bounds what arrives from disk, not only what is added');

      // The newest evidence is what the cap keeps, and it is what still gets
      // delivered - the shed rows are the oldest ones.
      proctoring.online = true;
      await relaunched.retryNow();
      expect(
        proctoring.violations.map((violation) => violation.timestamp.second),
        <int>[2, 3],
      );
    });
  });

  group('network probe', () {
    test('an "online" event drains a queue that was waiting', () async {
      final exams = _FlakyExamRepository()..online = false;
      final network = _FakeNetworkStatus(isOnline: false);
      final sync = _service(
        exams: exams,
        proctoring: _FlakyProctoringRepository(),
        network: network,
      );
      addTearDown(sync.dispose);

      await sync.cacheChoice(
        submissionId: 'sub-1',
        questionId: 'q-1',
        selectedOption: 1,
      );
      expect(sync.state.online, isFalse);
      expect(sync.state.label, 'Offline - syncing locally');

      exams.online = true;
      network.report(true);
      await pumpEventQueue();

      expect(exams.optionAnswers, <String>['q-1=1']);
      expect(sync.state.online, isTrue);
    });

    test('an "offline" event flips the banner before anything fails', () async {
      final network = _FakeNetworkStatus();
      final sync = _service(
        exams: _FlakyExamRepository(),
        proctoring: _FlakyProctoringRepository(),
        network: network,
      );
      addTearDown(sync.dispose);

      network.report(false);
      await pumpEventQueue();

      expect(sync.state.online, isFalse);
    });
  });

  group('client event ids', () {
    test('uuidV4 has the v4 shape', () {
      expect(
        uuidV4(),
        matches(RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        )),
      );
    });

    test('uuidV4 does not repeat itself', () {
      final seen = <String>{for (var i = 0; i < 500; i++) uuidV4()};
      expect(seen, hasLength(500));
    });
  });
}

/// One service over throwaway fakes.
OfflineSyncService _service({
  required ExamRepository exams,
  required ProctoringRepository proctoring,
  KeyValueStore? store,
  NetworkStatus? network,
  Duration minRetryDelay = const Duration(milliseconds: 20),
  int maxQueuedViolations = 200,
}) =>
    OfflineSyncService(
      exams: exams,
      proctoring: proctoring,
      store: store ?? InMemoryKeyValueStore(),
      network: network,
      // Short enough that a test never has to wait on a real backoff.
      minRetryDelay: minRetryDelay,
      maxRetryDelay: const Duration(milliseconds: 400),
      maxQueuedViolations: maxQueuedViolations,
    );

Violation _violation(ViolationType type) => Violation(
      type: type,
      timestamp: DateTime.utc(2026, 3, 4, 9, 15),
      clientEventId: uuidV4(),
    );

/// Thrown by the fakes when their network is "down".
class _Offline implements Exception {
  const _Offline();

  @override
  String toString() => 'offline';
}

/// An [ExamRepository] whose backend can be switched off, recording what it
/// actually accepted.
class _FlakyExamRepository implements ExamRepository {
  bool online = true;
  final List<String> optionAnswers = <String>[];
  final List<String> textAnswers = <String>[];
  final List<String> submitted = <String>[];

  /// One question this backend refuses no matter what, the way a server-side
  /// schema change would: the row stays queued for good while every other row
  /// must still get through.
  String? rejectQuestionId;
  String? rejectPermanentlyQuestionId;
  int permanentRejections = 0;

  @override
  Future<List<Exam>> getPublishedExams() async => <Exam>[];

  @override
  Future<List<Question>> getQuestions(String examId) async => <Question>[];

  @override
  Future<Submission> startOrResumeSubmission(String examId) =>
      throw UnimplementedError('not used by the offline layer');

  @override
  Future<void> saveAnswer({
    required String submissionId,
    required String questionId,
    required int selectedOption,
  }) async {
    if (questionId == rejectPermanentlyQuestionId) {
      permanentRejections++;
      throw const AnswerWriteRejected();
    }
    if (!online || questionId == rejectQuestionId) throw const _Offline();
    optionAnswers.add('$questionId=$selectedOption');
  }

  @override
  Future<void> saveTextAnswer({
    required String submissionId,
    required String questionId,
    required String answer,
  }) async {
    if (questionId == rejectPermanentlyQuestionId) {
      permanentRejections++;
      throw const AnswerWriteRejected();
    }
    if (!online || questionId == rejectQuestionId) throw const _Offline();
    textAnswers.add('$questionId=$answer');
  }

  @override
  Future<void> submitExam(String submissionId) async {
    if (!online) throw const _Offline();
    submitted.add(submissionId);
  }

  @override
  Future<void> markDisqualified(String submissionId) async {}
}

/// The proctoring side of the same switch. [warningCount] and [disqualifyAt] let a
/// test decide what the server "answers" when a queued violation finally lands.
class _FlakyProctoringRepository implements ProctoringRepository {
  bool online = true;
  int warningCount = 1;
  int disqualifyAt = 3;
  final List<Violation> violations = <Violation>[];

  @override
  Future<({int warningCount, bool disqualified})> logViolation({
    required String submissionId,
    required Violation violation,
  }) async {
    if (!online) throw const _Offline();
    violations.add(violation);
    final count = warningCount + violations.length - 1;
    return (warningCount: count, disqualified: count >= disqualifyAt);
  }

  @override
  Stream<List<Map<String, dynamic>>> watchLogs(String submissionId) =>
      const Stream<List<Map<String, dynamic>>>.empty();
}

/// A connectivity probe a test can drive (the real one is DOM-backed, so it only
/// exists in a web build).
class _FakeNetworkStatus implements NetworkStatus {
  _FakeNetworkStatus({bool isOnline = true}) : _online = isOnline;

  bool _online;
  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  void report(bool online) {
    if (online == _online) return;
    _online = online;
    _changes.add(online);
  }

  @override
  bool get isSupported => true;

  @override
  bool get isOnline => _online;

  @override
  Stream<bool> get changes => _changes.stream;

  @override
  void dispose() => _changes.close();
}
