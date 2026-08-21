/// The wizard's working answers.
///
/// Held as nullables rather than defaults, so "not answered yet" and
/// "answered no" stay distinguishable all the way to the wire. The contract is
/// explicit that this matters — a skipped waist is missing, not zero, and
/// LightGBM handles missing natively.
///
/// Ranges here mirror `feature_spec.json` and the database CHECK constraints.
/// The UI's job is to **prevent** an out-of-range value, not to submit one and
/// let the server reject it.
library;

import 'package:flutter/foundation.dart';

import '../data/models.dart';

class WizardState extends ChangeNotifier {
  // ── step 1 · about you ──────────────────────────────────────────────
  int? age; // 18–120, hard block below 18
  Sex? sex;

  // ── step 2 · measurements ───────────────────────────────────────────
  double? heightCm; // 100–250
  double? weightKg; // 25–300

  // ── step 3 · waist ──────────────────────────────────────────────────
  /// Skippable. Skipping widens the range; it never blocks.
  double? waistCm; // 40–200
  bool waistSkipped = false;

  // ── step 4 · family and daily life ──────────────────────────────────
  FamilyHistory? family;
  Activity? activity;
  bool? smoker;

  // ── step 5 · what a doctor may have told you ────────────────────────
  bool? knownHighBp;
  bool? onBpMeds;
  bool? historyHighGlucose;

  /// Only asked of female profiles. Null for male means not-applicable, which
  /// is a different thing from unknown.
  bool? gestational;

  DiabetesStatus? diabetesStatus;

  // ── step 6 · population guidelines (optional) ───────────────────────
  AncestryGroup? ancestry;
  bool ancestrySkipped = false;

  static const ageMin = 18, ageMax = 120;
  static const heightMin = 100.0, heightMax = 250.0;
  static const weightMin = 25.0, weightMax = 300.0;
  static const waistMin = 40.0, waistMax = 200.0;

  bool get asksGestational => sex == Sex.female;

  /// Under-18 must never get through. Enforced server-side as well, but the UI
  /// must not offer the path either.
  bool get isUnderage => age != null && age! < ageMin;

  bool get step1Complete => age != null && !isUnderage && sex != null;
  bool get step2Complete => heightCm != null && weightKg != null;
  bool get step3Complete => waistCm != null || waistSkipped;
  bool get step4Complete =>
      family != null && activity != null && smoker != null;
  bool get step5Complete =>
      knownHighBp != null &&
      onBpMeds != null &&
      historyHighGlucose != null &&
      diabetesStatus != null &&
      (!asksGestational || gestational != null);

  bool completeThrough(int step) => switch (step) {
        0 => step1Complete,
        1 => step2Complete,
        2 => step3Complete,
        3 => step4Complete,
        4 => step5Complete,
        _ => true,
      };

  /// True once every required answer is in. Waist is intentionally not
  /// required — it is the most valuable answer and still optional, because
  /// blocking on it would lose the user entirely.
  bool get readyToSubmit =>
      step1Complete && step2Complete && step4Complete && step5Complete;

  HealthProfile toWire() => HealthProfile(
        ageYears: age!,
        sexAtBirth: sex!,
        heightCm: heightCm!,
        weightKg: weightKg!,
        waistCm: waistCm,
        familyHistory: family ?? FamilyHistory.none,
        physicalActivity: activity ?? Activity.sedentary,
        smoker: smoker ?? false,
        gestationalDiabetesHistory: asksGestational ? gestational : null,
        knownHighBp: knownHighBp ?? false,
        onBpMeds: onBpMeds ?? false,
        historyHighGlucose: historyHighGlucose ?? false,
        diabetesStatus: diabetesStatus ?? DiabetesStatus.no,
        ancestryCutoffGroup: ancestry,
      );

  void set_(void Function() mutate) {
    mutate();
    notifyListeners();
  }
}

// ── unit conversion, for display only ─────────────────────────────────
//
// Canonical SI is what gets stored (PRD 13.2). These exist so someone who
// thinks in feet and pounds can answer honestly, and they never reach the API.

double cmToInches(double cm) => cm / 2.54;
double inchesToCm(double inches) => inches * 2.54;
double kgToPounds(double kg) => kg * 2.2046226218;
double poundsToKg(double lb) => lb / 2.2046226218;

/// Height as feet and inches, for the ft/in entry mode.
(int feet, double inches) cmToFeetInches(double cm) {
  final total = cmToInches(cm);
  final feet = total ~/ 12;
  return (feet, total - feet * 12);
}

double feetInchesToCm(int feet, double inches) =>
    inchesToCm(feet * 12 + inches);
