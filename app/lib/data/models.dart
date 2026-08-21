/// Wire models, mirroring `backend/app/schemas.py`.
///
/// The health-profile fields mirror `ml/contracts/feature_spec.json` v1.0.0,
/// which is FROZEN. Where this file and the contract disagree, the contract
/// wins — there is a test asserting the field names match.
library;

import 'dart:convert';

// ── auth ──────────────────────────────────────────────────────────────

class Tokens {
  const Tokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
  });

  final String accessToken;
  final String refreshToken;
  final int expiresIn;

  factory Tokens.fromJson(Map<String, dynamic> j) => Tokens(
        accessToken: j['access_token'] as String,
        refreshToken: j['refresh_token'] as String,
        expiresIn: (j['expires_in'] as num).toInt(),
      );

  String encode() => jsonEncode({
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_in': expiresIn,
      });

  static Tokens? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return Tokens.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

class Account {
  const Account({
    required this.id,
    required this.email,
    required this.homeRegion,
    required this.locale,
    this.subscriptionStatus = 'free',
  });

  final String id;
  final String email;
  final String homeRegion;
  final String locale;

  /// `free` · `trial` · `active` · `past_due` · `cancelled`.
  final String subscriptionStatus;

  bool get isPremium =>
      subscriptionStatus == 'trial' || subscriptionStatus == 'active';

  String get subscriptionLabel => switch (subscriptionStatus) {
        'trial' => 'Premium — trial',
        'active' => 'Premium',
        'past_due' => 'Payment overdue',
        'cancelled' => 'Cancelled',
        _ => 'Free',
      };

  factory Account.fromJson(Map<String, dynamic> j) => Account(
        id: j['id'] as String,
        email: j['email'] as String,
        homeRegion: j['home_region'] as String? ?? 'bd',
        locale: j['locale'] as String? ?? 'bn',
        subscriptionStatus: j['subscription_status'] as String? ?? 'free',
      );
}

class Profile {
  const Profile({
    required this.id,
    required this.displayName,
    required this.regionPack,
  });

  final String id;
  final String displayName;
  final String regionPack;

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        id: j['id'] as String,
        displayName: j['display_name'] as String,
        regionPack: j['region_pack'] as String? ?? 'bd',
      );
}

// ── consent ───────────────────────────────────────────────────────────

class ConsentStatus {
  const ConsentStatus({
    required this.accepted,
    required this.outstanding,
    required this.mayAnswerHealthQuestions,
  });

  final Map<String, String> accepted;
  final List<String> outstanding;

  /// The gate the wizard reads. The server enforces this too, so a client that
  /// skips the disclaimer screen gets a 403, not a silent success.
  final bool mayAnswerHealthQuestions;

  factory ConsentStatus.fromJson(Map<String, dynamic> j) => ConsentStatus(
        accepted: (j['accepted'] as Map).map((k, v) => MapEntry('$k', '$v')),
        outstanding:
            (j['outstanding'] as List).map((e) => e.toString()).toList(),
        mayAnswerHealthQuestions:
            j['may_answer_health_questions'] as bool? ?? false,
      );
}

// ── health profile (the eleven questions) ─────────────────────────────

enum Sex { male, female }

enum FamilyHistory { none, secondDegree, firstDegree }

enum Activity { sedentary, light, moderate, active, veryActive }

enum DiabetesStatus { no, prediabetes, t2d, t1d, gestational }

/// The optional cutoff-group override. NOT an ethnicity model feature — it
/// selects a published clinical threshold set at the calibration layer, and it
/// never reaches the gradient booster. Must be user-declared and optional.
enum AncestryGroup {
  southAsian,
  eastAsian,
  european,
  african,
  middleEastern,
  hispanic,
}

String _snake(String camel) => camel.replaceAllMapped(
      RegExp(r'[A-Z]'),
      (m) => '_${m.group(0)!.toLowerCase()}',
    );

extension SexWire on Sex {
  String get wire => name;
}

extension FamilyWire on FamilyHistory {
  String get wire => _snake(name);
}

extension ActivityWire on Activity {
  String get wire => _snake(name);
}

