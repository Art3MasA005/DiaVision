/// 05 · Population guidelines — optional.
///
/// This screen has the most careful copy in the product, and three rules that
/// are not style preferences:
///
///   * **Never framed as a question about race or ethnicity.** The heading asks
///     which population's *health guidelines* to use. What it selects is a
///     published clinical threshold set at the calibration layer — the same
///     mechanism as choosing a region pack, keyed on the user rather than the
///     border they happen to live inside. It never reaches the model.
///   * **Never pre-selected** from language, name, or location. The screen
///     opens with nothing chosen, in every locale.
///   * **Genuinely skippable, with no nag.** Skipping leaves the app fully
///     usable and is not asked about again. Under GDPR Art. 9 this is
///     special-category data; omitting it has to cost the user nothing.
///
/// It exists because of a real gap: a Bangladeshi in London was being scored
/// against European cutoffs (BMI 25/30, waist 94cm) instead of Asian-Pacific
/// (23/27.5, 90cm), under-detecting exactly the highest-value users. UK NICE
/// advises the lower thresholds too.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/shell.dart';
import 'wizard_screen.dart';

/// The route-level entry, for direct navigation.
class PopulationScreen extends StatelessWidget {
  const PopulationScreen({super.key});

  @override
  Widget build(BuildContext context) => const PopulationScreenBody();
}

/// The body, so the wizard can host it inside its own route with the answers
/// still in scope.
class PopulationScreenBody extends StatefulWidget {
  const PopulationScreenBody({super.key});

  @override
  State<PopulationScreenBody> createState() => _PopulationScreenBodyState();
}

class _PopulationScreenBodyState extends State<PopulationScreenBody> {
  /// Starts null and stays null until the user picks. Never seeded from the
  /// app language or the region pack.
  AncestryGroup? _selected;

  void _continue({required bool skipped}) {
    final w = WizardScope.of(context);
    final app = AppScope.read(context);

    w.set_(() {
      w.ancestry = skipped ? null : _selected;
      w.ancestrySkipped = skipped;
    });
    // Held client-side: the backend does not yet persist this field. See the
    // gap noted in app/README.md.
    app.setAncestry(skipped ? null : _selected);

    if (skipped) showToast(context, context.s.toastPopSkipped);
    submitProfileAndAssess(context, w);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;

    return Shell(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
                AppSpace.gutter, 10, AppSpace.gutter, 0),
            child: HGap(
              12,
              children: [
                CircleIconButton(
                  icon: Icons24.chevronLeft,
                  semanticLabel: s.back,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Text(
                    s.popKicker,
                    style: context.t.caption.copyWith(
                      color: c.neutral.c600,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                // Skip is a first-class action, sitting level with the title
                // rather than buried at the bottom of the scroll.
                GhostButton(
                  label: s.skip,
                  onPressed: () => _continue(skipped: true),
                ),
              ],
            ),
          ),
          Expanded(
            child: ScreenBody(
              topPad: 14,
              bottomPad: 24,
              gap: 18,
              children: [
                VGap(
                  8,
                  children: [
                    Text(s.popHead,
                        style: context.t.screenTitleSm.copyWith(color: c.text)),
                    P(s.popSub),
                  ],
                ),
                VGap(
                  9,
                  children: [
                    for (final (v, label) in [
                      (AncestryGroup.southAsian, s.popSouthAsian),
                      (AncestryGroup.eastAsian, s.popEastAsian),
                      (AncestryGroup.european, s.popEuropean),
                      (AncestryGroup.african, s.popAfrican),
                      (AncestryGroup.middleEastern, s.popMiddleEastern),
                      (AncestryGroup.hispanic, s.popHispanic),
                    ])
                      OptionRow<AncestryGroup?>(
                        value: v,
                        groupValue: _selected,
                        label: label,
                        onChanged: (x) => setState(() => _selected = x),
                      ),
                    // "Prefer not to say" is a real answer, not the absence of
                    // one, so it sits in the list with the others.
                    OptionRow<AncestryGroup?>(
                      value: null,
                      groupValue: _selected,
                      label: s.popPreferNot,
                      onChanged: (_) => _continue(skipped: true),
                    ),
                  ],
                ),
                AppCard(
                  radius: 24,
                  color: c.accent2Ramp.c100,
                  borderColor: c.accent2Ramp.c300,
                  padding: const EdgeInsets.all(16),
                  child: VGap(
                    8,
                    cross: CrossAxisAlignment.start,
                    children: [
                      Kicker(s.popWhyKicker, color: c.accent2Ramp.c800),
                      P(s.popWhyBody,
                          style: context.t.caption.copyWith(height: 1.6),
                          color: c.accent2Ramp.c900),
                    ],
                  ),
                ),
                P(s.popNote, style: context.t.footnote, color: c.neutral.c600),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
                AppSpace.gutter, 8, AppSpace.gutter, 12),
            child: PillButton(
              label: s.next,
              // Disabled until a choice is made — but Skip above is always
              // live, so this is never a dead end.
              enabled: _selected != null,
              onPressed: () => _continue(skipped: false),
              onDisabledTap: () => _continue(skipped: true),
            ),
          ),
        ],
      ),
    );
  }
}
