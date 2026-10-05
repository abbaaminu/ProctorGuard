import 'package:flutter/material.dart';

import '../../domain/entities/proctoring_risk.dart';

/// The proctoring risk index as a chip: the band's word, the 0-100 score, and
/// the breakdown in the tooltip.
///
/// Exists as one widget rather than a colour choice per screen so the student's
/// own session and the supervisor's grid cannot disagree about what "High"
/// looks like. The band drives the colour (and the tooltip carries
/// [ProctoringRisk.explanation]), so the number is never the only thing saying
/// how bad a row is.
class RiskIndexChip extends StatelessWidget {
  const RiskIndexChip({
    super.key,
    required this.risk,
    this.compact = false,
    this.onDark = false,
  });

  final ProctoringRisk risk;

  /// Drops the score and keeps only the band's word — for the live monitor grid,
  /// where each row already carries its own "N flags" count.
  final bool compact;

  /// Set when the chip sits on the dark proctoring overlay rather than on a card
  /// surface. The band still picks the colour, but the two ends of the scale are
  /// re-picked for a black background: the light scheme's `onSurfaceVariant` is a
  /// *dark* grey and its `error` a dark red, which would read as "greyed out" and
  /// "muted" on black exactly when the student most needs to read them.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (risk.band) {
      RiskBand.low =>
        onDark ? Colors.white70 : theme.colorScheme.onSurfaceVariant,
      RiskBand.moderate => Colors.amber.shade800,
      RiskBand.high => Colors.deepOrange,
      RiskBand.critical => onDark ? Colors.redAccent : theme.colorScheme.error,
    };

    return Tooltip(
      message: 'Risk index ${risk.score}/100 — ${risk.explanation}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.speed, size: 12, color: color),
            const SizedBox(width: 4),
            Text(
              compact ? risk.label : '${risk.label} risk · ${risk.score}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
