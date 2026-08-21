/// 10 · Calorie tracker.
///
/// Dual concentric ring — calories outside, glycemic load inside — with the
/// remaining figure in the middle, macro chips below, and the day's meals.
///
/// The glycemic-load ring is the diabetes-specific part no generic calorie app
/// carries, and it is computed from *available* carbohydrate rather than total
/// food weight. Where a food has no known glycemic index the server returns
/// null and this screen says the load is partial, rather than showing a number
/// built on a guess.
///
/// **Never a "you failed" state.** Going over a calorie target is not a safety
/// event: the ring turns caution amber at most, never safety red, and the copy
/// names the next smaller portion instead of scolding.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../widgets/charts.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/nav_pill.dart';
import '../widgets/shell.dart';

class TrackerScreen extends StatefulWidget {
  const TrackerScreen({super.key});

  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen> {
  PlanToday? _plan;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) {
      setState(() {
        _loading = false;
        _error = context.s.errNeedProfile;
      });
      return;
    }
    try {
      final plan = await app.api.planToday(profileId);
      app.markOffline(false);
      if (mounted) {
        setState(() {
          _plan = plan;
          _loading = false;
          _error = null;
        });
      }
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e is NetworkFailure ? context.s.errNetwork : context.s.errServer;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final n = context.n;
    final plan = _plan;

    return Shell(
      tab: NavTab.tracker,
      child: _loading
          ? Center(child: CircularProgressIndicator(color: c.accent))
          : ScreenBody(
              topPad: 14,
              gap: 20,
              children: [
                HGap(
                  12,
                  children: [
                    Expanded(
                      child: Text(s.trackerHead,
                          style: context.t.screenTitleSm.copyWith(color: c.text)),
                    ),
                    CircleIconButton(
                      icon: Icons24.retry,
                      semanticLabel: s.retry,
                      onPressed: _load,
                    ),
                  ],
                ),

                if (_error != null)
                  AppCard(
                    radius: 20,
                    color: c.cautionTint,
                    borderColor: c.cautionBorder,
                    child: P(_error!, style: context.t.caption, color: c.caution),
                  ),

                if (plan != null) ...[
                  _ringCard(c, s, n, plan),
                  _macros(c, s, n, plan),

                  // A §5.4 rail tripped by the last fortnight's pattern. It
                  // turns aggressive targets OFF; it is never a failure state.
                  if (plan.safetyCard != null) _railCard(c, plan.safetyCard!),

                  if (plan.target == null) _noTargetCard(c, s),
                  if (plan.target != null && plan.target!.wasClamped)
                    _clampNote(c, s, plan.target!),

                  PillButton(
                    label: s.trackerAddMeal,
                    icon: Icons24.flask,
                    onPressed: () async {
                      await Navigator.of(context).pushNamed(Routes.scan);
                      if (mounted) _load();
                    },
                  ),

                  _mealList(c, s, n, plan),
                ],
              ],
            ),
    );
  }

