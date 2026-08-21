/// 16 · Insights + doctor report.
///
/// Two tabs. **Weekly** shows patterns found in the user's own logs and
/// nowhere else; **Doctor report** is the artefact a patient hands a clinician.
///
/// Three rules, all enforced server-side and surfaced here:
///
///   * **Never assert causation.** The copy says "often follows", never
///     "causes". These are correlations in one person's self-report.
///   * **A pattern needs evidence.** Below the server's minimum, the honest
///     output is the empty state — which explains what to log rather than
///     apologising.
///   * **Every card names its evidence.** Each insight shows the number of
///     days it was computed from. An insight the user cannot check is an
///     assertion.
///
/// The report carries the basis line and the validation status, because a
/// report quoting a risk figure without saying what produced it leaves the
/// doctor unable to judge how much to trust it.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/shell.dart';

class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  bool _weeklyTab = true;
  WeeklyInsights? _weekly;
  DoctorReport? _report;
  bool _loading = true;
  bool _generating = false;

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
      final weekly = await app.api.weeklyInsights(profileId);
      app.markOffline(false);
      if (mounted) {
        setState(() {
          _weekly = weekly;
          _loading = false;
        });
      }
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _generate() async {
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null || _generating) return;
    setState(() => _generating = true);
    try {
      final report = await app.api.generateReport(profileId, days: 28);
      app.markOffline(false);
      if (mounted) setState(() => _report = report);
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
      if (mounted) showToast(context, context.s.errNetwork);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;

    return Shell(
      child: Column(
        children: [
          ScreenHeader(title: s.insightsHead),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(18, 12, 18, 0),
            child: Segmented<bool>(
              value: _weeklyTab,
              options: [(true, s.insightsTabWeekly), (false, s.insightsTabReport)],
              onChanged: (v) => setState(() => _weeklyTab = v),
            ),
          ),
          Expanded(
            child: _loading
                ? Center(child: CircularProgressIndicator(color: c.accent))
                : (_weeklyTab ? _weeklyView(c, s) : _reportView(c, s)),
          ),
        ],
      ),
    );
  }

  Widget _weeklyView(dynamic c, dynamic s) {
    final weekly = _weekly;
    final n = context.n;

    if (weekly == null || weekly.insufficientData) {
      return ScreenBody(
        topPad: 24,
        bottomPad: 24,
        children: [
          IconChip(icon: Icons24.clipboard, size: 52),
          Text(s.insightsEmptyTitle,
              style: context.t.screenTitleSm.copyWith(color: c.text)),
          P(s.insightsEmptyBody(
              n.int_(weekly?.minimumObservations ?? 5))),
        ],
      );
    }

    return ScreenBody(
      topPad: 16,
      bottomPad: 24,
      gap: 12,
      children: [
        for (final insight in weekly.insights) _insightCard(c, s, n, insight),
      ],
    );
  }

  Widget _insightCard(dynamic c, dynamic s, dynamic n, Insight insight) {
    // Direction is informational only. A rising figure is never styled as an
    // alarm — rule 4 applies to trends as much as to bands.
    final icon = switch (insight.direction) {
      'up' => 'M4 16l6-6 4 4 6-8',
      'down' => 'M4 8l6 6 4-4 6 8',
      _ => 'M4 12h16',
    };

    return AppCard(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      child: VGap(
        9,
        cross: CrossAxisAlignment.start,
        children: [
          HGap(
            10,
            cross: CrossAxisAlignment.start,
            children: [
              IconChip(icon: icon, size: 36, iconSize: 17),
              Expanded(
                child: Text(insight.headline,
                    style: context.t.rowTitle.copyWith(color: c.text)),
              ),
            ],
          ),
          P(insight.detail, style: context.t.caption),
          // Every card names its evidence.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: c.neutral.c200,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              s.observationsFrom(n.int_(insight.observations)),
              style: context.t.footnote.copyWith(color: c.neutral.c700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _reportView(dynamic c, dynamic s) {
    final report = _report;
    final n = context.n;

    if (report == null) {
      return ScreenBody(
        topPad: 24,
        bottomPad: 24,
        children: [
          IconChip(icon: Icons24.clipboard, size: 52),
          Text(s.insightsTabReport,
              style: context.t.screenTitleSm.copyWith(color: c.text)),
          P(s.reportShareNote, style: context.t.caption),
          _generating
              ? Center(child: CircularProgressIndicator(color: c.accent))
              : PillButton(label: s.reportGenerate, onPressed: _generate),
        ],
      );
    }

    final payload = report.payload;
    final risk = payload['risk'] as Map<String, dynamic>?;
    final intake = payload['intake'] as Map<String, dynamic>?;
    final activity = payload['activity'] as Map<String, dynamic>?;
    final glucose = payload['glucose_mmol_l'] as Map<String, dynamic>?;
    final patterns = (payload['patterns'] as List?) ?? const [];
    final period = payload['period'] as Map<String, dynamic>?;

    return ScreenBody(
      topPad: 16,
      bottomPad: 24,
      gap: 14,
      children: [
        AppCard(
          radius: 26,
          shadow: true,
          padding: const EdgeInsets.fromLTRB(17, 17, 17, 17),
          child: VGap(
            12,
            cross: CrossAxisAlignment.start,
            children: [
              Kicker(s.insightsTabReport),
              Text(
                '${payload['generated_for']}',
                style: context.t.cardTitle.copyWith(color: c.text),
              ),
              if (period != null)
                Text(
                  '${s.reportPeriod}: ${period['start']} → ${period['end']}',
                  style: context.t.footnote.copyWith(color: c.neutral.c600),
                ),
            ],
          ),
        ),

        // The risk block, as a range, with the basis and the validation state.
        if (risk != null)
          AppCard(
            radius: 24,
            color: c.accentRamp.c100,
            borderColor: c.accentRamp.c300,
            child: VGap(
              8,
              cross: CrossAxisAlignment.start,
              children: [
                Kicker(s.riskLabel, color: c.accentRamp.c800),
                Text(
                  n.range((risk['range_low'] as num).toDouble(),
                      (risk['range_high'] as num).toDouble()),
                  style: context.t.statValue.copyWith(color: c.accentRamp.c900),
                ),
                P(
                  '${risk['clinical_score']} · '
                  '${n.int_((risk['clinical_points'] as num?) ?? 0)}'
                  '/${n.int_((risk['clinical_max'] as num?) ?? 100)}',
                  style: context.t.footnote,
                  color: c.accentRamp.c800,
                ),
                P(
                  risk['validation_status'] == 'not_validated'
                      ? s.validationNotValidated
                      : s.validationProvisional,
                  style: context.t.footnote,
                  color: c.accentRamp.c800,
                ),
              ],
            ),
          ),

        _summaryRow(c, s, n, s.reportIntake, [
          if (intake?['mean_kcal'] != null)
            '${n.int_(intake!['mean_kcal'] as num)} kcal/day',
          if (intake?['mean_glycemic_load'] != null)
            'GL ${n.int_(intake!['mean_glycemic_load'] as num)}',
        ]),
        _summaryRow(c, s, n, s.reportActivity, [
          if (activity?['mean_steps'] != null)
            '${n.int_(activity!['mean_steps'] as num)} steps/day',
        ]),
        _summaryRow(c, s, n, s.reportGlucose, [
          if (glucose != null)
            '${n.decimal((glucose['min'] as num).toDouble())}–'
                '${n.decimal((glucose['max'] as num).toDouble())} mmol/L',
        ]),

        if (patterns.isNotEmpty)
          VGap(
            10,
            children: [
              Kicker(s.reportPatterns),
              for (final p in patterns)
                AppCard(
                  radius: 18,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: VGap(
                    4,
                    cross: CrossAxisAlignment.start,
                    children: [
                      Text('${(p as Map)['headline']}',
                          style: context.t.rowTitle.copyWith(color: c.text)),
                      P('${p['detail']}', style: context.t.footnote),
                    ],
                  ),
                ),
            ],
          ),

        PillButton(
          label: s.reportShare,
          icon: Icons24.stethoscope,
          onPressed: () => showToast(context, s.reportShareNote),
        ),

        // The report travels away from the app that framed it, so it restates
        // the disclaimer inside itself.
        DisclaimerFooter(text: '${payload['disclaimer']}'),
      ],
    );
  }

  Widget _summaryRow(
      dynamic c, dynamic s, dynamic n, String label, List<String> values) {
    return AppCard(
      radius: 20,
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      child: HGap(
        12,
        children: [
          Expanded(
            child: Text(label,
                style: context.t.bodyStrong.copyWith(color: c.text)),
          ),
          Text(
            values.isEmpty ? s.reportNone : values.join(' · '),
            style: context.t.caption.copyWith(
              color: values.isEmpty ? c.neutral.c500 : c.neutral.c800,
            ),
          ),
        ],
      ),
    );
  }
}
