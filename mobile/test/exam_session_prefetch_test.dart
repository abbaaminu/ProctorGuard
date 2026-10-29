import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/core/di/providers.dart';
import 'package:proctorguard/features/exam/domain/entities/exam.dart';
import 'package:proctorguard/features/exam/domain/entities/exam_submit_result.dart';
import 'package:proctorguard/features/exam/domain/entities/question.dart';
import 'package:proctorguard/features/exam/domain/entities/submission.dart';
import 'package:proctorguard/features/exam/domain/repositories/exam_repository.dart';
import 'package:proctorguard/features/exam/presentation/providers/exam_session_controller.dart';

/// The question feed is the slowest wait in the exam bootstrap that is not a
/// dialog, and it is independent of every device step the page takes before it
/// paints a question: opening the camera, pinning the kiosk, arming the
/// integrity probe.
///
/// [ExamSessionController.prefetchQuestions] therefore starts it at the top of
/// the bootstrap and [ExamSessionController.loadQuestions] applies it at the
/// end. These tests pin both halves of that split, because each one carries a
/// guarantee the screen depends on:
///
///  * the request really is in flight while the device is being set up (so the
///    student waits for the longer of the two, not for their sum);
///  * nothing is painted when it resolves (the spinner still covers the whole
///    setup, and the cached answers are restored before a question shows);
///  * a failed fetch is asked for again by the retry behind the blocking state
///    instead of awaiting the same rejected future forever.
void main() {
  /// The paper the fake server hands back once the test lets it.
  const question = Question(
    id: 'q-1',
    examId: 'exam-1',
    questionText: 'What is 2 + 2?',
    options: <String>['3', '4'],
  );

  /// A controller over a repository whose question fetch the test completes by
  /// hand, so "started" and "finished" are two observable moments.
  ({ExamSessionController controller, _PendingExamRepository exams})
      sessionUnderTest() {
    final exams = _PendingExamRepository();
    final container = ProviderContainer(
      overrides: <Override>[examRepositoryProvider.overrideWithValue(exams)],
    );
    addTearDown(container.dispose);

    const args = ExamSessionArgs(examId: 'exam-1', submissionId: 'sub-1');
    // A listener keeps the `autoDispose` provider alive for the test; a bare
    // `read` would let Riverpod dispose it on the next microtask.
    container.listen(examSessionControllerProvider(args), (_, _) {});

    final controller =
        container.read(examSessionControllerProvider(args).notifier);
    return (controller: controller, exams: exams);
  }

  test('the fetch is in flight while the device is still being set up', () {
    final built = sessionUnderTest();

    built.controller.prefetchQuestions();

    expect(
      built.exams.questionRequests,
      1,
      reason: 'the request must not be queued behind the camera and the kiosk',
    );
    // Still on the spinner: the bootstrap has not called `loadQuestions` yet.
    expect(built.controller.state.loading, isTrue);
    expect(built.controller.state.questions, isEmpty);
  });

  test('what arrives early is painted by loadQuestions, not before it', () async {
    final built = sessionUnderTest();

    built.controller.prefetchQuestions();
    built.exams.requests.single.complete(const <Question>[question]);
    await pumpEventQueue();

    expect(
      built.controller.state.questions,
      isEmpty,
      reason: 'the cache is hydrated and the camera opened before a question '
          'is shown, so an early answer to the fetch waits its turn',
    );
    expect(built.controller.state.loading, isTrue);

    await built.controller.loadQuestions();

    expect(built.controller.state.questions, <Question>[question]);
    expect(built.controller.state.loading, isFalse);
  });

  test('a retry reuses the feed it already has instead of asking again',
      () async {
    final built = sessionUnderTest();

    built.controller.prefetchQuestions();
    built.exams.requests.single.complete(const <Question>[question]);
    await built.controller.loadQuestions();

    // What the blocking states' Try again does once the camera is already up.
    await built.controller.loadQuestions();

    expect(built.exams.questionRequests, 1);
    expect(built.controller.state.questions, <Question>[question]);
  });

  test('a failed fetch is asked for again by the retry', () async {
    final built = sessionUnderTest();

    built.controller.prefetchQuestions();
    // The early failure must not surface as an unhandled error while the
    // bootstrap is still working through the device: this test would fail on it.
    built.exams.requests.single.completeError(StateError('offline'));
    await pumpEventQueue();

    // Nothing is applied yet - the bootstrap is still on the camera.
    expect(built.controller.state.questions, isEmpty);
    expect(built.controller.state.blockingError, isNull);

    await built.controller.loadQuestions();
    expect(built.controller.state.blockingError, isNotNull);

    final retry = built.controller.loadQuestions();
    built.exams.requests.last.complete(const <Question>[question]);
    await retry;

    expect(
      built.exams.questionRequests,
      2,
      reason: 'a rejected future must not be replayed forever',
    );
    expect(built.controller.state.questions, <Question>[question]);
  });
}

/// Answers `getQuestions` only when the test says so. Every other call is
/// outside the scope of these tests, and fails loudly if a future change makes
/// the bootstrap reach for one behind the feed.
class _PendingExamRepository implements ExamRepository {
  final List<Completer<List<Question>>> requests =
      <Completer<List<Question>>>[];

  int get questionRequests => requests.length;

  @override
  Future<List<Question>> getQuestions(String examId) {
    final completer = Completer<List<Question>>();
    requests.add(completer);
    return completer.future;
  }

  @override
  Future<List<Exam>> getPublishedExams() async => const <Exam>[];

  @override
  Future<Submission> startOrResumeSubmission(String examId) =>
      throw UnimplementedError();

  @override
  Future<void> saveAnswer({
    required String submissionId,
    required String questionId,
    required int selectedOption,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> saveTextAnswer({
    required String submissionId,
    required String questionId,
    required String answer,
  }) =>
      throw UnimplementedError();

  @override
  Future<ExamSubmitResult> submitExam(String submissionId) =>
      throw UnimplementedError();

  @override
  Future<void> markDisqualified(String submissionId) =>
      throw UnimplementedError();
}

