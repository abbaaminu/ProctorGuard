import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Width breakpoints shared by every student-facing screen.
///
/// The app runs on Android phones *and* in desktop browsers (Chrome/Edge), so
/// layouts key off the **available width** instead of the platform: a 360 dp
/// phone and a narrow browser window behave the same, and a 1440 px monitor
/// gets the roomy treatment. Reading `MediaQuery.sizeOf` only where the size is
/// actually needed keeps a resize from rebuilding unrelated subtrees.
abstract final class Breakpoints {
  const Breakpoints._();

  /// Desktop browser / tablet landscape: side-by-side layouts start here.
  static const double expanded = 900;

  /// Large phone / small tablet: extra padding, still a single column.
  static const double medium = 600;
}

/// Padding and sizing rules derived from the current viewport.
abstract final class ResponsiveSizing {
  const ResponsiveSizing._();

  static Size viewportOf(BuildContext context) => MediaQuery.sizeOf(context);

  static bool isExpanded(BuildContext context) =>
      viewportOf(context).width >= Breakpoints.expanded;

  static bool isLandscapeOrWide(BuildContext context) {
    final size = viewportOf(context);
    return size.width >= Breakpoints.medium || size.width > size.height;
  }

  /// Gutters that stay comfortable on a phone and do not look lost on a monitor.
  static double horizontalPadding(BuildContext context) {
    final width = viewportOf(context).width;
    if (width >= Breakpoints.expanded) return 32;
    if (width >= Breakpoints.medium) return 24;
    return 16;
  }

  /// A readable column width for the given content kind.
  static double contentWidth(BuildContext context, {double phone = 520, double desktop = 720}) =>
      isExpanded(context) ? desktop : phone;
}

/// Centres [child] in the viewport and clamps it to a readable [maxWidth].
///
/// This is what keeps a phone layout from being stretched across a monitor —
/// the padding grows with the viewport, the content column does not.
class ResponsiveContent extends StatelessWidget {
  const ResponsiveContent({
    super.key,
    required this.child,
    this.maxWidth = 720,
    this.padding,
    this.alignment = Alignment.topCenter,
  });

  final Widget child;
  final double maxWidth;

  /// Overrides the width-derived gutter.
  final EdgeInsetsGeometry? padding;

  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final insets = padding ??
        EdgeInsets.symmetric(
          horizontal: ResponsiveSizing.horizontalPadding(context),
          vertical: 16,
        );

    return Align(
      alignment: alignment,
      child: Padding(
        padding: insets,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      ),
    );
  }
}

/// A page body that *fills* the viewport and scrolls only when it has to.
///
/// A bare `Center(Column(...))` overflows the moment the content is taller than
/// the viewport — a phone in landscape, a desktop window resized short, or a
/// large accessibility text scale. Here the content is centred while it fits (so
/// there is no awkward top gap on a tall screen) and becomes scrollable as soon
/// as it does not.
class ResponsiveScrollView extends StatelessWidget {
  const ResponsiveScrollView({
    super.key,
    required this.child,
    this.maxWidth = 560,
    this.padding,
    this.centerVertically = true,
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry? padding;

  /// When false the content sticks to the top and only scrolls.
  final bool centerVertically;

  @override
  Widget build(BuildContext context) {
    final insets = padding ??
        EdgeInsets.symmetric(
          horizontal: ResponsiveSizing.horizontalPadding(context),
          vertical: 24,
        );

    return LayoutBuilder(
      builder: (context, constraints) {
        // `maxHeight` is Infinity when a parent gives unbounded height; the
        // clamp keeps the min-height constraint valid in that case.
        final minHeight = constraints.maxHeight.isFinite
            ? math.max(0.0, constraints.maxHeight - insets.vertical)
            : 0.0;

        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: insets,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Align(
              alignment: centerVertically
                  ? Alignment.center
                  : Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}
