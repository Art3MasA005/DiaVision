/// The floating navigation pill.
///
/// Five destinations, absolute at the bottom of the screen. **Hidden on
/// splash, auth, disclaimer and calculating** — there is no escape from a
/// gate, and the shell enforces that rather than each screen remembering.
///
/// A scrolling screen under this pill needs 128px of bottom padding to clear
/// it; [ScreenBody] applies that by default.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import 'line_icon.dart';

enum NavTab { home, tracker, scan, activity, coach }

class NavPill extends StatelessWidget {
  const NavPill({super.key, required this.current, required this.onSelect});

  final NavTab current;
  final ValueChanged<NavTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;

    final items = <(NavTab, String, String)>[
      (NavTab.home, Icons24.navHome, s.navHome),
      (NavTab.tracker, Icons24.navBowl, s.navTracker),
      (NavTab.scan, Icons24.navCamera, s.navScan),
      (NavTab.activity, Icons24.navWalk, s.navActivity),
      (NavTab.coach, Icons24.navChat, s.navCoach),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: c.pill,
            borderRadius: AppRadius.rPill,
            boxShadow: AppShadow.lg(c.isDark),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (tab, icon, label) in items)
                _NavItem(
                  icon: icon,
                  label: label,
                  selected: tab == current,
                  onTap: () => onSelect(tab),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    // The pill sits on `--pill`, so its foreground is `--pill-fg` — inverted
    // from the rest of the app, in both themes.
    final fg = selected ? c.pillFg : c.pillFg.withValues(alpha: 0.55);

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: AppMotion.riseIn,
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? c.pillFg.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: AppRadius.rPill,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 3,
              children: [
                LineIcon(icon, size: 20, color: fg),
                // No fixed height — a longer Bangla label grows the pill
                // rather than clipping.
                Text(
                  label,
                  style: context.t.footnote.copyWith(
                    color: fg,
                    fontSize: 10.5,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
