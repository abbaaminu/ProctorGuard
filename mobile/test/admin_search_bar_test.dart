import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/features/admin/domain/entities/admin_account_search.dart';
import 'package:proctorguard/features/admin/domain/entities/managed_account.dart';
import 'package:proctorguard/features/admin/domain/entities/search_query.dart';
import 'package:proctorguard/features/admin/presentation/widgets/admin_search_bar.dart';
import 'package:proctorguard/features/auth/domain/entities/user_profile.dart';

/// The bar, driven the way a page drives it.
///
/// The harness below is deliberately the smallest honest copy of the three real
/// pages: it owns a [SearchQuery], filters its rows through the same adapter the
/// roster uses, and renders the match count the page would render. What is being
/// tested is therefore the contract a page has to honour — the debounce, the
/// keys, the reset — rather than a private arrangement inside the widget.
void main() {
  const ada = ManagedAccount(
    id: 'ada',
    email: 'ada@uni.test',
    fullName: 'Ada Nwosu',
    role: UserRole.student,
    faculty: 'Science',
    department: 'Computer Science',
    level: '300',
    matricNumber: 'CSC/2021/041',
  );
  const tunde = ManagedAccount(
    id: 'tunde',
    email: 'tunde@uni.test',
    fullName: 'Tunde Bello',
    role: UserRole.student,
    faculty: 'Medicine',
    department: 'Medicine',
    level: '400',
  );
  const obi = ManagedAccount(
    id: 'obi',
    email: 'obi@uni.test',
    fullName: 'Chidi Obi',
    role: UserRole.lecturer,
    staffId: 'STF-0142',
  );
  const roster = <ManagedAccount>[ada, tunde, obi];

  Future<void> pumpBar(
    WidgetTester tester, {
    List<ManagedAccount> accounts = roster,
    bool isLoading = false,
    List<SearchQuery>? log,
  }) async {
    await tester.pumpWidget(
      _Harness(accounts: accounts, isLoading: isLoading, log: log),
    );
    await tester.pump();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('t-field')), text);
    await tester.pump();
  }

  /// Longer than the harness's 300 ms debounce.
  const settled = Duration(milliseconds: 350);

  /// A menu entry. Two widgets carry its key while the menu is open, because
  /// `CheckboxMenuButton` hands the key down to the `MenuItemButton` it builds —
  /// a tap names the first, while `findsNothing` wants the plain finder.
  Finder option(String groupId, String value) =>
      find.byKey(AdminSearchBar.optionKey('t', groupId, value));

  testWidgets('shows the total, then narrows it after the debounce', (
    tester,
  ) async {
    final log = <SearchQuery>[];
    await pumpBar(tester, log: log);

    expect(find.text('3 accounts'), findsOneWidget);
    expect(find.byKey(const Key('row-ada')), findsOneWidget);
    expect(find.byKey(const Key('row-obi')), findsOneWidget);

    await type(tester, 'nwosu');
    // A keystroke rebuilds the bar (the clear icon appears) but not the list:
    // this is what keeps typing cheap on a long roster.
    expect(find.text('3 accounts'), findsOneWidget);
    expect(find.byKey(const Key('row-obi')), findsOneWidget);
    expect(log, isEmpty);

    await tester.pump(settled);
    expect(log.single.text, 'nwosu');
    expect(find.text('1 of 3 accounts'), findsOneWidget);
    expect(find.byKey(const Key('row-ada')), findsOneWidget);
    expect(find.byKey(const Key('row-obi')), findsNothing);
  });

  testWidgets('only the last keystroke filters', (tester) async {
    final log = <SearchQuery>[];
    await pumpBar(tester, log: log);

    await type(tester, 'a');
    await tester.pump(const Duration(milliseconds: 120));
    await type(tester, 'ad');
    await tester.pump(const Duration(milliseconds: 120));
    await type(tester, 'ada');
    await tester.pump(settled);

    // Two timers were cancelled; one query reached the page.
    expect(log.map((query) => query.text), ['ada']);
    expect(find.text('1 of 3 accounts'), findsOneWidget);
  });

  testWidgets('Enter filters without waiting out the timer', (tester) async {
    final log = <SearchQuery>[];
    await pumpBar(tester, log: log);

    await type(tester, 'obi');
    await tester.showKeyboard(find.byKey(const Key('t-field')));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(log.single.text, 'obi');
    expect(find.text('1 of 3 accounts'), findsOneWidget);

    // The timer the keystroke started was cancelled, so nothing else arrives.
    await tester.pump(settled);
    expect(log, hasLength(1));
  });

  testWidgets('a facet chip filters, and a second tick keeps the menu open', (
    tester,
  ) async {
    await pumpBar(tester);

    await tester.tap(find.byKey(const Key('t-filter-role')));
    await tester.pumpAndSettle();

    await tester.tap(option('role', 'student').first);
    await tester.pumpAndSettle();
    expect(find.text('2 of 3 accounts'), findsOneWidget);
    // The menu stayed open, so narrowing to "student or lecturer" is one more
    // tap rather than a second visit to the chip.
    final lecturer = option('role', 'lecturer');
    expect(lecturer, findsWidgets);
    await tester.tap(lecturer.first);
    await tester.pumpAndSettle();
    expect(find.text('3 of 3 accounts'), findsOneWidget);
    // The chip shows how many values it holds.
    expect(find.text('Role (2)'), findsOneWidget);

    // Closing the menu leaves the selection in place.
    await tester.tap(find.byKey(const Key('t-filter-role')));
    await tester.pumpAndSettle();
    expect(lecturer, findsNothing);
    expect(find.text('Role (2)'), findsOneWidget);

    // One chip's clear drops that facet only.
    await tester.tap(find.byKey(const Key('t-filter-role')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('t-clear-role')));
    await tester.pumpAndSettle();
    expect(find.text('3 accounts'), findsOneWidget);
    expect(find.text('Role'), findsOneWidget);
  });

  testWidgets('text and a facet narrow together, and Clear drops both', (
    tester,
  ) async {
    await pumpBar(tester);

    await type(tester, 'medicine');
    await tester.pump(settled);
    expect(find.text('1 of 3 accounts'), findsOneWidget);

    await tester.tap(find.byKey(const Key('t-filter-level')));
    await tester.pumpAndSettle();
    // Ticking a level the text already excludes changes nothing but the count…
    await tester.tap(option('level', '300').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('t-filter-level')));
    await tester.pumpAndSettle();
    expect(find.text('0 of 3 accounts'), findsOneWidget);
    expect(find.byType(AdminSearchEmpty), findsOneWidget);

    // …and the bar's Clear drops the text and every tick at once.
    await tester.tap(find.byKey(const Key('t-reset')));
    await tester.pumpAndSettle();
    expect(find.text('3 accounts'), findsOneWidget);
    expect(_fieldText(tester), isEmpty);
    expect(find.byKey(const Key('t-reset')), findsNothing);
  });

  testWidgets("the field's own clear keeps the facets", (tester) async {
    await pumpBar(tester);

    await type(tester, 'ada');
    await tester.pump(settled);
    await tester.tap(find.byKey(const Key('t-filter-role')));
    await tester.pumpAndSettle();
    await tester.tap(option('role', 'student').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('t-filter-role')));
    await tester.pumpAndSettle();
    expect(find.text('1 of 3 accounts'), findsOneWidget);

    await tester.tap(find.byKey(const Key('t-clear-text')));
    await tester.pumpAndSettle();
    expect(_fieldText(tester), isEmpty);
    // Both students, because the role facet is still ticked.
    expect(find.text('2 of 3 accounts'), findsOneWidget);
    expect(find.text('Role (1)'), findsOneWidget);
  });

  testWidgets('nothing matches: a placeholder resets the whole bar', (
    tester,
  ) async {
    await pumpBar(tester);

    await type(tester, '%');
    await tester.pump(settled);
    // A percent sign is a literal here, and no row holds one.
    expect(find.text('0 of 3 accounts'), findsOneWidget);
    expect(
      find.text('No accounts match this search and these filters.'),
      findsOneWidget,
    );

    // The placeholder talks to the page, and the field adopts what comes back —
    // which is how a reset works from below the bar.
    await tester.tap(find.byKey(const Key('accounts-clear-filters')));
    await tester.pumpAndSettle();
    expect(find.text('3 accounts'), findsOneWidget);
    expect(_fieldText(tester), isEmpty);
    expect(find.byType(AdminSearchEmpty), findsNothing);
  });

  testWidgets('an empty roster counts zero, and loading outranks the count', (
    tester,
  ) async {
    await pumpBar(tester, accounts: const <ManagedAccount>[]);
    expect(find.text('0 accounts'), findsOneWidget);

    await pumpBar(tester, accounts: const <ManagedAccount>[], isLoading: true);
    expect(find.text('Loading accounts…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}

String _fieldText(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const Key('t-field'))).controller!.text;

/// The smallest page the bar can live on: it owns the query, filters its rows
/// through [AdminAccountSearch] — the same call the roster makes — and renders
/// the count the page would render.
class _Harness extends StatefulWidget {
  const _Harness({required this.accounts, this.isLoading = false, this.log});

  final List<ManagedAccount> accounts;
  final bool isLoading;

  /// Every query the bar handed up, so a test can see how many times it fired.
  final List<SearchQuery>? log;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  SearchQuery _query = SearchQuery.empty;

  void _onChanged(SearchQuery query) {
    widget.log?.add(query);
    setState(() => _query = query);
  }

  @override
  Widget build(BuildContext context) {
    final matched = AdminAccountSearch.filter(widget.accounts, _query);

    return MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: <Widget>[
              AdminSearchBar(
                keyPrefix: 't',
                query: _query,
                groups: AdminAccountSearch.groupsFor(widget.accounts),
                onChanged: _onChanged,
                matchCount: matched.length,
                totalCount: widget.accounts.length,
                noun: 'accounts',
                isLoading: widget.isLoading,
              ),
              if (matched.isEmpty)
                AdminSearchEmpty(
                  noun: 'accounts',
                  onReset: () => _onChanged(SearchQuery.empty),
                )
              else
                for (final account in matched)
                  ListTile(
                    key: Key('row-${account.id}'),
                    title: Text(account.fullName),
                    subtitle: Text(account.email),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
