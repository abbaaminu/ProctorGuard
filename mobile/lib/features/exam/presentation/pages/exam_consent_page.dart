import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/services/crash_reporting.dart';
import '../../../../core/widgets/responsive_layout.dart';
import '../../domain/entities/exam.dart';
import '../../domain/entities/proctor_consent.dart';
import '../../domain/repositories/consent_repository.dart';
import '../widgets/exam_instructions_dialog.dart';

/// The proctoring consent notice, and the only way past it.
///
/// Shown **before** the device check and before the instructions, because it is
/// the screen that explains what the rest of the exam is going to do: the camera,
/// the stills, who reads them and how long they are kept. Accepting writes a row
/// through `record_consent()`; declining leaves the portal without creating an
/// attempt - and, since `submissions_insert_own_ongoing` now requires a consent
/// row, without any way of creating one from a patched client either.
///
/// Pops `true` only when the acceptance is stored *and* the stored version is the
/// one the server has in force. Every other exit (back button, close, an error)
/// pops `false`, which the portal reads as "do not start".
///
/// The wording itself lives in [ProctorConsentConfig] - one constant, versioned -
/// so this file is layout and interaction only.
class ExamConsentPage extends ConsumerStatefulWidget {
  const ExamConsentPage({super.key, required this.exam, this.repository});

  /// The paper being started. Its title heads the screen so the notice is never
  /// ambiguous about which sitting it applies to.
  final Exam exam;

  /// Injected in tests; defaults to the provider (which `main()` binds to
  /// `ConsentRepositoryImpl`).
  final ConsentRepository? repository;

  @override
  ConsumerState<ExamConsentPage> createState() => _ExamConsentPageState();
}

class _ExamConsentPageState extends ConsumerState<ExamConsentPage> {
  ConsentRepository get _repository =>
      widget.repository ?? ref.read(consentRepositoryProvider);

  /// The checkbox. Accept stays disabled until it is ticked: a notice a student
  /// can accept without touching is a notice nobody read.
  bool _accepted = false;

  /// One accept in flight; a double tap must not race the pop. (The RPC is
  /// idempotent, so the second call would be harmless - the second *pop* is not.)
  bool _saving = false;

  /// The server's version, when it could be read and it differs from the one this
  /// build displays. Null means "no reason to complain", including the case where
  /// the read failed: a diagnostic must never be the thing that blocks a student.
  String? _serverVersion;

  /// Set when `record_consent()` answered `is_current: false` - the acceptance
  /// was stored, but for wording the server has replaced.
  bool _rejectedAsStale = false;

  /// An error from the accept call, shown above the button.
  String? _error;

  /// True when accepting cannot possibly work from this build, so the checkbox is
  /// disabled and the block explains why instead of leaving a dead button.
  bool get _stale => _rejectedAsStale ||
      (_serverVersion != null && _serverVersion != ProctorConsentConfig.version);

  @override
  void initState() {
    super.initState();
    _checkVersion();
  }

  /// Compares the bundled wording against the server's, once, in the background.
  ///
  /// A mismatch is the one case the student cannot fix from here - it needs a new
  /// build - so it is worth an early, specific sentence rather than the generic
  /// refusal the insert would have produced later.
  Future<void> _checkVersion() async {
    try {
      final serverVersion = await _repository.currentServerVersion();
      if (!mounted) return;
      if (serverVersion != null) {
        setState(() => _serverVersion = serverVersion);
      }
    } catch (_) {
      // Diagnostics only: the accept call is the authority on whether the
      // acceptance counts, and it reports `is_current` itself.
    }
  }

  Future<void> _accept() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final record = await _repository.recordConsent(
        examId: widget.exam.id,
        version: ProctorConsentConfig.version,
      );
      if (!mounted) return;