extension DiabetesWire on DiabetesStatus {
  String get wire => name;
}

extension AncestryWire on AncestryGroup {
  String get wire => _snake(name);
}

class HealthProfile {
  const HealthProfile({
    required this.ageYears,
    required this.sexAtBirth,
    required this.heightCm,
    required this.weightKg,
    this.waistCm,
    this.familyHistory = FamilyHistory.none,
    this.physicalActivity = Activity.sedentary,
    this.smoker = false,
    this.gestationalDiabetesHistory,
    this.knownHighBp = false,
    this.onBpMeds = false,
    this.historyHighGlucose = false,
    this.diabetesStatus = DiabetesStatus.no,
    this.pregnant = false,
    this.ancestryCutoffGroup,
  });

  final int ageYears;
  final Sex sexAtBirth;
  final double heightCm;
  final double weightKg;

  /// Nullable on purpose. The contract says LightGBM handles waist as missing
  /// natively — do NOT impute it, and do not send 0 for "skipped".
  final double? waistCm;

  final FamilyHistory familyHistory;
  final Activity physicalActivity;
  final bool smoker;

  /// Null for male profiles — null means not-applicable here, not unknown.
  final bool? gestationalDiabetesHistory;

  final bool knownHighBp;
  final bool onBpMeds;
  final bool historyHighGlucose;
  final DiabetesStatus diabetesStatus;
  final bool pregnant;

  /// Sent for forward compatibility. The backend does not yet persist this —
  /// see `docs/ui_spec.md` and the gap noted in the app README.
  final AncestryGroup? ancestryCutoffGroup;

  Map<String, dynamic> toJson() => {
        'age_years': ageYears,
        'sex_at_birth': sexAtBirth.wire,
        'height_cm': heightCm,
        'weight_kg': weightKg,
        'waist_cm': waistCm,
        'family_history': familyHistory.wire,
        'physical_activity': physicalActivity.wire,
        'smoker': smoker,
        'gestational_diabetes_history': gestationalDiabetesHistory,
        'known_high_bp': knownHighBp,
        'on_bp_meds': onBpMeds,
        'history_high_glucose': historyHighGlucose,
        'diabetes_status': diabetesStatus.wire,
        'conditions': const <String>[],
        'pregnant': pregnant,
        if (ancestryCutoffGroup != null)
          'ancestry_cutoff_group': ancestryCutoffGroup!.wire,
      };
}

// ── risk ──────────────────────────────────────────────────────────────

class RiskFactor {
  const RiskFactor({
    required this.label,
    required this.points,
    required this.modifiable,
    required this.detail,
  });

  final String label;
  final int points;
  final bool modifiable;
  final String detail;

  factory RiskFactor.fromJson(Map<String, dynamic> j) => RiskFactor(
        label: j['label'] as String,
        points: (j['points'] as num).toInt(),
        modifiable: j['modifiable'] as bool? ?? false,
        detail: j['detail'] as String? ?? '',
      );
}

class LabFinding {
  const LabFinding({
    required this.test,
    required this.value,
    required this.display,
    required this.band,
    required this.statement,
  });

  final String test;
  final double value;
  final String display;
  final String band;
  final String statement;

  factory LabFinding.fromJson(Map<String, dynamic> j) => LabFinding(
        test: j['test'] as String,
        value: (j['value'] as num).toDouble(),
        display: j['display'] as String? ?? '',
        band: j['band'] as String? ?? '',
        statement: j['statement'] as String? ?? '',
      );
}

class RiskResult {
  const RiskResult({
    required this.band,
    required this.bandLabel,
    required this.probability,
    required this.rangeLow,
    required this.rangeHigh,
    required this.tier,
    required this.basis,
    required this.validationStatus,
    required this.region,
    required this.clinicalScore,
    required this.clinicalPoints,
    required this.clinicalMax,
    required this.modifiableFactors,
    required this.fixedFactors,
    required this.caveats,
    required this.disclaimer,
    required this.labFindings,
    required this.raw,
    this.labStatement,
    this.takenAt,
  });

