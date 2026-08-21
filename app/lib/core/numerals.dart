/// The single number formatter.
///
/// Every number the UI renders goes through here — the handoff is explicit
/// that this is one formatter, not a per-screen `toString()`. Bangla, Hindi,
/// Arabic and Urdu render local numerals; everyone else renders Western.
///
/// What is *stored* is always canonical SI in Western digits. This is display
/// only, and it never reaches the API layer.
library;

/// Digit sets, keyed by language code.
const _digits = <String, String>{
  'bn': '০১২৩৪৫৬৭৮৯',
  'hi': '०१२३४५६७८९',
  'ar': '٠١٢٣٤٥٦٧٨٩',
  'ur': '۰۱۲۳۴۵۶۷۸۹',
};

class Numerals {
  const Numerals(this.lang, {this.useLocalDigits = true});

  final String lang;

  /// Bangladesh's region pack defaults to Western digits and lets the user
  /// switch to Bengali ones, so this is a preference, not a consequence of the
  /// language choice.
  final bool useLocalDigits;

  String? get _set => useLocalDigits ? _digits[lang] : null;

  /// Transliterate the ASCII digits in [input], leaving everything else alone.
  String digits(String input) {
    final set = _set;
    if (set == null) return input;
    final out = StringBuffer();
    for (final rune in input.runes) {
      if (rune >= 0x30 && rune <= 0x39) {
        out.write(set[rune - 0x30]);
      } else {
        out.writeCharCode(rune);
      }
    }
    return out.toString();
  }

  /// An integer.
  String int_(num value) => digits(value.round().toString());

  /// A decimal at [places]. Trailing zeros are kept — `6.0%` reads as a
  /// measured value, `6%` reads as a rounded one.
  String decimal(num value, {int places = 1}) =>
      digits(value.toStringAsFixed(places));

  /// A percentage from a 0–1 probability.
  String percent(double p) => '${digits((p * 100).round().toString())}%';

  /// A risk range. NEVER render a point value — rule 1, and the reason this
  /// helper exists at all rather than a generic percent formatter.
  String range(double low, double high) =>
      '${digits((low * 100).round().toString())}–'
      '${digits((high * 100).round().toString())}%';

  /// `x of y`, for step counters and goals.
  String pair(num a, num b) => '${int_(a)}/${int_(b)}';
}
