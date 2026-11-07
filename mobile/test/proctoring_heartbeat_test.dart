import 'dart:async';

import 'package:proctorguard/core/services/proctoring_heartbeat.dart';
import 'package:proctorguard/features/proctoring/domain/entities/heartbeat.dart';
import 'package:proctorguard/features/proctoring/domain/entities/violation.dart';
import 'package:proctorguard/features/proctoring/domain/repositories/proctoring_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// The client half of the liveness signal: a beat on a timer, never queued, never
/// able to throw into the exam.
///
/// The server half (rate limit, dedupe, coverage, retention) is SQL and is
/// exercised by the SQL tests; what matters here is that this class keeps beating
/// through a dead network, refuses to replay old beats, and stops the moment the
/// session does.
void main() {
  group('the ack', () {
    test('every outcome the server can name is mapped', () {
      // Spelled out one by one rather than compared in a loop: these four strings
      // are the contract with `record_heartbeat()`.
      expect(HeartbeatOutcome.fromDb('recorded'), HeartbeatOutcome.recorded);
      expect(HeartbeatOutcome.fromDb('duplicate'), HeartbeatOutcome.duplicate);
      expect(HeartbeatOutcome.fromDb('throttled'), HeartbeatOutcome.throttled);
    });

    test('an answer this build does not know is still an answer', () {
      // A newer server may add an outcome. Treating it as a failure would make an
      // honest client believe it never reached the database, which is the one
      // thing a beat exists to prove.
      expect(HeartbeatOutcome.fromDb('queued_for_review'), HeartbeatOutcome.unknown);
      expect(HeartbeatOutcome.fromDb(null), HeartbeatOutcome.unknown);
      // ...and the ack that wraps it still says "the attempt is alive", which is
      // all a beat claims.
      expect(
        HeartbeatAck(outcome: HeartbeatOutcome.unknown).provesLiveness,
        isTrue,
      );
    });

    test('only a stored beat grew the table', () {
      expect(HeartbeatOutcome.recorded.stored, isTrue);
      // A throttled beat and a replayed one both prove the client is alive without
      // adding a row: normal, not an error.
      expect(HeartbeatOutcome.duplicate.stored, isFalse);
      expect(HeartbeatOutcome.throttled.stored, isFalse);
      expect(HeartbeatOutcome.unknown.stored, isFalse);
    });
  });

  group('the cadence', () {
    test('one beat goes out immediately, then one per cadence', () async {
      // 20 ms instead of 15 s: the assertion is that the timer is wired to
      // [ProctoringHeartbeatService.cadence] at all, and fifteen seconds per
      // sample would make this suite unusable.
      final repo = _FakeProctoringRepository();
      final service = ProctoringHeartbeatService(
        repo,
        cadence: const Duration(milliseconds: 20),
      );
      addTearDown(service.dispose);

      service.start('sub-1');
      expect(repo.beats, hasLength(1), reason: 'the first beat is immediate');

      await Future<void>.delayed(const Duration(milliseconds: 110));
      expect(repo.beats.length, greaterThanOrEqualTo(3));
      expect(service.beatsAcked, repo.beats.length);
    });

    test('starting twice for the same attempt does not stack timers', () async {
      final repo = _FakeProctoringRepository();
      final service = ProctoringHeartbeatService(
        repo,
        cadence: const Duration(milliseconds: 20),
      );
      addTearDown(service.dispose);

      service.start('sub-1');
      // A retried bootstrap (a rebuild, a resume that runs twice) must not double
      // the beat rate: the server would throttle it, and throttling honest
      // clients is what makes a coverage report noisy.
      service.start('sub-1');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(repo.beats.length, lessThanOrEqualTo(4));
    });

    test('a different attempt restarts the series instead of doubling it', () async {
      final repo = _FakeProctoringRepository();
      final service = ProctoringHeartbeatService(
        repo,
        cadence: const Duration(milliseconds: 20),
      );
      addTearDown(service.dispose);

      service.start('sub-1');
      // Let the first beat finish before switching attempts: two beats cannot be
      // in flight at once, so an immediate second `start` would find the first
      // one still on the wire and the restart would be invisible to this fake.
      await service.beatNow();
      service.start('sub-2');
      await service.beatNow();

      expect(service.submissionId, 'sub-2');
      expect(repo.beats.last.submissionId, 'sub-2');
    });

    test('stop cancels the timer for good', () async {
      final repo = _FakeProctoringRepository();
      final service = ProctoringHeartbeatService(
        repo,
        cadence: const Duration(milliseconds: 10),
      );
      addTearDown(service.dispose);

      service.start('sub-1');
      service.stop();
      final afterStop = repo.beats.length;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(service.isBeating, isFalse);
      expect(repo.beats, hasLength(afterStop));
    });

    test('a disposed service never beats again', () async {
      final repo = _FakeProctoringRepository();
      final service = ProctoringHeartbeatService(repo);
      service.start('sub-1');
      service.dispose();

      service.start('sub-1'); // ignored
      await service.beatNow(); // ignored

      expect(service.isBeating, isFalse);
      expect(repo.beats, hasLength(1));
    });
  });

  group('what travels with a beat', () {
    test('attempt id, camera state, version, clock and a fresh event id', () async {
      final repo = _FakeProctoringRepository();
      final now = DateTime.utc(2026, 5, 11, 9, 30);
      final service = ProctoringHeartbeatService(
        repo,
        appVersion: '1.0.0(12)',
        clock: () => now,
        newEventId: () => repo.nextEventId,
      );
      addTearDown(service.dispose);

      service.start('sub-1');
      await service.beatNow();

      final beat = repo.beats.first;
      expect(beat.submissionId, 'sub-1');
      expect(beat.cameraOk, isTrue);
      expect(beat.monitoringOk, isTrue);
      expect(beat.appVersion, '1.0.0(12)');
      // The device's own clock: stored for diagnostics only. Coverage is measured
      // on the server's `received_at`, so a wrong device clock cannot distort it.
      expect(beat.clientTime, now);
      // The idempotency key. A repeated id would be deduped server-side into one
      // row, which is the opposite of what a second beat means.
      expect(beat.clientEventId, 'event-1');

      repo.nextEventId = 'event-2';
      await service.beatNow();
      expect(repo.beats.last.clientEventId, 'event-2');
    });

    test('a monitor that is not monitoring says so', () async {
      final repo = _FakeProctoringRepository();
      final service = ProctoringHeartbeatService(repo);
      addTearDown(service.dispose);

      service.start('sub-1', cameraOk: false, monitoringOk: false);
      await service.beatNow();

      expect(repo.beats.last.cameraOk, isFalse);
      expect(repo.beats.last.monitoringOk, isFalse);
    });
  });

  group('when the network is the problem', () {
    test('a rejected beat is counted, never thrown, and the next tick tries again',
        () async {
      // The rule this test protects: a heartbeat is the least important thing the
      // client does. It may never interrupt the exam, and a lost beat is a gap in
      // the coverage report - which is exactly what the report is for.
      final repo = _FakeProctoringRepository()
        ..answer = (beat) async => throw const _Offline();
      final service = ProctoringHeartbeatService(repo);
      addTearDown(service.dispose);

      service.start('sub-1');
      await service.beatNow();

      expect(service.failures, greaterThanOrEqualTo(1));
      expect(service.beatsAcked, 0);
      expect(service.lastError, contains('network is unreachable'));

      repo.answer = (beat) async => HeartbeatAck(
            outcome: HeartbeatOutcome.recorded,
            recordedAt: beat.clientTime,
          );
      await service.beatNow();

      expect(service.beatsAcked, 1);
      expect(service.beatsStored, 1);
      expect(service.lastError, isNull);
    });

    test('a socket that never answers is written off, not retried in place',
        () async {
      // Not queued, not awaited forever: coverage is measured on when the server
      // received a beat, so a beat replayed after the connection returns would
      // fill the gap it exists to expose.
      final hang = Completer<HeartbeatAck>();
      final repo = _FakeProctoringRepository()..answer = (beat) => hang.future;
      final service = ProctoringHeartbeatService(
        repo,
        sendTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(service.dispose);
      addTearDown(
        () => hang.complete(HeartbeatAck(outcome: HeartbeatOutcome.recorded)),
      );

      service.start('sub-1');
      // Long enough for the 20 ms send deadline to expire: `beatNow` returns when
      // the beat it started is settled, and this one settles by timing out.
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(service.failures, greaterThanOrEqualTo(1));
      expect(service.lastError, contains('timed out'));
      // One attempt was made; nothing was kept back to send later.
      expect(repo.beats, hasLength(1));
    });

    test('a slow beat does not let the timer pile requests up behind it',
        () async {
      final hang = Completer<HeartbeatAck>();
      final repo = _FakeProctoringRepository()..answer = (beat) => hang.future;
      final service = ProctoringHeartbeatService(
        repo,
        cadence: const Duration(milliseconds: 10),
        sendTimeout: const Duration(seconds: 5),
      );
      addTearDown(service.dispose);
      addTearDown(
        () => hang.complete(HeartbeatAck(outcome: HeartbeatOutcome.recorded)),
      );

      service.start('sub-1'); // fires the first (hanging) beat
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await service.beatNow(); // also collapses into the in-flight beat

      expect(repo.beats, hasLength(1));
    });

    test('a throttled answer still counts, but adds no row', () async {
      // The server answers `throttled` when two beats land inside its 8 s window
      // (a resume and a timer colliding) and `duplicate` for a replay. Neither is
      // a client-side failure.
      final repo = _FakeProctoringRepository()
        ..answer = (beat) async => HeartbeatAck(
              outcome: HeartbeatOutcome.throttled,
              recordedAt: beat.clientTime,
            );
      final service = ProctoringHeartbeatService(repo);
      addTearDown(service.dispose);

      service.start('sub-1');
      await service.beatNow();

      expect(service.beatsAcked, 1);
      expect(service.beatsStored, 0);
      expect(service.failures, 0);
      expect(service.lastError, isNull);
    });
  });
}

/// What an unreachable Supabase call looks like to the repository layer.
class _Offline implements Exception {
  const _Offline();

  @override
  String toString() => 'SocketException: network is unreachable';
}

/// One beat, as the service sent it.
class _Beat {
  const _Beat({
    required this.submissionId,
    required this.cameraOk,
    required this.monitoringOk,
    required this.appVersion,
    required this.clientTime,
    required this.clientEventId,
  });

  final String submissionId;
  final bool cameraOk;
  final bool monitoringOk;
  final String? appVersion;
  final DateTime? clientTime;
  final String? clientEventId;
}

/// A proctoring repository that records beats and answers however the test says.
///
/// Deliberately not a mock: the contract being tested is "never throws and never
/// queues", so the interesting states are `answer` throwing, `answer` never
/// completing, and `answer` naming each of the server's outcomes.
class _FakeProctoringRepository implements ProctoringRepository {
  final List<_Beat> beats = <_Beat>[];

  /// The id the next beat is stamped with. Flipping it mid-test proves the
  /// service mints a *new* idempotency key for every beat rather than reusing one.
  String nextEventId = 'event-1';

  /// What the server answers. Defaults to the happy path; assign to make the
  /// network dead, hung, or answer `throttled`.
  Future<HeartbeatAck> Function(_Beat beat) answer = (beat) async => HeartbeatAck(
        outcome: HeartbeatOutcome.recorded,
        recordedAt: beat.clientTime,
        beatCount: 1,
      );

  @override
  Future<HeartbeatAck> recordHeartbeat({
    required String submissionId,
    bool cameraOk = true,
    bool monitoringOk = true,
    String? appVersion,
    DateTime? clientTime,
    String? clientEventId,
  }) {
    final beat = _Beat(
      submissionId: submissionId,
      cameraOk: cameraOk,
      monitoringOk: monitoringOk,
      appVersion: appVersion,
      clientTime: clientTime,
      clientEventId: clientEventId,
    );
    beats.add(beat);
    return answer(beat);
  }

  @override
  Future<({int warningCount, bool disqualified, bool flagged})> logViolation({
    required String submissionId,
    required Violation violation,
  }) =>
      throw UnimplementedError('the heartbeat service never logs violations');

  @override
  Stream<List<Map<String, dynamic>>> watchLogs(String submissionId) =>
      const Stream<List<Map<String, dynamic>>>.empty();
}
