/// Renders the waist-measurement diagram to a golden so the artwork can be
/// reviewed as an image rather than as geometry.
///
///   flutter test --update-goldens test/waist_diagram_golden_test.dart
///
/// The golden is a review aid, not a regression gate — re-run it after any
/// change to the painter and look at the output.
library;

import 'package:byebye/core/theme.dart';
import 'package:byebye/core/tokens.dart';
import 'package:byebye/core/typography.dart';
import 'package:byebye/ui/illustrations/waist_diagram.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(AppColors colors, Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: AppTheme(
        colors: colors,
        text: AppText.of(Script.latin),
        child: ColoredBox(
          color: colors.bg,
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    );

void main() {
  testWidgets('waist diagram — all four panels, light and dark',
      (tester) async {
    tester.view.physicalSize = const Size(1520, 900);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    Widget row(AppColors c) => Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 16,
          children: [
            for (final s in WaistStep.values)
              WaistDiagram(step: s, size: 150),
          ],
        );

    await tester.pumpWidget(
      Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _host(AppColors.light, row(AppColors.light)),
          _host(AppColors.dark, row(AppColors.dark)),
        ],
      ),
    );

    await expectLater(
      find.byType(Column).first,
      matchesGoldenFile('goldens/waist_diagram.png'),
    );
  });
}