  Widget _ringCard(dynamic c, dynamic s, dynamic n, PlanToday plan) {
    final target = plan.target?.kcal;
    final eaten = plan.totals.kcal;
    final remaining = target == null ? null : target - eaten;
    final over = remaining != null && remaining < 0;

    final gl = plan.totals.glycemicLoad;
    final glCeiling = plan.target?.glycemicLoadCeiling ?? 100;

    return AppCard(
      radius: 30,
      shadow: true,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
      child: Column(
        spacing: 16,
        children: [
          DualRing(
            outer: target == null ? 0 : eaten / target,
            inner: gl == null ? 0 : gl / glCeiling,
            centre: remaining == null
                ? n.int_(eaten)
                : n.int_(remaining.abs()),
            caption: remaining == null
                ? 'kcal'
                : (over ? s.trackerOver : s.trackerRemaining),
            semanticLabel: target == null
                ? '${n.int_(eaten)} kcal logged today'
                : '${n.int_(eaten)} of ${n.int_(target)} kcal, '
                    '${n.int_(remaining!.abs())} ${over ? "over" : "remaining"}',
          ),
          if (target != null)
            Text(
              s.targetOf(n.int_(eaten), n.int_(target)),
              style: context.t.caption.copyWith(color: c.neutral.c600),
            ),
          // The estimate band, because a logged portion is not exact.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: c.neutral.c200,
              borderRadius: AppRadius.rPill,
            ),
            child: Text(
              '${s.trackerEstimate} ${n.int_(plan.totals.kcalLow)}–'
              '${n.int_(plan.totals.kcalHigh)} kcal',
              style: context.t.footnote.copyWith(color: c.neutral.c700),
            ),
          ),
          if (over)
            P(s.trackerNextPortion,
                align: TextAlign.center,
                style: context.t.footnote,
                color: c.caution),
        ],
      ),
    );
  }

  Widget _macros(dynamic c, dynamic s, dynamic n, PlanToday plan) {
    final gl = plan.totals.glycemicLoad;
    return VGap(
      10,
      children: [
        Row(
          spacing: 9,
          children: [
            Expanded(
                child: MacroChip(
                    label: s.trackerCarbs,
                    value: '${n.int_(plan.totals.carbsG)} g')),
            Expanded(
                child: MacroChip(
                    label: s.trackerProtein,
                    value: '${n.int_(plan.totals.proteinG)} g')),
            Expanded(
              child: MacroChip(
                label: s.trackerGlycemicLoad,
                // A missing GI gives no load. Never a guessed number.
                value: gl == null ? '—' : n.int_(gl),
                tone: c.accent2Ramp.c700,
              ),
            ),
          ],
        ),
        if (gl == null && plan.meals.isNotEmpty)
          P(s.trackerGlUnknown, style: context.t.footnote),
      ],
    );
  }

  Widget _railCard(dynamic c, SafetyCard card) => AppCard(
        radius: 22,
        color: c.cautionTint,
        borderColor: c.cautionBorder,
        child: VGap(
          8,
          cross: CrossAxisAlignment.start,
          children: [
            Text(card.title,
                style: context.t.rowTitle.copyWith(color: c.text)),
            P(card.body, style: context.t.caption, color: c.neutral.c800),
          ],
        ),
      );

  Widget _noTargetCard(dynamic c, dynamic s) => AppCard(
        radius: 22,
        color: c.neutral.c200,
        borderColor: c.neutral.c300,
        child: VGap(
          10,
          cross: CrossAxisAlignment.start,
          children: [
            P(s.trackerNoTarget, style: context.t.caption),
            GhostButton(
              label: s.trackerNoTargetCta,
              onPressed: () => Navigator.of(context).pushNamed(Routes.wizard),
            ),
          ],
        ),
      );

  Widget _clampNote(dynamic c, dynamic s, DailyTarget target) => AppCard(
        radius: 20,
        color: c.accentRamp.c100,
        borderColor: c.accentRamp.c300,
        child: HGap(
          10,
          cross: CrossAxisAlignment.start,
          children: [
            LineIcon(Icons24.shieldCheck, size: 17, color: c.accentRamp.c700),
            Expanded(
              child: P(
                target.clampReason ?? s.trackerClampNote,
                style: context.t.footnote,
                color: c.accentRamp.c900,
              ),
            ),
          ],
        ),
      );

  Widget _mealList(dynamic c, dynamic s, dynamic n, PlanToday plan) => VGap(
        10,
        children: [
          Kicker(s.homeTodaysMeals),
          if (plan.meals.isEmpty)
            AppCard(
              radius: 20,
              color: c.neutral.c200,
              borderColor: c.neutral.c300,
              child: P(s.trackerEmpty, style: context.t.caption),
            ),
          for (final meal in plan.meals) _mealRow(c, s, n, meal),
        ],
      );

  Widget _mealRow(dynamic c, dynamic s, dynamic n, Meal meal) => AppCard(
        radius: 20,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
        child: HGap(
          12,
          cross: CrossAxisAlignment.start,
          children: [
            IconChip(icon: Icons24.flask, size: 38, iconSize: 18),
            Expanded(
              child: VGap(
                3,
                cross: CrossAxisAlignment.start,
                children: [
                  Text(_slotLabel(s, meal.slot),
                      style: context.t.rowTitle.copyWith(color: c.text)),
                  P(meal.items.map((i) => i.name).join(', '),
                      style: context.t.footnote),
                  // Always a range with an estimate label.
                  Text(
                    '${s.trackerEstimate} ${n.int_(meal.kcalLow)}–'
                    '${n.int_(meal.kcalHigh)} kcal',
                    style: context.t.footnote.copyWith(color: c.neutral.c600),
                  ),
                ],
              ),
            ),
            CircleIconButton(
              icon: 'M6 6l12 12M18 6L6 18',
              size: 32,
              iconSize: 14,
              semanticLabel: s.cancel,
              onPressed: () async {
                final app = AppScope.read(context);
                try {
                  await app.api.deleteMeal(meal.id);
                } on ApiFailure {
                  // Nothing to say — the reload below shows the real state.
                }
                if (mounted) _load();
              },
            ),
          ],
        ),
      );

  String _slotLabel(dynamic s, String slot) => switch (slot) {
        'breakfast' => s.lang == 'bn' ? 'সকালের নাশতা' : 'Breakfast',
        'lunch' => s.lang == 'bn' ? 'দুপুরের খাবার' : 'Lunch',
        'dinner' => s.lang == 'bn' ? 'রাতের খাবার' : 'Dinner',
        'snack' => s.lang == 'bn' ? 'নাশতা' : 'Snack',
        'sehri' => s.lang == 'bn' ? 'সেহরি' : 'Sehri',
        'iftar' => s.lang == 'bn' ? 'ইফতার' : 'Iftar',
        _ => slot,
      };
}
