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
/// they happen — no polling. RLS is what scopes the rows: a supervisor may read
/// every attempt and every log (see `submissions_select_own_or_supervisor` and
/// `profiles_select_own_or_staff` in `supabase/schema.sql`), a student only their
/// own.
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
/// session reads through, so the names are all there.
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

final submissionResetInFlightProvider =
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
  final bool canResetAttempts;
  const SupervisorDashboardPage({
    super.key,
    required this.examId,
    required this.examTitle,
    this.canResetAttempts = false,
  });

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

    Future<void> resetAttempt(Map<String, dynamic> row) async {
      if (!canResetAttempts) return;
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
                _RosterSummary(roster: roster),
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
                            itemCount: rows.length,
                            itemBuilder: (context, i) {
                              final row = rows[i];
                              final status = row['status'] as String;
                              final score = row['score'];
                              final flags = flagsBySubmission[row['id']] ?? 0;

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
                                    '${score != null ? '  •  Score: $score' : ''}',
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
                                      if (canResetAttempts)
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
  const _RosterSummary({required this.roster});

  final List<Map<String, dynamic>> roster;

  @override
  Widget build(BuildContext context) {
    final total = roster.length;
    final ongoing = roster.where((row) => row['status'] == 'ongoing').length;
    final submitted =
        roster.where((row) => row['status'] == 'submitted').length;
    final disqualified =
        roster.where((row) => row['status'] == 'disqualified').length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        '$total attempt(s)  •  $ongoing in progress  •  $submitted submitted  •  '
        '$disqualified disqualified',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
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
