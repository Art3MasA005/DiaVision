/// Design tokens, ported from
/// `design_handoff/design_handoff_byebyediabetes/design-tokens.json`.
///
/// PALETTE DECISION: the handoff's Organic terracotta-and-sand system wins over
/// the deep teal proposed in `docs/ui_spec.md` §6. The handoff README flags the
/// divergence and asks for a decision; design-tokens.json is the later,
/// machine-readable, high-fidelity source, so it is the one we build against.
/// The two roles the spec cares about most — safety `#9f1239` and caution
/// `#a2560b` — are identical in both, so nothing safety-critical turns on this.
///
/// Every value here is a straight transcription. If the JSON changes, change
/// this file with it; a test asserts the two stay in step.
library;

import 'package:flutter/widgets.dart';

/// A 100–900 ramp. Index by the same numbers the JSON uses.
class Ramp {
  const Ramp({
    required this.c100,
    required this.c200,
    required this.c300,
    required this.c400,
    required this.c500,
    required this.c600,
    required this.c700,
    required this.c800,
    required this.c900,
  });

  final Color c100, c200, c300, c400, c500, c600, c700, c800, c900;
}

/// The colours that flip between light and dark. Dark remaps the same names,
/// so every screen flips together — no per-screen dark handling anywhere.
class AppColors {
  const AppColors({
    required this.bg,
    required this.surface,
    required this.text,
    required this.card,
    required this.pill,
    required this.pillFg,
    required this.onAccent,
    required this.accent,
    required this.accent2,
    required this.accentRamp,
    required this.accent2Ramp,
    required this.neutral,
    required this.safety,
    required this.safetyTint,
    required this.safetyBorder,
    required this.caution,
    required this.cautionTint,
    required this.cautionBorder,
    required this.isDark,
  });

  final Color bg, surface, text, card, pill, pillFg, onAccent, accent, accent2;
  final Ramp accentRamp, accent2Ramp, neutral;

  /// SAFETY CARDS ONLY. Never a risk band, a missed goal, or a rising trend.
  /// The moment it appears somewhere ordinary it stops meaning anything.
  final Color safety, safetyTint, safetyBorder;

  final Color caution, cautionTint, cautionBorder;
  final bool isDark;

  static const light = AppColors(
    bg: Color(0xFFF5EAD8),
    surface: Color(0xFFEBDDC5),
    text: Color(0xFF201E1D),
    card: Color(0xFFFFFDF9),
    pill: Color(0xFF201E1D),
    pillFg: Color(0xFFF9F4ED),
    onAccent: Color(0xFFFFFDF9),
    accent: Color(0xFFC67139),
    accent2: Color(0xFF7A8A5E),
    accentRamp: Ramp(
      c100: Color(0xFFFFF2EB),
      c200: Color(0xFFFFE1D0),
      c300: Color(0xFFFFC6A5),
      c400: Color(0xFFF6A06B),
      c500: Color(0xFFD67F48),
      c600: Color(0xFFB2622D),
      c700: Color(0xFF8C491A),
      c800: Color(0xFF643312),
      c900: Color(0xFF402310),
    ),
    accent2Ramp: Ramp(
      c100: Color(0xFFF0FAE1),
      c200: Color(0xFFE1EECC),
      c300: Color(0xFFCCDBB2),
      c400: Color(0xFFAEBF92),
      c500: Color(0xFF8FA073),
      c600: Color(0xFF728157),
      c700: Color(0xFF56633F),
      c800: Color(0xFF3D472B),
      c900: Color(0xFF272E1B),
    ),
    neutral: Ramp(
      c100: Color(0xFFF9F4ED),
      c200: Color(0xFFEEE7DB),
      c300: Color(0xFFDCD3C4),
      c400: Color(0xFFC0B6A5),
      c500: Color(0xFFA19786),
      c600: Color(0xFF82796A),
      c700: Color(0xFF645C50),
      c800: Color(0xFF474238),
      c900: Color(0xFF2E2B25),
    ),
    safety: Color(0xFF9F1239),
    safetyTint: Color(0xFFFBEDF0),
    safetyBorder: Color(0xFFEECFD7),
    caution: Color(0xFFA2560B),
    cautionTint: Color(0xFFFBF1E3),
    cautionBorder: Color(0xFFECD6B6),
    isDark: false,
  );

