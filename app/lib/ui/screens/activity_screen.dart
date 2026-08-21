/// 13 · Activity.
///
/// Step-goal ring mirroring the tracker's visual language, current against
/// goal in local numerals, and a weekly bar row.
///
/// Activity is one of only four inputs the clinical score reads, so the copy
/// connects movement to the risk number explicitly rather than treating steps
/// as a generic fitness metric.
///
/// Steps are entered by hand here. HealthKit / Health Connect sync is real
/// work — background permissions, battery budget, reconciliation with the
/// native app — and a fake "connected" toggle would be worse than an honest
/// manual field.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../widgets/charts.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/nav_pill.dart';
import '../widgets/shell.dart';

/// A plain daily goal. Not clinical guidance — the copy says what actually
/// matters, which is moving more than yesterday.
const _stepGoal = 8000;

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  List<ActivityDay> _week = const [];
  bool _loading = true;
  int _draftSteps = 0;
  int _draftMinutes = 0;

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
      final week = await app.api.activity(profileId, days: 7);
      app.markOffline(false);
      if (mounted) {
        setState(() {
          _week = week;
          _loading = false;
          _draftSteps = _today?.steps ?? 0;
          _draftMinutes = _today?.activeMinutes ?? 0;
        });
      }
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
      if (mounted) setState(() => _loading = false);
    }
  }

  ActivityDay? get _today {
    final now = DateTime.now();
    for (final day in _week) {
      if (day.on.year == now.year &&
          day.on.month == now.month &&
          day.on.day == now.day) {
        return day;
      }
    }
    return null;
  }

  Future<void> _save() async {
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) return;
    try {
      await app.api.saveActivity(profileId,
          steps: _draftSteps, activeMinutes: _draftMinutes);
      app.markOffline(false);
      if (mounted) {
        showToast(context, context.s.vitalsSaved);
        _load();
      }
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
    final steps = _today?.steps ?? 0;

    // Seven days, oldest first, with gaps filled so a missed day reads as a
    // gap rather than shifting the whole row.
    final now = DateTime.now();
    final series = <double>[];
    final labels = <String>[];
    for (var i = 6; i >= 0; i--) {
      final day = DateTime(now.year, now.month, now.day - i);
      final match = _week.where((d) =>
          d.on.year == day.year && d.on.month == day.month && d.on.day == day.day);
      series.add(match.isEmpty ? 0 : match.first.steps.toDouble());
      labels.add(_weekdayLabel(s, day.weekday));
    }

    return Shell(
      tab: NavTab.activity,
      child: _loading
          ? Center(child: CircularProgressIndicator(color: c.accent))
          : ScreenBody(
              topPad: 14,
              gap: 20,
              children: [
                Text(s.activityHead,
                    style: context.t.screenTitleSm.copyWith(color: c.text)),

                AppCard(
                  radius: 30,
                  shadow: true,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
                  child: Column(
                    spacing: 14,
                    children: [
                      GoalRing(
                        value: steps / _stepGoal,
                        centre: n.int_(steps),
                        caption: s.activitySteps,
                        semanticLabel:
                            '${n.int_(steps)} steps of a ${n.int_(_stepGoal)} '
                            'step goal',
                      ),
                      Text(
                        s.targetOf(n.int_(steps), n.int_(_stepGoal)),
                        style: context.t.caption
                            .copyWith(color: c.neutral.c600),
                      ),
                    ],
                  ),
                ),

                // Why this screen exists at all.
                AppCard(
                  radius: 22,
                  color: c.accent2Ramp.c100,
                  borderColor: c.accent2Ramp.c300,
                  child: HGap(
                    11,
                    cross: CrossAxisAlignment.start,
                    children: [
                      LineIcon(Icons24.infoCircle,
                          size: 18, color: c.accent2Ramp.c700),
                      Expanded(
                        child: P(s.activityWhyItCounts,
                            style: context.t.caption,
                            color: c.accent2Ramp.c900),
                      ),
                    ],
                  ),
                ),

                VGap(
                  10,
                  children: [
                    Kicker(s.activityWeek),
                    AppCard(
                      radius: 24,
                      padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
                      child: series.every((v) => v == 0)
                          ? P(s.activityEmpty, style: context.t.caption)
                          : WeekBars(
                              values: series,
                              labels: labels,
                              goal: _stepGoal.toDouble(),
                              semanticLabel: 'Steps for the last seven days',
                            ),
                    ),
                  ],
                ),

                _entryCard(c, s, n),
              ],
            ),
    );
  }

  Widget _entryCard(dynamic c, dynamic s, dynamic n) => AppCard(
        radius: 26,
        shadow: true,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: VGap(
          14,
          cross: CrossAxisAlignment.start,
          children: [
            Kicker(s.activityAdd),
            _stepper(c, n, s.activitySteps, _draftSteps, 500,
                (v) => setState(() => _draftSteps = v.clamp(0, 200000))),
            _stepper(c, n, s.activityMinutes, _draftMinutes, 5,
                (v) => setState(() => _draftMinutes = v.clamp(0, 1440))),
            PillButton(label: s.done, compact: true, onPressed: _save),
          ],
        ),
      );

  Widget _stepper(dynamic c, dynamic n, String label, int value, int step,
          ValueChanged<int> onChanged) =>
      HGap(
        12,
        children: [
          Expanded(
            child: Text(label,
                style: context.t.bodyStrong.copyWith(color: c.text)),
          ),
          CircleIconButton(
            icon: 'M5 12h14',
            size: 34,
            iconSize: 16,
            semanticLabel: '−',
            onPressed:
                value > 0 ? () => onChanged(value - step) : null,
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 66),
            child: Text(
              n.int_(value),
              textAlign: TextAlign.center,
              style: context.t.statValue.copyWith(color: c.text, fontSize: 20),
            ),
          ),
          CircleIconButton(
            icon: 'M12 5v14|M5 12h14',
            size: 34,
            iconSize: 16,
            semanticLabel: '+',
            onPressed: () => onChanged(value + step),
          ),
        ],
      );

  String _weekdayLabel(dynamic s, int weekday) {
    const en = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const bn = ['সোম', 'মঙ্গল', 'বুধ', 'বৃহ', 'শুক্র', 'শনি', 'রবি'];
    return (s.lang == 'bn' ? bn : en)[weekday - 1];
  }
}
