import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/features/admin/domain/entities/admin_account_search.dart';
import 'package:proctorguard/features/admin/domain/entities/managed_account.dart';
import 'package:proctorguard/features/admin/domain/entities/search_query.dart';
import 'package:proctorguard/features/auth/domain/entities/user_profile.dart';
import 'package:proctorguard/features/dashboard/domain/entities/attempt_search.dart';
import 'package:proctorguard/features/exam/domain/entities/exam.dart';
import 'package:proctorguard/features/supervision/domain/entities/exam_assignment_search.dart';

/// The admin search bar's model, without a widget in the way.
///
/// Three things are worth testing separately from the bar:
///
///  * [SearchQuery] itself — token matching, AND across facets / OR inside one,
///    the reset, and (the reason the class exists) that `%`, `_`, `,`, brackets
///    and quotes are compared **literally** rather than as pattern syntax;
///  * [SearchFacets] — the order a data-derived facet is offered in, and the
///    "Not stated" entry that must be last and must not collide with a row whose
///    faculty is literally called that;
///  * the three per-page adapters, because "which fields does the free text
///    match" is a product decision, not an implementation detail: a supervisor's
///    name has to find their paper on Assign supervisors, and a status the app
///    has never seen has to be filterable on the live monitor.
void main() {
  ManagedAccount account({
    required String id,
    required String name,
    required UserRole role,
    String? faculty,
    String? department,
    String? level,
    String? matricNumber,
    String? staffId,
  }) => ManagedAccount(
    id: id,
    email: '$id@uni.test',
    fullName: name,
    role: role,
    faculty: faculty,
    department: department,
    level: level,
    matricNumber: matricNumber,
    staffId: staffId,
    createdAt: DateTime.utc(2026, 2, 3, 9, 30),
  );

  final ada = account(
    id: 'ada',
    name: 'Ada Nwosu',
    role: UserRole.student,
    faculty: 'Science',
    department: 'Computer Science',
    level: '300',
    matricNumber: 'CSC/2021/041',
  );
  final tunde = account(
    id: 'tunde',
    name: 'Tunde Bello',
    role: UserRole.student,
    faculty: 'Medicine',
    department: 'Medicine',
    level: '400',
    matricNumber: 'MED/2020/002',
  );
  final obi = account(
    id: 'obi',
    name: 'Chidi Obi',
    role: UserRole.lecturer,
    staffId: 'STF-0142',
  );
  final roster = <ManagedAccount>[ada, tunde, obi];

  group('SearchQuery', () {
    test('empty is not active and narrows nothing', () {
      const query = SearchQuery.empty;
      expect(query.isActive, isFalse);
      expect(query.hasText, isFalse);
      expect(query.selectedCount, 0);
      expect(query.selectionFor('role'), isEmpty);
      expect(query.matches(AdminAccountSearch.recordFor(ada)), isTrue);
    });

    test('text matches any field, in any order, case-insensitively', () {
      final record = AdminAccountSearch.recordFor(ada);
      expect(const SearchQuery(text: 'ada').matches(record), isTrue);
      expect(const SearchQuery(text: 'NWOSU').matches(record), isTrue);
      expect(const SearchQuery(text: 'nwosu ada').matches(record), isTrue);
      expect(const SearchQuery(text: '  ada   nwosu ').matches(record), isTrue);
      // The address, the matric number, the cohort — all "parameters".
      expect(const SearchQuery(text: 'ada@uni.test').matches(record), isTrue);
      expect(const SearchQuery(text: 'csc/2021/041').matches(record), isTrue);
      expect(const SearchQuery(text: '300 science').matches(record), isTrue);
      expect(const SearchQuery(text: 'feb 2026').matches(record), isTrue);
      // Every token has to be somewhere: "tunde" is not on Ada's row.
      expect(const SearchQuery(text: 'ada tunde').matches(record), isFalse);
    });

    test('facets are AND across groups and OR inside one', () {
      final query = SearchQuery.empty
          .toggle(AdminAccountSearch.roleGroup, 'student')
          .toggle(AdminAccountSearch.levelGroup, '300');

      expect(AdminAccountSearch.filter(roster, query).map((a) => a.id), [
        'ada',
      ]);
      expect(query.selectedCount, 2);

      // Two levels at once: either one satisfies the level group.
      final either = query.toggle(AdminAccountSearch.levelGroup, '400');
      expect(AdminAccountSearch.filter(roster, either).map((a) => a.id), [
        'ada',
        'tunde',
      ]);

      // Text and facets are ANDed too.
      final narrowed = either.withText('tunde');
      expect(AdminAccountSearch.filter(roster, narrowed).map((a) => a.id), [
        'tunde',
      ]);
    });

    test('toggling the same value twice un-ticks it and drops the group', () {
      final once = SearchQuery.empty.toggle(
        AdminAccountSearch.roleGroup,
        'admin',
      );
      expect(once.selectedCount, 1);
      final twice = once.toggle(AdminAccountSearch.roleGroup, 'admin');
      expect(twice.selectedCount, 0);
      expect(twice.selections, isEmpty);
      expect(twice.isActive, isFalse);
    });

    test('withText keeps the facets, withSelection keeps the text', () {
      final query = const SearchQuery(
        text: 'ada',
      ).withSelection(AdminAccountSearch.roleGroup, {'student'});
      expect(query.text, 'ada');
      expect(query.selectionFor(AdminAccountSearch.roleGroup), {'student'});
      expect(
        query.withText('nwosu').selectionFor(AdminAccountSearch.roleGroup),
        {'student'},
      );
      expect(
        query.withSelection(AdminAccountSearch.roleGroup, const <String>{}),
        const SearchQuery(text: 'ada'),
      );
    });
    test(
      'a row that states nothing answers the sentinel, not "Not stated"',
      () {
        final record = AdminAccountSearch.recordFor(obi);
        expect(
          record.attribute(AdminAccountSearch.facultyGroup),
          SearchRecord.unstated,
        );
        // A group the record does not mention at all reads the same way.
        expect(record.attribute('never-heard-of-it'), SearchRecord.unstated);
        // So "Not stated" finds the unlabelled lecturer and nothing else.
        final notStated = SearchQuery.empty.toggle(
          AdminAccountSearch.facultyGroup,
          SearchRecord.unstated,
        );
        expect(AdminAccountSearch.filter(roster, notStated).map((a) => a.id), [
          'obi',
        ]);
      },
    );

    test('special characters are literal, never pattern syntax', () {
      final record = AdminAccountSearch.recordFor(ada);
      // A slash is the matric number's own character — not a path, not a regex.
      expect(const SearchQuery(text: 'csc/2021').matches(record), isTrue);
      // `%` is SQL's wildcard and PostgREST's separator: typed here it must
      // mean a literal percent sign, which this row does not hold.
      expect(const SearchQuery(text: '%').matches(record), isFalse);
      expect(const SearchQuery(text: 'csc%').matches(record), isFalse);
      // Likewise `_`, which ILIKE reads as "any one character".
      expect(const SearchQuery(text: '_').matches(record), isFalse);
      expect(const SearchQuery(text: 'nwosu,').matches(record), isFalse);
      expect(const SearchQuery(text: "o'brien").matches(record), isFalse);

      // A row whose fields really do contain them still matches exactly.
      const punctuation = SearchRecord(
        fields: ['Data, Structures (CSC 201)', '100% coursework', "O'Brien"],
      );
      expect(
        const SearchQuery(text: 'data, structures').matches(punctuation),
        isTrue,
      );
      expect(const SearchQuery(text: '(csc 201)').matches(punctuation), isTrue);
      expect(const SearchQuery(text: '100%').matches(punctuation), isTrue);
      expect(const SearchQuery(text: "o'brien").matches(punctuation), isTrue);
      // …and a quote is not a phrase delimiter: the rest of the word must fit.
      expect(const SearchQuery(text: "\"brien").matches(punctuation), isFalse);
    });

    test('curly quotes fold, so a name pasted from a document matches', () {
      const curly = SearchRecord(fields: ['Ada O’Brien']);
      expect(const SearchQuery(text: "o'brien").matches(curly), isTrue);
      const straight = SearchRecord(fields: ["Ada O'Brien"]);
      expect(const SearchQuery(text: 'o’brien').matches(straight), isTrue);
      // A non-breaking space, which is what a pasted name usually carries.
      const spaced = SearchRecord(fields: ['Ada\u00A0Nwosu']);
      expect(const SearchQuery(text: 'ada nwosu').matches(spaced), isTrue);
    });

    test('the reset is the empty query', () {
      final busy = const SearchQuery(text: 'ada')
          .toggle(AdminAccountSearch.roleGroup, 'student')
          .toggle(AdminAccountSearch.facultyGroup, 'Science');
      expect(busy.isActive, isTrue);
      expect(busy.selectedCount, 2);
      // Equality is by value, so a page can compare against `empty`.
      expect(
        busy
            .withText('')
            .withSelection(AdminAccountSearch.roleGroup, const <String>{})
            .withSelection(AdminAccountSearch.facultyGroup, const <String>{}),
        SearchQuery.empty,
      );
    });
  });

  group('SearchFacets.fromValues', () {
    test('catalogue order first, unknown values after, unstated last', () {
      final options = SearchFacets.fromValues(
        ['medicine', 'Zzz Unknown', 'Science', 'medicine', null, '  '],
        preferredOrder: const ['Science', 'Medicine'],
      );

      expect(
        options.map((option) => option.value),
        // The catalogue's spelling wins over the row's lower-cased one; the
        // unseen value is kept rather than dropped; "Not stated" is one entry
        // however many blank rows there were.
        ['Science', 'medicine', 'Zzz Unknown', SearchRecord.unstated],
      );
      expect(options.last.label, 'Not stated');
    });

    test('offers no "Not stated" when every row states a value', () {
      final options = SearchFacets.fromValues(const ['Science', 'Science']);
      expect(options.map((option) => option.value), ['Science']);
    });

    test('a page cannot collide a real value with the sentinel', () {
      final options = SearchFacets.fromValues(const ['Not stated', '']);
      expect(options.map((option) => option.label), [
        'Not stated',
        'Not stated',
      ]);
      // The same words, two different values: one is a faculty somebody typed,
      // the other is a row that says nothing.
      expect(options.first.value, 'Not stated');
      expect(options.last.value, SearchRecord.unstated);
    });
  });

  group('the Assign supervisors adapter', () {
    Exam paper({
      required String id,
      required String title,
      required bool published,
      String? faculty,
      String? department,
      String? level,
      int minutes = 60,
    }) => Exam(
      id: id,
      title: title,
      createdBy: 'lecturer',
      durationMinutes: minutes,
      isPublished: published,
      faculty: faculty,
      department: department,
      level: level,
    );

    final rows = <ExamAssignmentRow>[
      ExamAssignmentRow(
        exam: paper(
          id: 'csc201',
          title: 'Data Structures',
          published: true,
          faculty: 'Science',
          department: 'Computer Science',
          level: '200',
        ),
        supervisors: <ManagedAccount>[ada],
      ),
      ExamAssignmentRow(
        exam: paper(id: 'med401', title: 'Clinical Rotation', published: false),
        supervisors: const <ManagedAccount>[],
      ),
    ];

    test("a supervisor's name finds their paper, and so does its title", () {
      expect(
        ExamAssignmentSearch.filter(
          rows,
          const SearchQuery(text: 'nwosu'),
        ).map((row) => row.exam.id),
        ['csc201'],
      );
      expect(
        ExamAssignmentSearch.filter(
          rows,
          const SearchQuery(text: 'clinical'),
        ).map((row) => row.exam.id),
        ['med401'],
      );
      // Draft is a field, so it can be typed as well as ticked.
      expect(
        ExamAssignmentSearch.filter(
          rows,
          const SearchQuery(text: 'draft'),
        ).map((row) => row.exam.id),
        ['med401'],
      );
    });

    test('"Nobody assigned" is the papers only an administrator can open', () {
      final unassigned = SearchQuery.empty.toggle(
        ExamAssignmentSearch.supervisorGroup,
        ExamAssignmentSearch.unassigned,
      );
      expect(
        ExamAssignmentSearch.filter(rows, unassigned).map((row) => row.exam.id),
        ['med401'],
      );
      // …and "Assigned" is the other half, never the same paper.
      final assigned = SearchQuery.empty.toggle(
        ExamAssignmentSearch.supervisorGroup,
        ExamAssignmentSearch.assigned,
      );
      expect(
        ExamAssignmentSearch.filter(rows, assigned).map((row) => row.exam.id),
        ['csc201'],
      );
    });

    test('facets come from the rows: an untargeted draft has no faculty', () {
      final groups = ExamAssignmentSearch.groupsFor(rows);
      final faculty = groups.firstWhere(
        (group) => group.id == ExamAssignmentSearch.facultyGroup,
      );
      expect(faculty.options.map((option) => option.label), [
        'Science',
        'Not stated',
      ]);
      final status = groups.firstWhere(
        (group) => group.id == ExamAssignmentSearch.statusGroup,
      );
      expect(status.options.map((option) => option.value), [
        ExamAssignmentSearch.published,
        ExamAssignmentSearch.draft,
      ]);
    });
  });

  group('the live monitor adapter', () {
    final rows = <Map<String, dynamic>>[
      {'id': 's1', 'student_id': 'ada', 'status': 'ongoing', 'score': 0},
      {'id': 's2', 'student_id': 'tunde', 'status': 'flagged_for_review'},
      // A status this build has never heard of, which must stay reachable.
      {'id': 'ghost', 'student_id': 'ghost-id-9', 'status': 'quarantined'},
      {'id': 's4', 'student_id': 'ada', 'status': 'submitted', 'score': 74.5},
    ];
    const names = <String, String>{'ada': 'Ada Nwosu', 'tunde': 'Tunde Bello'};

    List<String?> ids(
      SearchQuery query, {
      Map<String, int> flags = const <String, int>{},
    }) => AttemptSearch.filter(
      rows,
      query,
      nameById: names,
      flagsBySubmission: flags,
    ).map((row) => row['id'] as String?).toList();

    test('every present status is filterable, known or not', () {
      final status = AttemptSearch.groupsFor(rows).single;
      expect(status.options.map((option) => option.value), [
        // Preferred order: the ones waiting on a person first…
        'flagged_for_review',
        'ongoing',
        'submitted',
        // …then whatever else the stream carried, alphabetically.
        'quarantined',
      ]);
      // The unknown one is labelled by prettifying it, not by throwing.
      expect(status.options.last.label, 'Quarantined');
      expect(
        ids(SearchQuery.empty.toggle(AttemptSearch.statusGroup, 'quarantined')),
        ['ghost'],
      );
    });

    test(
      'a row with no status offers no facet entry, and reads as unstated',
      () {
        final statusless = <Map<String, dynamic>>[
          {'id': 's0', 'student_id': 'ada'},
          ...rows,
        ];
        expect(
          AttemptSearch.groupsFor(
            statusless,
          ).single.options.map((option) => option.value),
          isNot(contains(SearchRecord.unstated)),
        );
        expect(
          AttemptSearch.filter(
            statusless,
            SearchQuery.empty.toggle(
              AttemptSearch.statusGroup,
              SearchRecord.unstated,
            ),
            nameById: names,
          ).map((row) => row['id']),
          ['s0'],
        );
      },
    );

    test('the name a supervisor sees is searchable, ids are too', () {
      expect(ids(const SearchQuery(text: 'tunde')), ['s2']);
      expect(ids(const SearchQuery(text: 'ada submitted')), ['s4']);
      expect(ids(const SearchQuery(text: 'ghost')), ['ghost']);
      // A student the name map has never heard of still gets a printable name.
      expect(AttemptSearch.studentName(rows[2], names), 'Student ghost-id');
      expect(ids(const SearchQuery(text: 'student ghost')), ['ghost']);
    });

    test('the score and the incident count are parameters too', () {
      expect(ids(const SearchQuery(text: '74.5')), ['s4']);
      const flags = <String, int>{'s2': 3};
      expect(ids(const SearchQuery(text: '3 flags'), flags: flags), ['s2']);
      // "Which of these had nothing on them?" — the unflagged ones.
      expect(ids(const SearchQuery(text: 'no flags'), flags: flags), [
        's1',
        'ghost',
        's4',
      ]);
    });
  });
}
