/// The type system.
///
/// Two constraints from `ui_spec.md` §6 shape everything here:
///
///   * **16sp minimum body text.** Older adults are a core demographic, not an
///     edge case. `body`/`bodyLarge` sit at or above it; the smaller ramp steps
///     are captions and kickers only, and nothing read as body copy uses them.
///   * **Bangla must sit at the same optical size as Latin.** Noto Sans Bengali
///     runs optically smaller than Figtree at the same px, so [AppText.of]
///     applies a per-script size nudge rather than shipping Bangla that reads
///     smaller than the English beside it.
///
/// The handoff's px values are the design's *ratios*. We keep the ratios and
/// lift the floor, because a design px value never outranks an accessibility
/// rule.
library;

import 'package:flutter/widgets.dart';

/// Which font stack a locale draws from.
enum Script { latin, bengali }

class AppText {
  const AppText._(this._script, this._scale);

  final Script _script;
  final double _scale;

  /// Bangla is drawn ~6% larger so it lands at the same optical size as the
  /// Latin beside it. Measured against Figtree at 16px.
  static const _bengaliOpticalNudge = 1.06;

  factory AppText.of(Script script, {double scale = 1.0}) => AppText._(
        script,
        scale * (script == Script.bengali ? _bengaliOpticalNudge : 1.0),
      );

  String get _bodyFamily =>
      _script == Script.bengali ? 'NotoSansBengali' : 'Figtree';

  /// Caprasimo has no Bengali coverage, so Bangla headings fall back to the
  /// Bengali body face at a heavier weight. Never let a heading silently
  /// render as tofu.
  String get _headingFamily =>
      _script == Script.bengali ? 'NotoSansBengali' : 'Caprasimo';

  /// Applied to every style, in both scripts.
  ///
  /// The Latin faces have no Bengali coverage, and that includes the taka sign
  /// `৳` (U+09F3) — which the paywall shows to an English-reading user in
  /// Bangladesh. Without a fallback it rendered as a tofu box. Chaining the
  /// Bengali face behind the Latin ones costs nothing when it is not needed
  /// and prevents a whole class of missing-glyph bugs.
  static const _fallback = ['NotoSansBengali', 'Figtree'];

  /// Variable fonts need the axis driven explicitly; relying on synthetic bold
  /// gives a different weight on each platform.
  List<FontVariation> _wght(double w) =>
      _bodyFamily == 'Figtree' || _bodyFamily == 'NotoSansBengali'
          ? [FontVariation('wght', w)]
          : const [];

  TextStyle _heading(double size, double height, {double bengaliWeight = 700}) {
    final isCaprasimo = _headingFamily == 'Caprasimo';
    return TextStyle(
      fontFamily: _headingFamily,
      fontFamilyFallback: _fallback,
      fontSize: size * _scale,
      height: height,
      // Caprasimo ships weight 400 only.
      fontWeight: isCaprasimo
          ? FontWeight.w400
          : FontWeight.values[(bengaliWeight ~/ 100) - 1],
      fontVariations: isCaprasimo ? const [] : [FontVariation('wght', bengaliWeight)],
      leadingDistribution: TextLeadingDistribution.even,
    );
  }

  TextStyle _body(double size, double height, double weight) => TextStyle(
        fontFamily: _bodyFamily,
        fontFamilyFallback: _fallback,
        fontSize: size * _scale,
        height: height,
        fontWeight: FontWeight.values[(weight ~/ 100) - 1],
        fontVariations: _wght(weight),
        leadingDistribution: TextLeadingDistribution.even,
      );

  // ── headings ────────────────────────────────────────────────────────

  /// The risk range on the result screen. 44/1.1.
  TextStyle get heroNumber => _heading(44, 1.1).withTabular();

  /// Splash wordmark. 38/1.06.
  TextStyle get wordmark => _heading(38, 1.06);

  /// Screen title. 25–27/1.2.
  TextStyle get screenTitle => _heading(26, 1.2);

  /// Slightly smaller screen title, for the denser screens.
  TextStyle get screenTitleSm => _heading(24, 1.25);

  /// Card title. 19–21/1.2.
  TextStyle get cardTitle => _heading(19.5, 1.22);

  /// Section heading inside a screen. 18.5/1.25.
  TextStyle get sectionTitle => _heading(18.5, 1.25);

  /// A number that carries a card — stepper values, live slider readouts.
  TextStyle get statValue => _heading(23, 1.2).withTabular();

  /// Pill button label.
  TextStyle get button => _heading(16, 1.2);

  // ── body ────────────────────────────────────────────────────────────

  /// 16/1.55. The floor for anything read as body copy.
  TextStyle get bodyLarge => _body(16, 1.55, 500);

  /// 16/1.6. The disclaimer card — the one block that must not be shrunk.
  TextStyle get bodyDisclaimer => _body(16, 1.7, 500);

  /// 16/1.5, semibold. Field values and option labels.
  TextStyle get bodyStrong => _body(16, 1.5, 600);

  /// 16/1.5. Default body.
  TextStyle get body => _body(16, 1.55, 500);

  /// Row title inside a card.
  TextStyle get rowTitle => _body(16, 1.3, 700);

  /// 14/1.55. Captions and helper text — never used for body copy.
  TextStyle get caption => _body(14, 1.55, 500);

  /// 14/1.5, bold. Points pills, small emphatic numbers.
  TextStyle get captionStrong => _body(14, 1.5, 700).withTabular();

  /// 12.5/1.5. The absolute floor, for footnotes and legal microcopy only.
  TextStyle get footnote => _body(12.5, 1.55, 500);

  /// Uppercase kicker. 11px, .10–.14em tracking, weight 700.
  TextStyle get kicker => _body(11.5, 1.2, 700).copyWith(letterSpacing: 1.15);
}

extension TabularFigures on TextStyle {
  /// `font-variant-numeric: tabular-nums` — on every number that can change or
  /// stack, so a rising figure does not make the row twitch.
  TextStyle withTabular() => copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}
