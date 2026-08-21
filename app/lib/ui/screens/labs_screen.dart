/// 08 · Lab values — Tier 2.
///
/// Offered **after** the first result and framed as an upgrade, never as a
/// missing field. Both values are optional; at least one is required to save.
///
/// Two things worth knowing about the mechanics:
///
///   * **Values are stored as dated observations**, not profile attributes, so
///     a stale result is never silently treated as current. The server ignores
///     anything outside its lookback window entirely — a three-year-old HbA1c
///     is not weak evidence about today, it is no evidence.
///   * **A fasting glucose entry can trip the red-flag interceptor.** When it
///     does the server returns 409 with a safety card and `recorded: true` —
///     the value *was* saved, and the card replaces the response. This screen
///     hands that straight to the safety card rather than treating it as a
///     failed save.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/typography.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/shell.dart';
import 'edge_states.dart';

class LabsScreen extends StatefulWidget {
  const LabsScreen({super.key, this.profileId, this.current});

  final String? profileId;

  /// The estimate being upgraded, so the preview can show what narrows.
  final RiskResult? current;

  @override
  State<LabsScreen> createState() => _LabsScreenState();
}

class _LabsScreenState extends State<LabsScreen> {
  // Null until touched — an untouched field is not sent at all.
  double? _hba1c;
  double? _glucose;

  bool _busy = false;
  String? _error;

  // Clamps from feature_spec.json. The steppers cannot leave them.
  static const _hba1cMin = 4.0, _hba1cMax = 14.0;
  static const _glucoseMin = 2.5, _glucoseMax = 25.0;

  bool get _canSave => _hba1c != null || _glucose != null;

