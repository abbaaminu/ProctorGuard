import 'package:flutter/material.dart';

import '../services/supabase_service.dart' show SupabaseInitStatus;

/// Shown when the app booted without a usable backend.
///
/// `main()` deliberately never throws (an exception before `runApp` renders as
/// a blank page, which is the classic Flutter Web startup failure), so this
/// screen is what turns a misconfigured or storage-restricted build into
/// something readable and actionable.
class SetupRequiredPage extends StatelessWidget {
  const SetupRequiredPage({
    super.key,
    required this.status,
    this.detail,
    this.storageBlocked = false,
  });

  final SupabaseInitStatus status;

  /// Raw error text from initialisation, when there was one.
  final String? detail;

  /// True when the runtime refused (browser) local storage, so sessions cannot
  /// survive a refresh.
  final bool storageBlocked;

  bool get _failed => status == SupabaseInitStatus.failed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final monospace = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _failed ? Icons.error_outline : Icons.settings_suggest_outlined,
                  size: 48,
                  color: _failed ? theme.colorScheme.error : null,
                ),
                const SizedBox(height: 12),
                Text(
                  _failed
                      ? 'Supabase failed to initialise'
                      : 'Supabase is not configured',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  _failed
                      ? 'The app started without a backend, so sign-in and data will not work.'
                      : 'This build has no SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY compiled in.',
                ),
                if (detail != null) ...[
                  const SizedBox(height: 12),
                  SelectableText(detail!, style: monospace),
                ],
                const SizedBox(height: 20),
                const Text('Run it with:'),
                const SizedBox(height: 6),
                const SelectableText(
                  'flutter run \\\n'
                  '  --dart-define=SUPABASE_URL=https://<project-ref>.supabase.co \\\n'
                  '  --dart-define=SUPABASE_PUBLISHABLE_KEY=<publishable/anon key>',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                const SizedBox(height: 12),
                Text(
                  'Helper script: .\\run_app.ps1   •   web: flutter run -d chrome',
                  style: monospace,
                ),
                if (storageBlocked) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Heads-up: this browser blocks local storage, so you will be '
                    'signed out whenever the page is refreshed.',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
