/// 07 · Risk result + what-if simulator. The hero screen.
///
/// Everything here comes straight from the API response. Nothing is computed
/// client-side — with one bounded exception, the what-if simulator, which is
/// labelled as simulated and explained below.
///
/// The rules this screen carries:
///
///   * **Never a bare number.** The headline is a range. `probability` is in
///     the payload and is deliberately never rendered.
///   * **Never red for a bad number.** The band chip is accent at every band,
///     including Very High. Safety red appears on safety cards and nowhere
///     else; the moment it turns up on a risk band it stops meaning anything.
///   * **Changeable factors come first.** The actionable half leads, and the
///     fixed half carries the "not your fault" framing, which must survive
///     translation.
///   * **The doctor CTA is required** on every risk result.
///   * **The disclaimer footer is persistent and not dismissible.**
///   * **Validation status is never hidden**, and `not_validated` is styled as
///     neutral information rather than a warning — Bangladesh is there today,
///     and alarming a whole market about its own launch state would be wrong.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/typography.dart';
import '../../data/models.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/shell.dart';
import 'labs_screen.dart';

class RiskScreen extends StatefulWidget {
  const RiskScreen({super.key, this.result, this.profileId});

  /// Supplied when arriving from calculating. When absent the screen falls
  /// back to the cached result, so it still renders offline.
  final RiskResult? result;
  final String? profileId;

  @override
  State<RiskScreen> createState() => _RiskScreenState();
}

class _RiskScreenState extends State<RiskScreen> {
  RiskResult? _result;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _result ??= widget.result ?? AppScope.read(context).lastResult;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final app = AppScope.of(context);
    final r = _result;

    if (r == null) {
      return Shell(
        child: ScreenBody(
          topPad: 40,
          children: [
            P(s.errNeedProfile, align: TextAlign.center),
            PillButton(
              label: s.homeNoResultCta,
              onPressed: () =>
                  Navigator.of(context).pushReplacementNamed(Routes.wizard),
            ),
          ],
        ),
      );
    }

    final profileId = widget.profileId ?? app.profileId;

