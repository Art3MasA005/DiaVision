/// 14 · Glucose & vitals.
///
/// Every value on this screen was typed by the person it belongs to, or copied
/// from their own lab report. **Nothing is ever derived from a device sensor** —
/// implying otherwise is an automatic App Store rejection under guideline
/// 1.4.1, and the footer says so plainly rather than leaving it implied.
///
/// A glucose entry goes through the red-flag interceptor server-side. A reading
/// above the region pack's threshold returns a safety card — and the reading is
/// still recorded, because refusing to store it would lose clinical history at
/// exactly the moment it matters most.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../widgets/charts.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/shell.dart';
import 'edge_states.dart';

class VitalsScreen extends StatefulWidget {
  const VitalsScreen({super.key});

  @override
  State<VitalsScreen> createState() => _VitalsScreenState();
}

class _VitalsScreenState extends State<VitalsScreen> {
  List<Vital> _readings = const [];
  bool _loading = true;

  String _type = 'glucose';
  String _context = 'fasting';
  double _value = 5.5;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final rows = await app.api.vitals(profileId, days: 60);
      app.markOffline(false);
      if (mounted) {
        setState(() {
          _readings = rows;
          _loading = false;
        });
      }
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Range and step for the current measurement type.
  (double, double, double, String) get _bounds => switch (_type) {
        'glucose' => (2.0, 25.0, 0.1, 'mmol/L'),
        'weight' => (25.0, 300.0, 0.5, 'kg'),
        _ => (40.0, 200.0, 0.5, 'cm'),
      };

  Future<void> _save() async {
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) return;
    final unit = _bounds.$4;

