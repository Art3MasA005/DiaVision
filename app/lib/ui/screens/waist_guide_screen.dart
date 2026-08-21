/// The waist-measurement guide — `ui_spec.md` §2 screen 07.
///
/// The spec calls this out as earning its place: waist is the strongest single
/// measurement in the form and the one most often measured wrongly, so the
/// guide is worth a whole screen rather than a line of helper text.
///
/// This is where the illustration the handoff lists as missing now lives. See
/// `ui/illustrations/waist_diagram.dart` for why it is drawn rather than
/// shipped as an image.
///
/// Presented as a full-height sheet rather than a route, so it reads as a
/// detour from the waist question and returns the user to exactly where they
/// were — measuring is something you do mid-form, not before it.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../illustrations/waist_diagram.dart';

Future<void> showWaistGuide(BuildContext context) {
  final c = context.c;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: c.bg,
    barrierColor: c.text.withValues(alpha: 0.32),
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: AppRadius.lg),
    ),
    builder: (_) => const WaistGuideSheet(),
  );
}

class WaistGuideSheet extends StatelessWidget {
  const WaistGuideSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;

    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.96,
      expand: false,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: c.neutral.c300,
                borderRadius: AppRadius.rPill,
              ),
            ),
          ),
          Expanded(
            child: ScreenBody(
              controller: controller,
              topPad: 10,
              bottomPad: 28,
              gap: 18,
              children: [
                HGap(
                  12,
                  cross: CrossAxisAlignment.start,
                  children: [
                    IconChip(icon: Icons24.ruler, size: 46, iconSize: 22),
                    Expanded(
                      child: VGap(
                        6,
                        cross: CrossAxisAlignment.start,
                        children: [
                          Text(s.waistGuideHead,
                              style: context.t.screenTitleSm
                                  .copyWith(color: c.text)),
                          P(s.waistGuideSub, style: context.t.caption),
                        ],
                      ),
                    ),
                  ],
                ),

                // The four panels. Wordless artwork, live localized numbers,
                // and one screen-reader description for the whole sequence.
                WaistDiagramSequence(
                  captions: [
                    s.waistGuideStep1,
                    s.waistGuideStep2,
                    s.waistGuideStep3,
                    s.waistGuideStep4,
                  ],
                ),

                // Most people in this market will not own a tape measure.
                // Saying so plainly beats assuming one.
                AppCard(
                  radius: 20,
                  color: c.accent2Ramp.c100,
                  borderColor: c.accent2Ramp.c300,
                  child: HGap(
                    11,
                    cross: CrossAxisAlignment.start,
                    children: [
                      LineIcon(Icons24.infoCircle,
                          size: 18, color: c.accent2Ramp.c700),
                      Expanded(
                        child: P(s.waistGuideNoTape,
                            style: context.t.caption,
                            color: c.accent2Ramp.c900),
                      ),
                    ],
                  ),
                ),

                PillButton(
                  label: s.waistGuideCtaDone,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
