import 'package:equatable/equatable.dart';

/// A value one of the search bar's filters can be set to.
///
/// [value] is what a [SearchRecord.attributes] entry compares against — a
/// database value (`'student'`), a label spelling (`'Computer Science'`), or one
/// of the sentinels below — while [label] is what the menu shows. Keeping them
/// apart is what lets a facet be renamed without breaking a saved match, and it
/// is why [SearchRecord.unstated] is `''` rather than the string "Not stated":
/// a row that states nothing must not collide with a row whose faculty is
/// literally called "Not stated".
class SearchFilterOption extends Equatable {
  const SearchFilterOption({required this.value, required this.label});

  final String value;
  final String label;

  @override
  List<Object?> get props => <Object?>[value, label];
}

/// One facet of a list: the heading its chip wears and the values it offers.
///
/// A group is defined by the *page*, because only the page knows what its rows
/// contain (`role` for accounts, `status` for papers and attempts). Two groups
/// with the same [id] are the same facet, which is how a record answers "what is
/// your faculty?" without the widget knowing anything about faculties.
class SearchFilterGroup extends Equatable {
  const SearchFilterGroup({
    required this.id,
    required this.label,
    required this.options,
  });

  final String id;
  final String label;
  final List<SearchFilterOption> options;

  @override
  List<Object?> get props => <Object?>[id, label, options];
}

/// One row, reduced to what a search can ask of it.
///
/// [fields] is every value the free text is matched against — name, address,
/// identity number, formatted date, whatever the list shows and whatever it
/// hides. [attributes] answers the filter groups by id; a group the record does
/// not mention is read as [unstated], so a page cannot make a row invisible to a
/// filter by forgetting a key.
class SearchRecord {
  const SearchRecord({
    required this.fields,
    this.attributes = const <String, String?>{},
  });

  /// The sentinel for "this row did not state this attribute".
  ///
  /// Empty rather than null so a `Set<String>` can hold it next to real values:
  /// the "Not stated" option a facet offers is a normal option whose value is
  /// this constant.
  static const String unstated = '';

  final List<String?> fields;
  final Map<String, String?> attributes;

  /// The value of [id] as it stands, or [unstated] when the row states nothing.
  String attribute(String id) => _valueOf(attributes[id]) ?? unstated;

  /// [raw] trimmed, or null when it says nothing — the reading every column in
  /// this app uses for "not recorded".
  static String? _valueOf(String? raw) {
    final value = raw?.trim() ?? '';
    return value.isEmpty ? null : value;
  }
}

/// Everything the administrator has narrowed a list by.
///
/// One value object for the text box and every facet, so a page has one piece of
/// state to hold ([isActive] is what a "Clear" button shows on) and the matching
/// rule lives in one place.
///
/// **The matching is deliberately local.** Every list this bar is used on is
/// already in memory — the admin roster is one `select` of `profiles`, the
/// assign-supervisors screen reads `exams` and `supervisor_exam_assignments`
/// whole, and the live monitor is a stream of one paper's `exam_submissions` —
/// so there is no PostgREST filter to build and therefore no `ilike` pattern and
/// no `or=()` list to escape. `%`, `_`, `,`, `(`, `)`, `'` and `"` are ordinary
/// characters here: they are compared literally, which is what an administrator
/// typing a matric number like `CSC/2021/041` expects. If a list ever outgrows
/// the client (see [matches] for the cost), the server-side replacement has to
/// escape twice — `\%` and `\_` for `ILIKE`, and double quotes for a value
/// inside `or=(...)` — instead of concatenating what was typed.
///
/// **Text matching** is case-insensitive, partial and whitespace-insensitive:
/// both sides are normalised through [normalise] (lower case, every whitespace
/// run collapsed to one space, curly quotes folded to straight ones) and the
/// query is split into tokens, **all** of which must appear somewhere in the
/// row's fields. So "ada nwosu" finds "Dr. Ada  Nwosu", "nwosu ada" finds her
/// too, "ada@proctor" finds her address, and "300 csc" finds a student in
/// Computer Science at 300 level without the two having to be adjacent or in
/// that order — which is what "find anything by any parameter" means once a row
/// has a dozen fields.
///
/// **Filters** are AND across groups and OR inside one: role = student **and**
/// level = 300, where level may be 300 *or* 400.
class SearchQuery extends Equatable {
  const SearchQuery({
    this.text = '',
    this.selections = const <String, Set<String>>{},
  });

  /// Nothing typed, nothing ticked — what the reset button produces.
  static const SearchQuery empty = SearchQuery();

  final String text;