    try {
      await app.api.addVital(
        profileId,
        type: _type,
        value: _value,
        unit: unit,
        contextTag: _type == 'glucose' ? _context : null,
      );
      app.markOffline(false);
      if (!mounted) return;
      showToast(context, context.s.vitalsSaved);
      _load();
    } on SafetyIntercept catch (e) {
      if (!mounted) return;
      // The reading WAS recorded. The card replaces the screen.
      Navigator.of(context).push(
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
      app.markOffline(e is NetworkFailure);
      if (mounted) showToast(context, context.s.errNetwork);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final n = context.n;
    final (min, max, step, unit) = _bounds;

    final glucose = _readings.where((r) => r.type == 'glucose').toList();

    return Shell(
      child: Column(
        children: [
          ScreenHeader(title: s.vitalsHead),
          Expanded(
            child: _loading
                ? Center(child: CircularProgressIndicator(color: c.accent))
                : ScreenBody(
                    topPad: 12,
                    bottomPad: 24,
                    gap: 20,
                    children: [
                      P(s.vitalsSub, style: context.t.caption),

                      if (glucose.length >= 2) _chartCard(c, s, n, glucose),

                      _entryCard(c, s, n, min, max, step, unit),

                      VGap(
                        10,
                        children: [
                          Kicker(s.vitalsHead),
                          if (_readings.isEmpty)
                            AppCard(
                              radius: 20,
                              color: c.neutral.c200,
                              borderColor: c.neutral.c300,
                              child:
                                  P(s.vitalsEmpty, style: context.t.caption),
                            ),
                          for (final r in _readings.take(20))
                            _readingRow(c, s, n, r),
                        ],
                      ),

                      // Rule 3, said out loud.
                      AppCard(
                        radius: 18,
                        color: c.neutral.c200,
                        borderColor: c.neutral.c300,
                        child: HGap(
                          10,
                          cross: CrossAxisAlignment.start,
                          children: [
                            LineIcon(Icons24.shieldCheck,
                                size: 17, color: c.neutral.c600),
                            Expanded(
                              child: P(s.vitalsNeverFromSensors,
                                  style: context.t.footnote),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _chartCard(dynamic c, dynamic s, dynamic n, List<Vital> glucose) {
    final recent = glucose.take(7).toList().reversed.toList();
    return AppCard(
      radius: 26,
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
      child: VGap(
        12,
        cross: CrossAxisAlignment.start,
        children: [
          Kicker(s.reportGlucose),
          WeekBars(
            values: [for (final r in recent) r.value],
            labels: [for (final r in recent) n.int_(r.recordedAt.day)],
            color: c.accent,
            semanticLabel: 'Recent glucose readings in mmol per litre',
          ),
        ],
      ),
    );
  }

  Widget _entryCard(dynamic c, dynamic s, dynamic n, double min, double max,
      double step, String unit) {
    return AppCard(
      radius: 26,
      shadow: true,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: VGap(
        14,
        cross: CrossAxisAlignment.start,
        children: [
          Kicker(s.vitalsType),
          Segmented<String>(
            value: _type,
            compact: true,
            options: [
              ('glucose', s.vitalsGlucose),
              ('weight', s.vitalsWeight),
              ('waist', s.vitalsWaist),
            ],
            onChanged: (v) => setState(() {
              _type = v;
              _value = switch (v) {
                'glucose' => 5.5,
                'weight' => 70,
                _ => 85,
              };
            }),
          ),

          if (_type == 'glucose') ...[
            Kicker(s.vitalsContext),
            Segmented<String>(
              value: _context,
              compact: true,
              options: [
                ('fasting', s.vitalsFasting),
                ('post_meal', s.vitalsPostMeal),
                ('random', s.vitalsRandom),
              ],
              onChanged: (v) => setState(() => _context = v),
            ),
          ],

          HGap(
            12,
            children: [
              CircleIconButton(
                icon: 'M5 12h14',
                size: 36,
                iconSize: 17,
                semanticLabel: '−',
                onPressed: _value > min
                    ? () => setState(() => _value = double.parse(
                        (_value - step).clamp(min, max).toStringAsFixed(1)))
                    : null,
              ),
              Expanded(
                child: Text(
                  '${n.decimal(_value, places: 1)} $unit',
                  textAlign: TextAlign.center,
                  style: context.t.statValue.copyWith(color: c.text),
                ),
              ),
              CircleIconButton(
                icon: 'M12 5v14|M5 12h14',
                size: 36,
                iconSize: 17,
                semanticLabel: '+',
                onPressed: _value < max
                    ? () => setState(() => _value = double.parse(
                        (_value + step).clamp(min, max).toStringAsFixed(1)))
                    : null,
              ),
            ],
          ),
          PillButton(label: s.vitalsAdd, compact: true, onPressed: _save),
        ],
      ),
    );
  }

  Widget _readingRow(dynamic c, dynamic s, dynamic n, Vital r) => AppCard(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
        child: HGap(
          12,
          children: [
            IconChip(icon: Icons24.droplet, size: 34, iconSize: 16),
            Expanded(
              child: VGap(
                2,
                cross: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${n.decimal(r.value, places: 1)} ${r.unit}',
                    style: context.t.rowTitle.copyWith(color: c.text),
                  ),
                  Text(
                    [
                      _typeLabel(s, r.type),
                      if (r.contextTag != null) _contextLabel(s, r.contextTag!),
                      '${n.int_(r.recordedAt.day)}/${n.int_(r.recordedAt.month)}',
                    ].join(' · '),
                    style: context.t.footnote.copyWith(color: c.neutral.c600),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  String _typeLabel(dynamic s, String type) => switch (type) {
        'glucose' => s.vitalsGlucose,
        'weight' => s.vitalsWeight,
        'waist' => s.vitalsWaist,
        'hba1c' => s.labHba1c,
        _ => type,
      };

  String _contextLabel(dynamic s, String tag) => switch (tag) {
        'fasting' => s.vitalsFasting,
        'post_meal' => s.vitalsPostMeal,
        'bedtime' => s.vitalsBedtime,
        _ => s.vitalsRandom,
      };
}
