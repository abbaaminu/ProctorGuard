import '../../../admin/domain/entities/search_query.dart';

/// The live monitor's search vocabulary.
///
/// The roster there is a stream of raw `exam_submissions` rows (the page renders
/// them without an entity of their own, because a realtime feed has to survive a
/// shape it does not recognise), so this helper reads the three columns the
/// monitor shows — student, status, score — plus the ids an administrator may
/// have been given over the phone. The status facet is built from the statuses
/// **present** rather than the four the app knows, so an unrecognised value is
/// filterable instead of invisible.
abstract final class AttemptSearch {
  static const String statusGroup = 'status';

  /// The order the facet lists statuses in: the ones waiting on a person first,
  /// which is also the order the roster itself sorts by.
  static const List<String> _preferred = <String>[
    'flagged_for_review',
    'ongoing',
    'submitted',
    'disqualified',
  ];

  static List<SearchFilterGroup> groupsFor(List<Map<String, dynamic>> rows) {
    final present = <String>{
      for (final row in rows)
        if ((row['status'] as String? ?? '').trim().isNotEmpty)
          (row['status'] as String).trim(),
    };
    final ordered = <String>[
      for (final status in _preferred)
        if (present.remove(status)) status,
      ...(present.toList()..sort()),
    ];

    return <SearchFilterGroup>[
      SearchFilterGroup(
        id: statusGroup,
        label: 'Status',
        options: <SearchFilterOption>[
          for (final status in ordered)
            SearchFilterOption(value: status, label: statusLabel(status)),
        ],
      ),
    ];
  }

  /// One attempt as a searchable record.
  ///
  /// [flags] is the incident count the page already has from its exam-scoped
  /// violation feed; it is searchable as a number and as "no flags", because
  /// "which of these had nothing on them?" is a question a supervisor asks.
  static SearchRecord recordFor(
    Map<String, dynamic> row, {
    required String studentName,
    int flags = 0,
  }) {
    final status = (row['status'] as String? ?? '').trim();
    final score = row['score'];

    return SearchRecord(
      fields: <String?>[
        studentName,
        status,
        status.isEmpty ? null : statusLabel(status),
        row['id'] as String?,
        row['student_id'] as String?,
        score?.toString(),
        flags == 0 ? 'no flags' : '$flags flags',
      ],
      attributes: <String, String?>{statusGroup: status},
    );
  }

  /// The rows of [rows] that survive [query], in their original order.
  static List<Map<String, dynamic>> filter(
    List<Map<String, dynamic>> rows,
    SearchQuery query, {
    required Map<String, String> nameById,
    Map<String, int> flagsBySubmission = const <String, int>{},
  }) {
    if (!query.isActive) return rows;
    return <Map<String, dynamic>>[
      for (final row in rows)
        if (query.matches(
          recordFor(
            row,
            studentName: studentName(row, nameById),
            flags: flagsBySubmission[row['id']] ?? 0,
          ),
        ))
          row,
    ];
  }

  /// The name the roster prints for [row], the same fallback included.
  static String studentName(
    Map<String, dynamic> row,
    Map<String, String> nameById,
  ) {
    final id = row['student_id'] as String? ?? '';
    final known = nameById[id]?.trim() ?? '';
    if (known.isNotEmpty) return known;
    final short = id.length <= 8 ? id : id.substring(0, 8);
    return 'Student $short';
  }

  /// `flagged_for_review` → `Flagged for review`.
  ///
  /// Tolerant on purpose: the monitor must not crash on a status this build has
  /// never seen (that is how a new server state would arrive), so an unknown
  /// value is prettified rather than mapped through a switch that throws.
  static String statusLabel(String status) => switch (status) {
    'flagged_for_review' => 'Flagged for review',
    'ongoing' => 'In progress',
    'submitted' => 'Submitted',
    'disqualified' => 'Disqualified',
    _ =>
      status
          .replaceAll('_', ' ')
          .split(' ')
          .where((part) => part.isNotEmpty)
          .map((part) => part[0].toUpperCase() + part.substring(1))
          .join(' '),
  };
}