  /// The source payload, kept so the result can be cached verbatim and
  /// re-read offline without a lossy round trip through these fields.
  final Map<String, dynamic> raw;

  String encode() => jsonEncode(raw);

  final String band;
  final String bandLabel;

  /// Present in the payload, and deliberately NOT rendered anywhere.
  /// Rule 1: ranges only. Use [rangeLow]/[rangeHigh].
  final double probability;

  final double rangeLow;
  final double rangeHigh;
  final int tier;
  final String basis;

  /// `not_validated` · `provisional` · `validated`.
  final String validationStatus;

  final String region;
  final String clinicalScore;
  final int clinicalPoints;
  final int clinicalMax;
  final List<RiskFactor> modifiableFactors;
  final List<RiskFactor> fixedFactors;
  final List<String> caveats;

  /// Server-supplied. Rendered as the persistent footer, never dismissible.
  final String disclaimer;

  final List<LabFinding> labFindings;
  final String? labStatement;
  final DateTime? takenAt;

  bool get isMeasurementLed => labFindings.isNotEmpty;

  factory RiskResult.fromJson(Map<String, dynamic> j) => RiskResult(
        band: j['band'] as String,
        bandLabel: j['band_label'] as String,
        probability: (j['probability'] as num).toDouble(),
        rangeLow: (j['range_low'] as num).toDouble(),
        rangeHigh: (j['range_high'] as num).toDouble(),
        tier: (j['tier'] as num).toInt(),
        basis: j['basis'] as String? ?? '',
        validationStatus: j['validation_status'] as String? ?? 'not_validated',
        region: j['region'] as String? ?? 'bd',
        clinicalScore: j['clinical_score'] as String? ?? '',
        clinicalPoints: (j['clinical_points'] as num?)?.toInt() ?? 0,
        clinicalMax: (j['clinical_max'] as num?)?.toInt() ?? 100,
        modifiableFactors: ((j['modifiable_factors'] as List?) ?? const [])
            .map((e) => RiskFactor.fromJson(e as Map<String, dynamic>))
            .toList(),
        fixedFactors: ((j['fixed_factors'] as List?) ?? const [])
            .map((e) => RiskFactor.fromJson(e as Map<String, dynamic>))
            .toList(),
        caveats:
            ((j['caveats'] as List?) ?? const []).map((e) => '$e').toList(),
        disclaimer: j['disclaimer'] as String? ?? '',
        labFindings: ((j['lab_findings'] as List?) ?? const [])
            .map((e) => LabFinding.fromJson(e as Map<String, dynamic>))
            .toList(),
        labStatement: j['lab_statement'] as String?,
        takenAt: j['taken_at'] == null
            ? null
            : DateTime.tryParse(j['taken_at'] as String),
        raw: j,
      );
}

/// One past assessment. Enough to draw a trajectory, and no more — the full
/// result is re-fetched when the user opens it.
class RiskHistoryPoint {
  const RiskHistoryPoint({
    required this.id,
    required this.takenAt,
    required this.probability,
    required this.band,
    required this.rangeLow,
    required this.rangeHigh,
  });

  final String id;
  final DateTime takenAt;

  /// Used only to compute a direction between two points. It is never
  /// rendered on its own — rule 1 holds here too, so the UI shows the range.
  final double probability;

  final String band;
  final double rangeLow, rangeHigh;

  factory RiskHistoryPoint.fromJson(Map<String, dynamic> j) => RiskHistoryPoint(
        id: j['id'] as String,
        takenAt: DateTime.parse(j['taken_at'] as String),
        probability: (j['risk_probability'] as num).toDouble(),
        band: j['risk_band'] as String,
        rangeLow: (j['confidence_low'] as num).toDouble(),
        rangeHigh: (j['confidence_high'] as num).toDouble(),
      );
}

// ── safety ────────────────────────────────────────────────────────────

class SafetyCard {
  const SafetyCard({
    required this.trigger,
    required this.severity,
    required this.title,
    required this.body,
    required this.actions,
    this.emergencyNumber,
  });

  final String trigger;

