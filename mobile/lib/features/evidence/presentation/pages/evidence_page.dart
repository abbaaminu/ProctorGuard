import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/home_button.dart';
import '../../../../core/widgets/responsive_layout.dart';
import '../../../admin/domain/entities/search_query.dart';
import '../../../admin/presentation/widgets/admin_search_bar.dart';
import '../../../exam/domain/entities/exam.dart';
import '../../domain/entities/attempt_evidence.dart';
import '../providers/evidence_providers.dart';

/// The Evidence screen: every incident recorded against one paper, with the
/// still captured for it.
///
/// What it is *not*: a new source of authority. `public.exam_evidence()` answers
/// only for a paper the caller may reach (`can_reach_exam()`), row security still
/// applies underneath, and each still is signed by Storage against the private
/// bucket's policy. So the page does not filter by role, does not decide who may
/// see what, and cannot be made to show a colleague's sitting by changing a route
/// parameter - the worst a wrong id can produce is an empty list.
///
/// The paper picker exists because neither console is scoped to one paper: the
/// lecturer's console lists the papers they wrote and the admin dashboard starts
/// on the roster. The list each portal already loads is reused
/// ([evidenceExamOptionsProvider]) rather than queried again, so the picker can
/// only offer a paper the read would answer for.
///
/// Opened from a specific attempt (the marking queue's Evidence action), the
/// paper is preselected and [highlightSubmissionId] marks the card the reviewer
/// came from.
class EvidencePage extends ConsumerStatefulWidget {
  const EvidencePage({
    super.key,
    required this.audience,
    this.initialExamId,
    this.highlightSubmissionId,
  });

  /// Which portal opened the page. Decides where the paper list comes from and
  /// whether the administrator's student search is offered; nothing else.
  final EvidenceAudience audience;

  /// The paper to open on. Null means "the first paper the account can read".
  final String? initialExamId;

  /// The attempt to mark out, when the page was opened from one.
  final String? highlightSubmissionId;

  @override
  ConsumerState<EvidencePage> createState() => _EvidencePageState();
}

class _EvidencePageState extends ConsumerState<EvidencePage> {
  /// The paper the reviewer picked, or null while the page is on its default.
  String? _examId;

  /// The administrator's student search. Empty on the lecturer's side, where the
  /// attempts on one paper are short enough to read.
  SearchQuery _query = SearchQuery.empty;

