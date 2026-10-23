/// The academic labels the institution uses, in one place.
///
/// Three free-text columns carry them — `profiles.faculty / department / level`
/// and `exams.faculty / department / level` — and `exams_select` compares them to
/// decide which published papers a student is offered (see
/// `supabase/migrations/academic_targeting.sql`). Free text in the database,
/// because a CSV import may know a spelling this build does not; a catalogue
/// here, because a dropdown that offers "Computer Science" and "computer
/// science" as different cohorts would quietly split a class.
///
/// Two rules follow from how the policy compares them:
///
///  * `level` is compared with plain equality (`p.level = exams.level`), so its
///    spelling matters — [normaliseLevel] is what turns "300 level" from a
///    spreadsheet into the `'300'` the column stores.
///  * `faculty` and `department` are compared case-insensitively
///    (`lower(a) = lower(b)`), so a stray capital cannot hide a paper; they are
///    still offered in catalogue spelling here.
///
/// **This is the file to edit** when a faculty or department is renamed or
/// added: the exam form, the profile form and the roster import all read their
/// options from it, and nothing else in the app writes those strings down.
class AcademicCatalog {
  const AcademicCatalog._();

  /// The levels a paper or a student can be labelled with. `level` is a string,
  /// not a number, because that is what the column stores and what the policy
  /// compares; "100" is a label, not a quantity.
  static const List<String> levels = <String>[
    '100',
    '200',
    '300',
    '400',
    '500',
    '600',
  ];

  /// Faculty → its departments, in the order the dropdowns offer them.
  static const Map<String, List<String>> faculties = <String, List<String>>{
    'Science': <String>[
      'Computer Science',
      'Mathematics',
      'Physics',
      'Chemistry',
      'Biology',
      'Statistics',
    ],
    'Engineering': <String>[
      'Computer Engineering',
      'Electrical and Electronics Engineering',
      'Mechanical Engineering',
      'Civil Engineering',
    ],
    'Social Sciences': <String>[
      'Economics',
      'Mass Communication',
      'Political Science',
      'Sociology',
      'Psychology',
    ],
    'Management Sciences': <String>[
      'Accounting',
      'Business Administration',
      'Banking and Finance',
      'Marketing',
    ],
    'Arts': <String>[
      'English',
      'History and International Studies',
      'Linguistics',
      'Philosophy',
      'Theatre Arts',
    ],
    'Education': <String>[
      'Educational Foundations',
      'Science Education',
      'Guidance and Counselling',
    ],
  };

  /// The faculties, for a dropdown.
  static List<String> get facultyNames =>
      faculties.keys.toList(growable: false);

  /// The departments of [faculty]. An unknown or absent faculty answers every
  /// department in the catalogue, so a lecturer who has not picked a faculty yet
  /// is not offered an empty list.
  static List<String> departmentsFor(String? faculty) {
    final name = clean(faculty);
    if (name != null) {
      for (final entry in faculties.entries) {
        if (entry.key.toLowerCase() == name.toLowerCase()) {
          return entry.value;
        }
      }
    }
    return allDepartments;
  }

  /// Every department once, in faculty order.
  static List<String> get allDepartments {
    final seen = <String>{};
    final all = <String>[];
    for (final departments in faculties.values) {
      for (final department in departments) {
        if (seen.add(department.toLowerCase())) all.add(department);
      }
    }
    return List<String>.unmodifiable(all);
  }

  /// The faculty a catalogue department belongs to, or null when it is not in
  /// the catalogue.
  static String? facultyOf(String? department) {
    final name = clean(department)?.toLowerCase();
    if (name == null) return null;
    for (final entry in faculties.entries) {
      for (final candidate in entry.value) {
        if (candidate.toLowerCase() == name) return entry.key;
      }
    }
    return null;
  }

  /// Trims [raw] and reads a blank as *not stated* (null), which is what the
  /// columns and the policies mean by it.
  static String? clean(String? raw) {
    final value = raw?.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  /// The catalogue's spelling of an imported level, or null when the value names
  /// no level at all.
  ///
  /// Accepts the plain label ("300"), the way a spreadsheet usually writes it
  /// ("300 Level", "300L", "LEVEL 300") and nothing else: guessing what "3"
  /// means would put a paper in front of the wrong cohort, so an unreadable value
  /// is refused and reported instead. The same holds for a four-digit typo —
  /// "3000" is refused rather than read as "300", because the digits that name
  /// the cohort have to be the only digits in the cell.
  static String? normaliseLevel(String? raw) {
    final value = clean(raw)?.toLowerCase();
    if (value == null) return null;

    final digits = RegExp(r'\d+').allMatches(value).toList();
    // One number, and it must be three digits long: "3000" and "300 400" both
    // name no single level.
    if (digits.length != 1 || digits.single.group(0)!.length != 3) return null;

    final level = digits.single.group(0)!;
    // Only the levels the catalogue knows: "700" is a typo, not a cohort.
    if (!levels.contains(level)) return null;

    // Whatever else the cell says has to be the word for the label — "300
    // Level", "300L", "LEVEL 300" — and nothing more ("300 (repeat)").
    final rest = value
        .replaceRange(digits.single.start, digits.single.end, '')
        .replaceAll(RegExp(r'[^a-z]'), '');
    if (rest.isEmpty || rest == 'l' || rest == 'lvl' || rest == 'level') {
      return level;
    }
    return null;
  }

  /// "Computer Science · 300" for a paper or a profile, or null when nothing is
  /// labelled — the reading that means "not narrowed" everywhere else.
  static String? describe({
    String? faculty,
    String? department,
    String? level,
  }) {
    final parts = <String>[
      if (clean(department) != null) clean(department)!,
      if (clean(faculty) != null) clean(faculty)!,
      if (clean(level) != null) '${clean(level)} Level',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}
