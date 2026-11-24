/// 09 · Home / My plan.
///
/// Rebuilt against the handoff: the HOME artboard in
/// `design_handoff/diavision/DiaVision App.dc.html` and README §09.
///
/// Top to bottom — profile switcher and greeting, the seven-day strip, the
/// trajectory card, a risk-band / glucose pair, the check-in prompt, the
/// adaptive plan list, the day's meals, and the disclaimer.
///
/// The trajectory card is built from `GET /risk/history` — two assessments a
/// few weeks apart. With only one it says so rather than drawing a trend line
/// through a single point, which would be a picture of nothing.
///
/// **A rising risk is never styled as an alarm.** The card keeps its shape and
/// swaps only its ramp: olive when the number is falling, terracotta when it
/// is rising, neutral when it is flat. Safety red belongs to safety cards, and
/// putting it on a trend would teach people to ignore it where it matters.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/typography.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../l10n/strings.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/nav_pill.dart';
import '../widgets/shell.dart';
import 'risk_screen.dart';

/// The step goal the plan row measures against, matching the handoff's copy.
/// Activity is one of only four inputs the clinical score reads, so this row
/// is not decoration.
const _stepGoal = 8000;

/// Chip glyphs for the three trend directions. Traced from the artboard's own
/// trending-up mark, mirrored for the falling case.
const _trendRising = 'm4 17 6-6 4 4 6-7|M14 8h6v6';
const _trendFalling = 'm4 7 6 6 4-4 6 7|M14 16h6v-6';
const _trendFlat = 'M4 12h16';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.clock});

  /// Where "today" comes from. Tests pin it so the date strip, and every
  /// screenshot of it, does not change with the calendar.
  @visibleForTesting
  final DateTime Function()? clock;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<RiskHistoryPoint> _history = const [];
  List<ActivityDay> _activity = const [];
  List<Vital> _glucose = const [];
  List<Profile> _profiles = const [];
  PlanToday? _plan;
  Checkin? _checkin;

  /// Which day the strip is pointing at. Everything below the strip reads it,
  /// so tapping a pill is real navigation rather than decoration.
  late DateTime _selected;

  @override
  void initState() {
    super.initState();
    final now = _now();
    _selected = DateTime(now.year, now.month, now.day);
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
        final plan = await app.api.planToday(profileId, on: _selected);
        if (mounted) setState(() => _plan = plan);
      },
      () async {
        final checkin = await app.api.checkinToday(profileId);
        if (mounted) setState(() => _checkin = checkin);
      },
      () async {
        final activity = await app.api.activity(profileId, days: 8);
        if (mounted) setState(() => _activity = activity);
      },
      () async {
        final glucose =
            await app.api.vitals(profileId, type: 'glucose', days: 8);
        if (mounted) setState(() => _glucose = glucose);
      },
      () async {
        final profiles = await app.api.profiles();
        if (mounted) setState(() => _profiles = profiles);
      },
    ]) {
      try {
        await load();
      } on ApiFailure {
        // Leave that card in its empty state.
      }
    }
  }

  /// The strip only offers days that have already happened, so this never
  /// asks the server for a plan that cannot exist yet.
  Future<void> _pickDay(DateTime day) async {
    if (_sameDay(day, _selected)) return;
    setState(() {
      _selected = day;
      _plan = null;
    });

    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) return;
    try {
      final plan = await app.api.planToday(profileId, on: day);
      if (mounted) setState(() => _plan = plan);
    } on ApiFailure {
      // The day's cards stay empty rather than showing yesterday's numbers.
    }
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  bool get _isToday => _sameDay(_selected, _now());

  ActivityDay? get _selectedActivity {
    for (final day in _activity) {
      if (_sameDay(day.on, _selected)) return day;
    }
    return null;
  }

  /// The last reading of the selected day — the one the cards should show.
  Vital? get _selectedGlucose {
    Vital? latest;
    for (final vital in _glucose) {
      if (!_sameDay(vital.recordedAt, _selected)) continue;
      if (latest == null || vital.recordedAt.isAfter(latest.recordedAt)) {
        latest = vital;
      }
    }
    return latest;
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
          topPad: 10,
          gap: 12,
          children: [
            _header(c, s, app),
            _dayStrip(c, s),
            if (result != null) _trajectory(c, s, result) else _emptyCard(c, s),
            _statRow(c, s, result),
            if (_isToday && _checkin == null) _checkinCard(c, s),
            _planSection(c, s),
            _mealsSection(c, s),

            // Rule 5: the disclaimer travels with the risk figure.
            if (result != null)
              DisclaimerFooter(
                  text: result.disclaimer.isEmpty ? null : result.disclaimer),
          ],
        ),
      ),
    );
  }

  // ── header ──────────────────────────────────────────────────────────

  /// Profile switcher on the start edge, greeting centred in what is left,
  /// two round controls on the end edge — the artboard's exact arrangement.
  ///
  /// The end-edge pair is the notifications bell and Settings. The bell
  /// carries the unread count and opens the inbox; Insights is reached from
  /// the weekly-report notification and from the Vitals header, as in the
  /// handoff.
  Widget _header(AppColors c, Strings s, AppState app) {
    final name = app.profile?.displayName ?? '';
    final trimmed = name.trim();
    final first =
        trimmed.isEmpty ? '' : trimmed.split(RegExp(r'\s+')).first;

    return HGap(
      12,
      children: [
        _AvatarButton(name: name, onTap: _showProfileSheet),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                first.isEmpty ? s.homeGreeting : s.homeGreetingNamed(first),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.t.footnote.copyWith(
                    color: c.neutral.c600, fontWeight: FontWeight.w600),
              ),
              Text(
                s.homeMyPlan,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.t.screenTitleSm.copyWith(color: c.text),
              ),
            ],
          ),
        ),
        HGap(
          7,
          children: [
            _BellButton(
              unread: app.inbox.unreadCount,
              onPressed: () =>
                  Navigator.of(context).pushNamed(Routes.notifications),
            ),
            CircleIconButton(
              icon: Icons24.settings,
              size: 42,
              shadow: true,
              semanticLabel: s.settingsHead,
              onPressed: () => Navigator.of(context).pushNamed(Routes.settings),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _showProfileSheet() async {
    final app = AppScope.read(context);
    final c = context.c;

    // Whatever the last fetch saw; falling back to the active profile means
    // the sheet still names whose diary this is when offline.
    final profiles = _profiles.isNotEmpty
        ? _profiles
        : [if (app.profile != null) app.profile!];
    if (profiles.isEmpty) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      barrierColor: c.text.withValues(alpha: 0.32),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: AppRadius.lg),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
          child: VGap(
            14,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: c.neutral.c300,
                    borderRadius: AppRadius.rPill,
                  ),
                ),
              ),
              Text(context.s.homeProfileTitle,
                  style: context.t.cardTitle.copyWith(color: c.text)),
              for (final profile in profiles)
                OptionRow<String>(
                  value: profile.id,
                  groupValue: app.profileId,
                  label: profile.displayName,
                  onChanged: (_) async {
                    Navigator.of(sheetContext).pop();
                    await app.setProfile(profile);
                    if (mounted) await _load();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── day strip ───────────────────────────────────────────────────────

  /// Seven pills ending today. The selected one is `--pill` with `shadow-md`;
  /// the rest are bare, so the strip reads as a rail rather than a row of
  /// buttons competing with the cards below it.
  Widget _dayStrip(AppColors c, Strings s) {
    final now = _now();
    return Row(
      spacing: 6,
      children: [
        for (var back = 6; back >= 0; back--)
          _dayPill(c, s, DateTime(now.year, now.month, now.day - back)),
      ],
    );
  }

  Widget _dayPill(AppColors c, Strings s, DateTime day) {
    final on = _sameDay(day, _selected);
    return Expanded(
      child: Semantics(
        button: true,
        selected: on,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _pickDay(day),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              // Bangla weekday names run longer than the Latin ones, and the
              // column is only a seventh of the gutter width.
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  s.weekdayShort[day.weekday - 1],
                  maxLines: 1,
                  style: context.t.footnote.copyWith(
                    fontSize: 11,
                    height: 1.1,
                    fontWeight: FontWeight.w700,
                    color: on ? c.text : c.neutral.c500,
                  ),
                ),
              ),
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: on ? c.pill : Colors.transparent,
                  shape: BoxShape.circle,
                  boxShadow: on ? AppShadow.md(c.isDark) : null,
                ),
                child: Center(
                  child: Text(
                    context.n.int_(day.day),
                    style: context.t.captionStrong
                        .copyWith(color: on ? c.pillFg : c.neutral.c700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── trajectory ──────────────────────────────────────────────────────

  Widget _trajectory(AppColors c, Strings s, RiskResult result) {
    final n = context.n;

    if (_history.length < 2) {
      return _trajectoryCard(
        c: c,
        ramp: c.neutral,
        headline: s.homeTrajectory,
        sub: s.homeNotEnoughTrend,
        chipLabel: null,
        chipIcon: null,
        series: const [],
        result: result,
      );
    }

    // `GET /risk/history` comes back newest first.
    final latest = _history.first;
    final earliest = _history.last;
    final delta = latest.probability - earliest.probability;

    final (ramp, headline, chip, icon) = delta < -0.01
        ? (c.accent2Ramp, s.homeTrajectoryImproving, s.homeTrendImproving,
            _trendFalling)
        : delta > 0.01
            ? (c.accentRamp, s.homeTrajectoryRising, s.homeTrendRising,
                _trendRising)
            : (
                c.neutral,
                s.homeTrajectorySteady,
                s.homeTrendSteady,
                _trendFlat
              );

    return _trajectoryCard(
      c: c,
      ramp: ramp,
      headline: headline,
      sub: s.trajectoryLine(
        n.percent(earliest.probability),
        n.percent(latest.probability),
        '${n.int_(earliest.takenAt.day)}/${n.int_(earliest.takenAt.month)}',
      ),
      chipLabel: chip,
      chipIcon: icon,
      // Oldest first, so the line reads left to right the way time does.
      series: [for (final point in _history.reversed) point.probability],
      result: result,
    );
  }

  Widget _trajectoryCard({
    required AppColors c,
    required Ramp ramp,
    required String headline,
    required String sub,
    required String? chipLabel,
    required String? chipIcon,
    required List<double> series,
    required RiskResult result,
  }) {
    // The ramp's 700 step is dark in light mode and light in dark mode, so the
    // chip's ink has to follow it. The handoff's `--on-accent-700` is exactly
    // the onAccent pair (#fffdf9 light, #201e1d dark).
    final onChip = c.onAccent;

    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => RiskScreen(result: result)),
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          boxShadow: AppShadow.sm(c.isDark),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: Container(
            color: ramp.c200,
            child: Stack(
              children: [
                // Two soft discs behind the copy, from the artboard. They are
                // the only ornament on this screen, and they sit on the end
                // edge so they flip with the text direction.
                PositionedDirectional(
                    end: -40, top: -46, child: _disc(150, ramp.c300, 0.75)),
                PositionedDirectional(
                    end: 26, top: 64, child: _disc(56, ramp.c100, 0.8)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
                  child: LayoutBuilder(
                    builder: (context, box) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (chipLabel != null && chipIcon != null) ...[
                          _trendChip(ramp, onChip, chipLabel, chipIcon),
                          const SizedBox(height: 12),
                        ],
                        // Held clear of the discs rather than wrapping under
                        // them, exactly as the artboard constrains it.
                        SizedBox(
                          width: box.maxWidth * 0.78,
                          child: Text(headline,
                              style: context.t.screenTitle
                                  .copyWith(color: ramp.c900)),
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          width: box.maxWidth * 0.74,
                          child: Text(sub,
                              style: context.t.caption
                                  .copyWith(color: ramp.c800)
                                  .withTabular()),
                        ),
                        if (series.length >= 2) ...[
                          const SizedBox(height: 12),
                          _Sparkline(
                              values: series, line: ramp.c700, dot: ramp.c800),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _disc(double size, Color color, double opacity) => Opacity(
        opacity: opacity,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      );

  Widget _trendChip(Ramp ramp, Color onChip, String label, String icon) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration:
            BoxDecoration(color: ramp.c700, borderRadius: AppRadius.rPill),
        // Hugs its label — an HGap would stretch it the full width of the card.
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            LineIcon(icon, size: 13, color: onChip, strokeWidth: 3),
            Text(
              label,
              style: context.t.footnote.copyWith(
                color: onChip,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      );

  // ── the risk-band / glucose pair ────────────────────────────────────

  Widget _statRow(AppColors c, Strings s, RiskResult? result) {
    final n = context.n;
    final glucose = _selectedGlucose;

    // The band card carries a third line and the glucose card does not, so
    // the pair is sized as one block rather than left with a ragged edge.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          if (result != null)
            Expanded(
              child: _statCard(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => RiskScreen(result: result)),
                ),
                bg: c.accentRamp.c100,
                border: c.accentRamp.c200,
                kicker: s.homeRiskBandChip,
                kickerColor: c.accentRamp.c700,
                // Localised like the risk screen: the server's label is
                // English, and this is the largest text on the card.
                value: switch (result.band.toLowerCase()) {
                  'low' => s.riskBandLow,
                  'moderate' => s.riskBandModerate,
                  'high' => s.riskBandHigh,
                  'very_high' || 'very high' => s.riskBandVeryHigh,
                  _ => result.bandLabel,
                },
                valueColor: c.accentRamp.c900,
                // Rule 1: the range travels with the band, never a bare number.
                foot: n.range(result.rangeLow, result.rangeHigh),
                footColor: c.accentRamp.c800,
              ),
            ),
          Expanded(
            child: _statCard(
              onTap: () => Navigator.of(context).pushNamed(Routes.vitals),
              bg: c.card,
              border: c.neutral.c300,
              kicker: s.vitalsHead,
              kickerColor: c.neutral.c600,
              value: glucose == null
                  ? s.homeNotLogged
                  : '${n.decimal(glucose.value)} ${glucose.unit}',
              valueColor: glucose == null ? c.neutral.c600 : c.text,
              quiet: glucose == null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statCard({
    required VoidCallback onTap,
    required Color bg,
    required Color border,
    required String kicker,
    required Color kickerColor,
    required String value,
    required Color valueColor,
    String? foot,
    Color? footColor,
    bool quiet = false,
  }) {
    final c = context.c;
    return GestureDetector(
      onTap: onTap,
      child: AppCard(
        radius: 20,
        color: bg,
        borderColor: border,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
        child: VGap(
          2,
          cross: CrossAxisAlignment.start,
          children: [
            Kicker(kicker, color: kickerColor),
            // Half-width cards and a 19.5px heading: a long value has to shrink
            // rather than clip.
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                value,
                maxLines: 1,
                style: (quiet ? context.t.rowTitle : context.t.cardTitle)
                    .copyWith(color: valueColor)
                    .withTabular(),
              ),
            ),
            if (foot != null)
              Text(
                foot,
                style: context.t.footnote
                    .copyWith(color: footColor ?? c.neutral.c600)
                    .withTabular(),
              ),
          ],
        ),
      ),
    );
  }

  // ── check-in ────────────────────────────────────────────────────────

  Widget _checkinCard(AppColors c, Strings s) => AppCard(
        radius: 24,
        shadow: true,
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
        child: HGap(
          14,
          children: [
            Expanded(
              child: VGap(
                2,
                cross: CrossAxisAlignment.start,
                children: [
                  Text(s.homeCheckInPrompt,
                      style: context.t.cardTitle.copyWith(color: c.text)),
                  Text(s.homeCheckInTakes,
                      style: context.t.caption.copyWith(color: c.neutral.c600)),
                ],
              ),
            ),
            PillButton(
              label: s.homeCheckInStart,
              compact: true,
              onPressed: () async {
                await Navigator.of(context).pushNamed(Routes.checkin);
                if (mounted) _load();
              },
            ),
          ],
        ),
      );

  // ── the plan list ───────────────────────────────────────────────────

  /// The artboard's fourth row is a water tracker. There is no water anywhere
  /// in the contract, so it is left out rather than faked — three rows that
  /// mean something beat four where one is theatre.
  Widget _planSection(AppColors c, Strings s) {
    final n = context.n;
    final plan = _plan;
    final steps = _selectedActivity?.steps ?? 0;
    final glucose = _selectedGlucose;
    final eaten = plan?.totals.kcal ?? 0;
    final target = plan?.target?.kcal;

    final rows = <_PlanItem>[
      _PlanItem(
        title: s.homePlanMeals,
        sub: target == null
            ? '${n.int_(eaten)} kcal'
            : '${s.targetOf(n.int_(eaten), n.int_(target))} kcal',
        icon: Icons24.navBowl,
        tint: c.accentRamp.c100,
        ink: c.accentRamp.c700,
        done: plan?.meals.isNotEmpty ?? false,
        route: Routes.tracker,
        replace: true,
      ),
      _PlanItem(
        title: s.homePlanMove,
        sub: s.stepsOf(n.int_(steps), n.int_(_stepGoal)),
        icon: Icons24.navWalk,
        tint: c.accent2Ramp.c100,
        ink: c.accent2Ramp.c700,
        done: steps >= _stepGoal,
        route: Routes.activity,
        replace: true,
      ),
      _PlanItem(
        title: s.homePlanReading,
        sub: glucose == null
            ? s.homeNotLogged
            : '${n.decimal(glucose.value)} ${glucose.unit}',
        icon: Icons24.droplet,
        tint: c.accentRamp.c100,
        ink: c.accentRamp.c700,
        done: glucose != null,
        route: Routes.vitals,
        replace: false,
      ),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: VGap(
        10,
        children: [
          Text(s.homePersonalPlan,
              style: context.t.cardTitle.copyWith(color: c.text)),
          for (final row in rows) _planRow(c, row),
        ],
      ),
    );
  }

  Widget _planRow(AppColors c, _PlanItem item) => Semantics(
        button: true,
        label: '${item.title}. ${item.sub}',
        child: GestureDetector(
          onTap: () {
            final navigator = Navigator.of(context);
            // The five pill destinations are siblings; stacking one on Home
            // would build a back history nobody asked for.
            if (item.replace) {
              navigator.pushReplacementNamed(item.route);
            } else {
              navigator.pushNamed(item.route);
            }
          },
          child: AppCard(
            radius: 22,
            shadow: true,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: HGap(
              13,
              children: [
                _doneMark(c, item.done),
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: item.tint,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Center(
                      child: LineIcon(item.icon, size: 21, color: item.ink)),
                ),
                Expanded(
                  child: VGap(
                    1,
                    cross: CrossAxisAlignment.start,
                    children: [
                      Text(item.title,
                          style: context.t.rowTitle.copyWith(color: c.text)),
                      Text(item.sub,
                          style: context.t.footnote
                              .copyWith(color: c.neutral.c600)
                              .withTabular()),
                    ],
                  ),
                ),
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: c.neutral.c300),
                  ),
                  child: Center(
                    child: LineIcon(Icons24.chevronRight,
                        size: 15, color: c.neutral.c700),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  /// A state read-out, not a control. The artboard's tick is tappable, but
  /// each of these rows is true or false because of what the record says —
  /// letting someone tick "you walked 8000 steps" would make the row lie.
  /// The row itself opens the screen where it can be made true.
  Widget _doneMark(AppColors c, bool done) => ExcludeSemantics(
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: done ? c.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border:
                Border.all(color: done ? c.accent : c.neutral.c400, width: 2),
          ),
          child: done
              ? Center(
                  child: LineIcon(Icons24.check,
                      size: 14, color: c.onAccent, strokeWidth: 3.5),
                )
              : null,
        ),
      );

  // ── meals ───────────────────────────────────────────────────────────

  Widget _mealsSection(AppColors c, Strings s) {
    final n = context.n;
    final meals = _plan?.meals ?? const <Meal>[];
    final heading = _isToday
        ? s.homeTodaysMeals
        : s.mealsOn('${n.int_(_selected.day)}/${n.int_(_selected.month)}');

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: VGap(
        10,
        children: [
          Text(heading, style: context.t.cardTitle.copyWith(color: c.text)),
          if (meals.isEmpty)
            AppCard(
              radius: 20,
              color: c.neutral.c200,
              borderColor: c.neutral.c300,
              child: P(s.homeNotLogged, style: context.t.caption),
            ),
          for (final meal in meals.take(4))
            AppCard(
              radius: 20,
              shadow: true,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: HGap(
                12,
                cross: CrossAxisAlignment.start,
                children: [
                  IconChip(icon: Icons24.navBowl, size: 42, iconSize: 19),
                  Expanded(
                    child: VGap(
                      2,
                      cross: CrossAxisAlignment.start,
                      children: [
                        Text(s.mealSlot(meal.slot),
                            style: context.t.rowTitle.copyWith(color: c.text)),
                        if (meal.items.isNotEmpty)
                          P(meal.items.map((i) => i.name).join(', '),
                              style: context.t.footnote),
                        // Always a range, and always labelled an estimate.
                        Text(
                          '${s.trackerEstimate} ${n.int_(meal.kcalLow)}–'
                          '${n.int_(meal.kcalHigh)} kcal',
                          style: context.t.footnote
                              .copyWith(color: c.neutral.c600)
                              .withTabular(),
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

  // ── no estimate yet ─────────────────────────────────────────────────

  Widget _emptyCard(AppColors c, Strings s) => AppCard(
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

/// One row of the adaptive plan.
class _PlanItem {
  const _PlanItem({
    required this.title,
    required this.sub,
    required this.icon,
    required this.tint,
    required this.ink,
    required this.done,
    required this.route,
    required this.replace,
  });

  final String title, sub, icon, route;
  final Color tint, ink;
  final bool done;

  /// True for the destinations that also live in the nav pill.
  final bool replace;
}

/// The 44px initial disc and its chevron — the artboard's profile switcher.
class _AvatarButton extends StatelessWidget {
  const _AvatarButton({required this.name, required this.onTap});

  final String name;
  final VoidCallback onTap;

  /// A stable colour per person, so the same face is the same colour every
  /// launch. All four read correctly against `--on-accent` in both themes.
  static Color _colorFor(AppColors c, String name) {
    final palette = [
      c.accent,
      c.accent2,
      c.accentRamp.c600,
      c.accent2Ramp.c600,
    ];
    var hash = 0;
    for (final rune in name.runes) {
      hash = (hash * 31 + rune) & 0x7fffffff;
    }
    return palette[hash % palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final trimmed = name.trim();
    final initial = trimmed.isEmpty
        ? '·'
        : String.fromCharCode(trimmed.runes.first).toUpperCase();

    return Semantics(
      button: true,
      label: context.s.homeProfileTitle,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: HGap(
          9,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: _colorFor(c, trimmed),
                shape: BoxShape.circle,
                border: Border.all(color: c.card, width: 2.5),
                boxShadow: AppShadow.sm(c.isDark),
              ),
              child: Center(
                child: Text(
                  initial,
                  style: context.t.bodyStrong
                      .copyWith(color: c.onAccent, fontWeight: FontWeight.w800),
                ),
              ),
            ),
            LineIcon(Icons24.chevronDown, size: 15, color: c.neutral.c600),
          ],
        ),
      ),
    );
  }
}

/// The trajectory card's 150×34 trend line.
///
/// Drawn from the real history rather than the artboard's fixed curve, so a
/// flat record draws a flat line. Smoothed through the midpoints, which keeps
/// the shape readable at this size without inventing points between readings.
class _Sparkline extends StatelessWidget {
  const _Sparkline({
    required this.values,
    required this.line,
    required this.dot,
  });

  /// Probabilities, oldest first.
  final List<double> values;
  final Color line, dot;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 150,
        height: 34,
        child: CustomPaint(
          painter: _SparkPainter(
            values: values,
            line: line,
            dot: dot,
            rtl: Directionality.of(context) == TextDirection.rtl,
          ),
        ),
      );
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({
    required this.values,
    required this.line,
    required this.dot,
    required this.rtl,
  });

  final List<double> values;
  final Color line, dot;
  final bool rtl;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    const pad = 5.0;
    final lo = values.reduce(math.min);
    final hi = values.reduce(math.max);
    final span = hi - lo;
    final usableW = size.width - pad * 2;
    final usableH = size.height - pad * 2;

    Offset at(int i) {
      // A flat record sits on the centre line rather than collapsing to the
      // top of the box, where it would read as "high".
      final t = span < 1e-6 ? 0.5 : (values[i] - lo) / span;
      final x = pad + usableW * (i / (values.length - 1));
      return Offset(rtl ? size.width - x : x, pad + usableH * (1 - t));
    }

    final points = [for (var i = 0; i < values.length; i++) at(i)];
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      final mid = Offset(
        (points[i - 1].dx + points[i].dx) / 2,
        (points[i - 1].dy + points[i].dy) / 2,
      );
      path.quadraticBezierTo(
          points[i - 1].dx, points[i - 1].dy, mid.dx, mid.dy);
    }
    path.lineTo(points.last.dx, points.last.dy);

    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(points.last, 4.5, Paint()..color = dot);
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values != values || old.line != line || old.rtl != rtl;
}

/// The Home bell: a round control with the unread count on its end-top
/// corner, capped at "9+". The count clears as items are read.
class _BellButton extends StatelessWidget {
  const _BellButton({required this.unread, required this.onPressed});

  final int unread;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final n = context.n;
    final label = unread > 0
        ? '${s.nTitle} · ${s.nUnread(n.digits('$unread'))}'
        : s.nTitle;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleIconButton(
          icon: Icons24.bell,
          size: 42,
          shadow: true,
          semanticLabel: label,
          onPressed: onPressed,
        ),
        if (unread > 0)
          PositionedDirectional(
            top: -3,
            end: -3,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: Container(
                  constraints: const BoxConstraints(minWidth: 19),
                  height: 19,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.accent,
                    borderRadius: AppRadius.rPill,
                    border: Border.all(color: c.neutral.c100, width: 2),
                  ),
                  child: Text(
                    n.digits(unread > 9 ? '9' : '$unread') +
                        (unread > 9 ? '+' : ''),
                    style: context.t.footnote.withTabular().copyWith(
                          fontSize: 10.5,
                          height: 1,
                          fontWeight: FontWeight.w800,
                          color: c.onAccent,
                        ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