  /// `urgent` → muted red, "contact a doctor today".
  /// `warning` → amber, "worth mentioning to your doctor".
  final String severity;

  final String title;
  final String body;
  final List<String> actions;
  final String? emergencyNumber;

  bool get isUrgent => severity == 'urgent';

  factory SafetyCard.fromJson(Map<String, dynamic> j) => SafetyCard(
        trigger: j['trigger'] as String? ?? 'unknown',
        severity: j['severity'] as String? ?? 'warning',
        title: j['title'] as String? ?? '',
        body: j['body'] as String? ?? '',
        actions:
            ((j['actions'] as List?) ?? const []).map((e) => '$e').toList(),
        emergencyNumber: j['emergency_number'] as String?,
      );
}

// ── vitals ────────────────────────────────────────────────────────────

enum VitalType { glucose, hba1c, weight, waist, bpSystolic, bpDiastolic }

extension VitalTypeWire on VitalType {
  String get wire => _snake(name);
}

class Vital {
  const Vital({
    required this.id,
    required this.type,
    required this.value,
    required this.unit,
    required this.recordedAt,
    this.contextTag,
  });

  final String id;
  final String type;
  final double value;
  final String unit;
  final DateTime recordedAt;
  final String? contextTag;

  factory Vital.fromJson(Map<String, dynamic> j) => Vital(
        id: j['id'] as String,
        type: j['type'] as String,
        value: (j['value'] as num).toDouble(),
        unit: j['unit'] as String,
        recordedAt: DateTime.parse(j['recorded_at'] as String),
        contextTag: j['context_tag'] as String?,
      );
}

// ── food and meals ────────────────────────────────────────────────────

class Food {
  const Food({
    required this.id,
    required this.nameEn,
    required this.nameLocal,
    required this.kcalPer100g,
    required this.glycemicIndex,
    required this.portionGrams,
    required this.source,
  });

  final String id;
  final String nameEn;
  final String? nameLocal;
  final double kcalPer100g;
  final double? glycemicIndex;
  final Map<String, double> portionGrams;

  /// `placeholder` means a widely-published approximation, not a licensed
  /// composition table. The UI must not present it as authoritative.
  final String source;

  bool get isPlaceholder => source == 'placeholder';

  List<String> get units =>
      portionGrams.keys.where((k) => k != 'g' && k != 'gram').toList();

  factory Food.fromJson(Map<String, dynamic> j) => Food(
        id: j['id'] as String,
        nameEn: j['name_en'] as String,
        nameLocal: j['name_local'] as String?,
        kcalPer100g: (j['kcal_per_100g'] as num).toDouble(),
        glycemicIndex: (j['glycemic_index'] as num?)?.toDouble(),
        portionGrams: ((j['portion_grams'] as Map?) ?? const {})
            .map((k, v) => MapEntry('$k', (v as num).toDouble())),
        source: j['source'] as String? ?? 'placeholder',
      );
}

class MealItem {
  const MealItem({
    required this.id,
    required this.name,
    required this.quantity,
    required this.unit,
    required this.grams,
    required this.kcal,
    required this.carbsG,
    required this.proteinG,
    required this.fatG,
    required this.fibreG,
    this.glycemicLoad,
  });

  final String id;
  final String name;
  final double quantity;
  final String unit;
  final double grams;
  final double kcal, carbsG, proteinG, fatG, fibreG;
  final double? glycemicLoad;

  factory MealItem.fromJson(Map<String, dynamic> j) => MealItem(
        id: j['id'] as String,
        name: j['name_snapshot'] as String,
        quantity: (j['quantity'] as num).toDouble(),
        unit: j['unit'] as String,
        grams: (j['grams'] as num).toDouble(),
        kcal: (j['kcal'] as num).toDouble(),
        carbsG: (j['carbs_g'] as num).toDouble(),
        proteinG: (j['protein_g'] as num).toDouble(),
        fatG: (j['fat_g'] as num).toDouble(),
        fibreG: (j['fibre_g'] as num).toDouble(),
        glycemicLoad: (j['glycemic_load'] as num?)?.toDouble(),
      );
}

