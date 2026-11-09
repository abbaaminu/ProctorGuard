import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/supabase_service.dart';
import '../../../../core/widgets/home_button.dart';
import '../../../proctoring/domain/entities/proctoring_risk.dart';
import '../../../proctoring/domain/entities/violation.dart';
import '../../../proctoring/presentation/widgets/risk_index_chip.dart';
import '../../domain/repositories/dashboard_repository.dart';
import '../providers/dashboard_providers.dart';
import 'analytics_page.dart';

/// Streams `proctoring_logs` and `exam_submissions` for a given exam via
/// Supabase Realtime, so supervisors see violations and status changes as
/// they happen — no polling. RLS is what scopes the rows: since
/// `20261109090000_supervisor_exam_assignments.sql` a supervisor reads the
/// attempts and the logs of the papers they were assigned
/// (`submissions_select_own_or_supervisor` → `can_supervise_exam()` in
/// `supabase/schema.sql`), a student only their own.
final examSubmissionsStreamProvider =
    StreamProvider.family<List<Map<String, dynamic>>, String>((ref, examId) {
  return SupabaseService.instance.client
      .from('exam_submissions')
      .stream(primaryKey: ['id'])
      .eq('exam_id', examId)
      .order('started_at');
});

/// `id -> display name` for every account the caller may read, so the monitor
/// shows "Aisha Bello" instead of a raw uuid.
///
/// The table is `profiles`, not `users`: the schema has no `public.users` at all
/// (only `auth.users`, which PostgREST does not expose, plus `public.profiles`,
/// 1:1 with it - see `profile_repository_impl.dart`). Pointing this stream at
/// `users` made every roster read fail with `42P01 relation "public.users" does
/// not exist`, so the monitor showed a raw uuid for a whole exam and said
/// nothing about why - the fallback label is built from the id, e.g.
/// `Student <uuid>`. `profiles_select_own_or_staff` is what a supervisor's
/// session reads through, and since
/// `20261109090000_supervisor_exam_assignments.sql` that read is scoped to the
/// people a supervisor is accountable for (`can_read_profile()`): a student with
/// an attempt on one of their papers, one on a paper's borrow list, or one a
/// labelled paper of theirs is aimed at. Those are exactly the ids this map is
/// asked about, so the roster still names every row it shows - another account's
/// profile is not readable at all, where it used to be readable
/// institution-wide.
final accountNamesProvider = StreamProvider<Map<String, String>>((ref) {
  return SupabaseService.instance.client.from('profiles').stream(
        primaryKey: ['id'],
      ).map((rows) => {
            for (final row in rows)
              row['id'] as String: _displayName(row),
          });
});

/// Live violation feed for **one** exam.
///
/// `proctoring_logs` carries no `exam_id` (it hangs off `submission_id`), so
/// this streams the bounded log feed and filters it against this exam's
/// submission ids — the previous version ignored `examId` altogether, which
/// meant the "live feed" for exam A also listed incidents from exam B.
///
/// The subscription does not restart when the roster changes: the filter is
/// applied on the stream, so a new submission is picked up without dropping
/// buffered rows. For very large exams, put the join in a Postgres view and
/// stream that instead.
final liveViolationFeedProvider =
    StreamProvider.family<List<Map<String, dynamic>>, String>((ref, examId) {
  final submissionIds = ref.watch(examSubmissionsStreamProvider(examId)).maybeWhen(
        data: (rows) => rows.map((row) => row['id'] as String).toSet(),
        orElse: () => const <String>{},
      );

  return SupabaseService.instance.client
      .from('proctoring_logs')
      .stream(primaryKey: ['id'])
      .order('timestamp', ascending: false)
      .limit(200)
      .map((rows) => rows
          .where((row) => submissionIds.contains(row['submission_id']))
          .toList());
});