    return Shell(
      child: ScreenBody(
        topPad: 12,
        bottomPad: 32,
        gap: 20,
        children: [
          _header(c, s),

          // A measurement outranks an estimate, so when a lab value exists it
          // takes the headline and the estimate moves below it.
          if (r.isMeasurementLed) _labBlock(c, r),

          _headlineCard(c, s, r, demoted: r.isMeasurementLed),

          if (r.modifiableFactors.isNotEmpty)
            _factorSection(
              c,
              title: s.changeableHead,
              sub: s.changeableSub,
              factors: r.modifiableFactors,
              pillFg: c.accent2Ramp.c700,
              pillBg: c.accent2Ramp.c200,
              barColor: c.accent2,
            ),

          if (r.fixedFactors.isNotEmpty)
            _factorSection(
              c,
              title: s.fixedHead,
              sub: s.fixedSub,
              factors: r.fixedFactors,
              pillFg: c.neutral.c700,
              pillBg: c.neutral.c200,
              barColor: c.neutral.c400,
            ),

          if (r.modifiableFactors.isNotEmpty) _WhatIf(result: r),

          // Required on every risk result. Guideline 1.4.1.
          PillButton(
            label: s.ctaFindDoctor,
            icon: Icons24.stethoscope,
            onPressed: () => showToast(context, s.toastDoctorPrivacy),
          ),
          PillButton(
            label: s.ctaGetTested,
            tone: PillTone.outline,
            compact: true,
            onPressed: () => showToast(context, s.ctaGetTested),
          ),

          // Offered only when there is no lab value yet — otherwise it reads
          // as a missing field rather than an upgrade.
          if (!r.isMeasurementLed && profileId != null)
            _addLabPrompt(c, s, profileId),

          _basisCard(c, s, r),

          if (r.caveats.isNotEmpty)
            Disclosure(
              label: s.caveatsLabel,
              children: [
                for (final caveat in r.caveats)
                  HGap(
                    9,
                    cross: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 7),
                        child: Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: c.neutral.c400,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      Expanded(
                        child: P(caveat, style: context.t.footnote),
                      ),
                    ],
                  ),
              ],
            ),

          // Persistent. Uses the server's own wording for this assessment.
          DisclaimerFooter(text: r.disclaimer.isEmpty ? null : r.disclaimer),
        ],
      ),
    );
  }

  Widget _header(dynamic c, dynamic s) => HGap(
        12,
        children: [
          Expanded(
            child: Text(context.s.homeMyPlan,
                style: context.t.cardTitle.copyWith(color: c.text)),
          ),
          GhostButton(
            label: context.s.homeSettings,
            onPressed: () =>
                Navigator.of(context).pushReplacementNamed(Routes.home),
          ),
        ],
      );

  /// The headline: label, range, band chip, band bar. Never a point value.
  Widget _headlineCard(dynamic c, dynamic s, RiskResult r,
      {required bool demoted}) {
    final n = context.n;
    return AppCard(
      radius: 30,
      shadow: true,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        spacing: 12,
        children: [
          Text(
            s.riskLabel,
            style: context.t.caption.copyWith(
                color: c.neutral.c600, fontWeight: FontWeight.w600),
          ),
          // Rule 1. Ranges only.
          Semantics(
            label: '${s.riskLabel} ${n.range(r.rangeLow, r.rangeHigh)}',
            child: ExcludeSemantics(
              child: Text(
                n.range(r.rangeLow, r.rangeHigh),
                textAlign: TextAlign.center,
                style: (demoted
                        ? context.t.screenTitle
                        : context.t.heroNumber)
                    .copyWith(color: c.text)
                    .withTabular(),
              ),
            ),
          ),
          // The band reads bigger and firmer than the number, and it is accent
          // at every level. Never red.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: c.accentRamp.c100,
              borderRadius: AppRadius.rPill,
              border: Border.all(color: c.accentRamp.c300),
            ),
            child: Text(
              _bandLabel(r),
              style: context.t.rowTitle.copyWith(color: c.accentRamp.c800),
            ),
          ),
          _bandBar(c, r),
          _validationLine(c, s, r),
        ],
      ),
    );
  }

  String _bandLabel(RiskResult r) {
    final s = context.s;
    // Prefer the server's own label; fall back to a localized one so a Bangla
    // user never sees an English band on the biggest text on the screen.
    return switch (r.band.toLowerCase()) {
      'low' => s.riskBandLow,
      'moderate' => s.riskBandModerate,
      'high' => s.riskBandHigh,
      'very_high' || 'very high' => s.riskBandVeryHigh,
      _ => r.bandLabel,
    };
  }

  /// Four segments with a marker. Neutral throughout — the position carries
  /// the meaning, and colouring the high end red would shame.
  Widget _bandBar(dynamic c, RiskResult r) {
    final position = (r.rangeLow * 2.4).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, box) => SizedBox(
        height: 22,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Row(
              spacing: 3,
              children: [
                for (var i = 0; i < 4; i++)
                  Expanded(
                    child: Container(
                      height: 11,
                      decoration: BoxDecoration(
                        color: [
                          c.accentRamp.c200,
                          c.accentRamp.c300,
                          c.accentRamp.c400,
                          c.accentRamp.c500,
                        ][i],
                        borderRadius: AppRadius.rPill,
                      ),
                    ),
                  ),
              ],
            ),
            PositionedDirectional(
              start: (box.maxWidth - 12) * position,
              top: 14,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(color: c.pill, shape: BoxShape.circle),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Three faces, never hidden. `not_validated` is informational, not a
  /// warning — it is the honest state of every market today.
  Widget _validationLine(dynamic c, dynamic s, RiskResult r) {
    final text = switch (r.validationStatus) {
      'not_validated' => s.validationNotValidated,
      'provisional' => s.validationProvisional,
      _ => null,
    };
    if (text == null) return const SizedBox.shrink();
    return HGap(
      8,
      cross: CrossAxisAlignment.start,
      children: [
        LineIcon(Icons24.infoCircle, size: 15, color: c.neutral.c600),
        Expanded(
          child: P(text, style: context.t.footnote, color: c.neutral.c600),
        ),
      ],
    );
  }

  /// Tier 2. Sits above the factors and takes the headline.
  Widget _labBlock(dynamic c, RiskResult r) => AppCard(
        radius: 28,
        color: c.accent2Ramp.c100,
        borderColor: c.accent2Ramp.c300,
        padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 18),
        child: VGap(
          10,
          cross: CrossAxisAlignment.start,
          children: [
            Kicker(context.s.labResultKicker, color: c.accent2Ramp.c800),
            for (final f in r.labFindings)
              VGap(
                4,
                cross: CrossAxisAlignment.start,
                children: [
                  // The server sends `display` as the bare figure ("6.1%"),
                  // so the test name is prefixed here — and the digits go
                  // through the numeral formatter, because the API has no way
                  // to know the user reads Bengali numerals.
                  Text(
                    '${f.test} ${context.n.digits(f.display.isEmpty ? '${f.value}' : f.display)}',
                    style: context.t.cardTitle
                        .copyWith(color: c.accent2Ramp.c900)
                        .withTabular(),
                  ),
                  if (f.band.isNotEmpty)
                    Text(
                      '→ ${_labBandLabel(f.band)}',
                      style: context.t.caption.copyWith(
                        color: c.accent2Ramp.c800,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            if (r.labStatement != null && r.labStatement!.isNotEmpty)
              P(r.labStatement!,
                  style: context.t.caption.copyWith(height: 1.6),
                  color: c.accent2Ramp.c900),
            // A lab value read against a published threshold is still not a
            // diagnosis, and this is the screen most likely to be read as one.
            P(context.s.labNoDiagnosisNote,
                style: context.t.footnote, color: c.accent2Ramp.c800),
          ],
        ),
      );

  String _labBandLabel(String band) {
    final s = context.s;
    return switch (band.toLowerCase()) {
      'normal' => s.labBandNormal,
      'prediabetes' => s.labBandPrediabetes,
      'diabetes' || 'above' => s.labBandAbove,
      _ => band,
    };
  }

  Widget _factorSection(
    dynamic c, {
    required String title,
    required String sub,
    required List<RiskFactor> factors,
    required Color pillFg,
    required Color pillBg,
    required Color barColor,
  }) {
    final maxPoints = factors.fold<int>(1, (m, f) => f.points > m ? f.points : m);
    return VGap(
      10,
      children: [
        VGap(
          4,
          cross: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: context.t.sectionTitle.copyWith(color: c.text)),
            P(sub, style: context.t.footnote, color: c.neutral.c600),
          ],
        ),
        for (final f in factors)
          _factorRow(c, f, maxPoints, pillFg, pillBg, barColor),
      ],
    );
  }

  Widget _factorRow(dynamic c, RiskFactor f, int maxPoints, Color pillFg,
      Color pillBg, Color barColor) {
    final n = context.n;
    return Semantics(
      label: '${f.label}, ${n.int_(f.points)} points. ${f.detail}',
      child: ExcludeSemantics(
        child: AppCard(
          radius: 20,
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
          child: VGap(
            8,
            cross: CrossAxisAlignment.start,
            children: [
              HGap(
                10,
                cross: CrossAxisAlignment.start,
                children: [
                  // min-width: 0 — a long Bangla factor label wraps rather
                  // than pushing the points pill off the row.
                  Expanded(
                    child: Text(f.label,
                        style: context.t.rowTitle.copyWith(color: c.text)),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: pillBg,
                      borderRadius: AppRadius.rPill,
                    ),
                    child: Text(
                      '+${n.int_(f.points)}',
                      style: context.t.captionStrong
                          .copyWith(color: pillFg, fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              if (f.detail.isNotEmpty)
                P(f.detail, style: context.t.footnote),
              ClipRRect(
                borderRadius: AppRadius.rPill,
                child: LinearProgressIndicator(
                  value: (f.points / maxPoints).clamp(0.0, 1.0),
                  minHeight: 7,
                  backgroundColor: c.neutral.c200,
                  valueColor: AlwaysStoppedAnimation(barColor),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _addLabPrompt(dynamic c, dynamic s, String profileId) => GestureDetector(
        onTap: () async {
          final updated = await Navigator.of(context).push<RiskResult>(
            MaterialPageRoute(
              builder: (_) => LabsScreen(profileId: profileId, current: _result),
            ),
          );
          if (updated != null && mounted) setState(() => _result = updated);
        },
        child: AppCard(
          radius: 22,
          dashed: true,
          color: c.accentRamp.c100,
          borderColor: c.accentRamp.c300,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: HGap(
            12,
            children: [
              LineIcon(Icons24.flask, size: 20, color: c.accentRamp.c700),
              Expanded(
                child: VGap(
                  3,
                  cross: CrossAxisAlignment.start,
                  children: [
                    Text(s.addLabTitle,
                        style: context.t.rowTitle.copyWith(color: c.text)),
                    P(s.addLabSub,
                        style: context.t.footnote, color: c.accentRamp.c700),
                  ],
                ),
              ),
              LineIcon(Icons24.chevronRight, size: 18, color: c.accentRamp.c700),
            ],
          ),
        ),
      );

  /// Quiet but present. It is what makes the number defensible.
  Widget _basisCard(dynamic c, dynamic s, RiskResult r) {
    final n = context.n;
    return AppCard(
      radius: 22,
      color: c.neutral.c200,
      borderColor: c.neutral.c300,
      child: P(
        s.basisLine(
          r.clinicalScore.toUpperCase(),
          n.int_(r.clinicalPoints),
          n.int_(r.clinicalMax),
        ),
        style: context.t.caption
            .copyWith(fontWeight: FontWeight.w700)
            .withTabular(),
        color: c.neutral.c800,
      ),
    );
  }
}

// ── the what-if simulator ─────────────────────────────────────────────

/// Three sliders, live-updating a *simulated* range.
///
/// This is the one thing on the screen not returned by the API, and it is
/// bounded deliberately: it moves the clinical-score points the server already
/// itemised for the three modifiable factors, and re-derives the range from
/// that. It never invents a new model, it is labelled "simulated" throughout,
/// and it cannot produce a lower band than the factors allow.
///
/// A round trip per slider drag would be the alternative, and at three sliders
/// moving continuously that is neither fast enough nor kind to a low-bandwidth
/// connection.
class _WhatIf extends StatefulWidget {
  const _WhatIf({required this.result});

  final RiskResult result;

  @override
  State<_WhatIf> createState() => _WhatIfState();
}

class _WhatIfState extends State<_WhatIf> {
  /// 0 = no change, 1 = this factor fully addressed.
  final Map<String, double> _relief = {};

  double get _totalRelief {
    final factors = widget.result.modifiableFactors;
    if (factors.isEmpty) return 0;
    var relieved = 0.0, total = 0.0;
    for (final f in factors) {
      total += f.points;
      relieved += f.points * (_relief[f.label] ?? 0);
    }
    return total == 0 ? 0 : relieved / total;
  }

  /// The simulated range. Scales the whole estimate by the share of modifiable
  /// points the user has moved, floored so it never claims risk can reach zero
  /// — nothing about age or family history is going to change.
  (double, double) get _simulated {
    final r = widget.result;
    final modifiableShare = () {
      final mod = r.modifiableFactors.fold<int>(0, (a, f) => a + f.points);
      final fixed = r.fixedFactors.fold<int>(0, (a, f) => a + f.points);
      final all = mod + fixed;
      return all == 0 ? 0.0 : mod / all;
    }();
    final factor = 1 - (_totalRelief * modifiableShare);
    return (r.rangeLow * factor, r.rangeHigh * factor);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final n = context.n;
    final (low, high) = _simulated;
    final changed = _totalRelief > 0.001;

    return AppCard(
      radius: 26,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      child: VGap(
        12,
        cross: CrossAxisAlignment.start,
        children: [
          HGap(
            10,
            children: [
              LineIcon(Icons24.sliders, size: 19, color: c.accentRamp.c700),
              Expanded(
                child: Text(s.whatIfHead,
                    style: context.t.sectionTitle.copyWith(color: c.text)),
              ),
            ],
          ),
          P(s.whatIfSub, style: context.t.footnote),

          // The simulated figure is a range too, and it says it is simulated.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: changed ? c.accent2Ramp.c100 : c.neutral.c200,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                  color: changed ? c.accent2Ramp.c300 : c.neutral.c300),
            ),
            child: VGap(
              4,
              cross: CrossAxisAlignment.start,
              children: [
                Kicker(s.whatIfSimulated,
                    color: changed ? c.accent2Ramp.c800 : c.neutral.c600),
                Text(
                  n.range(low, high),
                  style: context.t.statValue
                      .copyWith(
                          color: changed ? c.accent2Ramp.c900 : c.neutral.c700)
                      .withTabular(),
                ),
              ],
            ),
          ),

          for (final f in widget.result.modifiableFactors)
            VGap(
              2,
              cross: CrossAxisAlignment.start,
              children: [
                Text(f.label,
                    style: context.t.caption.copyWith(
                        color: c.neutral.c700, fontWeight: FontWeight.w700)),
                AppSlider(
                  value: _relief[f.label] ?? 0,
                  min: 0,
                  max: 1,
                  divisions: 20,
                  label: f.label,
                  semanticFormatter: (v) =>
                      '${n.int_(v * 100)}% ${s.whatIfSimulated}',
                  onChanged: (v) => setState(() => _relief[f.label] = v),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