  Future<void> _save() async {
    if (!_canSave || _busy) return;
    final app = AppScope.read(context);
    final profileId = widget.profileId ?? app.profileId;
    if (profileId == null) {
      setState(() => _error = context.s.errNeedProfile);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await app.api.addLabs(
        profileId,
        hba1cPercent: _hba1c,
        fastingGlucoseMmolL: _glucose,
      );
      // Re-assess so the result comes back measurement-led.
      final updated = await app.api.assess(profileId);
      await app.saveResult(updated);
      app.markOffline(false);
      if (!mounted) return;
      showToast(context, context.s.toastLabAdded);
      Navigator.of(context).pop(updated);
    } on SafetyIntercept catch (e) {
      if (!mounted) return;
      // The reading was recorded. The card replaces the screen.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => SafetyCardScreen(
            card: e.card,
            emergencyNumber:
                e.card.emergencyNumber ?? app.region.emergencyNumber,
            country: app.region.country,
          ),
        ),
      );
    } on ApiFailure catch (e) {
      if (!mounted) return;
      app.markOffline(e is NetworkFailure);
      setState(() => _error = switch (e) {
            NetworkFailure() => context.s.errNetwork,
            ServerFailure(detail: final d?) when d.isNotEmpty => d,
            _ => context.s.errServer,
          });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
                  child: Text(s.labHba1c,
                      style: context.t.caption.copyWith(
                          color: c.neutral.c600,
                          fontWeight: FontWeight.w700)),
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
                    Text(s.labsHead,
                        style: context.t.screenTitleSm.copyWith(color: c.text)),
                    P(s.labsSub),
                  ],
                ),

                _LabStepper(
                  label: s.labHba1c,
                  unit: '%',
                  help: s.labHba1cHelp,
                  value: _hba1c,
                  fallback: 5.6,
                  min: _hba1cMin,
                  max: _hba1cMax,
                  step: 0.1,
                  format: (v) => context.n.decimal(v, places: 1),
                  onChanged: (v) => setState(() => _hba1c = v),
                  onClear: () => setState(() => _hba1c = null),
                ),

                _LabStepper(
                  label: s.labGlucose,
                  unit: AppScope.of(context).region.glucoseUnit,
                  help: s.labGlucoseHelp,
                  value: _glucose,
                  fallback: 5.5,
                  min: _glucoseMin,
                  max: _glucoseMax,
                  step: 0.1,
                  format: (v) => context.n.decimal(v, places: 1),
                  onChanged: (v) => setState(() => _glucose = v),
                  onClear: () => setState(() => _glucose = null),
                ),

                if (_hba1c != null) _interpretation(c, s),

                if (widget.current != null && _canSave)
                  _preview(c, s, widget.current!),

                if (_error != null)
                  AppCard(
                    radius: 18,
                    color: c.cautionTint,
                    borderColor: c.cautionBorder,
                    child: HGap(
                      10,
                      cross: CrossAxisAlignment.start,
                      children: [
                        LineIcon(Icons24.infoCircle,
                            size: 18, color: c.caution),
                        Expanded(
                          child: P(_error!,
                              style: context.t.caption, color: c.caution),
                        ),
                      ],
                    ),
                  ),

                DisclaimerFooter(text: s.labNoDiagnosisNote),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
                AppSpace.gutter, 8, AppSpace.gutter, 12),
            child: VGap(
              8,
              children: [
                _busy
                    ? Center(
                        child: SizedBox.square(
                          dimension: 26,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.6, color: c.accent),
                        ),
                      )
                    : PillButton(
                        label: s.labSave,
                        enabled: _canSave,
                        onPressed: _save,
                        onDisabledTap: () => showToast(context, s.labsSub),
                      ),
                GhostButton(
                  label: s.labSkip,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The published interpretation bands. None of them uses the word
  /// "diagnosis", and each is paired with the note that a threshold reading is
  /// still not one.
  Widget _interpretation(dynamic c, dynamic s) {
    final v = _hba1c!;
    final (label, tint, border, fg) = v < 5.7
        ? (s.labBandNormal, c.accent2Ramp.c100, c.accent2Ramp.c300,
            c.accent2Ramp.c900)
        : v < 6.5
            ? (s.labBandPrediabetes, c.cautionTint, c.cautionBorder, c.caution)
            : (s.labBandAbove, c.cautionTint, c.cautionBorder, c.caution);

    return AppCard(
      radius: 22,
      color: tint,
      borderColor: border,
      child: HGap(
        11,
        cross: CrossAxisAlignment.start,
        children: [
          LineIcon(Icons24.droplet, size: 18, color: fg),
          Expanded(
            child: Text(
              '${s.labHba1c} ${context.n.decimal(v, places: 1)}% → $label',
              style: context.t.bodyStrong.copyWith(color: fg).withTabular(),
            ),
          ),
        ],
      ),
    );
  }

  /// What this does to the estimate. The old range struck through, the new one
  /// leading — a measurement outranks an estimate and the layout says so.
  Widget _preview(dynamic c, dynamic s, RiskResult current) {
    final n = context.n;
    return AppCard(
      radius: 24,
      color: c.accentRamp.c100,
      borderColor: c.accentRamp.c300,
      padding: const EdgeInsets.all(16),
      child: VGap(
        10,
        cross: CrossAxisAlignment.start,
        children: [
          Kicker(s.labPreviewKicker, color: c.accentRamp.c800),
          HGap(
            10,
            children: [
              Text(
                n.range(current.rangeLow, current.rangeHigh),
                style: context.t.caption
                    .copyWith(
                      color: c.neutral.c600,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.lineThrough,
                    )
                    .withTabular(),
              ),
              LineIcon(Icons24.arrowRight, size: 16, color: c.accentRamp.c700),
              // The narrowed figure is not shown as a number here: only the
              // server knows it, and inventing one would be a bare claim.
              Expanded(
                child: P(s.labPreviewNote,
                    style: context.t.footnote, color: c.accentRamp.c900),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A −/+ stepper that starts empty. Until it is touched the field is absent
/// from the request — absence routes to Tier 1 and never gets a fabricated
/// average.
class _LabStepper extends StatelessWidget {
  const _LabStepper({
    required this.label,
    required this.unit,
    required this.help,
    required this.value,
    required this.fallback,
    required this.min,
    required this.max,
    required this.step,
    required this.format,
    required this.onChanged,
    required this.onClear,
  });

  final String label, unit, help;
  final double? value;
  final double fallback, min, max, step;
  final String Function(double) format;
  final ValueChanged<double> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final v = value ?? fallback;
    final on = value != null;

    return AppCard(
      radius: 26,
      shadow: true,
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      child: VGap(
        10,
        cross: CrossAxisAlignment.start,
        children: [
          HGap(
            12,
            children: [
              Expanded(
                child: VGap(
                  3,
                  cross: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: context.t.rowTitle.copyWith(color: c.text)),
                    Text(unit,
                        style: context.t.footnote.copyWith(
                            color: c.neutral.c600,
                            fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              CircleIconButton(
                icon: 'M5 12h14',
                size: 36,
                iconSize: 17,
                semanticLabel: '−',
                onPressed: on && v > min
                    ? () => onChanged(
                        double.parse((v - step).clamp(min, max).toStringAsFixed(1)))
                    : null,
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 64),
                child: Text(
                  on ? format(v) : '—',
                  textAlign: TextAlign.center,
                  style: context.t.statValue
                      .copyWith(color: on ? c.text : c.neutral.c500),
                ),
              ),
              CircleIconButton(
                icon: 'M12 5v14|M5 12h14',
                size: 36,
                iconSize: 17,
                semanticLabel: '+',
                onPressed: () => onChanged(
                    on
                        ? double.parse(
                            (v + step).clamp(min, max).toStringAsFixed(1))
                        : fallback),
              ),
            ],
          ),
          P(help, style: context.t.footnote),
          if (on)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: GhostButton(
                label: context.s.cancel,
                onPressed: onClear,
              ),
            ),
        ],
      ),
    );
  }
}