/// How long an ongoing attempt may go without a heartbeat before the monitor
/// stops calling its proctoring live.
///
/// The client beats every 15s (`ProctoringHeartbeatService`) and
/// `record_heartbeat()` stores at most one beat per 8s, so 45s is three missed
/// beats: tolerant enough that one dropped request, a sleeping screen or a slow
/// upload does not blink a student's row, tight enough that a client that died a
/// minute ago is not still painted as watched.
const heartbeatSilence = Duration(seconds: 45);

/// What the roster can say about an attempt's proctoring client from
/// `exam_submissions.last_heartbeat_at` alone.
///
/// Three states, because two would lie: [live], [silent] (it checked in, then
/// stopped) and [never] (`NULL` — nothing ever checked in, which is *not*
/// evidence of a clean sitting). Only a running attempt has a state at all: a
/// submitted or disqualified row is over, and its beats belong to the coverage
/// report rather than to the live grid.
enum ProctorPulse { live, silent, never }

/// The pulse of [row] at [now], or `null` when the row cannot have one (see
/// [ProctorPulse]).
///
/// Reads the row the realtime stream already delivered — `record_heartbeat()`
/// stamps `last_heartbeat_at` in the same transaction as the beat, so every
/// accepted beat arrives here as an UPDATE and the grid refreshes itself without
/// polling or a second query.
ProctorPulse? proctorPulseFor(Map<String, dynamic> row, {DateTime? now}) {
  if (row['status'] != 'ongoing') return null;
  final raw = row['last_heartbeat_at'];
  final beat = raw is String ? DateTime.tryParse(raw) : null;
  if (beat == null) return ProctorPulse.never;
  final silence = (now ?? DateTime.now()).toUtc().difference(beat.toUtc());
  return silence <= heartbeatSilence ? ProctorPulse.live : ProctorPulse.silent;
}

/// The roster's wording for [pulse], given the beat that produced it.
///
/// A silent row prints *how long* it has been quiet: "silent 3m" is a question a
/// supervisor can act on, "silent" on its own is not. Lower case, so the words
/// read as part of the "Status: …" line they follow.
String proctorPulseText(
  ProctorPulse pulse, {
  required DateTime now,
  Object? lastHeartbeatAt,
}) {
  switch (pulse) {
    case ProctorPulse.live:
      return 'proctoring live';
    case ProctorPulse.silent:
      final beat =
          lastHeartbeatAt is String ? DateTime.tryParse(lastHeartbeatAt) : null;
      final quiet =
          beat == null ? heartbeatSilence : now.toUtc().difference(beat.toUtc());
      return 'proctoring silent ${_quietFor(quiet)}';
    case ProctorPulse.never:
      // Deliberately not "no violations": silence from the client is the state
      // this row exists to tell apart from a clean sitting.
      return 'no proctoring signal';
  }
}

/// `45s` / `12m` / `2h`, rounded down, never negative — a device clock ahead of
/// the server must not print a beat that has not happened yet.
String _quietFor(Duration quiet) {
  final seconds = quiet.isNegative ? 0 : quiet.inSeconds;
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m';
  return '${seconds ~/ 3600}h';
}

final submissionResetInFlightProvider =
    StateProvider.family<bool, String>((ref, id) => false);

/// Whether a supervisor's `resolve_flagged_attempt` call for one attempt is in
/// flight, so the two decision buttons disable while it runs (a double-tap must
/// not look like two decisions - the RPC would refuse the second anyway, but the
/// console should not offer it).
final attemptResolutionInFlightProvider =
    StateProvider.family<bool, String>((ref, id) => false);

/// `profiles.full_name`, falling back to the address (never an empty tile).
String _displayName(Map<String, dynamic> row) {
  final name = (row['full_name'] as String? ?? '').trim();
  if (name.isNotEmpty) return name;
  final email = (row['email'] as String? ?? '').trim();
  return email.isEmpty ? 'Unknown account' : email;
}

