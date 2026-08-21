/// 04 · The onboarding wizard — the eleven questions.
///
/// Five steps of questions plus the optional population step, which lives on
/// its own screen. Target for the whole flow, install to result, is under four
/// minutes.
///
/// Rules carried by this screen:
///
///   * **Every field has a "Why do we ask?".** Required by App Store guideline
///     1.4.1 — not decoration, and not dropped to save vertical space.
///   * **Prevent, do not reject.** Ranges come from `feature_spec.json` and are
///     enforced by sliders, steppers and clamps, so an out-of-range value
///     cannot be entered in the first place.
///   * **Under 18 is a hard stop**, and the UI must not offer the path.
///   * **Skipping widens the range, never blocks.** Only waist is skippable,
///     and its skip copy says what it costs.
///   * **Resumable.** Answers survive back-navigation between steps.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../data/models.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../../state/wizard_state.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/shell.dart';
import 'population_screen.dart';
import 'waist_guide_screen.dart';

/// Carries the wizard's answers from this screen through population and into
/// calculating, without a global.
class WizardScope extends InheritedNotifier<WizardState> {
  const WizardScope({super.key, required WizardState state, required super.child})
      : super(notifier: state);

  static WizardState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WizardScope>()!.notifier!;
}

class WizardScreen extends StatefulWidget {
  const WizardScreen({super.key});

  @override
  State<WizardScreen> createState() => _WizardScreenState();
}

class _WizardScreenState extends State<WizardScreen> {
  final _w = WizardState();
  int _step = 0;
  static const _steps = 5;

  @override
  void dispose() {
    _w.dispose();
    super.dispose();
  }

  void _back() {
    if (_step == 0) {
      Navigator.of(context).maybePop();
    } else {
      setState(() => _step--);
    }
  }

