/// 10 · Calorie tracker.
///
/// Dual ring — calories outside against the target, carbohydrate inside
/// against its goal — then macros computed from the log, a glycemic-load bar
/// with the day's aim marked, water, and one card per meal with its items.
///
/// The glycemic-load bar is the diabetes-specific part no generic calorie app
/// carries. It is computed from *available* carbohydrate, and where a food has
/// no known glycemic index the server returns null and this screen says the
/// load is partial rather than showing a number built on a guess.
///
/// **Never a "you failed" state.** Going over a calorie target is not a safety
/// event: the ring turns caution amber at most, never safety red, and the copy
/// names the next smaller portion instead of scolding.
///
/// The goal sheet takes a request, not an order: the server puts it through
/// the §5.4 rails and the screen says so when the target came back different.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../widgets/charts.dart' show DualRing;
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/nav_pill.dart';
import '../widgets/shell.dart';
import 'add_food_screen.dart';

/// The meals every day shows, in order. Region slots such as sehri and iftar
/// appear only when something was logged under them.
const _baseSlots = ['breakfast', 'lunch', 'snack', 'dinner'];

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

class TrackerScreen extends StatefulWidget {
  const TrackerScreen({super.key, this.clock});

  /// Tests only: a fixed "now", so goldens do not change with the date.
  @visibleForTesting
  final DateTime Function()? clock;

  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen> {
  PlanToday? _plan;
  bool _loading = true;
  String? _error;
  late DateTime _day = _today;

  DateTime get _today => _dateOnly((widget.clock ?? DateTime.now)());

  /// Item ids with a request in flight, so a double-tap is not two requests.
  final _busy = <String>{};

  bool get _isToday => _day == _today;

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
      final plan =
          await app.api.planToday(profileId, on: _isToday ? null : _day);
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
          _error =
              e is NetworkFailure ? context.s.errNetwork : context.s.errServer;
        });
      }
    }
  }

  void _shiftDay(int days) {
    final next = _day.add(Duration(days: days));
    if (next.isAfter(_today)) return;
    setState(() {
      _day = next;
      _loading = true;
    });
    _load();
  }

  Future<void> _run(Future<void> Function(Api api, String profileId) action,
      {String? busyKey}) async {
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) return;
    if (busyKey != null) {
      if (_busy.contains(busyKey)) return;
      setState(() => _busy.add(busyKey));
    }
    try {
      await action(app.api, profileId);
      app.markOffline(false);
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
      if (mounted) {
        showToast(context,
            e is NetworkFailure ? context.s.errNetwork : context.s.errServer);
      }
    } finally {
      if (busyKey != null && mounted) setState(() => _busy.remove(busyKey));
    }
    if (mounted) await _load();
  }

  // ── actions ─────────────────────────────────────────────────────────

  Future<void> _setPortion(Meal meal, MealItem item, double quantity) =>
      _run((api, _) => api.updateMealItem(meal.id, item.id, quantity: quantity),
          busyKey: item.id);

  Future<void> _removeItem(Meal meal, MealItem item) =>
      _run((api, _) => api.deleteMealItem(meal.id, item.id), busyKey: item.id);

  Future<void> _copyYesterday(String slot) async {
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) return;
    final s = context.s;
    try {
      await app.api.copyMeals(profileId,
          from: _day.subtract(const Duration(days: 1)), to: _day, slot: slot);
      if (mounted) showToast(context, s.trSameToast(s.mealSlot(slot)));
    } on ServerFailure catch (e) {
      if (mounted) {
        showToast(context, e.status == 404 ? s.trNothingToCopy : s.errServer);
      }
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
      if (mounted) showToast(context, s.errNetwork);
    }
    if (mounted) await _load();
  }

  Future<void> _setWater(int glasses) => _run(
      (api, profileId) => api.setWater(profileId,
          glasses: glasses, on: _isToday ? null : _day));

  Future<void> _openAddFood(String slot) async {
    await Navigator.of(context).push(MaterialPageRoute<bool>(
      builder: (_) => AddFoodScreen(slot: slot, day: _day),
    ));
    if (mounted) _load();
  }

  Future<void> _openScan(String slot) async {
    await Navigator.of(context).pushNamed(Routes.scan,
        arguments: {'camera': true, 'slot': slot, 'day': _day});
    if (mounted) _load();
  }

  // ── build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final n = context.n;
    final plan = _plan;

    return Shell(
      tab: NavTab.tracker,
      child: ScreenBody(
        topPad: 14,
        gap: 18,
        children: [
          HGap(
            12,
            children: [
              Expanded(
                child: Text(s.trackerHead,
                    style: context.t.screenTitleSm.copyWith(color: c.text)),
              ),
              if (plan?.target != null)
                CircleIconButton(
                  icon: Icons24.sliders,
                  semanticLabel: s.trEditGoal,
                  onPressed: () => _goalSheet(plan!.target!),
                ),
            ],
          ),
          _daySwitcher(c, s, n),

          if (_error != null)
            AppCard(
              radius: 20,
              color: c.cautionTint,
              borderColor: c.cautionBorder,
              child: P(_error!, style: context.t.caption, color: c.caution),
            ),

          if (_loading && plan == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 60),
              child:
                  Center(child: CircularProgressIndicator(color: c.accent)),
            ),

          if (plan != null) ...[
            _ringCard(c, s, n, plan),
            _macros(c, s, n, plan),
            _glCard(c, s, n, plan),

            // A §5.4 rail tripped by the last fortnight's pattern. It turns
            // aggressive targets OFF; it is never a failure state.
            if (plan.safetyCard != null) _railCard(c, plan.safetyCard!),
            if (plan.target == null) _noTargetCard(c, s),
            if (plan.target != null && plan.target!.wasClamped)
              _clampNote(c, s, plan.target!),

            _waterCard(c, s, n, plan.water),

            PillButton(
              label: s.trackerAddMeal,
              icon: Icons24.plus,
              onPressed: () => _addMealSheet(plan),
            ),

            for (final slot in _slotsFor(plan)) _mealCard(c, s, n, plan, slot),

            P(s.trFoot, style: context.t.footnote),
          ],
        ],
      ),
    );
  }

  List<String> _slotsFor(PlanToday plan) => {
        ..._baseSlots,
        for (final m in plan.meals) m.slot,
      }.toList();

  // ── day switcher ────────────────────────────────────────────────────

  Widget _daySwitcher(dynamic c, dynamic s, dynamic n) {
    final ago = _today.difference(_day).inDays;
    final label = switch (ago) {
      0 => s.trToday,
      1 => s.trYesterday,
      _ => s.trDaysAgo(n.int_(ago)),
    };
    return AppCard(
      radius: 99,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: HGap(
        8,
        children: [
          CircleIconButton(
            icon: Icons24.chevronLeft,
            size: 38,
            semanticLabel: s.trPrevDay,
            onPressed: () => _shiftDay(-1),
          ),
          Expanded(
            child: Column(
              children: [
                Text(label,
                    style: context.t.bodyStrong.copyWith(color: c.text)),
                Text(
                  '${s.trWeekday(_day.weekday)} ${n.int_(_day.day)}/'
                  '${n.int_(_day.month)}',
                  style: context.t.footnote.copyWith(color: c.neutral.c600),
                ),
              ],
            ),
          ),
          CircleIconButton(
            icon: Icons24.chevronRight,
            size: 38,
            semanticLabel: s.trNextDay,
            onPressed: _isToday ? null : () => _shiftDay(1),
          ),
        ],
      ),
    );
  }

  // ── ring ────────────────────────────────────────────────────────────

  Widget _ringCard(dynamic c, dynamic s, dynamic n, PlanToday plan) {
    final target = plan.target;
    final eaten = plan.totals.kcal;
    final remaining = target == null ? null : target.kcal - eaten;
    final over = remaining != null && remaining < 0;
    final carbs = plan.totals.carbsG;

    return AppCard(
      radius: 30,
      shadow: true,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
      child: Column(
        spacing: 14,
        children: [
          DualRing(
            outer: target == null ? 0 : eaten / target.kcal,
            inner: target == null || target.carbsG == 0
                ? 0
                : carbs / target.carbsG,
            centre: remaining == null
                ? n.int_(eaten)
                : n.int_(remaining.abs()),
            caption: remaining == null
                ? 'kcal'
                : (over ? s.trOverGoal : s.trackerRemaining),
            semanticLabel: target == null
                ? '${n.int_(eaten)} kcal'
                : '${n.int_(eaten)} / ${n.int_(target.kcal)} kcal, '
                    '${n.int_(carbs)} / ${n.int_(target.carbsG)} g',
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 16,
            children: [
              _legend(c, c.accent, s.trLegendKcal),
              _legend(c, c.accent2, s.trLegendCarb),
            ],
          ),
          if (target != null)
            GestureDetector(
              onTap: () => _goalSheet(target),
              child: Text(
                s.targetOf(n.int_(eaten), n.int_(target.kcal)),
                style: context.t.caption.copyWith(
                  color: c.accentRamp.c700,
                  decoration: TextDecoration.underline,
                  decorationColor: c.accentRamp.c300,
                ),
              ),
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

  Widget _legend(dynamic c, Color colour, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
          ),
          Text(label,
              style: context.t.footnote.copyWith(color: c.neutral.c700)),
        ],
      );

  Widget _macros(dynamic c, dynamic s, dynamic n, PlanToday plan) {
    final t = plan.totals;
    final target = plan.target;
    Widget chip(String label, double value, int? goal) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: c.neutral.c200,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 1,
              children: [
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.footnote
                        .copyWith(color: c.neutral.c600, fontSize: 11)),
                Text('${n.int_(value)} g',
                    style: context.t.captionStrong
                        .copyWith(color: c.text, fontSize: 15)),
                if (goal != null)
                  Text('/ ${n.int_(goal)} g',
                      style: context.t.footnote
                          .copyWith(color: c.neutral.c600, fontSize: 11)),
              ],
            ),
          ),
        );
    return Row(
      spacing: 8,
      children: [
        chip(s.trackerCarbs, t.carbsG, target?.carbsG),
        chip(s.trackerProtein, t.proteinG, target?.proteinG),
        chip(s.trackerFat, t.fatG, target?.fatG),
        chip(s.trackerFibre, t.fibreG, target?.fibreG),
      ],
    );
  }

  // ── glycemic load ───────────────────────────────────────────────────

  Widget _glCard(dynamic c, dynamic s, dynamic n, PlanToday plan) {
    final gl = plan.totals.glycemicLoad;
    final aim = plan.target?.glycemicLoadCeiling ?? 80;
    // The bar runs to 1.5× the aim so the marker sits two-thirds along.
    final scale = aim * 1.5;

    String note;
    if (plan.meals.isEmpty) {
      note = s.trGlEmpty;
    } else if (gl == null) {
      note = s.trackerGlUnknown;
    } else if (gl < aim * 0.6) {
      note = s.trGlLow;
    } else {
      note = s.trGlNote(s.mealSlot(_topSlot(plan)));
    }

    return AppCard(
      radius: 24,
      child: VGap(
        10,
        cross: CrossAxisAlignment.start,
        children: [
          HGap(
            10,
            children: [
              Expanded(child: Kicker(s.trackerGlycemicLoad)),
              Text(
                gl == null ? '—' : n.int_(gl),
                style: context.t.statValue
                    .copyWith(color: c.accent2Ramp.c800, fontSize: 21),
              ),
            ],
          ),
          LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              final fill = ((gl ?? 0) / scale).clamp(0.0, 1.0) * w;
              final marker = (aim / scale) * w;
              return SizedBox(
                height: 22,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 7,
                      child: Container(
                        height: 9,
                        decoration: BoxDecoration(
                          color: c.neutral.c200,
                          borderRadius: AppRadius.rPill,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      top: 7,
                      child: Container(
                        width: fill,
                        height: 9,
                        decoration: BoxDecoration(
                          // Over the aim is caution amber, never safety red.
                          color: (gl ?? 0) > aim ? c.caution : c.accent2,
                          borderRadius: AppRadius.rPill,
                        ),
                      ),
                    ),
                    Positioned(
                      left: marker - 1.5,
                      top: 2,
                      child: Container(
                        width: 3,
                        height: 19,
                        decoration: BoxDecoration(
                          color: c.text,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          Text(s.trGlAim(n.int_(aim)),
              style: context.t.footnote.copyWith(color: c.neutral.c600)),
          P(note, style: context.t.caption),
        ],
      ),
    );
  }

  String _topSlot(PlanToday plan) {
    final bySlot = <String, double>{};
    for (final m in plan.meals) {
      bySlot[m.slot] = (bySlot[m.slot] ?? 0) + (m.glycemicLoad ?? 0);
    }
    if (bySlot.isEmpty) return 'lunch';
    return (bySlot.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .first
        .key;
  }

  // ── water ───────────────────────────────────────────────────────────

  Widget _waterCard(dynamic c, dynamic s, dynamic n, WaterDay water) {
    final total = water.goalGlasses > water.glasses
        ? water.goalGlasses
        : water.glasses;
    return AppCard(
      radius: 24,
      child: VGap(
        12,
        cross: CrossAxisAlignment.start,
        children: [
          HGap(
            10,
            children: [
              Expanded(
                child: Text(s.trWater,
                    style: context.t.rowTitle.copyWith(color: c.text)),
              ),
              Text(
                s.trWaterSub(n.int_(water.glasses), n.int_(water.goalGlasses),
                    n.int_(water.glasses * water.mlPerGlass)),
                style: context.t.footnote.copyWith(color: c.neutral.c600),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var i = 0; i < total; i++)
                Semantics(
                  button: true,
                  selected: i < water.glasses,
                  label: s.trGlass(n.int_(i + 1)),
                  child: GestureDetector(
                    // Tapping a filled glass empties back to it; an empty one
                    // fills up to it.
                    onTap: () =>
                        _setWater(i < water.glasses ? i : i + 1),
                    child: Container(
                      width: 34,
                      height: 42,
                      decoration: BoxDecoration(
                        color: i < water.glasses
                            ? c.accent2Ramp.c100
                            : c.neutral.c200,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(6),
                          bottom: Radius.circular(12),
                        ),
                        border: Border.all(
                          color: i < water.glasses
                              ? c.accent2Ramp.c400
                              : c.neutral.c300,
                          width: 1.5,
                        ),
                      ),
                      child: Center(
                        child: LineIcon(
                          Icons24.droplet,
                          size: 16,
                          color: i < water.glasses
                              ? c.accent2Ramp.c700
                              : c.neutral.c400,
                          fill: i < water.glasses ? c.accent2Ramp.c300 : null,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ── meals ───────────────────────────────────────────────────────────

  Widget _mealCard(
      dynamic c, dynamic s, dynamic n, PlanToday plan, String slot) {
    final meals = plan.meals.where((m) => m.slot == slot).toList();
    final items = [
      for (final m in meals)
        for (final i in m.items) (m, i),
    ];
    final low = meals.fold<int>(0, (a, m) => a + m.kcalLow);
    final high = meals.fold<int>(0, (a, m) => a + m.kcalHigh);

    return AppCard(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      child: VGap(
        10,
        cross: CrossAxisAlignment.start,
        children: [
          HGap(
            10,
            children: [
              IconChip(icon: Icons24.navBowl, size: 38, iconSize: 18),
              Expanded(
                child: VGap(
                  1,
                  cross: CrossAxisAlignment.start,
                  children: [
                    Text(s.mealSlot(slot),
                        style: context.t.rowTitle.copyWith(color: c.text)),
                    Text(
                      items.isEmpty
                          ? s.trNotLogged
                          : '${s.trackerEstimate} ${n.int_(low)}–'
                              '${n.int_(high)} kcal',
                      style:
                          context.t.footnote.copyWith(color: c.neutral.c600),
                    ),
                  ],
                ),
              ),
              CircleIconButton(
                icon: Icons24.plus,
                size: 36,
                iconSize: 16,
                semanticLabel: '${s.trAddFood} · ${s.mealSlot(slot)}',
                onPressed: () => _openAddFood(slot),
              ),
            ],
          ),
          for (final (meal, item) in items) _itemRow(c, s, n, meal, item),
          if (items.isEmpty)
            Wrap(
              spacing: 4,
              children: [
                GhostButton(
                  label: s.trSame,
                  icon: Icons24.retry,
                  onPressed: () => _copyYesterday(slot),
                ),
                GhostButton(
                  label: s.trScan,
                  icon: Icons24.navCamera,
                  onPressed: () => _openScan(slot),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _itemRow(dynamic c, dynamic s, dynamic n, Meal meal, MealItem item) {
    final busy = _busy.contains(item.id);
    return Opacity(
      opacity: busy ? 0.5 : 1,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        decoration: BoxDecoration(
          color: c.neutral.c200,
          borderRadius: BorderRadius.circular(16),
        ),
        child: HGap(
          8,
          children: [
            Expanded(
              child: VGap(
                1,
                cross: CrossAxisAlignment.start,
                children: [
                  Text(item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.t.bodyStrong.copyWith(color: c.text)),
                  Text(
                    '${n.decimal(item.quantity, places: 1)} '
                    '${s.scanUnit(item.unit)} · ~${n.int_(item.kcal)} kcal',
                    style: context.t.footnote.copyWith(color: c.neutral.c600),
                  ),
                ],
              ),
            ),
            CircleIconButton(
              icon: Icons24.minus,
              size: 30,
              iconSize: 13,
              semanticLabel: s.trLess,
              onPressed: busy || item.quantity <= 0.5
                  ? null
                  : () => _setPortion(meal, item, item.quantity - 0.5),
            ),
            CircleIconButton(
              icon: Icons24.plus,
              size: 30,
              iconSize: 13,
              semanticLabel: s.trMore,
              onPressed:
                  busy ? null : () => _setPortion(meal, item, item.quantity + 0.5),
            ),
            CircleIconButton(
              icon: Icons24.close,
              size: 30,
              iconSize: 12,
              semanticLabel: s.trRemove,
              onPressed: busy ? null : () => _removeItem(meal, item),
            ),
          ],
        ),
      ),
    );
  }

  // ── sheets ──────────────────────────────────────────────────────────

  Future<void> _addMealSheet(PlanToday plan) async {
    final c = context.c;
    final s = context.s;
    // Defaults to the first meal not yet logged.
    var slot = _baseSlots.firstWhere(
      (x) => !plan.meals.any((m) => m.slot == x),
      orElse: () => 'snack',
    );

    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: c.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, setSheet) => SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
            child: VGap(
              14,
              cross: CrossAxisAlignment.start,
              children: [
                HGap(
                  10,
                  children: [
                    Expanded(
                      child: Text(s.amHead,
                          style: context.t.cardTitle.copyWith(color: c.text)),
                    ),
                    GhostButton(
                      label: s.done,
                      onPressed: () => Navigator.of(sheet).pop(),
                    ),
                  ],
                ),
                Kicker(s.amWhich),
                Segmented<String>(
                  value: slot,
                  compact: true,
                  options: [
                    for (final x in _baseSlots)
                      (x, _shortSlot(s, x)),
                  ],
                  onChanged: (v) => setSheet(() => slot = v),
                ),
                _sheetOption(c, Icons24.search, s.amSearch,
                    () => Navigator.of(sheet).pop('search')),
                _sheetOption(c, Icons24.navCamera, s.amScan,
                    () => Navigator.of(sheet).pop('scan')),
                _sheetOption(c, Icons24.retry, s.trSame,
                    () => Navigator.of(sheet).pop('same')),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'search':
        await _openAddFood(slot);
      case 'scan':
        await _openScan(slot);
      case 'same':
        await _copyYesterday(slot);
    }
  }

  String _shortSlot(dynamic s, String slot) => s.lang == 'bn'
      ? const {
          'breakfast': 'নাশতা',
          'lunch': 'দুপুর',
          'snack': 'হালকা',
          'dinner': 'রাত',
        }[slot]!
      : s.mealSlot(slot);

  Widget _sheetOption(dynamic c, String icon, String label, VoidCallback onTap) =>
      Semantics(
        button: true,
        label: label,
        child: GestureDetector(
          onTap: onTap,
          child: AppCard(
            radius: 20,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: HGap(
              12,
              children: [
                IconChip(icon: icon, size: 38, iconSize: 18),
                Expanded(
                  child: Text(label,
                      style: context.t.bodyStrong.copyWith(color: c.text)),
                ),
                LineIcon(Icons24.chevronRight,
                    size: 17, color: c.neutral.c500),
              ],
            ),
          ),
        ),
      );

  Future<void> _goalSheet(DailyTarget target) async {
    final c = context.c;
    final s = context.s;
    final n = context.n;
    var goal = (target.goalKcal ?? target.kcal)
        .clamp(target.goalMinKcal, target.goalMaxKcal);

    final result = await showModalBottomSheet<(bool, int?)>(
      context: context,
      backgroundColor: c.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, setSheet) => SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 22),
            child: VGap(
              16,
              children: [
                Text(s.goalHead,
                    style: context.t.cardTitle.copyWith(color: c.text)),
                HGap(
                  18,
                  main: MainAxisAlignment.center,
                  children: [
                    CircleIconButton(
                      icon: Icons24.minus,
                      size: 48,
                      semanticLabel: s.goalLess,
                      onPressed: goal > target.goalMinKcal
                          ? () => setSheet(() => goal -= 50)
                          : null,
                    ),
                    Column(
                      children: [
                        Text(n.int_(goal),
                            style: context.t.heroNumber
                                .copyWith(color: c.text, fontSize: 40)),
                        Text('kcal',
                            style: context.t.footnote
                                .copyWith(color: c.neutral.c600)),
                      ],
                    ),
                    CircleIconButton(
                      icon: Icons24.plus,
                      size: 48,
                      semanticLabel: s.goalMore,
                      onPressed: goal < target.goalMaxKcal
                          ? () => setSheet(() => goal += 50)
                          : null,
                    ),
                  ],
                ),
                Text(
                  '${n.int_(target.goalMinKcal)}–${n.int_(target.goalMaxKcal)} kcal',
                  style: context.t.footnote.copyWith(color: c.neutral.c600),
                ),
                // A big change is a doctor's conversation, said every time.
                AppCard(
                  radius: 18,
                  color: c.neutral.c200,
                  borderColor: c.neutral.c300,
                  child: HGap(
                    10,
                    cross: CrossAxisAlignment.start,
                    children: [
                      LineIcon(Icons24.stethoscope,
                          size: 17, color: c.neutral.c600),
                      Expanded(
                          child: P(s.goalNote, style: context.t.footnote)),
                    ],
                  ),
                ),
                PillButton(
                  label: s.goalSave,
                  onPressed: () => Navigator.of(sheet).pop((true, goal)),
                ),
                if (target.goalKcal != null)
                  GhostButton(
                    label: s.goalReset,
                    color: c.neutral.c700,
                    onPressed: () => Navigator.of(sheet).pop((true, null)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || result == null || !result.$1) return;
    final requested = result.$2;
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) return;
    try {
      final updated = await app.api.setGoal(profileId, requested);
      if (!mounted) return;
      // The rails may have moved it. Say so rather than show a different
      // number silently.
      if (requested != null && updated != null && updated.kcal != requested) {
        showToast(context, s.goalRaised(n.int_(updated.kcal)));
      } else {
        showToast(context, s.goalToast);
      }
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
      if (mounted) showToast(context, s.errServer);
    }
    if (mounted) await _load();
  }

  // ── rails ───────────────────────────────────────────────────────────

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
                s.trackerClampNote,
                style: context.t.footnote,
                color: c.accentRamp.c900,
              ),
            ),
          ],
        ),
      );
}
