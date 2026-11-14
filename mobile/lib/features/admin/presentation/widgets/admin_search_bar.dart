import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/entities/search_query.dart';

/// The admin console's one search-and-filter bar.
///
/// Used by every admin list — the accounts roster, Assign supervisors and the
/// live monitor — so "how do I find a row" is answered the same way on all of
/// them: one text box that matches every field the list knows, one chip per
/// facet, one result count, one reset.
///
/// The *page* owns the query (it has the rows, so it is the only thing that can
/// count a match) and passes it back down; this widget owns only the text field's
/// controller and the debounce timer. That split is what keeps typing cheap:
/// a keystroke rebuilds this bar (to move the clear icon) and nothing else, and
/// the list itself is filtered once, 300 ms after the typing stops.
///
/// The query is the source of truth, so a page can reset from outside the bar
/// (its "nothing matches" placeholder does exactly that). The bar therefore
/// remembers the last text it handed up: a [SearchQuery.text] that differs from
/// that is the page talking, and the field adopts it; one that matches is the
/// bar's own echo, and is ignored — so a rebuild that arrives mid-word cannot
/// delete what is being typed.
///
/// Layout is width-driven rather than platform-driven (see `Breakpoints`): the
/// field is full width, the chips sit in a [Wrap] that becomes two or three rows
/// on a phone, and the menu is capped to a readable width so a long department
/// name does not stretch a phone off-screen.
class AdminSearchBar extends StatefulWidget {
  const AdminSearchBar({
    super.key,
    required this.query,
    required this.groups,
    required this.onChanged,
    required this.matchCount,
    required this.totalCount,
    required this.noun,
    this.isLoading = false,
    this.hintText = 'Search by name, email, number, label…',
    this.keyPrefix = 'admin-search',
    this.debounce = const Duration(milliseconds: 300),
  });

  /// What is currently narrowing the list. Filters change it immediately; the
  /// text does so after [debounce].
  final SearchQuery query;

  /// The facets this list can be filtered by, built from the rows themselves.
  final List<SearchFilterGroup> groups;

  final ValueChanged<SearchQuery> onChanged;

  /// Rows left after filtering, and rows there were to begin with.
  final int matchCount;
  final int totalCount;

  /// What to call the rows: `accounts`, `papers`, `attempts` — plural, so the
  /// count reads as a sentence without a pluralisation table.
  final String noun;

  /// True while the page is still loading its rows (the count line says so
  /// instead of claiming "0 of 0").
  final bool isLoading;

  final String hintText;

  /// Prefix of every widget key this bar builds, so three lists on one screen
  /// (or in one test file) cannot collide: `<prefix>-field`, `-reset`, `-count`,
  /// `-filter-<groupId>`, `-option-<groupId>-<value>`.
  final String keyPrefix;

  /// How long the text box waits after the last keystroke before it filters.
  final Duration debounce;

  /// The key of the menu entry for [value] in [groupId].
  ///
  /// Public so a test names the same entry the widget built instead of
  /// re-implementing the slug rule (a department label contains spaces).
  static Key optionKey(String keyPrefix, String groupId, String value) =>
      Key('$keyPrefix-option-$groupId-${_slug(value)}');

  static String _slug(String value) {
    if (value.isEmpty) return 'unstated';
    final slug = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'unstated' : slug;
  }

  @override
  State<AdminSearchBar> createState() => AdminSearchBarState();
}

