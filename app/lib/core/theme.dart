/// Theme plumbing and the `context.c` / `context.t` / `context.s` accessors
/// every screen reads.
///
/// The tokens are carried by a plain [InheritedWidget] rather than Material's
/// [ThemeData], because the design system is not Material and mapping a warm
/// terracotta ramp onto ColorScheme roles would lose information. A minimal
/// [ThemeData] still goes to [MaterialApp] so Material's own overlays — text
/// selection, scrollbars, the cursor — pick up the right colours.
library;

import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'numerals.dart';
import 'tokens.dart';
import 'typography.dart';

class AppTheme extends InheritedWidget {
  const AppTheme({
    super.key,
    required this.colors,
    required this.text,
    required super.child,
  });

  final AppColors colors;
  final AppText text;

  static AppTheme of(BuildContext context) {
    final t = context.dependOnInheritedWidgetOfExactType<AppTheme>();
    assert(t != null, 'AppTheme is missing above this widget');
    return t!;
  }

  @override
  bool updateShouldNotify(AppTheme old) =>
      old.colors != colors || old.text != text;
}

extension ThemeAccess on BuildContext {
  /// Colours.
  AppColors get c => AppTheme.of(this).colors;

  /// Type scale, already carrying the current script's font stack.
  AppText get t => AppTheme.of(this).text;

  /// Strings for the current language.
  Strings get s => AppScope.of(this).s;

  /// The single number formatter.
  Numerals get n => AppScope.of(this).n;

  bool get isDark => c.isDark;
}

/// Wraps [child] with the tokens for the current language and theme mode.
class ThemeHost extends StatelessWidget {
  const ThemeHost({super.key, required this.builder});

  final Widget Function(BuildContext, AppColors) builder;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final platformDark =
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final dark = switch (app.themeMode) {
      AppThemeMode.light => false,
      AppThemeMode.dark => true,
      AppThemeMode.system => platformDark,
    };
    final colors = dark ? AppColors.dark : AppColors.light;

    return AppTheme(
      colors: colors,
      text: AppText.of(app.script),
      child: Builder(builder: (inner) => builder(inner, colors)),
    );
  }
}

/// The minimal Material theme. Everything visible is drawn by our own widgets;
/// this exists so Material's built-in chrome does not clash.
ThemeData materialTheme(AppColors c) {
  final base = c.isDark ? ThemeData.dark() : ThemeData.light();
  return base.copyWith(
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    splashFactory: InkRipple.splashFactory,
    colorScheme: base.colorScheme.copyWith(
      primary: c.accent,
      onPrimary: c.onAccent,
      secondary: c.accent2,
      surface: c.card,
      onSurface: c.text,
      error: c.safety,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.accentRamp.c300.withValues(alpha: 0.55),
      selectionHandleColor: c.accent,
    ),
    // Focus is `2px solid accent` at 2px offset everywhere — never the
    // platform default, which disappears against the warm ground.
    focusColor: c.accent.withValues(alpha: 0.2),
  );
}

/// Text scaling. The spec asks for full dynamic type; the cap exists only to
/// stop the largest accessibility sizes from breaking the phone-frame layouts
/// entirely, and it is generous.
TextScaler clampScaler(BuildContext context) =>
    MediaQuery.textScalerOf(context).clamp(minScaleFactor: 1.0, maxScaleFactor: 1.8);