  @override
  Widget build(BuildContext context) {
    final gutter = ResponsiveSizing.horizontalPadding(context);
    final options = ref.watch(evidenceExamOptionsProvider(widget.audience));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Evidence'),
        actions: [
          const HomeButton(key: Key('evidence-home')),
          IconButton(
            key: const Key('evidence-refresh'),
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: options.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _EvidenceNotice(
          icon: Icons.error_outline,
          message: '$error',
          onRetry: () =>
              ref.invalidate(evidenceExamOptionsProvider(widget.audience)),
        ),
        data: (papers) {
          if (papers.isEmpty) {
            return const _EvidenceNotice(
              icon: Icons.menu_book_outlined,
              message:
                  'No papers to review yet. The papers you can read '
                  'evidence for appear here.',
            );
          }

          final examId = _selectedExamId(papers);
          final evidence = ref.watch(examEvidenceProvider(examId));

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 0),
                child: DropdownButtonFormField<String>(
                  key: const Key('evidence-exam-picker'),
                  initialValue: examId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Paper',
                    prefixIcon: Icon(Icons.menu_book_outlined),
                    border: OutlineInputBorder(),
                  ),
                  items: <DropdownMenuItem<String>>[
                    for (final paper in papers)
                      DropdownMenuItem<String>(
                        value: paper.id,
                        child: Text(paper.title),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null || value == examId) return;
                    setState(() {
                      _examId = value;
                      // A search carried across papers would hide the new
                      // paper's attempts behind a name from the old one.
                      _query = SearchQuery.empty;
                    });
                  },
                ),
              ),
              Expanded(
                child: evidence.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => _EvidenceNotice(
                    icon: Icons.error_outline,
                    message: '$error',
                    onRetry: () => ref.invalidate(examEvidenceProvider(examId)),
                  ),
                  data: (attempts) => _EvidenceBody(
                    attempts: attempts,
                    audience: widget.audience,
                    query: _query,
                    onQueryChanged: (query) => setState(() => _query = query),
                    highlightSubmissionId: widget.highlightSubmissionId,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// The paper the page is showing.
  ///
  /// [EvidencePage.initialExamId] is honoured while it is one of the papers
  /// offered - a route parameter can name anything, and a picker whose value is
  /// not in its own item list throws. When it is not offered (a paper deleted
  /// under the reviewer, a link from a stale screen) the first paper is shown
  /// instead of an error.
  String _selectedExamId(List<EvidenceExamOption> papers) {
    final available = papers.map((paper) => paper.id).toSet();
    final preferred = _examId ?? widget.initialExamId;
    if (preferred != null && available.contains(preferred)) return preferred;
    return papers.first.id;
  }

  /// Asks for the same two things again: the paper list (an assignment or a new
  /// paper can appear between visits) and the incidents of the paper on screen.
  void _refresh() {
    ref.invalidate(evidenceExamOptionsProvider(widget.audience));
    final examId = _examId ?? widget.initialExamId;
    if (examId != null) ref.invalidate(examEvidenceProvider(examId));
  }
}

/// The list under the picker: the administrator's student search, then one card
/// per sitting.
class _EvidenceBody extends StatelessWidget {
  const _EvidenceBody({
    required this.attempts,
    required this.audience,
    required this.query,
    required this.onQueryChanged,
    this.highlightSubmissionId,
  });

  final List<AttemptEvidence> attempts;
  final EvidenceAudience audience;
  final SearchQuery query;
  final ValueChanged<SearchQuery> onQueryChanged;
  final String? highlightSubmissionId;

  @override
  Widget build(BuildContext context) {
    final gutter = ResponsiveSizing.horizontalPadding(context);
    final visible = query.isActive
        ? attempts
              .where((attempt) => query.matches(recordFor(attempt)))
              .toList(growable: false)
        : attempts;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The administrator's roster is the whole institution, so a sitting has
        // to be findable by the student's name. Same bar, same matching rule and
        // same keys as every other admin list (`admin_search_bar.dart`), with no
        // facets: the only thing to narrow by here is the person.
        if (audience == EvidenceAudience.admin)
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 0),
            child: AdminSearchBar(
              query: query,
              groups: const <SearchFilterGroup>[],
              onChanged: onQueryChanged,
              matchCount: visible.length,
              totalCount: attempts.length,
              noun: 'attempts',
              hintText: 'Search by student name or id…',
              keyPrefix: 'evidence-search',
            ),
          ),
        Expanded(
          child: attempts.isEmpty
              // Nothing recorded is the good answer, and it is a different
              // sentence from "your search matched nothing".
              ? const _EvidenceNotice(
                  icon: Icons.verified_user_outlined,
                  message: 'No incidents were recorded on this paper.',
                )
              : visible.isEmpty
              ? AdminSearchEmpty(
                  noun: 'attempts',
                  onReset: () => onQueryChanged(SearchQuery.empty),
                )
              : ListView.separated(
                  padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 24),
                  itemCount: visible.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 12),
                  itemBuilder: (context, index) => _AttemptCard(
                    attempt: visible[index],
                    highlighted:
                        visible[index].submissionId == highlightSubmissionId,
                  ),
                ),
        ),
      ],
    );
  }

  /// What the free text is matched against: the name shown, the id behind it, the
  /// state, and the actions logged - so "ada", "flagged" and "no face" all find
  /// the sitting they belong to.
  static SearchRecord recordFor(AttemptEvidence attempt) => SearchRecord(
    fields: <String?>[
      attempt.displayName,
      attempt.studentId,
      attempt.statusLabel,
      for (final item in attempt.items) item.actionLabel,
    ],
  );
}

/// One sitting: who, when, how it ended, and the stills behind those incidents.
class _AttemptCard extends StatelessWidget {
  const _AttemptCard({required this.attempt, required this.highlighted});

  final AttemptEvidence attempt;

  /// The attempt the reviewer arrived from. Marked with a border rather than a
  /// scroll jump: it stays obvious while the page is read, and nothing has to
  /// guess an offset in a list that is still being laid out.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = attempt.needsReview ? scheme.error : scheme.primary;