/// One item on its way to the server — a portion the user has confirmed.
class MealItemDraft {
  MealItemDraft({
    this.foodId,
    required this.name,
    this.quantity = 1,
    this.unit = 'serving',
    this.kcalPer100g = 0,
    this.portionGrams = const {},
  });

  final String? foodId;
  final String name;
  double quantity;
  String unit;

  /// Held for the live estimate shown while editing. The server recomputes
  /// from its own composition row on save, and its answer is the one stored.
  final double kcalPer100g;
  final Map<String, double> portionGrams;

  double get grams =>
      quantity * (portionGrams[unit] ?? _genericPortionGrams[unit] ?? 120);

  double get estimatedKcal => kcalPer100g * grams / 100;

  Map<String, dynamic> toJson() => {
        if (foodId != null) 'food_id': foodId,
        'name': name,
        'quantity': quantity,
        'unit': unit,
      };
}

const _genericPortionGrams = <String, double>{
  'cup': 150,
  'bowl': 200,
  'spoon': 15,
  'piece': 50,
  'slice': 30,
  'ladle': 80,
  'serving': 120,
};

class Meal {
  const Meal({
    required this.id,
    required this.slot,
    required this.eatenAt,
    required this.entryMethod,
    required this.items,
    required this.kcal,
    required this.carbsG,
    required this.proteinG,
    required this.fatG,
    required this.fibreG,
    required this.kcalLow,
    required this.kcalHigh,
    this.glycemicLoad,
    this.note,
  });

  final String id;
  final String slot;
  final DateTime eatenAt;
  final String entryMethod;
  final List<MealItem> items;
  final double kcal, carbsG, proteinG, fatG, fibreG;

  /// Calories are always shown as a range with an "estimate" label. A photo of
  /// a plate of rice is not known to the calorie.
  final int kcalLow, kcalHigh;

  final double? glycemicLoad;
  final String? note;

  factory Meal.fromJson(Map<String, dynamic> j) => Meal(
        id: j['id'] as String,
        slot: j['slot'] as String,
        eatenAt: DateTime.parse(j['eaten_at'] as String),
        entryMethod: j['entry_method'] as String? ?? 'manual',
        items: ((j['items'] as List?) ?? const [])
            .map((e) => MealItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        kcal: (j['kcal'] as num).toDouble(),
        carbsG: (j['carbs_g'] as num).toDouble(),
        proteinG: (j['protein_g'] as num).toDouble(),
        fatG: (j['fat_g'] as num).toDouble(),
        fibreG: (j['fibre_g'] as num).toDouble(),
        kcalLow: (j['kcal_low'] as num).toInt(),
        kcalHigh: (j['kcal_high'] as num).toInt(),
        glycemicLoad: (j['glycemic_load'] as num?)?.toDouble(),
        note: j['note'] as String?,
      );
}

class DailyTarget {
  const DailyTarget({
    required this.kcal,
    required this.carbsG,
    required this.proteinG,
    required this.fatG,
    required this.fibreG,
    required this.glycemicLoadCeiling,
    required this.maintenanceKcal,
    required this.wasClamped,
    required this.weightLossDisabled,
    required this.notes,
    this.clampReason,
  });

  final int kcal, carbsG, proteinG, fatG, fibreG;
  final int glycemicLoadCeiling, maintenanceKcal;

  /// True when the §5.4 safety rails moved the number. Surfaced so the UI can
  /// explain itself rather than silently showing a different figure.
  final bool wasClamped;
  final bool weightLossDisabled;
  final List<String> notes;
  final String? clampReason;

