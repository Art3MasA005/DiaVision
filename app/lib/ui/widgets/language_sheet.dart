/// The language picker, and the Bangla-numeral toggle that travels with it.
///
/// A bottom sheet with the `sheetUp` motion from `design-tokens.json`. Bangla
/// and English are the two shipping languages; the other thirteen in the
/// handoff are scaffolded, not translated, and offering them here would
/// promise something the string table cannot keep.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../l10n/strings.dart';
import '../../state/app_state.dart';
import 'kit.dart';
import 'line_icon.dart';

String supportedLanguageName(String code) =>
    supportedLanguages[code] ?? code.toUpperCase();

Future<void> showLanguageSheet(BuildContext context) {
  final c = context.c;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: c.card,
    barrierColor: c.text.withValues(alpha: 0.32),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: AppRadius.lg),
    ),
    // `sheetUp` — translateY(100%)→0, 280ms ease.
    transitionAnimationController: null,
    builder: (sheetContext) => const _LanguageSheet(),
  );
}

class _LanguageSheet extends StatelessWidget {
  const _LanguageSheet();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = context.c;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
        child: VGap(
          14,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: c.neutral.c300,
                  borderRadius: AppRadius.rPill,
                ),
              ),
            ),
            Text(context.s.languageLabel,
                style: context.t.cardTitle.copyWith(color: c.text)),
            for (final entry in supportedLanguages.entries)
              OptionRow<String>(
                value: entry.key,
                groupValue: app.lang,
                label: entry.value,
                onChanged: (v) async {
                  await app.setLang(v);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),

            // Bangladesh's region pack defaults to Western digits and lets the
            // user switch to Bengali ones, so this is a preference rather than
            // a consequence of picking Bangla.
            AppCard(
              radius: 20,
              color: c.neutral.c200,
              child: HGap(
                12,
                children: [
                  LineIcon(Icons24.globe, size: 18, color: c.neutral.c700),
                  Expanded(
                    child: Text(
                      context.s.homeNumerals,
                      style: context.t.bodyStrong.copyWith(color: c.text),
                    ),
                  ),
                  Switch(
                    value: app.localDigits,
                    activeThumbColor: c.onAccent,
                    activeTrackColor: c.accent,
                    onChanged: app.setLocalDigits,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
