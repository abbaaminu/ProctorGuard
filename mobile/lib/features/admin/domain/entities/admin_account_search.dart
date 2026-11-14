import '../../../../core/utils/academic_catalog.dart';
import '../../../auth/domain/entities/user_profile.dart';
import 'managed_account.dart';
import 'profile_labels.dart';
import 'search_query.dart';

/// The accounts roster's half of the search bar: which facets it has, and what
/// one account looks like to a search.
///
/// Kept out of the page so the matching is testable without a widget (and so the
/// fields the free text matches are listed in one place rather than implied by
/// what the tile happens to render). Every column the roster *shows* is here —
/// name, address, role, identity number, faculty/department/level — plus the
/// created date, which the tile shows as a timestamp and which an administrator
/// hunts by ("everyone created this term").
///
/// The facet options are derived from the rows, not from the catalogue alone: a
/// faculty the institution wrote into a CSV but this build has never heard of is
/// still filterable, and "Not stated" appears exactly when some row states
/// nothing — the rows the label-correction card exists for.
abstract final class AdminAccountSearch {
  static const String roleGroup = 'role';
  static const String facultyGroup = 'faculty';
  static const String departmentGroup = 'department';
  static const String levelGroup = 'level';
  static const String labelsGroup = 'labels';

  /// The values [labelsGroup] offers. "Missing" is any blank among the three
  /// columns `exams_select` compares ([ManagedAccountLabels.isFullyLabelled]),
  /// because one blank is enough to hide a paper from that student.
  static const String labelsComplete = 'complete';
  static const String labelsMissing = 'missing';

  static List<SearchFilterGroup> groupsFor(
    List<ManagedAccount> accounts,
  ) => <SearchFilterGroup>[
    SearchFilterGroup(
      id: roleGroup,
      label: 'Role',
      options: <SearchFilterOption>[
        for (final role in UserRole.values)
          SearchFilterOption(value: role.dbValue, label: role.label),
      ],
    ),
    SearchFilterGroup(
      id: facultyGroup,
      label: 'Faculty',
      options: SearchFacets.fromValues(
        accounts.map((account) => account.faculty),
        preferredOrder: AcademicCatalog.facultyNames,
      ),
    ),
    SearchFilterGroup(
      id: departmentGroup,
      label: 'Department',
      options: SearchFacets.fromValues(
        accounts.map((account) => account.department),
        preferredOrder: AcademicCatalog.allDepartments,
      ),
    ),
    SearchFilterGroup(
      id: levelGroup,
      label: 'Level',
      options: SearchFacets.fromValues(
        accounts.map((account) => account.level),
        preferredOrder: AcademicCatalog.levels,
      ),
    ),
    const SearchFilterGroup(
      id: labelsGroup,
      label: 'Labels',
      options: <SearchFilterOption>[
        SearchFilterOption(value: labelsMissing, label: 'Missing a label'),
        SearchFilterOption(value: labelsComplete, label: 'All three labels'),
      ],
    ),
  ];

  static SearchRecord recordFor(ManagedAccount account) => SearchRecord(
    fields: <String?>[
      account.fullName,
      account.email,
      account.role.label,
      account.faculty,
      account.department,
      account.level,
      account.academicLabel,
      account.matricNumber,
      account.staffId,
      _date(account.createdAt),
    ],
    attributes: <String, String?>{
      roleGroup: account.role.dbValue,
      facultyGroup: account.faculty,
      departmentGroup: account.department,
      levelGroup: account.level,
      labelsGroup: account.isFullyLabelled ? labelsComplete : labelsMissing,
    },
  );

  /// The rows of [accounts] that survive [query], in their original order.
  static List<ManagedAccount> filter(
    List<ManagedAccount> accounts,
    SearchQuery query,
  ) {
    if (!query.isActive) return accounts;
    return <ManagedAccount>[
      for (final account in accounts)
        if (query.matches(recordFor(account))) account,
    ];
  }

  /// `2026-02-03 3 Feb 2026` for [createdAt] — an exact date for a paste and a
  /// readable one for typing ("feb"), or null when the column is empty.
  static String? _date(DateTime? createdAt) {
    if (createdAt == null) return null;
    final local = createdAt.toLocal();
    final iso =
        '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
    return '$iso ${local.day} ${_months[local.month - 1]} ${local.year}';
  }

  static const List<String> _months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
}
