/// 11 · Camera meal review.
///
/// **This screen scans food, never "your health".** Implying vitals come from
/// a device sensor is an automatic App Store rejection (rule 3), so the
/// viewfinder copy says what it is looking at and the footer repeats it.
///
/// **AI proposes, the human disposes.** Nothing is saved until the user has
/// confirmed every item and its portion. In this build there is no recognition
/// model at all — the server says so — and the screen falls back to search and
/// manual portions rather than inventing items. Fabricated food on a blood
/// sugar app is not a cosmetic problem.
///
/// Calories are shown as a range with an "estimate" label throughout, and the
/// nutrition figures are flagged as approximations rather than a licensed
/// composition table.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/nav_pill.dart';
import '../widgets/shell.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _search = TextEditingController();
  final _drafts = <MealItemDraft>[];

  List<Food> _results = const [];
  Recognition? _recognition;
  String _slot = 'lunch';
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkRecognition();
      _searchFoods('');
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _checkRecognition() async {
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) return;
    try {
      final r = await app.api.recognizeFood(profileId);
      if (mounted) setState(() => _recognition = r);
    } on ApiFailure {
      // Falling back to manual entry is exactly what happens anyway.
    }
  }

  Future<void> _searchFoods(String q) async {
    final app = AppScope.read(context);
    try {
      final foods = await app.api.searchFoods(q: q, region: app.regionCode);
      if (mounted) setState(() => _results = foods);
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
    }
  }

  double get _estimatedKcal =>
      _drafts.fold(0.0, (sum, d) => sum + d.estimatedKcal);

  Future<void> _save() async {
    if (_drafts.isEmpty || _saving) return;
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await app.api.logMeal(profileId, slot: _slot, items: _drafts);
      app.markOffline(false);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
      if (mounted) {
        setState(() => _error =
            e is NetworkFailure ? context.s.errNetwork : context.s.errServer);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final n = context.n;

    return Shell(
      tab: NavTab.scan,
      child: ScreenBody(
        topPad: 14,
        gap: 18,
        children: [
          Text(s.scanHead,
              style: context.t.screenTitleSm.copyWith(color: c.text)),
          P(s.scanSub, style: context.t.caption),

          _viewfinder(c, s),

          // Which meal this is.
          VGap(
            8,
            children: [
              Kicker(s.scanSlot),
              Segmented<String>(
                value: _slot,
                compact: true,
                options: [
                  ('breakfast', s.lang == 'bn' ? 'নাশতা' : 'Breakfast'),
                  ('lunch', s.lang == 'bn' ? 'দুপুর' : 'Lunch'),
                  ('snack', s.lang == 'bn' ? 'হালকা' : 'Snack'),
                  ('dinner', s.lang == 'bn' ? 'রাত' : 'Dinner'),
                ],
                onChanged: (v) => setState(() => _slot = v),
              ),
            ],
          ),

          // Search — the actual path to adding an item in this build.
          FieldCard(
            label: s.scanSearchFood,
            icon: Icons24.flask,
            child: BareInput(
              controller: _search,
              hint: s.lang == 'bn' ? 'ভাত, ডাল, রুটি…' : 'rice, dal, roti…',
              onChanged: _searchFoods,
            ),
          ),

          if (_results.isEmpty && _search.text.isNotEmpty)
            P(s.scanNoResults, style: context.t.caption)
          else
            VGap(
              8,
              children: [
                for (final food in _results.take(6))
                  _foodRow(c, s, n, food),
              ],
            ),

          if (_drafts.isNotEmpty) ...[
            Kicker(s.scanEstimatedTotal),
            VGap(
              9,
              children: [
                for (var i = 0; i < _drafts.length; i++)
                  _draftRow(c, s, n, i),
              ],
            ),
            _totalCard(c, s, n),
          ],

          if (_error != null)
            AppCard(
              radius: 18,
              color: c.cautionTint,
              borderColor: c.cautionBorder,
              child: P(_error!, style: context.t.caption, color: c.caution),
            ),

          _saving
              ? Center(child: CircularProgressIndicator(color: c.accent))
              : PillButton(
                  label: s.scanSaveMeal,
                  enabled: _drafts.isNotEmpty,
                  onPressed: _save,
                  onDisabledTap: () => showToast(context, s.scanSub),
                ),

          // Rule 3, restated where a user can see it.
          AppCard(
            radius: 18,
            color: c.neutral.c200,
            borderColor: c.neutral.c300,
            child: VGap(
              6,
              cross: CrossAxisAlignment.start,
              children: [
                P(s.scanConfirmNote, style: context.t.footnote),
                P(s.scanPlaceholderNote, style: context.t.footnote),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The viewfinder block. In this build it carries the honest message that
  /// recognition is unavailable rather than a live camera preview that would
  /// promise something the server cannot do.
  Widget _viewfinder(dynamic c, dynamic s) {
    final unavailable = _recognition?.modelAvailable == false;
    return AppCard(
      radius: 26,
      dashed: true,
      color: c.neutral.c200,
      borderColor: c.neutral.c400,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 26),
      child: Column(
        spacing: 12,
        children: [
          IconChip(
            icon: Icons24.droplet,
            size: 48,
            bg: c.card,
            border: c.neutral.c300,
            fg: c.neutral.c600,
          ),
          P(
            unavailable
                ? (_recognition?.message.isNotEmpty ?? false
                    ? _recognition!.message
                    : s.scanNoModel)
                : s.scanViewfinderHint,
            align: TextAlign.center,
            style: context.t.caption,
          ),
        ],
      ),
    );
  }

  Widget _foodRow(dynamic c, dynamic s, dynamic n, Food food) {
    final already = _drafts.any((d) => d.foodId == food.id);
    return GestureDetector(
      onTap: already
          ? null
          : () => setState(() => _drafts.add(MealItemDraft(
                foodId: food.id,
                name: food.nameEn,
                unit: food.units.isEmpty ? 'serving' : food.units.first,
                kcalPer100g: food.kcalPer100g,
                portionGrams: food.portionGrams,
              ))),
      child: AppCard(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        color: already ? c.accentRamp.c100 : c.card,
        borderColor: already ? c.accentRamp.c300 : c.neutral.c300,
        child: HGap(
          10,
          children: [
            Expanded(
              child: VGap(
                2,
                cross: CrossAxisAlignment.start,
                children: [
                  Text(
                    food.nameLocal != null && s.lang == 'bn'
                        ? food.nameLocal!
                        : food.nameEn,
                    style: context.t.bodyStrong.copyWith(color: c.text),
                  ),
                  Text(
                    '${n.int_(food.kcalPer100g)} kcal / 100 g',
                    style: context.t.footnote.copyWith(color: c.neutral.c600),
                  ),
                ],
              ),
            ),
            LineIcon(already ? Icons24.check : Icons24.chevronRight,
                size: 17, color: c.accentRamp.c700),
          ],
        ),
      ),
    );
  }

  /// An editable portion row. This is the "human disposes" half — the quantity
  /// and the unit are the user's, always.
  Widget _draftRow(dynamic c, dynamic s, dynamic n, int index) {
    final draft = _drafts[index];
    final units = draft.portionGrams.keys
        .where((u) => u != 'g' && u != 'gram')
        .toList();

    return AppCard(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: VGap(
        10,
        cross: CrossAxisAlignment.start,
        children: [
          HGap(
            10,
            children: [
              Expanded(
                child: Text(draft.name,
                    style: context.t.rowTitle.copyWith(color: c.text)),
              ),
              Text(
                '≈ ${n.int_(draft.estimatedKcal)} kcal',
                style: context.t.captionStrong.copyWith(color: c.neutral.c700),
              ),
              CircleIconButton(
                icon: 'M6 6l12 12M18 6L6 18',
                size: 30,
                iconSize: 13,
                semanticLabel: s.cancel,
                onPressed: () => setState(() => _drafts.removeAt(index)),
              ),
            ],
          ),
          HGap(
            10,
            children: [
              CircleIconButton(
                icon: 'M5 12h14',
                size: 32,
                iconSize: 15,
                semanticLabel: '−',
                onPressed: draft.quantity > 0.5
                    ? () => setState(() => draft.quantity -= 0.5)
                    : null,
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48),
                child: Text(
                  n.decimal(draft.quantity, places: 1),
                  textAlign: TextAlign.center,
                  style: context.t.statValue
                      .copyWith(color: c.text, fontSize: 19),
                ),
              ),
              CircleIconButton(
                icon: 'M12 5v14|M5 12h14',
                size: 32,
                iconSize: 15,
                semanticLabel: '+',
                onPressed: () => setState(() => draft.quantity += 0.5),
              ),
              // Local portion units from the region pack's own food rows.
              if (units.length > 1)
                Expanded(
                  child: Segmented<String>(
                    value: draft.unit,
                    compact: true,
                    options: [for (final u in units.take(3)) (u, u)],
                    onChanged: (u) => setState(() => draft.unit = u),
                  ),
                )
              else
                Expanded(
                  child: Text(draft.unit,
                      style: context.t.caption
                          .copyWith(color: c.neutral.c600)),
                ),
            ],
          ),
          Text('${n.int_(draft.grams)} g',
              style: context.t.footnote.copyWith(color: c.neutral.c600)),
        ],
      ),
    );
  }

  Widget _totalCard(dynamic c, dynamic s, dynamic n) {
    // The same ±14% manual band the server applies, shown live while editing.
    final low = (_estimatedKcal * 0.86).round();
    final high = (_estimatedKcal * 1.14).round();
    return AppCard(
      radius: 22,
      color: c.accentRamp.c100,
      borderColor: c.accentRamp.c300,
      child: VGap(
        4,
        cross: CrossAxisAlignment.start,
        children: [
          Kicker(s.trackerEstimate, color: c.accentRamp.c800),
          Text(
            '${n.int_(low)}–${n.int_(high)} kcal',
            style: context.t.statValue.copyWith(color: c.accentRamp.c900),
          ),
        ],
      ),
    );
  }
}
