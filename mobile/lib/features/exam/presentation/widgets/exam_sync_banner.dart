import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/services/offline_sync_service.dart';

/// The "your work is safe" strip that sits above the question.
///
/// It appears exactly while something the student typed has not reached the
/// server, and it distinguishes the two kinds of waiting: a delivery that is
/// still in flight, and one the network is holding ("Offline - syncing locally").
/// With an empty queue it renders nothing at all, so a normal online exam has no
/// banner to read.
///
/// It listens to [OfflineSyncService.changes] rather than being rebuilt by the
/// exam page, because the queue drains on its own schedule (a retry timer, an
/// `online` event, the app coming back to the foreground) - none of which the page
/// is involved in.
class ExamSyncBanner extends StatefulWidget {
  const ExamSyncBanner({super.key, required this.service});

  final OfflineSyncService service;

  @override
  State<ExamSyncBanner> createState() => _ExamSyncBannerState();
}

class _ExamSyncBannerState extends State<ExamSyncBanner> {
  late SyncState _state = widget.service.state;
  StreamSubscription<SyncState>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.service.changes.listen(_onState);
  }

  @override
  void didUpdateWidget(ExamSyncBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service == widget.service) return;
    unawaited(_subscription?.cancel());
    _state = widget.service.state;
    _subscription = widget.service.changes.listen(_onState);
  }

  void _onState(SyncState state) {
    if (!mounted) return;

    // Repaint only when something the banner actually renders changed. A delivery
    // pass emits twice (syncing on, then off) and an offline queue retries on a
    // backoff, so repainting on every emission would keep a dead-connection exam
    // scheduling frames for as long as it stayed offline.
    if (state.online == _state.online &&
        state.pending == _state.pending &&
        state.rejectedAnswers == _state.rejectedAnswers) {
      _state = state;
      return;
    }

    setState(() => _state = state);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Nothing pending: the server has everything, so there is nothing to say.
    if (!_state.hasPending && !_state.hasRejectedAnswers) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final offline = !_state.online;
    final warning = _state.hasRejectedAnswers;
    final color = offline || warning
        ? Colors.amber.shade800
        : theme.colorScheme.primary;

    return Container(
      key: const Key('exam-sync-banner'),
      width: double.infinity,
      color: color.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(
            warning
                ? Icons.warning_amber_outlined
                : offline
                    ? Icons.cloud_off
                    : Icons.cloud_upload_outlined,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _state.label,
              style: theme.textTheme.labelLarge?.copyWith(color: color),
            ),
          ),
          if (_state.hasPending)
            Text(
              '${_state.pending} to sync',
              style: theme.textTheme.labelSmall?.copyWith(color: color),
            )
          else
            Text(
              '${_state.rejectedAnswers} not saved',
              style: theme.textTheme.labelSmall?.copyWith(color: color),
            ),
        ],
      ),
    );
  }
}
