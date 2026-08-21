/// 19 · Safety and edge states.
///
/// Five states. In the app they are triggered, never browsable.
///
///   * **Safety card — urgent.** Muted red. *Replaces the screen entirely* and
///     suppresses everything else. This is the only place `#9f1239` is
///     correct: the moment it appears on a risk band or a missed goal it stops
///     meaning anything.
///   * **Safety card — warning.** Amber, non-blocking, heading in ink rather
///     than amber.
///   * **Under-18.** Full screen, kind, no route past it, and **no risk figure
///     anywhere on it**. Offers a doctor route and nothing else.
///   * **Already diagnosed.** A branch, not an error. An estimate of whether
///     you might have diabetes is the wrong screen for someone who has been
///     told they do.
///   * **Error.** Says what happened *and* what to do. No apologies, no
///     "something went wrong", and nothing the user typed is lost.
///
/// The emergency number always comes from the region pack — never hard-coded
/// into a screen.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../data/models.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/shell.dart';

// ── safety card ───────────────────────────────────────────────────────

class SafetyCardScreen extends StatelessWidget {
  const SafetyCardScreen({
    super.key,
    required this.card,
    required this.emergencyNumber,
    required this.country,
  });

  final SafetyCard card;
  final String emergencyNumber;
  final String country;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final urgent = card.isUrgent;

    // Urgent: muted red, and the only correct use of it in the app.
    // Warning: amber, with the heading in ink so it informs rather than alarms.
    final tint = urgent ? c.safetyTint : c.cautionTint;
    final border = urgent ? c.safetyBorder : c.cautionBorder;
    final accent = urgent ? c.safety : c.caution;
    final headingColor = urgent ? c.safety : c.text;

    return PopScope(
      canPop: !urgent,
      child: Shell(
        child: ScreenBody(
          topPad: 20,
          bottomPad: 28,
          gap: 16,
          children: [
            AppCard(
              radius: 30,
              color: tint,
              borderColor: border,
              borderWidth: 1.5,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
              child: VGap(
                14,
                cross: CrossAxisAlignment.start,
                children: [
                  IconChip(
                    icon: urgent ? Icons24.triangleAlert : Icons24.infoCircle,
                    size: 42,
                    bg: c.card,
                    border: border,
                    fg: accent,
                    iconSize: 21,
                  ),
                  Kicker(
                    urgent ? s.safetyUrgentKicker : s.safetyWarningKicker,
                    color: accent,
                  ),
                  Text(
                    card.title,
                    style: context.t.screenTitle.copyWith(color: headingColor),
                  ),
                  P(card.body, style: context.t.body, color: c.text),

                  // The local emergency number, from the region pack.
                  if (urgent)
                    AppCard(
                      radius: 20,
                      color: c.card,
                      borderColor: border,
                      child: HGap(
                        12,
                        children: [
                          LineIcon(Icons24.phone, size: 20, color: accent),
                          Expanded(
                            child: VGap(
                              2,
                              cross: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  context.n.digits(emergencyNumber),
                                  style: context.t.rowTitle
                                      .copyWith(
                                          color: c.text,
                                          fontWeight: FontWeight.w800)
                                      .withTabular(),
                                ),
                                Text(
                                  s.emergencyServices(country),
                                  style: context.t.footnote
                                      .copyWith(color: c.neutral.c600),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),

            PillButton(
              label: card.actions.isNotEmpty
                  ? card.actions.first
                  : (urgent ? s.ctaFindDoctor : s.safetyCtaNotes),
              tone: urgent ? PillTone.safety : PillTone.accent,
              onPressed: () => showToast(context, s.toastDoctorPrivacy),
            ),
            GhostButton(
              label: urgent ? s.safetyCtaSpoken : s.safetyCtaDismiss,
              color: c.neutral.c700,
              onPressed: () => Navigator.of(context)
                  .pushNamedAndRemoveUntil(Routes.home, (_) => false),
            ),
          ],
        ),
      ),
    );
  }
}

// ── under 18 ──────────────────────────────────────────────────────────

class Under18Screen extends StatelessWidget {
  const Under18Screen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;

    return PopScope(
      // No way past it. Enforced server-side too, but the UI must not offer
      // the path either.
      canPop: false,
      child: Shell(
        child: ScreenBody(
          topPad: 30,
          bottomPad: 28,
          gap: 18,
          children: [
            // Accent, not safety red. Being under 18 is not a safety event and
            // styling it as one would be unkind as well as wrong.
            IconChip(icon: Icons24.person, size: 56, iconSize: 26),
            Text(s.under18Head,
                style: context.t.screenTitle.copyWith(color: c.text)),
            AppCard(
              radius: 26,
              color: c.accentRamp.c100,
              borderColor: c.accentRamp.c300,
              padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 18),
              child: P(s.under18Body,
                  style: context.t.bodyLarge, color: c.accentRamp.c900),
            ),
            // A doctor route and nothing else. No risk figure appears
            // anywhere on this screen.
            PillButton(
              label: s.under18Cta,
              icon: Icons24.stethoscope,
              onPressed: () => showToast(context, s.toastDoctorPrivacy),
            ),
            GhostButton(
              label: s.signOut,
              color: c.neutral.c700,
              onPressed: () async {
                final app = AppScope.read(context);
                await app.signOut();
                if (context.mounted) {
                  Navigator.of(context)
                      .pushNamedAndRemoveUntil(Routes.auth, (_) => false);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ── already diagnosed ─────────────────────────────────────────────────

class AlreadyDiagnosedScreen extends StatelessWidget {
  const AlreadyDiagnosedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;

    return Shell(
      child: ScreenBody(
        topPad: 30,
        bottomPad: 28,
        gap: 18,
        children: [
          IconChip(icon: Icons24.heart, size: 56, iconSize: 26),
          Text(s.diagnosedHead,
              style: context.t.screenTitle.copyWith(color: c.text)),
          AppCard(
            radius: 26,
            padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 18),
            child: P(s.diagnosedBody, style: context.t.bodyLarge, color: c.text),
          ),
          PillButton(
            label: s.diagnosedCta,
            onPressed: () =>
                Navigator.of(context).pushReplacementNamed(Routes.wizard),
          ),
          PillButton(
            label: s.ctaFindDoctor,
            tone: PillTone.outline,
            compact: true,
            icon: Icons24.stethoscope,
            onPressed: () => showToast(context, s.toastDoctorPrivacy),
          ),
        ],
      ),
    );
  }
}

// ── error ─────────────────────────────────────────────────────────────

class ErrorScreen extends StatelessWidget {
  const ErrorScreen({super.key, this.message, required this.onRetry});

  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;

    return Shell(
      child: ScreenBody(
        topPad: 40,
        bottomPad: 28,
        gap: 18,
        children: [
          IconChip(
            icon: Icons24.retry,
            size: 52,
            bg: c.neutral.c200,
            border: c.neutral.c300,
            fg: c.neutral.c700,
          ),
          Text(s.errorHead,
              style: context.t.screenTitleSm.copyWith(color: c.text)),
          // Says what happened and what to do. Nothing the user typed is lost.
          P(message ?? s.errorBody, style: context.t.bodyLarge),
          PillButton(label: s.errorRetry, onPressed: onRetry),
          GhostButton(
            label: s.errorLeave,
            color: c.neutral.c700,
            onPressed: () => Navigator.of(context)
                .pushNamedAndRemoveUntil(Routes.home, (_) => false),
          ),
        ],
      ),
    );
  }
}
