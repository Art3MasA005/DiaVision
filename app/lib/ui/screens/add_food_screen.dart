/// 13 · Add food.
///
/// Search in Bangla, English or Bangla typed in Latin letters ("murgir jhol")
/// — the server matches all three. With the search empty, the user's own
/// Recent, Frequent and Favourite foods are one tap away.
///
/// Portions are in the units people actually use (কাপ, বাটি, চামচ, পিস,
/// প্লেট), converted per food: a বাটি of ভাত is not a বাটি of ডাল. The gram
/// equivalent and a calorie estimate are shown before anything is added.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/shell.dart';

class AddFoodScreen extends StatefulWidget {
  const AddFoodScreen({super.key, required this.slot, required this.day});

  final String slot;
  final DateTime day;

  @override
  State<AddFoodScreen> createState() => _AddFoodScreenState();
}

class _AddFoodScreenState extends State<AddFoodScreen> {
  final _search = TextEditingController();
  int _tab = 0;

  List<Food> _results = const [];
  List<Food> _recent = const [];
  List<Food> _frequent = const [];
  List<Food> _favourites = const [];
  bool _loading = true;
  bool _added = false;

  /// Guards against a slow search answering after a newer one.
  int _searchSeq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadLists());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadLists() async {
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) return;
    try {
      final results = await Future.wait([
        app.api.recentFoods(profileId),
        app.api.frequentFoods(profileId),
        app.api.favouriteFoods(profileId),
      ]);
      app.markOffline(false);
      if (!mounted) return;
      setState(() {
        _recent = results[0];
        _frequent = results[1];
        _favourites = results[2];
        _loading = false;
        // Nothing logged yet: start on Favourites only if there are some.
        if (_recent.isEmpty && _favourites.isNotEmpty) _tab = 2;
      });
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _runSearch(String q) async {
    final seq = ++_searchSeq;
    if (q.trim().isEmpty) {
      setState(() => _results = const []);
      return;
    }
    final app = AppScope.read(context);
    try {
      final foods = await app.api.searchFoods(q: q, region: app.regionCode);
      if (mounted && seq == _searchSeq) setState(() => _results = foods);
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
    }
  }

  bool _isFavourite(Food f) => _favourites.any((x) => x.id == f.id);

  Future<void> _toggleFavourite(Food food) async {
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) return;
    final on = !_isFavourite(food);
    setState(() {
      _favourites = on
          ? [food, ..._favourites]
          : _favourites.where((x) => x.id != food.id).toList();
    });
    try {
      await app.api.setFavourite(profileId, food.id, on);
    } on ApiFailure {
      // Put it back: the star must reflect what the server holds.
      if (mounted) _loadLists();
    }
  }

  Future<void> _pickPortion(Food food) async {
    final c = context.c;
    final s = context.s;
    final n = context.n;
    final draft = MealItemDraft(
      foodId: food.id,
      name: food.nameEn,
      nameLocal: food.nameLocal,
      unit: food.units.isEmpty ? 'serving' : food.units.first,
      kcalPer100g: food.kcalPer100g,
      portionGrams: food.portionGrams,
    );

    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: c.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, setSheet) {
          final units = food.units.isEmpty ? const ['serving'] : food.units;
          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 20, 18, 22),
              child: VGap(
                14,
                cross: CrossAxisAlignment.start,
                children: [
                  Text(draft.displayName(s.lang),
                      style: context.t.cardTitle.copyWith(color: c.text)),
                  Kicker(s.addPortion),
                  HGap(
                    12,
                    children: [
                      CircleIconButton(
                        icon: Icons24.minus,
                        size: 40,
                        semanticLabel: s.trLess,
                        onPressed: draft.quantity > 0.5
                            ? () => setSheet(() => draft.quantity -= 0.5)
                            : null,
                      ),
                      ConstrainedBox(
                        constraints: const BoxConstraints(minWidth: 52),
                        child: Text(
                          n.decimal(draft.quantity, places: 1),
                          textAlign: TextAlign.center,
                          style: context.t.statValue.copyWith(color: c.text),
                        ),
                      ),
                      CircleIconButton(
                        icon: Icons24.plus,
                        size: 40,
                        semanticLabel: s.trMore,
                        onPressed: () => setSheet(() => draft.quantity += 0.5),
                      ),
                    ],
                  ),
                  if (units.length > 1)
                    Segmented<String>(
                      value: draft.unit,
                      compact: true,
                      options: [
                        for (final u in units.take(4)) (u, s.scanUnit(u))
                      ],
                      onChanged: (u) => setSheet(() => draft.unit = u),
                    ),
                  Text(
                    '${n.decimal(draft.quantity, places: 1)} '
                    '${s.scanUnit(draft.unit)} (${n.int_(draft.grams)} g) · '
                    '${s.trackerEstimate} ${n.int_(draft.estimatedKcal * 0.86)}–'
                    '${n.int_(draft.estimatedKcal * 1.14)} kcal',
                    style: context.t.caption.copyWith(color: c.neutral.c700),
                  ),
                  PillButton(
                    label: s.addConfirm,
                    onPressed: () => Navigator.of(sheet).pop(true),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (ok != true || !mounted) return;

    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) return;
    try {
      await app.api.logMeal(profileId,
          slot: widget.slot, items: [draft], eatenAt: eatenAtFor(widget.day));
      app.markOffline(false);
      _added = true;
      if (mounted) {
        showToast(context,
            s.addAdded(draft.displayName(s.lang), s.mealSlot(widget.slot)));
        _loadLists();
      }
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
      if (mounted) {
        showToast(context, e is NetworkFailure ? s.errNetwork : s.errServer);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final searching = _search.text.trim().isNotEmpty;
    final list = searching
        ? _results
        : switch (_tab) { 0 => _recent, 1 => _frequent, _ => _favourites };

    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_added);
      },
      child: Shell(
        child: ScreenBody(
          topPad: 10,
          gap: 16,
          children: [
            HGap(
              12,
              children: [
                CircleIconButton(
                  icon: Icons24.chevronLeft,
                  semanticLabel: s.back,
                  onPressed: () => Navigator.of(context).pop(_added),
                ),
                Expanded(
                  child: Text(s.addHead(s.mealSlot(widget.slot)),
                      style: context.t.screenTitleSm.copyWith(color: c.text)),
                ),
              ],
            ),
            FieldCard(
              label: s.addSearch,
              icon: Icons24.search,
              child: BareInput(
                controller: _search,
                hint: s.addPh,
                textInputAction: TextInputAction.search,
                onChanged: (q) {
                  setState(() {});
                  _runSearch(q);
                },
              ),
            ),
            if (!searching)
              Segmented<int>(
                value: _tab,
                compact: true,
                options: [
                  for (var i = 0; i < s.addTabs.length; i++) (i, s.addTabs[i])
                ],
                onChanged: (v) => setState(() => _tab = v),
              ),
            if (_loading && !searching)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 30),
                child:
                    Center(child: CircularProgressIndicator(color: c.accent)),
              )
            else if (list.isEmpty)
              AppCard(
                radius: 20,
                color: c.neutral.c200,
                borderColor: c.neutral.c300,
                child: P(
                  searching
                      ? s.addNone
                      : (_tab == 2 ? s.addEmptyFav : s.addEmptyRecent),
                  style: context.t.caption,
                ),
              )
            else
              VGap(
                8,
                children: [for (final f in list.take(30)) _foodRow(c, s, f)],
              ),
            Center(
              child: GhostButton(
                label: s.addScan,
                icon: Icons24.navCamera,
                onPressed: () => Navigator.of(context).pushReplacementNamed(
                  Routes.scan,
                  arguments: {
                    'camera': true,
                    'slot': widget.slot,
                    'day': widget.day,
                  },
                ),
              ),
            ),
            P(s.scanPlaceholderNote, style: context.t.footnote),
          ],
        ),
      ),
    );
  }

  Widget _foodRow(dynamic c, dynamic s, Food food) {
    final n = context.n;
    final fav = _isFavourite(food);
    final primary = s.lang == 'bn' && food.nameLocal != null
        ? food.nameLocal!
        : food.nameEn;
    final secondary = s.lang == 'bn' ? food.nameEn : food.nameLocal;
    return GestureDetector(
      onTap: () => _pickPortion(food),
      child: AppCard(
        radius: 18,
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: HGap(
          8,
          children: [
            Expanded(
              child: VGap(
                2,
                cross: CrossAxisAlignment.start,
                children: [
                  Text(primary,
                      style: context.t.bodyStrong.copyWith(color: c.text)),
                  Text(
                    [
                      if (secondary != null) secondary,
                      '${n.int_(food.kcalPer100g)} kcal / 100 g',
                    ].join(' · '),
                    style: context.t.footnote.copyWith(color: c.neutral.c600),
                  ),
                ],
              ),
            ),
            Semantics(
              button: true,
              toggled: fav,
              label: fav ? s.addUnfav : s.addFav,
              child: GestureDetector(
                onTap: () => _toggleFavourite(food),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: LineIcon(
                    Icons24.star,
                    size: 20,
                    color: fav ? c.accentRamp.c600 : c.neutral.c400,
                    fill: fav ? c.accentRamp.c300 : null,
                  ),
                ),
              ),
            ),
            CircleIconButton(
              icon: Icons24.plus,
              size: 34,
              iconSize: 15,
              semanticLabel: s.addConfirm,
              onPressed: () => _pickPortion(food),
            ),
          ],
        ),
      ),
    );
  }
}