/// `proctoring_logs.timestamp` → `HH:mm:ss`, or the raw value when it is not a
/// parseable timestamp (the feed must never crash on an unexpected shape).
String _clock(String? iso) {
  final parsed = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (parsed == null) return iso ?? '';
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(parsed.hour)}:${two(parsed.minute)}:${two(parsed.second)}';
}

class SupervisorDashboardPage extends ConsumerWidget {
  final String examId;
  final String examTitle;

  /// Whether this account may reset an attempt **at all** - the role gate's
  /// answer (`UserRole.canResetAttempts`, i.e. `is_attempt_resetter()`).
  final bool canResetAttempts;

  /// Whether this account may reset an attempt **on this paper**.
  ///
  /// The role gate answers the first question and the policy answers this one:
  /// `submissions_delete_supervisor` is
  /// `is_exam_supervisor() or owns_exam(exam_id)`, so an administrator or a
  /// supervisor may clear any sitting while a lecturer may clear only the papers
  /// they wrote. Offering the control on somebody else's paper would be an icon
  /// whose only outcome is "the server deleted nothing" - so the two booleans are
  /// asked together, and a caller that does not know the paper's author (the role
  /// gate's lecturer path does know: it only ever lists the lecturer's own papers)
  /// must pass `false` rather than guess.
  final bool canResetThisExam;

  const SupervisorDashboardPage({
    super.key,
    required this.examId,
    required this.examTitle,
    this.canResetAttempts = false,
    this.canResetThisExam = true,
  });

  /// Whether this account may resolve a flagged attempt **on this paper**.
  ///
  /// `resolve_flagged_attempt()` enforces `is_exam_supervisor() or
  /// owns_exam(exam_id)` - the same predicate `submissions_delete_supervisor` uses -
  /// which is exactly what [canResetThisExam] already answers, so the two controls
  /// appear together or not at all.
  bool get canResolveHere => canResetThisExam;

