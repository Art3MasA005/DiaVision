/// 12 · Daily check-in.
///
/// Five taps, under thirty seconds. Energy, sleep, mood, and a symptom
/// interceptor.
///
/// **The interceptor is the point of the screen.** A symptom combination that
/// crosses the threshold routes to the safety card instead of back to Home,
/// and the check-in is recorded either way — the server writes it before it
/// decides whether to intercept, because losing what someone reported would be
/// the worst possible response to them reporting it.
///
/// The symptom card is firm and never says "you have diabetes". A warning is
/// "write it down and take it with you"; an emergency phrase in the note is
/// what escalates.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/api.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/shell.dart';
import 'edge_states.dart';

/// The symptoms the interceptor knows about. Keys match the server's clusters.
const _symptomKeys = [
  'blurred_vision',
  'excessive_thirst',
  'frequent_urination',
  'numbness',
  'slow_healing',
  'fatigue',
];

class CheckinScreen extends StatefulWidget {
  const CheckinScreen({super.key});

  @override
  State<CheckinScreen> createState() => _CheckinScreenState();
}

class _CheckinScreenState extends State<CheckinScreen> {
  final _note = TextEditingController();
  final _symptoms = <String>{};

  int _energy = 3;
  double _sleep = 7;
  int _mood = 3;

  bool _existing = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadExisting());
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _loadExisting() async {
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) return;
    try {
      final today = await app.api.checkinToday(profileId);
      if (today != null && mounted) {
        setState(() {
          _existing = true;
          _energy = today.energy ?? 3;
          _sleep = today.sleepHours ?? 7;
          _mood = today.mood ?? 3;
          _symptoms
            ..clear()
            ..addAll(today.symptoms);
          _note.text = today.note ?? '';
        });
      }
    } on ApiFailure {
      // A fresh check-in is a fine fallback.
    }
  }

  Future<void> _submit() async {
    if (_saving) return;
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await app.api.submitCheckin(
        profileId,
        energy: _energy,
        sleepHours: _sleep,
        mood: _mood,
        symptoms: _symptoms.toList(),
        note: _note.text.trim(),
      );
      app.markOffline(false);
      if (!mounted) return;
      showToast(context, context.s.checkinDone);
      Navigator.of(context).pushReplacementNamed(Routes.home);
    } on SafetyIntercept catch (e) {
      if (!mounted) return;
      // The check-in WAS recorded. The card replaces the screen.
      Navigator.of(context).pushReplacement(
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
      child: Column(
        children: [
          ScreenHeader(title: s.checkinHead),
          Expanded(
            child: ScreenBody(
              topPad: 12,
              bottomPad: 24,
              gap: 20,
              children: [
                P(s.checkinSub, style: context.t.caption),
                if (_existing)
                  AppCard(
                    radius: 18,
                    color: c.neutral.c200,
                    borderColor: c.neutral.c300,
                    child: P(s.checkinAlready, style: context.t.footnote),
                  ),

                _scale(c, s, n, s.checkinEnergy, _energy,
                    (v) => setState(() => _energy = v)),

                VGap(
                  8,
                  children: [
                    HGap(
                      10,
                      children: [
                        Expanded(child: Kicker(s.checkinSleep)),
                        Text('${n.decimal(_sleep, places: 1)} h',
                            style: context.t.statValue.copyWith(color: c.text)),
                      ],
                    ),
                    AppSlider(
                      value: _sleep,
                      min: 0,
                      max: 12,
                      divisions: 24,
                      label: s.checkinSleep,
                      semanticFormatter: (v) =>
                          '${n.decimal(v, places: 1)} hours',
                      onChanged: (v) => setState(() => _sleep = v),
                    ),
                  ],
                ),

                _scale(c, s, n, s.checkinMood, _mood,
                    (v) => setState(() => _mood = v)),

                VGap(
                  10,
                  children: [
                    Kicker(s.checkinSymptoms),
                    P(s.checkinSymptomsHint, style: context.t.footnote),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final key in _symptomKeys)
                          _symptomChip(c, s, key),
                      ],
                    ),
                  ],
                ),

                FieldCard(
                  label: s.checkinNote,
                  icon: Icons24.clipboard,
                  child: BareInput(
                    controller: _note,
                    hint: s.checkinNoteHint,
                  ),
                ),

                if (_error != null)
                  AppCard(
                    radius: 18,
                    color: c.cautionTint,
                    borderColor: c.cautionBorder,
                    child:
                        P(_error!, style: context.t.caption, color: c.caution),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(18, 8, 18, 12),
            child: _saving
                ? Center(child: CircularProgressIndicator(color: c.accent))
                : PillButton(label: s.checkinSubmit, onPressed: _submit),
          ),
        ],
      ),
    );
  }

  /// A 1–5 scale. Numbers go through the formatter so Bangla shows ১–৫.
  Widget _scale(dynamic c, dynamic s, dynamic n, String label, int value,
      ValueChanged<int> onChanged) {
    return VGap(
      8,
      children: [
        Kicker(label),
        Row(
          spacing: 8,
          children: [
            for (var i = 1; i <= 5; i++)
              Expanded(
                child: Semantics(
                  inMutuallyExclusiveGroup: true,
                  selected: i == value,
                  label: '$label ${n.int_(i)}',
                  child: ExcludeSemantics(
                    child: GestureDetector(
                      onTap: () => onChanged(i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 140),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: i == value ? c.accentRamp.c100 : c.card,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: i == value ? c.accent : c.neutral.c300,
                            width: 1.5,
                          ),
                        ),
                        child: Text(
                          n.int_(i),
                          textAlign: TextAlign.center,
                          style: context.t.bodyStrong.copyWith(
                            color: i == value ? c.accentRamp.c800 : c.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _symptomChip(dynamic c, dynamic s, String key) {
    final on = _symptoms.contains(key);
    return Semantics(
      checked: on,
      label: s.symptomLabel(key),
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: () => setState(
              () => on ? _symptoms.remove(key) : _symptoms.add(key)),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              // Caution, not safety red. Reporting a symptom is not itself an
              // emergency, and colouring it as one would teach people to stop.
              color: on ? c.cautionTint : c.card,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: on ? c.cautionBorder : c.neutral.c300,
                width: 1.5,
              ),
            ),
            child: Text(
              s.symptomLabel(key),
              style: context.t.caption.copyWith(
                color: on ? c.caution : c.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