  void _next() {
    // The under-18 block fires the moment we know the age, not at submit —
    // no one should answer ten more questions to be turned away.
    if (_w.isUnderage) {
      Navigator.of(context).pushNamed(Routes.under18);
      return;
    }
    if (_step < _steps - 1) {
      setState(() => _step++);
      return;
    }
    // Someone already diagnosed does not need an estimate of whether they
    // might be. Branch before the network call rather than after a 409.
    if (_w.diabetesStatus == DiabetesStatus.t2d ||
        _w.diabetesStatus == DiabetesStatus.t1d ||
        _w.diabetesStatus == DiabetesStatus.gestational) {
      Navigator.of(context).pushNamed(Routes.diagnosed);
      return;
    }
    // Population keeps the wizard's answers in scope, because skipping it has
    // to land straight in the assessment with everything already gathered.
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            WizardScope(state: _w, child: const PopulationScreenBody()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final n = context.n;

    return WizardScope(
      state: _w,
      child: Shell(
        child: ListenableBuilder(
          listenable: _w,
          builder: (context, _) => Column(
            children: [
              // Header row: back, step counter, and the progress bar.
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                    AppSpace.gutter, 10, AppSpace.gutter, 0),
                child: VGap(
                  12,
                  children: [
                    HGap(
                      12,
                      children: [
                        CircleIconButton(
                          icon: Icons24.chevronLeft,
                          semanticLabel: s.back,
                          onPressed: _back,
                        ),
                        Expanded(
                          child: Text(
                            s.stepOf(n.int_(_step + 1), n.int_(_steps)),
                            style: context.t.caption.copyWith(
                              color: c.neutral.c600,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    _progress(c),
                  ],
                ),
              ),
              Expanded(
                child: RiseIn(
                  key: ValueKey(_step),
                  child: _stepBody(),
                ),
              ),
              // The advance button sits outside the scroll area so it is
              // always reachable — a long Bangla step should not bury it.
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                    AppSpace.gutter, 8, AppSpace.gutter, 12),
                child: PillButton(
                  label: s.next,
                  enabled: _w.completeThrough(_step),
                  onPressed: _next,
                  onDisabledTap: () =>
                      showToast(context, _incompleteHint(_step)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _incompleteHint(int step) {
    final s = context.s;
    if (step == 0 && _w.isUnderage) return s.under18Head;
    return switch (step) {
      0 => '${s.fieldAge} · ${s.fieldSex}',
      1 => '${s.fieldHeight} · ${s.fieldWeight}',
      2 => s.fieldWaist,
      3 => '${s.fieldFamily} · ${s.fieldActivity} · ${s.fieldSmoker}',
      _ => s.qHistoryHead,
    };
  }

  Widget _progress(dynamic c) => Row(
        spacing: 5,
        children: [
          for (var i = 0; i < _steps; i++)
            Expanded(
              child: AnimatedContainer(
                duration: AppMotion.riseIn,
                height: 5,
                decoration: BoxDecoration(
                  color: i <= _step ? c.accent : c.neutral.c300,
                  borderRadius: AppRadius.rPill,
                ),
              ),
            ),
        ],
      );

  Widget _stepBody() => switch (_step) {
        0 => _StepAboutYou(w: _w),
        1 => _StepMeasurements(w: _w),
        2 => _StepWaist(w: _w),
        3 => _StepHabits(w: _w),
        _ => _StepHistory(w: _w),
      };
}

// ── step 1 · age and sex at birth ─────────────────────────────────────

class _StepAboutYou extends StatelessWidget {
  const _StepAboutYou({required this.w});

  final WizardState w;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;

    return ScreenBody(
      topPad: 16,
      bottomPad: 24,
      children: [
        _Head(title: s.qAgeHead, sub: s.qAgeSub),
        VGap(
          10,
          children: [
            // A stepper rather than a free text field: the range is 18–120 and
            // the control simply cannot produce anything outside it.
            _StepperCard(
              label: s.fieldAge,
              value: (w.age ?? 35).toDouble(),
              min: WizardState.ageMin.toDouble(),
              max: WizardState.ageMax.toDouble(),
              step: 1,
              format: (v) => context.n.int_(v),
              onChanged: (v) => w.set_(() => w.age = v.round()),
            ),
            WhyDoWeAsk(body: s.whyAge),
          ],
        ),
        VGap(
          10,
          children: [
            Kicker(s.fieldSex),
            HGap(
              9,
              children: [
                Expanded(
                  child: _ChoiceChip(
                    label: s.sexMale,
                    selected: w.sex == Sex.male,
                    onTap: () => w.set_(() => w.sex = Sex.male),
                  ),
                ),
                Expanded(
                  child: _ChoiceChip(
                    label: s.sexFemale,
                    selected: w.sex == Sex.female,
                    onTap: () => w.set_(() => w.sex = Sex.female),
                  ),
                ),
              ],
            ),
            WhyDoWeAsk(body: s.whySex),
          ],
        ),
        if (w.isUnderage)
          AppCard(
            radius: 20,
            color: c.cautionTint,
            borderColor: c.cautionBorder,
            child: HGap(
              10,
              cross: CrossAxisAlignment.start,
              children: [
                LineIcon(Icons24.infoCircle, size: 18, color: c.caution),
                Expanded(
                  child:
                      P(s.under18Body, style: context.t.caption, color: c.caution),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ── step 2 · height and weight ────────────────────────────────────────

class _StepMeasurements extends StatelessWidget {
  const _StepMeasurements({required this.w});

  final WizardState w;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final app = AppScope.of(context);

    return ScreenBody(
      topPad: 16,
      bottomPad: 24,
      children: [
        _Head(title: s.qBodyHead, sub: s.qBodySub),
        VGap(
          10,
          children: [
            _UnitStepperCard(
              label: s.fieldHeight,
              siValue: w.heightCm ?? 165,
              siMin: WizardState.heightMin,
              siMax: WizardState.heightMax,
              metric: app.heightUnitCm,
              metricUnit: 'cm',
              imperialUnit: 'ft·in',
              siStep: 1,
              toDisplay: (cm) => app.heightUnitCm ? cm : cmToInches(cm),
              formatDisplay: (cm) {
                if (app.heightUnitCm) return context.n.int_(cm);
                final (feet, inches) = cmToFeetInches(cm);
                return "${context.n.int_(feet)}′${context.n.int_(inches)}″";
              },
              onUnitChanged: (metric) => app.setUnits(heightCm: metric),
              onChanged: (cm) => w.set_(() => w.heightCm = cm),
            ),
            WhyDoWeAsk(body: s.whyHeight),
          ],
        ),
        VGap(
          10,
          children: [
            _UnitStepperCard(
              label: s.fieldWeight,
              siValue: w.weightKg ?? 65,
              siMin: WizardState.weightMin,
              siMax: WizardState.weightMax,
              metric: app.weightUnitKg,
              metricUnit: 'kg',
              imperialUnit: 'lb',
              siStep: 0.5,
              toDisplay: (kg) => app.weightUnitKg ? kg : kgToPounds(kg),
              formatDisplay: (kg) => app.weightUnitKg
                  ? context.n.decimal(kg, places: 1)
                  : context.n.int_(kgToPounds(kg)),
              onUnitChanged: (metric) => app.setUnits(weightKg: metric),
              onChanged: (kg) => w.set_(() => w.weightKg = kg),
            ),
            WhyDoWeAsk(body: s.whyWeight),
          ],
        ),
      ],
    );
  }
}

// ── step 3 · waist ────────────────────────────────────────────────────

class _StepWaist extends StatelessWidget {
  const _StepWaist({required this.w});

  final WizardState w;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final value = w.waistCm ?? 84;

    return ScreenBody(
      topPad: 16,
      bottomPad: 24,
      children: [
        _Head(title: s.qWaistHead, sub: s.qWaistSub),

        AppCard(
          radius: 26,
          shadow: true,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: VGap(
            6,
            children: [
              HGap(
                10,
                children: [
                  Expanded(child: Kicker(s.fieldWaist)),
                  Text(
                    '${context.n.int_(value)} cm',
                    style: context.t.statValue.copyWith(
                      color: w.waistSkipped ? c.neutral.c500 : c.text,
                    ),
                  ),
                ],
              ),
              // A slider over 40–200 cm: the range from the contract, and no
              // way to leave it.
              AppSlider(
                value: value,
                min: WizardState.waistMin,
                max: WizardState.waistMax,
                divisions: (WizardState.waistMax - WizardState.waistMin).round(),
                label: s.fieldWaist,
                semanticFormatter: (v) => '${context.n.int_(v)} centimetres',
                onChanged: (v) => w.set_(() {
                  w.waistCm = v;
                  w.waistSkipped = false;
                }),
              ),
            ],
          ),
        ),

        // The guide, and the illustration the handoff was missing.
        PillButton(
          label: s.waistGuideCta,
          tone: PillTone.card,
          icon: Icons24.ruler,
          compact: true,
          onPressed: () => showWaistGuide(context),
        ),

        WhyDoWeAsk(body: s.whyWaist),

        // Genuinely skippable, and the copy says what it costs — waist moves
        // the band more than any other answer.
        AppCard(
          radius: 20,
          color: c.neutral.c200,
          borderColor: c.neutral.c300,
          child: VGap(
            10,
            cross: CrossAxisAlignment.start,
            children: [
              P(s.waistSkipNote, style: context.t.footnote),
              GhostButton(
                label: w.waistSkipped ? s.back : s.skip,
                onPressed: () => w.set_(() {
                  w.waistSkipped = !w.waistSkipped;
                  if (w.waistSkipped) w.waistCm = null;
                }),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── step 4 · family history, activity, smoking ────────────────────────

class _StepHabits extends StatelessWidget {
  const _StepHabits({required this.w});

  final WizardState w;

  @override
  Widget build(BuildContext context) {
    final s = context.s;

    return ScreenBody(
      topPad: 16,
      bottomPad: 24,
      children: [
        _Head(title: s.qHabitsHead, sub: s.qHabitsSub),
        VGap(
          10,
          children: [
            Kicker(s.fieldFamily),
            for (final (v, label) in [
              (FamilyHistory.none, s.familyNone),
              (FamilyHistory.secondDegree, s.familySecond),
              (FamilyHistory.firstDegree, s.familyFirst),
            ])
              OptionRow<FamilyHistory>(
                value: v,
                groupValue: w.family,
                label: label,
                onChanged: (x) => w.set_(() => w.family = x),
              ),
            WhyDoWeAsk(body: s.whyFamily),
          ],
        ),
        VGap(
          10,
          children: [
            Kicker(s.fieldActivity),
            for (final (v, label) in [
              (Activity.sedentary, s.activitySedentary),
              (Activity.light, s.activityLight),
              (Activity.moderate, s.activityModerate),
              (Activity.active, s.activityActive),
              (Activity.veryActive, s.activityVeryActive),
            ])
              OptionRow<Activity>(
                value: v,
                groupValue: w.activity,
                label: label,
                onChanged: (x) => w.set_(() => w.activity = x),
              ),
            WhyDoWeAsk(body: s.whyActivity),
          ],
        ),
        VGap(
          10,
          children: [
            Kicker(s.fieldSmoker),
            YesNo(
              value: w.smoker,
              yes: s.yes,
              no: s.no,
              onChanged: (v) => w.set_(() => w.smoker = v),
            ),
            WhyDoWeAsk(body: s.whySmoker),
          ],
        ),
      ],
    );
  }
}

// ── step 5 · what a doctor may have told you ──────────────────────────

class _StepHistory extends StatelessWidget {
  const _StepHistory({required this.w});

  final WizardState w;

  @override
  Widget build(BuildContext context) {
    final s = context.s;

    return ScreenBody(
      topPad: 16,
      bottomPad: 24,
      children: [
        _Head(title: s.qHistoryHead, sub: s.qHistorySub),
        _YesNoQuestion(
          label: s.fieldHighBp,
          why: s.whyHighBp,
          value: w.knownHighBp,
          onChanged: (v) => w.set_(() => w.knownHighBp = v),
        ),
        _YesNoQuestion(
          label: s.fieldBpMeds,
          why: s.whyBpMeds,
          value: w.onBpMeds,
          onChanged: (v) => w.set_(() => w.onBpMeds = v),
        ),
        _YesNoQuestion(
          label: s.fieldHighGlucose,
          why: s.whyHighGlucose,
          value: w.historyHighGlucose,
          onChanged: (v) => w.set_(() => w.historyHighGlucose = v),
        ),
        // Only asked of female profiles. Null for male is not-applicable,
        // which the wire model keeps distinct from unknown.
        if (w.asksGestational)
          _YesNoQuestion(
            label: s.fieldGestational,
            why: s.whyGestational,
            value: w.gestational,
            onChanged: (v) => w.set_(() => w.gestational = v),
          ),
        VGap(
          10,
          children: [
            Kicker(s.fieldDiabetesStatus),
            for (final (v, label) in [
              (DiabetesStatus.no, s.diabetesNo),
              (DiabetesStatus.prediabetes, s.diabetesPrediabetes),
              (DiabetesStatus.t2d, s.diabetesT2d),
              (DiabetesStatus.t1d, s.diabetesT1d),
              (DiabetesStatus.gestational, s.diabetesGestational),
            ])
              OptionRow<DiabetesStatus>(
                value: v,
                groupValue: w.diabetesStatus,
                label: label,
                onChanged: (x) => w.set_(() => w.diabetesStatus = x),
              ),
            WhyDoWeAsk(body: s.whyDiabetesStatus),
          ],
        ),
      ],
    );
  }
}

// ── shared step furniture ─────────────────────────────────────────────

class _Head extends StatelessWidget {
  const _Head({required this.title, required this.sub});

  final String title, sub;

  @override
  Widget build(BuildContext context) => VGap(
        8,
        cross: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: context.t.screenTitleSm.copyWith(color: context.c.text)),
          P(sub),
        ],
      );
}

class _YesNoQuestion extends StatelessWidget {
  const _YesNoQuestion({
    required this.label,
    required this.why,
    required this.value,
    required this.onChanged,
  });

  final String label, why;
  final bool? value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => VGap(
        10,
        children: [
          // No fixed height, so a long Bangla question wraps rather than
          // clipping.
          Text(label,
              style: context.t.bodyStrong.copyWith(color: context.c.text)),
          YesNo(
            value: value,
            yes: context.s.yes,
            no: context.s.no,
            onChanged: onChanged,
          ),
          WhyDoWeAsk(body: why),
        ],
      );
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: selected,
      button: true,
      label: label,
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
            decoration: BoxDecoration(
              color: selected ? c.accentRamp.c100 : c.card,
              borderRadius: AppRadius.rPill,
              border: Border.all(
                color: selected ? c.accent : c.neutral.c300,
                width: 1.5,
              ),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: context.t.bodyStrong
                  .copyWith(color: selected ? c.accentRamp.c800 : c.text),
            ),
          ),
        ),
      ),
    );
  }
}

/// A −/+ stepper. Values are clamped to the contract's range, so the control
/// cannot produce something the database would reject.
class _StepperCard extends StatelessWidget {
  const _StepperCard({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.format,
    required this.onChanged,
    this.unit,
  });

  final String label;
  final double value, min, max, step;
  final String Function(double) format;
  final ValueChanged<double> onChanged;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return AppCard(
      radius: 26,
      shadow: true,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: HGap(
        12,
        children: [
          Expanded(
            child: VGap(
              3,
              cross: CrossAxisAlignment.start,
              children: [
                Kicker(label),
                if (unit != null)
                  Text(unit!,
                      style: context.t.footnote.copyWith(
                          color: c.neutral.c600, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          CircleIconButton(
            icon: 'M5 12h14',
            size: 36,
            iconSize: 17,
            semanticLabel: '−',
            onPressed:
                value > min ? () => onChanged((value - step).clamp(min, max)) : null,
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 64),
            child: Text(
              format(value),
              textAlign: TextAlign.center,
              style: context.t.statValue.copyWith(color: c.text),
            ),
          ),
          CircleIconButton(
            icon: 'M12 5v14|M5 12h14',
            size: 36,
            iconSize: 17,
            semanticLabel: '+',
            onPressed:
                value < max ? () => onChanged((value + step).clamp(min, max)) : null,
          ),
        ],
      ),
    );
  }
}

/// A stepper with a unit toggle. Everything is held in SI and converted only
/// for display — canonical SI is what gets stored, and the display unit never
/// reaches the API.
class _UnitStepperCard extends StatelessWidget {
  const _UnitStepperCard({
    required this.label,
    required this.siValue,
    required this.siMin,
    required this.siMax,
    required this.siStep,
    required this.metric,
    required this.metricUnit,
    required this.imperialUnit,
    required this.toDisplay,
    required this.formatDisplay,
    required this.onUnitChanged,
    required this.onChanged,
  });

  final String label, metricUnit, imperialUnit;
  final double siValue, siMin, siMax, siStep;
  final bool metric;
  final double Function(double) toDisplay;
  final String Function(double) formatDisplay;
  final ValueChanged<bool> onUnitChanged;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => VGap(
        10,
        children: [
          _StepperCard(
            label: label,
            unit: metric ? metricUnit : imperialUnit,
            value: siValue,
            min: siMin,
            max: siMax,
            step: siStep,
            format: formatDisplay,
            onChanged: onChanged,
          ),
          Segmented<bool>(
            value: metric,
            compact: true,
            options: [(true, metricUnit), (false, imperialUnit)],
            onChanged: onUnitChanged,
          ),
        ],
      );
}

// ── submitting ────────────────────────────────────────────────────────

/// Hands the gathered answers to the calculating screen, which does the two
/// network calls. Called from the population screen's continue *and* its skip,
/// because skipping must land in the assessment just as completely.
///
/// If the profile is not resolved yet — a token restored without a session, or
/// a first launch that never reached [AppState.restoreSession] — this recovers
/// it rather than giving up. Eleven answered questions must not be lost to a
/// missing id, and a toast the user cannot act on is the worst of both.
Future<void> submitProfileAndAssess(BuildContext context, WizardState w) async {
  final app = AppScope.read(context);
  final navigator = Navigator.of(context);

  var profileId = app.profileId;
  if (profileId == null) {
    await app.restoreSession();
    profileId = app.profileId;
  }

  if (profileId == null) {
    if (!context.mounted) return;
    // Genuinely nowhere to send this. Say what happened and what to do,
    // rather than appearing to ignore the tap.
    showToast(context, context.s.errNetwork);
    return;
  }

  navigator.pushNamedAndRemoveUntil(
    Routes.calculating,
    (_) => false,
    arguments: CalculatingArgs(profileId: profileId, wizard: w),
  );
}

/// What the calculating screen needs to do its work.
class CalculatingArgs {
  const CalculatingArgs({required this.profileId, required this.wizard});

  final String profileId;
  final WizardState wizard;
}