  /// Human wording for `proctoring_logs.action_type`, kept identical to the
  /// dashboard's incident labels so both consoles read the same.
  static const Map<String, String> actionLabels = {
    'looking_away': 'Looking away',
    'multiple_faces': 'Multiple faces',
    'no_face': 'No face',
    'app_minimized': 'Left the exam app',
    'audio_noise': 'Background noise',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final submissions = ref.watch(examSubmissionsStreamProvider(examId));
    final violations = ref.watch(liveViolationFeedProvider(examId));
    final names = ref.watch(accountNamesProvider);

    final roster = submissions.valueOrNull ?? const <Map<String, dynamic>>[];
    final nameById = names.valueOrNull ?? const <String, String>{};

    // One clock for the frame: the summary above the list and the rows inside it
    // must not disagree about which beats have gone quiet.
    final now = DateTime.now();

    // Attempts under review first. They are the only rows here that are waiting on
    // the person reading them - every other status is either still running or
    // finished - so the grid leads with the work rather than with the roster order.
    // Two filters rather than a comparator: `List.sort` is not stable, and the
    // stream's `started_at` order is worth keeping inside each group.
    final orderedRoster = <Map<String, dynamic>>[
      ...roster.where((row) => row['status'] == 'flagged_for_review'),
      ...roster.where((row) => row['status'] != 'flagged_for_review'),
    ];

    Future<void> resetAttempt(Map<String, dynamic> row) async {
      if (!canResetAttempts || !canResetThisExam) return;
      final submissionId = row['id'] as String;
      final inFlight =
          ref.read(submissionResetInFlightProvider(submissionId).notifier);
      if (inFlight.state) return;
      inFlight.state = true;
      final studentId = row['student_id'] as String;
      final studentName = nameById[studentId] ?? 'Student ${_shortId(studentId)}';
      try {
        final approved = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('Reset $studentName’s attempt?'),
            content: const Text(
              'This permanently deletes the attempt, saved answers and its '
              'proctoring incidents. The student can start this exam again from '
              'a fresh attempt. This cannot be undone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Reset attempt'),
              ),
            ],
          ),
        );
        if (approved != true || !context.mounted) return;
        final outcome = await ref
            .read(dashboardRepositoryProvider)
            .resetSubmission(submissionId);
        ref.invalidate(examSubmissionsStreamProvider(examId));
        ref.invalidate(liveViolationFeedProvider(examId));
        if (!context.mounted) return;
        // Both warnings are caveats on a reset that *did* happen, so they are
        // appended to the confirmation rather than replacing it — and a reset
        // with neither reads as the plain success it is.
        final warnings = <String>[
          if (outcome.storageWarning != null) outcome.storageWarning!,
          if (outcome.auditWarning != null) outcome.auditWarning!,
        ];
        final message = warnings.isEmpty
            ? 'Attempt reset. ${outcome.incidents} incident(s) and '
                '${outcome.snapshots} snapshot(s) removed.'
            : 'Attempt reset, but ${warnings.join('; ')}';
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(message),
            backgroundColor: warnings.isEmpty
                ? null
                : Theme.of(context).colorScheme.error,
          ));
      } on DashboardException catch (error) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(error.message),
            backgroundColor: Theme.of(context).colorScheme.error,
          ));
      } finally {
        if (context.mounted) inFlight.state = false;
      }
    }

    // submission id -> student name: a log row only knows its submission.
    final studentBySubmission = <String, String>{
      for (final row in roster)
        row['id'] as String: nameById[row['student_id'] as String] ??
            'Student ${_shortId(row['student_id'])}',
    };

    /// Decides a flagged attempt: `decision` is `'disqualify'` or `'clear'`.
    ///
    /// The row is the only place the console learns an attempt is waiting on a
    /// person, and the note is part of the record rather than a courtesy - the
    /// audit trail in `attempt_review_logs` is what an appeal is answered from, so
    /// the dialog asks for it before it asks for the decision.
    Future<void> resolveAttempt(
      Map<String, dynamic> row,
      String decision,
    ) async {
      if (!canResolveHere) return;
      final submissionId = row['id'] as String;
      final inFlight =
          ref.read(attemptResolutionInFlightProvider(submissionId).notifier);
      if (inFlight.state) return;
      inFlight.state = true;
      final studentId = row['student_id'] as String;
      final studentName =
          nameById[studentId] ?? 'Student ${_shortId(studentId)}';
      final disqualify = decision == 'disqualify';
      final note = TextEditingController();
      try {
        final approved = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(
              disqualify
                  ? 'Disqualify $studentName?'
                  : 'Unlock $studentName’s attempt?',
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  disqualify
                      ? 'The attempt is marked disqualified and does not count. '
                          'The evidence stays on the record, and the student '
                          'cannot start this paper again without a reset.'
                      : 'The review flag is cleared and the attempt is restored '
                          'to submitted, marked from the answers already saved. '
                          'Subjective answers can be marked afterwards as usual. '
                          'The student can sit this paper again only if you also '
                          'reset the attempt; until then this one is their '
                          'attempt.',
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('resolve-note'),
                  controller: note,
                  maxLength: 2000,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Note for the record',
                    helperText: 'Stored with the decision and the reviewer’s name.',
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: Key('resolve-confirm-$submissionId'),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(disqualify ? 'Disqualify' : 'Unlock'),
              ),
            ],
          ),
        );
        if (approved != true || !context.mounted) return;

        final trimmed = note.text.trim();
        final outcome = await ref
            .read(dashboardRepositoryProvider)
            .resolveFlaggedAttempt(
              submissionId,
              decision: decision,
              note: trimmed.isEmpty ? null : trimmed,
            );
        ref.invalidate(examSubmissionsStreamProvider(examId));
        ref.invalidate(liveViolationFeedProvider(examId));
        if (!context.mounted) return;
        final message = switch (outcome) {
          'disqualified' => 'Attempt disqualified.',
          'submitted' => 'Attempt unlocked and restored for marking.',
          // The RPC is idempotent: an attempt somebody else already resolved
          // answers with the status it holds rather than a second decision.
          '' => 'Attempt resolved.',
          _ => 'Attempt was already resolved (status: $outcome).',
        };
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      } on DashboardException catch (error) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(error.message),
            backgroundColor: Theme.of(context).colorScheme.error,
          ));
      } finally {
        note.dispose();
        if (context.mounted) inFlight.state = false;
      }
    }

    // Flags are counted from the feed that is already scoped to this exam.
    final flagsBySubmission = <String, int>{};
    for (final log in violations.valueOrNull ?? const <Map<String, dynamic>>[]) {
      final id = log['submission_id'] as String;
      flagsBySubmission[id] = (flagsBySubmission[id] ?? 0) + 1;
    }

    // The *kinds* of signal behind those flags, which is what the risk index
    // reads: the feed is the same exam-scoped log stream, so the index needs no
    // extra query and cannot disagree with the "N flags" printed beside it.
    //
    // A row whose `action_type` this build does not know still counts as a flag
    // (see [_signalFor]) but does not widen the set of distinct signals, so one
    // unreadable row cannot inflate the mix.
    final signalsBySubmission = <String, Set<ViolationType>>{};
    for (final log in violations.valueOrNull ?? const <Map<String, dynamic>>[]) {
      final signal = _signalFor(log['action_type'] as String?);
      if (signal == null) continue;
      (signalsBySubmission[log['submission_id'] as String] ??=
              <ViolationType>{})
          .add(signal);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Live Monitor — $examTitle'),
        actions: [
          // Back to whichever landing page this console was opened from, without
          // unwinding the stack by hand - see [HomeButton].
          const HomeButton(key: Key('monitor-home')),
          IconButton(
            key: const Key('monitor-analytics'),
            tooltip: 'Analytics',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const AnalyticsPage()),
            ),
            icon: const Icon(Icons.analytics_outlined),
          ),
        ],
      ),
      body: Row(
        children: [
          // ---- Student status grid --------------------------------------
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _RosterSummary(roster: roster, now: now),
                Expanded(
                  child: submissions.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (error, _) => _FeedError(
                      message: 'Could not load the roster.',
                      detail: '$error',
                    ),
                    data: (rows) => rows.isEmpty
                        ? const _FeedEmpty(
                            message: 'No student has started this exam yet.',
                          )
                        : ListView.builder(
                            itemCount: orderedRoster.length,
                            itemBuilder: (context, i) {
                              final row = orderedRoster[i];
                              final status = row['status'] as String;
                              final score = row['score'];
                              final flags = flagsBySubmission[row['id']] ?? 0;

                              // Was anything actually watching? An empty
                              // violation feed and a client that stopped
                              // reporting look identical without this.
                              final pulse = proctorPulseFor(row, now: now);
                              final pulseText = pulse == null
                                  ? ''
                                  : '  •  ${proctorPulseText(pulse, now: now, lastHeartbeatAt: row['last_heartbeat_at'])}';

                              // The same evidence the "N flags" count is made of,
                              // scored: flags are the strikes, the mapped signals
                              // are the mix. Zero flags short-circuits to "no
                              // evidence", so an untouched attempt is never
                              // labelled.
                              final risk = ProctoringRisk.fromViolations(
                                signalsBySubmission[row['id']] ??
                                    const <ViolationType>{},
                                serverStrikes: flags,
                              );

                              return Card(
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                child: ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: _statusColor(status),
                                    child: Text(
                                      status.substring(0, 1).toUpperCase(),
                                      style:
                                          const TextStyle(color: Colors.white),
                                    ),
                                  ),
                                  title: Text(
                                    nameById[row['student_id'] as String] ??
                                        'Student ${_shortId(row['student_id'])}',
                                  ),
                                  subtitle: Text(
                                    'Status: $status'
                                    '${score != null ? '  •  Score: $score' : ''}'
                                    '$pulseText',
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      // Band word only: the row already prints
                                      // its flag count, and the tooltip carries
                                      // the breakdown of what the score is made
                                      // of. Hidden at zero flags so a clean row
                                      // stays as quiet as it was.
                                      if (flags > 0) ...[
                                        RiskIndexChip(
                                          key: Key('risk-${row['id']}'),
                                          risk: risk,
                                          compact: true,
                                        ),
                                        const SizedBox(width: 8),
                                      ],
                                      Text(
                                        '$flags flags',
                                        style: TextStyle(
                                          color: flags > 0
                                              ? Colors.orange
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                        ),
                                      ),
                                      // The decision controls: only on an attempt
                                      // that is actually waiting for one, and only
                                      // for the tier the RPC accepts.
                                      if (canResolveHere &&
                                          status == 'flagged_for_review')
                                        Consumer(
                                          builder: (context, watchRef, _) {
                                            final resolving = watchRef.watch(
                                              attemptResolutionInFlightProvider(
                                                row['id'] as String,
                                              ),
                                            );
                                            if (resolving) {
                                              return const Padding(
                                                padding: EdgeInsets.symmetric(
                                                  horizontal: 12,
                                                ),
                                                child: SizedBox(
                                                  height: 18,
                                                  width: 18,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                  ),
                                                ),
                                              );
                                            }
                                            return Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                // The unlock: the control that
                                                // makes the student's exam
                                                // attempt usable again. The RPC
                                                // is `resolve_flagged_attempt`
                                                // with 'clear', which restores the
                                                // attempt to 'submitted' and marks
                                                // it from the answers already
                                                // saved - so the word on the
                                                // console is "unlock", and the
                                                // tooltip says what that means.
                                                IconButton(
                                                  key: Key(
                                                    'resolve-clear-${row['id']}',
                                                  ),
                                                  tooltip: 'Unlock: clear the '
                                                      'review flag and restore '
                                                      'the attempt to submitted '
                                                      'for marking',
                                                  onPressed: () => resolveAttempt(
                                                    row,
                                                    'clear',
                                                  ),
                                                  icon: const Icon(
                                                    Icons.lock_open_outlined,
                                                    color: Colors.green,
                                                  ),
                                                ),
                                                IconButton(
                                                  key: Key(
                                                    'resolve-disqualify-${row['id']}',
                                                  ),
                                                  tooltip: 'Disqualify this '
                                                      'attempt',
                                                  onPressed: () => resolveAttempt(
                                                    row,
                                                    'disqualify',
                                                  ),
                                                  icon: const Icon(
                                                    Icons.gavel,
                                                    color: Colors.redAccent,
                                                  ),
                                                ),
                                              ],
                                            );
                                          },
                                        ),
                                      if (canResetAttempts && canResetThisExam)
                                        Consumer(
                                          builder: (context, watchRef, _) {
                                            final resetting = watchRef.watch(
                                              submissionResetInFlightProvider(
                                                row['id'] as String,
                                              ),
                                            );
                                            return IconButton(
                                              key: Key(
                                                'reset-attempt-${row['id']}',
                                              ),
                                              tooltip: 'Reset attempt',
                                              onPressed: resetting
                                                  ? null
                                                  : () => resetAttempt(row),
                                              icon: resetting
                                                  ? const SizedBox(
                                                      width: 18,
                                                      height: 18,
                                                      child:
                                                          CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                    )
                                                  : const Icon(
                                                      Icons.restart_alt,
                                                      color: Colors.redAccent,
                                                    ),
                                            );
                                          },
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          // ---- Live violation feed ---------------------------------------
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('Live Violation Feed',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
                Expanded(
                  child: violations.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (error, _) => _FeedError(
                      message: 'Could not load violations.',
                      detail: '$error',
                    ),
                    data: (logs) => logs.isEmpty
                        ? const _FeedEmpty(
                            message: 'No violations recorded for this exam.',
                          )
                        : ListView.builder(
                            itemCount: logs.length,
                            itemBuilder: (context, i) {
                              final log = logs[i];
                              final type =
                                  log['action_type'] as String? ?? 'unknown';

                              return ListTile(
                                dense: true,
                                leading: const Icon(Icons.flag,
                                    color: Colors.orange, size: 18),
                                title: Text(actionLabels[type] ?? type),
                                subtitle: Text(
                                  '${studentBySubmission[log['submission_id']] ?? 'Unknown student'}'
                                  '  •  ${_clock(log['timestamp'] as String?)}',
                                ),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One-line roll-up above the student list.
class _RosterSummary extends StatelessWidget {
  const _RosterSummary({required this.roster, required this.now});

  final List<Map<String, dynamic>> roster;

  /// The frame's clock, so this sentence and the rows below it agree on which
  /// beats have gone quiet (see [proctorPulseFor]).
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final total = roster.length;
    final ongoing = roster.where((row) => row['status'] == 'ongoing').length;
    final submitted =
        roster.where((row) => row['status'] == 'submitted').length;
    final disqualified =
        roster.where((row) => row['status'] == 'disqualified').length;
    // Attempts waiting on a decision come first in the list, and first here too:
    // they are work, not a statistic.
    final flagged =
        roster.where((row) => row['status'] == 'flagged_for_review').length;
    // Running attempts whose proctoring client has gone quiet (or never checked
    // in). Counted here because it is the one number that separates "nothing
    // happened" from "nothing was watching" - the case an empty violation feed
    // used to hide. It marks a row for a human; it ends nothing.
    final quiet = roster.where((row) {
      final pulse = proctorPulseFor(row, now: now);
      return pulse == ProctorPulse.silent || pulse == ProctorPulse.never;
    }).length;

    final warn = flagged > 0 || quiet > 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        '$total attempt(s)  •  $ongoing in progress  •  $submitted submitted  •  '
        '$disqualified disqualified'
        '${flagged > 0 ? '  •  $flagged under review' : ''}'
        '${quiet > 0 ? '  •  $quiet not reporting' : ''}',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: warn
                  ? Colors.orange
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

/// `proctoring_logs.action_type` → the signal it is, or `null` when this build
/// does not know that type.
///
/// Nullable rather than [ViolationType.fromDb], which *throws* on drift: this
/// runs against a live stream that a newer server can add a type to, and a
/// supervisor's console must not take an `ArgumentError` because one row came
/// from the future. The unknown row still counts as a flag; it just cannot widen
/// the mix of distinct signals the risk index prices (see the caller).
ViolationType? _signalFor(String? actionType) {
  if (actionType == null) return null;
  try {
    return ViolationType.fromDb(actionType);
  } on ArgumentError {
    return null;
  }
}

/// First eight characters of a uuid, for the fallback student label.
String _shortId(Object? value) {
  final text = value is String ? value : '';
  return text.length <= 8 ? text : text.substring(0, 8);
}

/// Avatar colour per submission status.
Color _statusColor(String status) => switch (status) {
      'ongoing' => Colors.blue,
      'flagged_for_review' => Colors.orange,
      'submitted' => Colors.green,
      'disqualified' => Colors.red,
      _ => Colors.grey,
    };

/// Centred placeholder for an empty pane.
class _FeedEmpty extends StatelessWidget {
  const _FeedEmpty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      );
}

/// Centred failure state for a pane that could not load (offline, RLS, …) —
/// deliberately not a silent empty list, which is indistinguishable from
/// "no incidents were recorded".
class _FeedError extends StatelessWidget {
  const _FeedError({required this.message, required this.detail});

  final String message;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, color: theme.colorScheme.error),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
