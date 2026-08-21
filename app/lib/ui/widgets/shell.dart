/// The screen shell every screen sits inside.
///
/// Carries the offline banner, the `riseIn` enter animation, and the floating
/// nav pill — so no screen has to remember any of them.
///
/// **The nav pill is hidden on splash, auth, disclaimer and calculating.**
/// Those are gates, and a gate with an escape hatch is not a gate. Screens
/// pass a [tab] to show it; omitting the tab hides it, which makes the safe
/// default the one you get by not thinking about it.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import 'kit.dart';
import 'language_sheet.dart';
import 'line_icon.dart';
import 'nav_pill.dart';

class Shell extends StatelessWidget {
  const Shell({
    super.key,
    required this.child,
    this.showLanguageSwitch = false,
    this.safeBottom = true,
    this.tab,
  });

  final Widget child;
  final bool showLanguageSwitch;
  final bool safeBottom;

  /// Which nav destination this screen is. Null on the gated screens, which
  /// is why null is the default.
  final NavTab? tab;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      backgroundColor: context.c.bg,
      body: SafeArea(
        bottom: safeBottom,
        child: Stack(
          children: [
            Column(
              children: [
                // Quiet, persistent, never blocking — the cached result and
                // the estimate both still work without a connection.
                if (app.offline) const OfflineBanner(),
                if (showLanguageSwitch) const _LanguageRow(),
                Expanded(child: RiseIn(child: child)),
              ],
            ),
            if (tab != null)
              PositionedDirectional(
                start: 0,
                end: 0,
                bottom: 0,
                child: NavPill(
                  current: tab!,
                  onSelect: (selected) => _go(context, selected),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _go(BuildContext context, NavTab selected) {
    if (selected == tab) return;
    final route = switch (selected) {
      NavTab.home => Routes.home,
      NavTab.tracker => Routes.tracker,
      NavTab.scan => Routes.scan,
      NavTab.activity => Routes.activity,
      NavTab.coach => Routes.coach,
    };
    // Replace rather than push: the five destinations are siblings, and
    // stacking them would build a back history nobody asked for.
    Navigator.of(context).pushReplacementNamed(route);
  }
}

class _LanguageRow extends StatelessWidget {
  const _LanguageRow();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 10, 0),
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: GhostButton(
          label: supportedLanguageName(app.lang),
          icon: Icons24.globe,
          onPressed: () => showLanguageSheet(context),
        ),
      ),
    );
  }
}

/// A back/title header row, shared by the screens that are pushed rather than
/// navigated to from the pill.
class ScreenHeader extends StatelessWidget {
  const ScreenHeader({
    super.key,
    required this.title,
    this.trailing,
    this.onBack,
  });

  final String title;
  final Widget? trailing;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(18, 10, 18, 0),
      child: HGap(
        12,
        children: [
          CircleIconButton(
            icon: Icons24.chevronLeft,
            semanticLabel: context.s.back,
            onPressed: onBack ?? () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Text(
              title,
              style: context.t.cardTitle.copyWith(color: c.text),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