/// Public only so the keys and the debounce can be driven from a test; nothing
/// outside this file should hold a reference to the state.
class AdminSearchBarState extends State<AdminSearchBar> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.query.text,
  );
  Timer? _debounce;

  /// The text this bar last handed to the page. Anything else arriving through
  /// [AdminSearchBar.query] came from the page itself (its "nothing matches"
  /// placeholder resets the query), and is adopted even while the field still
  /// holds focus.
  late String _lastEmitted = widget.query.text;

  @override
  void didUpdateWidget(AdminSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final external = widget.query.text;
    if (external == _lastEmitted) return;
    _lastEmitted = external;
    _debounce?.cancel();
    _controller.value = TextEditingValue(
      text: external,
      selection: TextSelection.collapsed(offset: external.length),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Typing: wait [AdminSearchBar.debounce] for the next keystroke, then filter.
  void _onChanged(String value) {
    _debounce?.cancel();
    // Redraws this bar only (the clear icon appears/disappears); the list below
    // is not rebuilt until the timer fires.
    setState(() {});
    _debounce = Timer(widget.debounce, () => _apply(value));
  }

  /// Enter: no reason to wait for the timer.
  void _onSubmitted(String value) {
    _debounce?.cancel();
    _apply(value);
  }

  void _apply(String value) {
    if (!mounted) return;
    _lastEmitted = value;
    widget.onChanged(widget.query.withText(value));
  }

  /// The field's own clear icon: text only, filters stay.
  void _clearText() {
    _debounce?.cancel();
    _controller.clear();
    setState(() {});
    _apply('');
  }

  /// "Clear": text and every facet, immediately.
  void _reset() {
    _debounce?.cancel();
    _controller.clear();
    setState(() {});
    _lastEmitted = '';
    widget.onChanged(SearchQuery.empty);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = widget.query;
    final hasText = _controller.text.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: Key('${widget.keyPrefix}-field'),
          controller: _controller,
          textInputAction: TextInputAction.search,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: _onChanged,
          onSubmitted: _onSubmitted,
          decoration: InputDecoration(
            hintText: widget.hintText,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: hasText
                ? IconButton(
                    key: Key('${widget.keyPrefix}-clear-text'),
                    tooltip: 'Clear the search text',
                    onPressed: _clearText,
                    icon: const Icon(Icons.close),
                  )
                : null,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final group in widget.groups)
                _FilterMenu(
                  keyPrefix: widget.keyPrefix,
                  group: group,
                  selected: query.selectionFor(group.id),
                  onToggle: (value) =>
                      widget.onChanged(query.toggle(group.id, value)),
                  onClear: () => widget.onChanged(
                    query.withSelection(group.id, const <String>{}),
                  ),
                ),
              if (query.isActive)
                TextButton.icon(
                  key: Key('${widget.keyPrefix}-reset'),
                  onPressed: _reset,
                  icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
                  label: Text(
                    query.selectedCount > 0
                        ? 'Clear (${query.selectedCount})'
                        : 'Clear',
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Semantics(
          liveRegion: true,
          child: Row(
            children: [
              if (widget.isLoading) ...<Widget>[
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  _countLabel,
                  key: Key('${widget.keyPrefix}-count'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// "240 accounts", "3 of 240 accounts", or a loading line — never "0 of 0"
  /// while the rows are still arriving.
  String get _countLabel {
    final noun = widget.noun;
    if (widget.isLoading) return 'Loading $noun…';
    if (!widget.query.isActive) return '${widget.totalCount} $noun';
    return '${widget.matchCount} of ${widget.totalCount} $noun';
  }
}

/// One facet: a chip that opens a menu of its values.
///
/// A menu rather than a row of chips because a department list is 20 entries
/// long and a phone is 360 dp wide; `CheckboxMenuButton` keeps the menu open
/// between ticks, so narrowing by two levels is two taps rather than two menus.
class _FilterMenu extends StatelessWidget {
  const _FilterMenu({
    required this.keyPrefix,
    required this.group,
    required this.selected,
    required this.onToggle,
    required this.onClear,
  });

  final String keyPrefix;
  final SearchFilterGroup group;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = selected.isNotEmpty;

    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      style: const MenuStyle(
        maximumSize: WidgetStatePropertyAll<Size>(Size(360, 420)),
      ),
      menuChildren: <Widget>[
        for (final option in group.options)
          CheckboxMenuButton(
            key: AdminSearchBar.optionKey(keyPrefix, group.id, option.value),
            value: selected.contains(option.value),
            // Ticking one value must not close the menu: two levels, or two
            // departments, are one visit to the chip.
            closeOnActivate: false,
            onChanged: (_) => onToggle(option.value),
            child: Text(option.label),
          ),
        if (active)
          MenuItemButton(
            key: Key('$keyPrefix-clear-${group.id}'),
            leadingIcon: const Icon(Icons.filter_alt_off_outlined, size: 18),
            onPressed: onClear,
            child: Text('Clear ${group.label.toLowerCase()}'),
          ),
      ],
      builder: (context, controller, child) => ActionChip(
        key: Key('$keyPrefix-filter-${group.id}'),
        avatar: Icon(
          active ? Icons.check : Icons.tune,
          size: 16,
          color: active ? theme.colorScheme.primary : null,
        ),
        label: Text(
          active ? '${group.label} (${selected.length})' : group.label,
          style: active
              ? TextStyle(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                )
              : null,
        ),
        onPressed: () {
          if (controller.isOpen) {
            controller.close();
          } else {
            controller.open();
          }
        },
      ),
    );
  }
}

/// The placeholder a filtered list shows when nothing matches.
///
/// Deliberately different from "this list is empty": the rows are there, the
/// filters are what is hiding them, and the one useful action is to drop the
/// filters — offered here so an administrator does not have to scroll back to
/// the bar (on a phone the bar may be several rows above, and inside a long
/// roster the top of the list may be off-screen).
class AdminSearchEmpty extends StatelessWidget {
  const AdminSearchEmpty({
    super.key,
    required this.noun,
    required this.onReset,
  });

  final String noun;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 12),
      child: Column(
        children: [
          Icon(Icons.search_off, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(
            'No $noun match this search and these filters.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          TextButton(
            key: Key('$noun-clear-filters'),
            onPressed: onReset,
            child: const Text('Clear search and filters'),
          ),
        ],
      ),
    );
  }
}