  factory DailyTarget.fromJson(Map<String, dynamic> j) => DailyTarget(
        kcal: (j['kcal'] as num).toInt(),
        carbsG: (j['carbs_g'] as num).toInt(),
        proteinG: (j['protein_g'] as num).toInt(),
        fatG: (j['fat_g'] as num).toInt(),
        fibreG: (j['fibre_g'] as num).toInt(),
        glycemicLoadCeiling: (j['glycemic_load_ceiling'] as num).toInt(),
        maintenanceKcal: (j['maintenance_kcal'] as num).toInt(),
        wasClamped: j['was_clamped'] as bool? ?? false,
        weightLossDisabled: j['weight_loss_disabled'] as bool? ?? false,
        notes: ((j['notes'] as List?) ?? const []).map((e) => '$e').toList(),
        clampReason: j['clamp_reason'] as String?,
      );
}

class DayTotals {
  const DayTotals({
    required this.kcal,
    required this.carbsG,
    required this.proteinG,
    required this.fatG,
    required this.fibreG,
    required this.kcalLow,
    required this.kcalHigh,
    this.glycemicLoad,
  });

  final double kcal, carbsG, proteinG, fatG, fibreG;
  final int kcalLow, kcalHigh;
  final double? glycemicLoad;

  factory DayTotals.fromJson(Map<String, dynamic> j) => DayTotals(
        kcal: (j['kcal'] as num).toDouble(),
        carbsG: (j['carbs_g'] as num).toDouble(),
        proteinG: (j['protein_g'] as num).toDouble(),
        fatG: (j['fat_g'] as num).toDouble(),
        fibreG: (j['fibre_g'] as num).toDouble(),
        kcalLow: (j['kcal_low'] as num).toInt(),
        kcalHigh: (j['kcal_high'] as num).toInt(),
        glycemicLoad: (j['glycemic_load'] as num?)?.toDouble(),
      );
}

class PlanToday {
  const PlanToday({
    required this.day,
    required this.totals,
    required this.meals,
    this.target,
    this.safetyCard,
  });

  final DateTime day;
  final DayTotals totals;
  final List<Meal> meals;
  final DailyTarget? target;

  /// Present when the day's pattern tripped a §5.4 rail. Never gamified, never
  /// a failure state — it turns aggressive targets off.
  final SafetyCard? safetyCard;

  factory PlanToday.fromJson(Map<String, dynamic> j) => PlanToday(
        day: DateTime.parse(j['day'] as String),
        totals: DayTotals.fromJson(j['totals'] as Map<String, dynamic>),
        meals: ((j['meals'] as List?) ?? const [])
            .map((e) => Meal.fromJson(e as Map<String, dynamic>))
            .toList(),
        target: j['target'] == null
            ? null
            : DailyTarget.fromJson(j['target'] as Map<String, dynamic>),
        safetyCard: j['safety_card'] == null
            ? null
            : SafetyCard.fromJson(j['safety_card'] as Map<String, dynamic>),
      );
}

class Recognition {
  const Recognition({
    required this.modelAvailable,
    required this.message,
    required this.confidenceFloor,
  });

  /// False in this build — no recognition model is wired. The client must say
  /// so rather than implying a photo was understood.
  final bool modelAvailable;
  final String message;
  final double confidenceFloor;

  factory Recognition.fromJson(Map<String, dynamic> j) => Recognition(
        modelAvailable: j['model_available'] as bool? ?? false,
        message: j['message'] as String? ?? '',
        confidenceFloor: (j['confidence_floor'] as num?)?.toDouble() ?? 0.55,
      );
}

// ── check-ins and activity ────────────────────────────────────────────

class Checkin {
  const Checkin({
    required this.id,
    required this.on,
    required this.symptoms,
    this.energy,
    this.sleepHours,
    this.mood,
    this.note,
  });

  final String id;
  final DateTime on;
  final List<String> symptoms;
  final int? energy;
  final double? sleepHours;
  final int? mood;
  final String? note;

  factory Checkin.fromJson(Map<String, dynamic> j) => Checkin(
        id: j['id'] as String,
        on: DateTime.parse(j['checkin_on'] as String),
        symptoms:
            ((j['symptoms'] as List?) ?? const []).map((e) => '$e').toList(),
        energy: (j['energy'] as num?)?.toInt(),
        sleepHours: (j['sleep_hours'] as num?)?.toDouble(),
        mood: (j['mood'] as num?)?.toInt(),
        note: j['note'] as String?,
      );
}

/// One day's movement. Named `ActivityDay` because [Activity] is already the
/// contract's five-point physical-activity level.
class ActivityDay {
  const ActivityDay({
    required this.on,
    required this.steps,
    required this.activeMinutes,
    this.distanceKm,
  });

