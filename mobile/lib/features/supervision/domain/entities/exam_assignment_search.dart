import '../../../admin/domain/entities/managed_account.dart';
import '../../../admin/domain/entities/search_query.dart';
import '../../../../core/utils/academic_catalog.dart';
import '../../../exam/domain/entities/exam.dart';

/// One paper on the Assign supervisors screen, with the supervisors on it.
///
/// The page already joins the two reads (`exams` and
/// `supervisor_exam_assignments`) to render a tile; naming that join lets the
/// search filter it without a second pass over three lists, and gives the
/// "assigned / unassigned" facet something to ask.
class ExamAssignmentRow {
  const ExamAssignmentRow({required this.exam, required this.supervisors});

  final Exam exam;

  /// The accounts assigned to this paper, in the order the dialog offers them.
  /// A row whose account the caller cannot read is dropped by the page, since
  /// rendering it would be an empty chip.
  final List<ManagedAccount> supervisors;

  bool get isAssigned => supervisors.isNotEmpty;
}

/// The search vocabulary of the Assign supervisors list.
///
/// Free text covers the paper (title, labels, duration, schedule, published or
/// draft) **and** the people on it (their names and addresses), because "who
/// runs CS101?" and "what does Dr Ada run?" are the same question asked from two
/// ends. The supervisor facet answers the other half — every paper nobody has
/// been assigned to yet, which is the state where only an administrator can open
/// it.
abstract final class ExamAssignmentSearch {
  static const String statusGroup = 'status';
  static const String facultyGroup = 'faculty';
  static const String departmentGroup = 'department';
  static const String levelGroup = 'level';
  static const String supervisorGroup = 'supervisor';

  static const String published = 'published';
  static const String draft = 'draft';
  static const String assigned = 'assigned';
  static const String unassigned = 'unassigned';

  static List<SearchFilterGroup> groupsFor(List<ExamAssignmentRow> rows) =>
      <SearchFilterGroup>[
        const SearchFilterGroup(
          id: statusGroup,
          label: 'Status',
          options: <SearchFilterOption>[
            SearchFilterOption(value: published, label: 'Published'),
            SearchFilterOption(value: draft, label: 'Draft'),
          ],
        ),
        SearchFilterGroup(
          id: facultyGroup,
          label: 'Faculty',
          options: SearchFacets.fromValues(
            rows.map((row) => row.exam.faculty),
            preferredOrder: AcademicCatalog.facultyNames,
          ),
        ),
        SearchFilterGroup(
          id: departmentGroup,
          label: 'Department',
          options: SearchFacets.fromValues(
            rows.map((row) => row.exam.department),
            preferredOrder: AcademicCatalog.allDepartments,
          ),
        ),
        SearchFilterGroup(
          id: levelGroup,
          label: 'Level',
          options: SearchFacets.fromValues(
            rows.map((row) => row.exam.level),
            preferredOrder: AcademicCatalog.levels,
          ),
        ),
        const SearchFilterGroup(
          id: supervisorGroup,
          label: 'Supervisor',
          options: <SearchFilterOption>[
            SearchFilterOption(value: unassigned, label: 'Nobody assigned'),
            SearchFilterOption(value: assigned, label: 'Assigned'),
          ],
        ),
      ];

  static SearchRecord recordFor(ExamAssignmentRow row) => SearchRecord(
    fields: <String?>[
      row.exam.title,
      row.exam.isPublished ? 'Published' : 'Draft',
      row.exam.targetLabel,
      row.exam.faculty,
      row.exam.department,
      row.exam.level,
      '${row.exam.durationMinutes} minutes',
      row.exam.scheduleLabel,
      for (final supervisor in row.supervisors) ...<String?>[
        supervisor.fullName,
        supervisor.email,
        supervisor.identityNumber,
      ],
    ],
    attributes: <String, String?>{
      statusGroup: row.exam.isPublished ? published : draft,
      facultyGroup: row.exam.faculty,
      departmentGroup: row.exam.department,
      levelGroup: row.exam.level,
      supervisorGroup: row.isAssigned ? assigned : unassigned,
    },
  );

  /// The rows of [rows] that survive [query], in their original order.
  static List<ExamAssignmentRow> filter(
    List<ExamAssignmentRow> rows,
    SearchQuery query,
  ) {
    if (!query.isActive) return rows;
    return <ExamAssignmentRow>[
      for (final row in rows)
        if (query.matches(recordFor(row))) row,
    ];
  }
}
