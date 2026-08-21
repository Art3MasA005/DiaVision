/// 09 · Home / My plan.
///
/// Day strip, greeting, risk-band chip, trajectory card, check-in prompt,
/// today's meals, and the quick actions into the rest of the app.
///
/// The trajectory card is built from `GET /risk/history` — two assessments a
/// few weeks apart. With only one it says so rather than drawing a trend line
/// through a single point, which would be a picture of nothing.
///
/// **A rising risk is never styled as an alarm.** Direction is carried by an
/// icon and a sentence, in accent or neutral. Safety red belongs to safety
/// cards, and putting it on a trend would teach people to ignore it where it
/// matters.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/typography.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/language_sheet.dart';
import '../widgets/line_icon.dart';
import '../widgets/nav_pill.dart';
import '../widgets/shell.dart';
import 'risk_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<RiskHistoryPoint> _history = const [];
  PlanToday? _plan;
  Checkin? _checkin;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) return;

    // Each of these is independently useful, so one failing must not blank
    // the others. The cached result already renders while they land.
    try {
      final result = await app.api.assess(profileId);
      await app.saveResult(result);
      app.markOffline(false);
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
    }

    for (final load in [
      () async {
        final history = await app.api.riskHistory(profileId);
        if (mounted) setState(() => _history = history);
      },
      () async {
        final plan = await app.api.planToday(profileId);
        if (mounted) setState(() => _plan = plan);
      },
      () async {
        final checkin = await app.api.checkinToday(profileId);
        if (mounted) setState(() => _checkin = checkin);
      },
    ]) {
      try {
        await load();
      } on ApiFailure {
        // Leave that card in its empty state.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final app = AppScope.of(context);
    final result = app.lastResult;

    return Shell(
      tab: NavTab.home,
      child: RefreshIndicator(
        color: c.accent,
        backgroundColor: c.card,
        onRefresh: _load,
        child: ScreenBody(
          topPad: 14,
          gap: 20,
          children: [
            _greeting(c, s, app),
            _dayStrip(c),

            if (result != null) _bandCard(c, s, result) else _emptyCard(c, s),

            if (_history.length >= 2)
              _trajectoryCard(c, s)
            else if (result != null)
              _notEnoughTrend(c, s),

            if (_checkin == null) _checkinPrompt(c, s),

            _planCard(c, s),
            _mealsCard(c, s),
            _quickActions(c, s),

            // Rule 5: the disclaimer travels with the risk figure.
            if (result != null)
              DisclaimerFooter(
                  text: result.disclaimer.isEmpty ? null : result.disclaimer),
          ],
        ),
      ),
    );
  }

  Widget _greeting(dynamic c, dynamic s, AppState app) => HGap(
        12,
        children: [
          Expanded(
            child: VGap(
              3,
              cross: CrossAxisAlignment.start,
              children: [
                Text(s.homeGreeting,
                    style: context.t.footnote.copyWith(
                        color: c.neutral.c600, fontWeight: FontWeight.w700)),
                Text(
                  app.profile?.displayName ?? s.homeMyPlan,
                  style: context.t.screenTitleSm.copyWith(color: c.text),
                ),
              ],
            ),
          ),
          CircleIconButton(
            icon: Icons24.globe,
            semanticLabel: s.languageLabel,
            onPressed: () => showLanguageSheet(context),
          ),
          CircleIconButton(
            icon: Icons24.settings,
            semanticLabel: s.settingsHead,
            onPressed: () => Navigator.of(context).pushNamed(Routes.settings),
          ),
        ],
      );

  /// Seven day pills, today selected. Chrome, but it orients the screen.
  Widget _dayStrip(dynamic c) {
    final n = context.n;
    final now = DateTime.now();
    return Row(
      spacing: 7,
      children: [
        for (var i = 6; i >= 0; i--)
          Builder(builder: (context) {
            final day = DateTime(now.year, now.month, now.day - i);
            final today = i == 0;
            return Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: today ? c.pill : c.card,
                  borderRadius: AppRadius.rPill,
                  border: Border.all(
                      color: today ? c.pill : c.neutral.c300),
                  boxShadow: today ? AppShadow.md(c.isDark) : null,
                ),
                child: Text(
                  n.int_(day.day),
                  textAlign: TextAlign.center,
                  style: context.t.caption.copyWith(
                    color: today ? c.pillFg : c.neutral.c600,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _bandCard(dynamic c, dynamic s, RiskResult result) {
    final n = context.n;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => RiskScreen(result: result)),
      ),
      child: AppCard(
        radius: 28,
        shadow: true,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
        child: VGap(
          12,
          cross: CrossAxisAlignment.start,
          children: [
            HGap(
              10,
              children: [
                Expanded(child: Kicker(s.homeRiskBandChip)),
                LineIcon(Icons24.chevronRight, size: 18, color: c.neutral.c500),
              ],
            ),
            HGap(
              12,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: c.accentRamp.c100,
                    borderRadius: AppRadius.rPill,
                    border: Border.all(color: c.accentRamp.c300),
                  ),
                  child: Text(result.bandLabel,
                      style: context.t.rowTitle
                          .copyWith(color: c.accentRamp.c800)),
                ),
                // A range, never a bare number — including here.
                Expanded(
                  child: Text(
                    n.range(result.rangeLow, result.rangeHigh),
                    style: context.t.statValue
                        .copyWith(color: c.text)
                        .withTabular(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Two or more assessments. Direction in words and an icon — never a colour
  /// that implies alarm.
  Widget _trajectoryCard(dynamic c, dynamic s) {
    final n = context.n;
    final latest = _history.first;
    final earliest = _history.last;
    final delta = latest.probability - earliest.probability;

    final (headline, icon) = delta < -0.01
        ? (s.homeTrajectoryImproving, 'M4 8l6 6 4-4 6 8')
        : delta > 0.01
            ? (s.homeTrajectoryRising, 'M4 16l6-6 4 4 6-8')
            : (s.homeTrajectorySteady, 'M4 12h16');

    return AppCard(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      child: VGap(
        9,
        cross: CrossAxisAlignment.start,
        children: [
          Kicker(s.homeTrajectory),
          HGap(
            11,
            cross: CrossAxisAlignment.start,
            children: [
              IconChip(icon: icon, size: 36, iconSize: 17),
              Expanded(
                child: VGap(
                  3,
                  cross: CrossAxisAlignment.start,
                  children: [
                    Text(headline,
                        style: context.t.rowTitle.copyWith(color: c.text)),
                    Text(
                      s.trajectoryLine(
                        n.percent(earliest.probability),
                        n.percent(latest.probability),
                        '${n.int_(earliest.takenAt.day)}/'
                        '${n.int_(earliest.takenAt.month)}',
                      ),
                      style: context.t.footnote
                          .copyWith(color: c.neutral.c600)
                          .withTabular(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _notEnoughTrend(dynamic c, dynamic s) => AppCard(
        radius: 20,
        color: c.neutral.c200,
        borderColor: c.neutral.c300,
        child: VGap(
          4,
          cross: CrossAxisAlignment.start,
          children: [
            Kicker(s.homeTrajectory),
            P(s.homeNotEnoughTrend, style: context.t.footnote),
          ],
        ),
      );

  Widget _checkinPrompt(dynamic c, dynamic s) => GestureDetector(
        onTap: () async {
          await Navigator.of(context).pushNamed(Routes.checkin);
          if (mounted) _load();
        },
        child: AppCard(
          radius: 24,
          color: c.accent2Ramp.c100,
          borderColor: c.accent2Ramp.c300,
          padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
          child: HGap(
            12,
            children: [
              IconChip(
                icon: Icons24.clipboard,
                size: 40,
                bg: c.card,
                border: c.accent2Ramp.c300,
                fg: c.accent2Ramp.c700,
              ),
              Expanded(
                child: VGap(
                  2,
                  cross: CrossAxisAlignment.start,
                  children: [
                    Text(s.homeCheckInPrompt,
                        style: context.t.rowTitle
                            .copyWith(color: c.accent2Ramp.c900)),
                    Text(s.homeCheckInTakes,
                        style: context.t.footnote
                            .copyWith(color: c.accent2Ramp.c800)),
                  ],
                ),
              ),
              LineIcon(Icons24.chevronRight,
                  size: 18, color: c.accent2Ramp.c700),
            ],
          ),
        ),
      );

  /// Today's intake against target, without repeating the whole tracker.
  Widget _planCard(dynamic c, dynamic s) {
    final plan = _plan;
    final n = context.n;
    if (plan == null) return const SizedBox.shrink();

    final target = plan.target?.kcal;
    return GestureDetector(
      onTap: () => Navigator.of(context).pushReplacementNamed(Routes.tracker),
      child: AppCard(
        radius: 24,
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
        child: VGap(
          10,
          cross: CrossAxisAlignment.start,
          children: [
            HGap(
              10,
              children: [
                Expanded(child: Kicker(s.homePersonalPlan)),
                LineIcon(Icons24.chevronRight,
                    size: 17, color: c.neutral.c500),
              ],
            ),
            Text(
              target == null
                  ? '${n.int_(plan.totals.kcal)} kcal'
                  : s.targetOf(n.int_(plan.totals.kcal), n.int_(target)),
              style: context.t.statValue.copyWith(color: c.text),
            ),
            if (target != null)
              ClipRRect(
                borderRadius: AppRadius.rPill,
                child: LinearProgressIndicator(
                  value: (plan.totals.kcal / target).clamp(0.0, 1.0),
                  minHeight: 8,
                  backgroundColor: c.neutral.c200,
                  // Over target is caution at most. Never safety red.
                  valueColor: AlwaysStoppedAnimation(
                      plan.totals.kcal > target ? c.caution : c.accent),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _mealsCard(dynamic c, dynamic s) {
    final meals = _plan?.meals ?? const <Meal>[];
    final n = context.n;
    return VGap(
      10,
      children: [
        Kicker(s.homeTodaysMeals),
        if (meals.isEmpty)
          AppCard(
            radius: 20,
            color: c.neutral.c200,
            borderColor: c.neutral.c300,
            child: P(s.homeNotLogged, style: context.t.caption),
          ),
        for (final meal in meals.take(4))
          AppCard(
            radius: 18,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: HGap(
              11,
              children: [
                IconChip(icon: Icons24.flask, size: 34, iconSize: 16),
                Expanded(
                  child: VGap(
                    2,
                    cross: CrossAxisAlignment.start,
                    children: [
                      Text(meal.items.map((i) => i.name).join(', '),
                          style: context.t.bodyStrong.copyWith(color: c.text)),
                      Text(
                        '${s.trackerEstimate} ${n.int_(meal.kcalLow)}–'
                        '${n.int_(meal.kcalHigh)} kcal',
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
    );
  }

  Widget _quickActions(dynamic c, dynamic s) => VGap(
        10,
        children: [
          Kicker(s.homeQuickActions),
          Row(
            spacing: 9,
            children: [
              Expanded(
                  child: _action(c, Icons24.droplet, s.vitalsHead,
                      () => Navigator.of(context).pushNamed(Routes.vitals))),
              Expanded(
                  child: _action(c, Icons24.clipboard, s.insightsHead,
                      () => Navigator.of(context).pushNamed(Routes.insights))),
              Expanded(
                  child: _action(c, Icons24.ruler, s.homeRetake,
                      () => Navigator.of(context).pushNamed(Routes.wizard))),
            ],
          ),
        ],
      );

  Widget _action(dynamic c, String icon, String label, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: AppCard(
          radius: 20,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
          child: Column(
            spacing: 8,
            children: [
              LineIcon(icon, size: 20, color: c.accentRamp.c700),
              Text(
                label,
                textAlign: TextAlign.center,
                style: context.t.footnote.copyWith(color: c.text),
              ),
            ],
          ),
        ),
      );

  Widget _emptyCard(dynamic c, dynamic s) => AppCard(
        radius: 28,
        shadow: true,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
        child: VGap(
          12,
          cross: CrossAxisAlignment.start,
          children: [
            IconChip(icon: Icons24.activity, size: 46, iconSize: 22),
            Text(s.homeNoResultTitle,
                style: context.t.cardTitle.copyWith(color: c.text)),
            P(s.homeNoResultSub, style: context.t.caption),
            PillButton(
              label: s.homeNoResultCta,
              onPressed: () => Navigator.of(context).pushNamed(Routes.wizard),
            ),
          ],
        ),
      );
}