      if (!record.isCurrentVersion) {
        // Stored, but for wording the server has replaced. Staying on the screen
        // is the honest outcome: the acceptance did not unlock anything, and the
        // student needs to know why rather than being sent to an insert that will
        // be refused.
        setState(() {
          _saving = false;
          _rejectedAsStale = true;
          _error = ProctorConsentConfig.staleVersionMessage;
        });
        return;
      }

      Navigator.of(context).pop(true);
    } catch (error, stackTrace) {
      await CrashReporting.captureException(
        error,
        stackTrace,
        context: 'ExamConsentPage failed to record consent',
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        // The insert policy refuses the attempt without this row, so the message
        // has to say "try again", not "it does not matter".
        _error = 'Your acceptance could not be saved. Check your connection and '
            'try again — the exam cannot start until it is.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stale = _stale;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const Key('consent-decline'),
          tooltip: 'Not now',
          // Nothing has been written yet, so leaving must stay possible - the
          // consequence is simply that no attempt can be started.
          onPressed: () => Navigator.of(context).pop(false),
          icon: const Icon(Icons.close),
        ),
        title: const Text('Consent'),
      ),
      body: ResponsiveContent(
        maxWidth: 760,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: ListView(
          key: const Key('exam-consent-page'),
          children: [
            Text(
              ProctorConsentConfig.title,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            Text(
              widget.exam.title,
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 12),
            Text(
              ProctorConsentConfig.preamble,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            // The version is on the screen, not hidden in an about box: a student
            // (or an appeal) can see which wording they accepted, and it is the
            // same string the database stores.
            Text(
              'Notice version ${ProctorConsentConfig.version}',
              key: const Key('consent-version'),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            for (final clause in ProctorConsentConfig.clauses) ...[
              _ClauseCard(clause: clause),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 6),
            TextButton.icon(
              key: const Key('consent-instructions'),
              onPressed: () => showExamInstructions(context, exam: widget.exam),
              icon: const Icon(Icons.menu_book_outlined),
              label: const Text('How the proctor works, in detail'),
            ),
            const Divider(height: 24),
            if (stale) ..._staleNotice(theme),
            CheckboxListTile(
              key: const Key('consent-accept-checkbox'),
              value: _accepted,
              onChanged: _saving || stale
                  ? null
                  : (value) => setState(() => _accepted = value ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: Text(
                ProctorConsentConfig.acceptanceLabel,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 8),
            if (_error != null) ...[
              Text(
                _error!,
                key: const Key('consent-error'),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
              const SizedBox(height: 8),
            ],
            FilledButton(
              key: const Key('consent-accept-button'),
              onPressed: _accepted && !_saving && !stale ? _accept : null,
              child: _saving
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Accept and continue'),
            ),
            const SizedBox(height: 12),
            Text(
              'Without accepting you cannot sit this proctored exam. Nothing '
              'has been recorded yet, and nothing will be if you leave now.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }


  /// The "your app is out of date" block. It says what to do, which is not
  /// something the student can fix on this screen - so the checkbox underneath it
  /// is disabled rather than being a dead end.
  List<Widget> _staleNotice(ThemeData theme) => [
        Container(
          key: const Key('consent-stale-notice'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.system_update_outlined,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  ProctorConsentConfig.staleVersionMessage,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ];
}

/// One clause: heading, body, and an icon so the five questions a notice has to
/// answer - what, who, how long, why, who to ask - are visible at a glance.
class _ClauseCard extends StatelessWidget {
  const _ClauseCard({required this.clause});

  final ConsentClause clause;

  /// Keyed by [ConsentClause.id], with a neutral fallback: adding a clause must
  /// not need a code change here to render.
  static const Map<String, IconData> _icons = <String, IconData>{
    'capture': Icons.videocam_outlined,
    'stills': Icons.photo_camera_outlined,
    'who': Icons.visibility_outlined,
    'retention': Icons.schedule_outlined,
    'decisions': Icons.gavel_outlined,
    'contact': Icons.support_agent_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      key: Key('consent-clause-${clause.id}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _icons[clause.id] ?? Icons.info_outline,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    clause.heading,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(clause.body, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