    return Card(
      key: Key('evidence-attempt-${attempt.submissionId}'),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: highlighted ? scheme.primary : scheme.outlineVariant,
          width: highlighted ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: accent.withValues(alpha: 0.12),
                  foregroundColor: accent,
                  child: Icon(
                    attempt.needsReview
                        ? Icons.flag_outlined
                        : Icons.person_outline,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        attempt.displayName,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${attempt.statusLabel} · sat ${_satAt(attempt.startedAt)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _countsLine(attempt),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final item in attempt.items) _StillTile(item: item),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// `Exam.formatStamp` is the console's one date format; an attempt row always
  /// carries `started_at`, so the fallback is for a row that arrived malformed
  /// rather than a state the server produces.
  static String _satAt(DateTime? startedAt) =>
      startedAt == null ? 'at an unknown time' : Exam.formatStamp(startedAt);

  /// "3 incidents · 2 counted points", with the still count when it differs - the
  /// one line that says whether this sitting needs a decision.
  static String _countsLine(AttemptEvidence attempt) {
    final incidents = attempt.items.length;
    final stills = attempt.items.where((item) => item.hasStill).length;
    final points = attempt.points;
    return <String>[
      '$incidents ${incidents == 1 ? 'incident' : 'incidents'}',
      '$points counted ${points == 1 ? 'point' : 'points'}',
      if (stills != incidents) '$stills ${stills == 1 ? 'still' : 'stills'}',
    ].join(' · ');
  }
}

/// One incident's still: the picture, or the reason there is none.
///
/// Signing is **per tile and lazy**: the URL is minted when this widget is
/// mounted - so only for tiles actually built - and it is never stored anywhere
/// that outlives the widget. The minted URL is valid for ten minutes
/// (`SupabaseService.snapshotUrlTtl`); keeping it in a provider or on the entity
/// would hand a later visit a URL that has already expired, which is why nothing
/// above this class holds one.
///
/// A failure is retried exactly once (a cold Storage edge, a dropped packet) and
/// then reported on the tile. It never fails the page: the incident is the
/// evidence, and the photograph is one of the two things that can be missing.
class _StillTile extends ConsumerStatefulWidget {
  const _StillTile({required this.item});

  final EvidenceItem item;

  @override
  ConsumerState<_StillTile> createState() => _StillTileState();
}

class _StillTileState extends ConsumerState<_StillTile> {
  static const double tileWidth = 168;
  static const double imageHeight = 126;

  String? _url;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _sign();
  }

  Future<void> _sign() async {
    final path = widget.item.snapshotUrl;
    if (path == null) return;

    final repository = ref.read(evidenceRepositoryProvider);
    for (var attempt = 0; attempt < 2; attempt++) {
      final url = await repository.signedStillUrl(path);
      if (!mounted) return;
      if (url != null) {
        setState(() => _url = url);
        return;
      }
    }
    if (mounted) setState(() => _failed = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = widget.item;

    return SizedBox(
      width: tileWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: tileWidth,
              height: imageHeight,
              child: _picture(),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.actionLabel,
            style: theme.textTheme.labelLarge,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            <String>[
              item.weightLabel,
              if (item.loggedAt != null) Exam.formatStamp(item.loggedAt!),
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            maxLines: 2,
          ),
        ],
      ),
    );
  }

  Widget _picture() {
    final item = widget.item;

    if (!item.hasStill) {
      // An incident logged with no picture: offline, camera busy, or the upload
      // was refused. The row is still evidence, so the tile says what it is
      // missing instead of disappearing.
      return const _StillPlaceholder(
        icon: Icons.image_not_supported_outlined,
        message: 'No still',
      );
    }

    final url = _url;
    if (url == null) {
      return _StillPlaceholder(
        icon: _failed ? Icons.broken_image_outlined : Icons.hourglass_empty,
        message: _failed ? 'Preview unavailable' : 'Loading still…',
      );
    }

    return Image.network(
      url,
      key: Key('evidence-still-${item.logId}'),
      fit: BoxFit.cover,
      // A still that will not decode is the same outcome as one Storage refused:
      // the tile says so, the page carries on.
      errorBuilder: (context, error, stackTrace) => const _StillPlaceholder(
        icon: Icons.broken_image_outlined,
        message: 'Preview unavailable',
      ),
      loadingBuilder: (context, child, progress) => progress == null
          ? child
          : const _StillPlaceholder(
              icon: Icons.hourglass_empty,
              message: 'Loading still…',
            ),
    );
  }
}

/// What a tile shows instead of a picture.
class _StillPlaceholder extends StatelessWidget {
  const _StillPlaceholder({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 4),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A message in place of the list, with an optional retry.
class _EvidenceNotice extends StatelessWidget {
  const _EvidenceNotice({
    required this.icon,
    required this.message,
    this.onRetry,
  });

  final IconData icon;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              TextButton(
                key: const Key('evidence-retry'),
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