  /// `groupId -> chosen values`. An absent group and an empty set mean the same
  /// thing (no narrowing), so [withSelection] removes a group rather than
  /// storing it empty and [isActive] does not have to special-case either.
  final Map<String, Set<String>> selections;

  /// The normalised tokens of [text]. Empty when there is nothing to match.
  List<String> get tokens => _tokensOf(text);

  /// Whether anything is narrowing the list at all.
  bool get isActive => hasText || selectedCount > 0;

  bool get hasText => tokens.isNotEmpty;

  /// How many options are ticked across every group — what makes a chip look
  /// active and what the reset button counts.
  int get selectedCount =>
      selections.values.fold<int>(0, (sum, values) => sum + values.length);

  /// The chosen values of [groupId], never null.
  Set<String> selectionFor(String groupId) =>
      selections[groupId] ?? const <String>{};

  /// The same query with a different text box (filters untouched).
  SearchQuery withText(String value) =>
      SearchQuery(text: value, selections: selections);

  /// Ticks [value] in [groupId] if it was not ticked, un-ticks it if it was.
  SearchQuery toggle(String groupId, String value) {
    final next = <String>{...selectionFor(groupId)};
    if (!next.remove(value)) next.add(value);
    return withSelection(groupId, next);
  }

  /// Replaces [groupId]'s selection outright; empty [values] drops the group.
  SearchQuery withSelection(String groupId, Set<String> values) {
    final next = <String, Set<String>>{...selections};
    if (values.isEmpty) {
      next.remove(groupId);
    } else {
      next[groupId] = <String>{...values};
    }
    return SearchQuery(text: text, selections: next);
  }

  /// Whether [record] survives this query.
  ///
  /// Cost is one normalised join plus one `contains` per token per row, so a
  /// few thousand rows is a fraction of a frame; a page re-runs it only when the
  /// query changes (after the debounce) or the list itself does. Tens of
  /// thousands of rows would be the point to stop filtering here and ask
  /// Postgres — see the class comment for what that query has to escape.
  bool matches(SearchRecord record) {
    final wanted = tokens;
    if (wanted.isNotEmpty) {
      final haystack = normalise(record.fields.whereType<String>().join(' '));
      for (final token in wanted) {
        if (!haystack.contains(token)) return false;
      }
    }
    for (final entry in selections.entries) {
      if (entry.value.isEmpty) continue;
      if (!entry.value.contains(record.attribute(entry.key))) return false;
    }
    return true;
  }

  @override
  List<Object?> get props => <Object?>[text, selections];

  /// Lower-cased, whitespace-collapsed, quote-folded form of [value].
  ///
  /// Folding the curly quotes matters for names pasted out of a document
  /// ("O’Brien" vs "O'Brien"); collapsing whitespace is what makes a double
  /// space between two typed words harmless. Nothing else is rewritten — a
  /// `%`, `_` or `(` in a matric number or a paper title stays itself.
  static String normalise(String? value) {
    if (value == null || value.isEmpty) return '';
    final folded = value
        .replaceAll('\u00A0', ' ') // non-breaking space
        .replaceAll('\u2018', "'")
        .replaceAll('\u2019', "'")
        .replaceAll('\u201C', '"')
        .replaceAll('\u201D', '"')
        .toLowerCase();
    return folded.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static List<String> _tokensOf(String? value) {
    final normalised = normalise(value);
    if (normalised.isEmpty) return const <String>[];
    return normalised
        .split(' ')
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
  }
}

/// Building the option list of a data-derived facet.
///
/// The catalogue order comes first (so faculties read the way the institution
/// lists them) and anything the database holds that the catalogue does not know
/// follows, alphabetically — a spelling the app has never seen is still
/// reachable rather than silently missing from the filter.
abstract final class SearchFacets {
  const SearchFacets._();

  /// The distinct values of [values], with "Not stated" last when at least one
  /// row states nothing.
  static List<SearchFilterOption> fromValues(
    Iterable<String?> values, {
    List<String> preferredOrder = const <String>[],
  }) {
    final present = <String, String>{};
    var hasUnstated = false;
    for (final raw in values) {
      final value = raw?.trim() ?? '';
      if (value.isEmpty) {
        hasUnstated = true;
        continue;
      }
      present.putIfAbsent(value.toLowerCase(), () => value);
    }

    final ordered = <String>[];
    for (final preferred in preferredOrder) {
      final match = present.remove(preferred.toLowerCase());
      if (match != null) ordered.add(match);
    }
    final extra = present.values.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    ordered.addAll(extra);

    return <SearchFilterOption>[
      for (final value in ordered)
        SearchFilterOption(value: value, label: value),
      if (hasUnstated)
        const SearchFilterOption(
          value: SearchRecord.unstated,
          label: 'Not stated',
        ),
    ];
  }
}