  final DateTime on;
  final int steps;
  final int activeMinutes;
  final double? distanceKm;

  factory ActivityDay.fromJson(Map<String, dynamic> j) => ActivityDay(
        on: DateTime.parse(j['activity_on'] as String),
        steps: (j['steps'] as num).toInt(),
        activeMinutes: (j['active_minutes'] as num).toInt(),
        distanceKm: (j['distance_km'] as num?)?.toDouble(),
      );
}

// ── coach ─────────────────────────────────────────────────────────────

class CoachReply {
  const CoachReply({
    required this.reply,
    required this.intercepted,
    required this.cited,
    required this.modelBacked,
    this.questionsRemaining,
    this.safetyCard,
  });

  final String reply;

  /// True when a guard answered instead of the responder — a red flag, a
  /// medication question, or the diagnosis question.
  final bool intercepted;

  /// What the answer was built from. An answer the user cannot check is an
  /// assertion, not an answer.
  final List<String> cited;

  /// False in this build. There is no language model behind the coach, and the
  /// UI says so rather than letting the user assume one.
  final bool modelBacked;

  final int? questionsRemaining;
  final SafetyCard? safetyCard;

  factory CoachReply.fromJson(Map<String, dynamic> j) => CoachReply(
        reply: j['reply'] as String,
        intercepted: j['intercepted'] as bool? ?? false,
        cited: ((j['cited'] as List?) ?? const []).map((e) => '$e').toList(),
        modelBacked: j['model_backed'] as bool? ?? false,
        questionsRemaining: (j['questions_remaining'] as num?)?.toInt(),
        safetyCard: j['safety_card'] == null
            ? null
            : SafetyCard.fromJson(j['safety_card'] as Map<String, dynamic>),
      );
}

class CoachTurn {
  const CoachTurn({
    required this.role,
    required this.body,
    required this.intercepted,
    required this.createdAt,
  });

  final String role;
  final String body;
  final bool intercepted;
  final DateTime createdAt;

  bool get isUser => role == 'user';

  factory CoachTurn.fromJson(Map<String, dynamic> j) => CoachTurn(
        role: j['role'] as String,
        body: j['body'] as String,
        intercepted: j['intercepted'] as bool? ?? false,
        createdAt: DateTime.parse(j['created_at'] as String),
      );
}

/// 402 from the coach — the free daily allowance is used up. A branch to the
/// paywall, not an error. Safety interceptions are never rate-limited.
class CoachLimitReached implements Exception {
  const CoachLimitReached(this.message);
  final String message;
}

// ── insights and reports ──────────────────────────────────────────────

class Insight {
  const Insight({
    required this.key,
    required this.headline,
    required this.detail,
    required this.observations,
    required this.direction,
  });

  final String key;
  final String headline;
  final String detail;

  /// What this was computed from, so the card can show its own evidence.
  final int observations;

  final String direction;

  factory Insight.fromJson(Map<String, dynamic> j) => Insight(
        key: j['key'] as String,
        headline: j['headline'] as String,
        detail: j['detail'] as String,
        observations: (j['observations'] as num).toInt(),
        direction: j['direction'] as String? ?? 'flat',
      );
}

class WeeklyInsights {
  const WeeklyInsights({
    required this.insights,
    required this.insufficientData,
    required this.minimumObservations,
  });

  final List<Insight> insights;
  final bool insufficientData;
  final int minimumObservations;

  factory WeeklyInsights.fromJson(Map<String, dynamic> j) => WeeklyInsights(
        insights: ((j['insights'] as List?) ?? const [])
            .map((e) => Insight.fromJson(e as Map<String, dynamic>))
            .toList(),
        insufficientData: j['insufficient_data'] as bool? ?? true,
        minimumObservations: (j['minimum_observations'] as num?)?.toInt() ?? 5,
      );
}

class DoctorReport {
  const DoctorReport({
    required this.id,
    required this.generatedAt,
    required this.payload,
  });