  /// `darkTheme` in the JSON only overrides some keys; the rest inherit.
  /// Ramp steps the JSON leaves out are interpolated between the ones it gives,
  /// so the ramp stays monotonic instead of jumping.
  static const dark = AppColors(
    bg: Color(0xFF1A1815),
    surface: Color(0xFF221F1B),
    text: Color(0xFFF4ECE0),
    card: Color(0xFF26231F),
    pill: Color(0xFFF0E6D6),
    pillFg: Color(0xFF201E1D),
    onAccent: Color(0xFF201E1D),
    accent: Color(0xFFD98A50),
    accent2: Color(0xFF97A874),
    accentRamp: Ramp(
      c100: Color(0xFF382A1F),
      c200: Color(0xFF4A3324),
      c300: Color(0xFF6B472D),
      c400: Color(0xFF8A5C38),
      c500: Color(0xFFAB7648),
      c600: Color(0xFFC8905C),
      c700: Color(0xFFE6A875),
      c800: Color(0xFFF0C9A5),
      c900: Color(0xFFF7E0C8),
    ),
    accent2Ramp: Ramp(
      c100: Color(0xFF262F1F),
      c200: Color(0xFF313F28),
      c300: Color(0xFF465635),
      c400: Color(0xFF5E7146),
      c500: Color(0xFF788C58),
      c600: Color(0xFF93A76B),
      c700: Color(0xFFAAC37C),
      c800: Color(0xFFCFE0B4),
      c900: Color(0xFFE4EFD0),
    ),
    neutral: Ramp(
      c100: Color(0xFF1E1C19),
      c200: Color(0xFF2B2823),
      c300: Color(0xFF3B362E),
      c400: Color(0xFF4E4840),
      c500: Color(0xFF7C7469),
      c600: Color(0xFFA69C8F),
      c700: Color(0xFFC4BAAB),
      c800: Color(0xFFE0D6C6),
      c900: Color(0xFFF2E9DA),
    ),
    safety: Color(0xFFF2A3B4),
    safetyTint: Color(0xFF3A1E26),
    safetyBorder: Color(0xFF5E2C39),
    caution: Color(0xFFE6B077),
    cautionTint: Color(0xFF3A2A17),
    cautionBorder: Color(0xFF5C452A),
    isDark: true,
  );
}

/// Radii. `pill` is the 999px stadium.
abstract final class AppRadius {
  static const sm = Radius.circular(8);
  static const md = Radius.circular(16);
  static const lg = Radius.circular(28);
  static const pill = Radius.circular(999);

  static const rSm = BorderRadius.all(sm);
  static const rMd = BorderRadius.all(md);
  static const rLg = BorderRadius.all(lg);
  static const rPill = BorderRadius.all(pill);

  static BorderRadius card(double r) => BorderRadius.circular(r);
}

/// Spacing. `s*` are the raw scale; the `in-app` values the handoff actually
/// uses per screen are named separately because they are what the layouts read.
abstract final class AppSpace {
  static const s1 = 4.4;
  static const s2 = 8.8;
  static const s3 = 13.2;
  static const s4 = 17.6;
  static const s6 = 26.4;
  static const s8 = 35.2;

  /// Screen gutter — 18px on every scrolling screen.
  static const gutter = 18.0;

  /// Clears the floating nav pill at the bottom of a scroll view.
  static const bottomPad = 128.0;

  /// Vertical gap between the cards inside one group.
  static const stack = 10.0;

  /// Vertical gap between two sections.
  static const section = 20.0;
}

/// Shadows. Colour is `#2e2b25` at the stated alpha.
abstract final class AppShadow {
  static const _ink = Color(0xFF2E2B25);

  static List<BoxShadow> sm(bool isDark) => [
        BoxShadow(
          color: _ink.withValues(alpha: isDark ? 0.34 : 0.14),
          blurRadius: 2,
          offset: const Offset(0, 1),
        ),
      ];

  static List<BoxShadow> md(bool isDark) => [
        BoxShadow(
          color: _ink.withValues(alpha: isDark ? 0.38 : 0.16),
          blurRadius: 10,
          offset: const Offset(0, 3),
        ),
      ];

  static List<BoxShadow> lg(bool isDark) => [
        BoxShadow(
          color: _ink.withValues(alpha: isDark ? 0.48 : 0.22),
          blurRadius: 32,
          offset: const Offset(0, 12),
        ),
      ];
}

/// Motion, transcribed from the JSON. Nothing bounces and nothing celebrates —
/// this app handles a frightening topic.
abstract final class AppMotion {
  static const riseIn = Duration(milliseconds: 280);
  static const sheetUp = Duration(milliseconds: 280);
  static const markIn = Duration(milliseconds: 700);
  static const blobDrift = Duration(seconds: 10);
  static const loadSlide = Duration(milliseconds: 1400);
  static const calcSpin = Duration(milliseconds: 2400);
  static const toast = Duration(milliseconds: 2600);

  static const riseCurve = Curves.ease;
  static const markCurve = Cubic(0.2, 0.8, 0.2, 1);
}

/// Lucide-style stroke settings for every icon we draw.
abstract final class AppIcon {
  static const strokeWidth = 2.75;
  static const cap = StrokeCap.round;
  static const join = StrokeJoin.round;
}