  final String id;
  final DateTime generatedAt;
  final Map<String, dynamic> payload;

  factory DoctorReport.fromJson(Map<String, dynamic> j) => DoctorReport(
        id: j['id'] as String,
        generatedAt: DateTime.parse(j['generated_at'] as String),
        payload: (j['payload'] as Map).cast<String, dynamic>(),
      );
}

// ── billing ───────────────────────────────────────────────────────────

class Plan {
  const Plan({
    required this.code,
    required this.name,
    required this.priceMinor,
    required this.currency,
    required this.period,
    required this.trialDays,
    required this.rails,
  });

  final String code;
  final String name;
  final int priceMinor;
  final String currency;
  final String period;
  final int trialDays;
  final List<String> rails;

  /// Minor units to major — poisha to taka.
  double get price => priceMinor / 100;

  factory Plan.fromJson(Map<String, dynamic> j) => Plan(
        code: j['code'] as String,
        name: j['name'] as String,
        priceMinor: (j['price_minor'] as num).toInt(),
        currency: j['currency'] as String,
        period: j['period'] as String,
        trialDays: (j['trial_days'] as num).toInt(),
        rails: ((j['rails'] as List?) ?? const []).map((e) => '$e').toList(),
      );
}

class Plans {
  const Plans({
    required this.plans,
    required this.freeForever,
    required this.freeForeverKeys,
    required this.currentStatus,
  });

  final List<Plan> plans;

  /// The server's English wording. A fallback only — see [freeForeverKeys].
  final List<String> freeForever;

  /// What is free, as stable keys. The server decides *what*; the client owns
  /// the wording, because it knows the user's language and the backend has no
  /// translation table. Render from these and fall back to [freeForever] for
  /// any key this build does not recognise.
  final List<String> freeForeverKeys;

  final String currentStatus;

  bool get isSubscribed => currentStatus == 'trial' || currentStatus == 'active';

  factory Plans.fromJson(Map<String, dynamic> j) => Plans(
        plans: ((j['plans'] as List?) ?? const [])
            .map((e) => Plan.fromJson(e as Map<String, dynamic>))
            .toList(),
        freeForever:
            ((j['free_forever'] as List?) ?? const []).map((e) => '$e').toList(),
        freeForeverKeys: ((j['free_forever_keys'] as List?) ?? const [])
            .map((e) => '$e')
            .toList(),
        currentStatus: j['current_status'] as String? ?? 'free',
      );
}

// ── region pack ───────────────────────────────────────────────────────

class RegionPack {
  const RegionPack({
    required this.code,
    required this.country,
    required this.languages,
    required this.defaultLanguage,
    required this.emergencyNumber,
    required this.glucoseUnit,
    required this.minAge,
  });

  final String code;
  final String country;
  final List<String> languages;
  final String defaultLanguage;

  /// `999` for Bangladesh. Always from the pack, never hard-coded in a screen.
  final String emergencyNumber;

  final String glucoseUnit;
  final int minAge;

  static const fallbackBd = RegionPack(
    code: 'bd',
    country: 'Bangladesh',
    languages: ['bn', 'en'],
    defaultLanguage: 'bn',
    emergencyNumber: '999',
    glucoseUnit: 'mmol/L',
    minAge: 18,
  );

  factory RegionPack.fromJson(Map<String, dynamic> j) {
    final units = (j['units_default'] as Map?) ?? const {};
    final safety = (j['safety_thresholds'] as Map?) ?? const {};
    return RegionPack(
      code: j['code'] as String? ?? 'bd',
      country: j['country'] as String? ?? 'Bangladesh',
      languages:
          ((j['languages'] as List?) ?? const ['en']).map((e) => '$e').toList(),
      defaultLanguage: j['default_language'] as String? ?? 'en',
      emergencyNumber: '${safety['emergency_number'] ?? '999'}',
      glucoseUnit: '${units['glucose'] ?? 'mmol/L'}',
      minAge: (safety['min_age'] as num?)?.toInt() ?? 18,
    );
  }
}
