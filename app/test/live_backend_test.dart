/// Drives the real [Api] class against a running backend.
///
///   $env:PYTHONPATH="E:\Bye Bye Diabetes\backend"
///   .\.venv\Scripts\python.exe -m uvicorn app.main:app --app-dir backend
///   cd app; flutter test test/live_backend_test.dart
///
/// Skipped automatically when nothing is listening on 127.0.0.1:8000, so the
/// suite stays green on a machine without the backend. Everything else in
/// `test/` runs offline against canned payloads; this is the one place the
/// wire contract is checked against the thing that actually serves it.
library;

import 'dart:io';

import 'package:byebye/data/api.dart';
import 'package:byebye/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Polls [check] until it holds, or fails.
///
/// Writes return before their transaction commits — the FastAPI `yield`
/// dependency commits in the generator's tail, after the response has been
/// built — so an immediate read on another pooled connection can still see the
/// old state. In the app this is invisible: a human spends minutes in the
/// wizard between accepting the disclaimer and submitting health data. A test
/// issues the two calls microseconds apart and catches it about one run in
/// four. Polling is the right shape for a test; the app does not need it.
Future<void> _eventually(
  Future<bool> Function() check, {
  required String describe,
}) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail(describe);
}

Future<void> _awaitConsent(Api api) => _eventually(
      () async => (await api.consentStatus()).mayAnswerHealthQuestions,
      describe: 'the medical disclaimer never became visible after recording',
    );

/// The signup transaction creates the account, the Terms consent and the self
/// profile together, and commits after responding with the tokens.
Future<void> _awaitSignup(Api api) => _eventually(
      () async => (await api.profiles()).isNotEmpty,
      describe: 'the signup profile never became visible',
    );

/// `PUT /profiles/{id}/health` commits after responding too, so an assessment
/// fired immediately afterwards can find no health row and return 400
/// ("Complete the health profile first"). Same race, same shape of fix.
Future<RiskResult> _assessWhenReady(Api api, String profileId) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    try {
      return await api.assess(profileId);
    } on ServerFailure catch (e) {
      if (e.status != 400) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
  fail('the health profile never became visible to /risk/assess');
}

Future<bool> _backendUp() async {
  try {
    final socket = await Socket.connect('127.0.0.1', 8000,
        timeout: const Duration(milliseconds: 600));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  late Api api;
  Tokens? tokens;

  setUp(() {
    api = Api(
      baseUrl: 'http://127.0.0.1:8000/api/v1',
      readTokens: () => tokens,
      writeTokens: (t) async => tokens = t,
    );
  });

  test('the whole onboarding flow, against the live API', () async {
    if (!await _backendUp()) {
      markTestSkipped('backend not running on 127.0.0.1:8000');
      return;
    }

    final email =
        'flutter.live.${DateTime.now().microsecondsSinceEpoch}@example.com';

    // ── signup records Terms only ──────────────────────────────────────
    tokens = await api.signup(
      email: email,
      password: 'correct-horse-8',
      displayName: 'Live Probe',
      region: 'bd',
      locale: 'bn',
      acceptTerms: true,
    );
    expect(tokens!.accessToken, isNotEmpty);
    await _awaitSignup(api);

    var consent = await api.consentStatus();
    expect(consent.accepted['terms'], isNotNull,
        reason: 'Terms are recorded at signup');
    expect(consent.outstanding, contains('medical_disclaimer'),
        reason: 'the disclaimer is a SEPARATE record, still outstanding');
    expect(consent.mayAnswerHealthQuestions, isFalse);

    final profiles = await api.profiles();
    expect(profiles, isNotEmpty);
    final profileId = profiles.first.id;

    const health = HealthProfile(
      ageYears: 42,
      sexAtBirth: Sex.female,
      heightCm: 158,
      weightKg: 71,
      waistCm: 92,
      familyHistory: FamilyHistory.firstDegree,
      physicalActivity: Activity.sedentary,
      gestationalDiabetesHistory: true,
      knownHighBp: true,
    );

    // ── the disclaimer gate is a branch, not an error ─────────────────
    await expectLater(
      api.putHealthProfile(profileId, health),
      throwsA(isA<DisclaimerRequired>()),
      reason: 'the server refuses health data before the disclaimer',
    );

    // ── accept it, and the same call now works ────────────────────────
    await api.recordConsent('medical_disclaimer', locale: 'bn');
    await _awaitConsent(api);

    consent = await api.consentStatus();
    expect(consent.accepted['medical_disclaimer'], isNotNull);
    expect(consent.outstanding, isEmpty);

    await api.putHealthProfile(profileId, health);

    // ── Tier 1 ────────────────────────────────────────────────────────
    final tier1 = await _assessWhenReady(api, profileId);
    expect(tier1.tier, 1);
    expect(tier1.rangeLow, lessThan(tier1.rangeHigh));
    expect(tier1.disclaimer, isNotEmpty,
        reason: 'every risk response carries a disclaimer');
    expect(tier1.modifiableFactors, isNotEmpty);
    expect(tier1.isMeasurementLed, isFalse);
    // Bangladesh is honestly not-validated today, and says so.
    expect(tier1.validationStatus, 'not_validated');

    // ── Tier 2 — a measurement outranks an estimate ───────────────────
    await api.addLabs(profileId, hba1cPercent: 6.1);
    final tier2 = await api.assess(profileId);
    expect(tier2.tier, 2);
    expect(tier2.isMeasurementLed, isTrue);
    expect(tier2.labFindings.first.band, 'prediabetes');
    expect(
      tier2.rangeHigh - tier2.rangeLow,
      lessThan(tier1.rangeHigh - tier1.rangeLow),
      reason: 'a lab value narrows the estimate',
    );

    // ── the red-flag interceptor ──────────────────────────────────────
    await expectLater(
      api.addLabs(profileId, fastingGlucoseMmolL: 15.2),
      throwsA(
        isA<SafetyIntercept>()
            .having((e) => e.card.isUrgent, 'urgent', isTrue)
            .having((e) => e.recorded, 'the value was still recorded', isTrue)
            .having((e) => e.card.emergencyNumber, 'emergency number', '999'),
      ),
    );

    // ── login round-trips ─────────────────────────────────────────────
    tokens = null;
    tokens = await api.login(email: email, password: 'correct-horse-8');
    expect((await api.me()).email, email);

    // ── a wrong password is Unauthorized, not a crash ─────────────────
    await expectLater(
      api.login(email: email, password: 'not-the-password'),
      throwsA(isA<ApiFailure>()),
    );

    // ── the region pack supplies the emergency number ─────────────────
    final pack = await api.regionPack('bd');
    expect(pack.emergencyNumber, '999');
    expect(pack.minAge, 18);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('the tracking half, against the live API', () async {
    if (!await _backendUp()) {
      markTestSkipped('backend not running on 127.0.0.1:8000');
      return;
    }

    tokens = await api.signup(
      email: 'flutter.track.${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'correct-horse-8',
      displayName: 'Tracking Probe',
      region: 'bd',
      locale: 'en',
      acceptTerms: true,
    );
    await _awaitSignup(api);
    await api.recordConsent('medical_disclaimer', locale: 'en');
    await _awaitConsent(api);
    final profileId = (await api.profiles()).first.id;

    await api.putHealthProfile(
      profileId,
      const HealthProfile(
        ageYears: 44,
        sexAtBirth: Sex.male,
        heightCm: 172,
        weightKg: 82,
        waistCm: 102,
        physicalActivity: Activity.sedentary,
      ),
    );

    // ── food is reference data that declares its own provenance ───────
    final foods = await api.searchFoods(q: 'rice');
    expect(foods, isNotEmpty);
    expect(foods.every((f) => f.isPlaceholder), isTrue,
        reason: 'seeded rows must not claim to be a licensed table');

    // ── a meal, priced from the local portion ─────────────────────────
    final rice = foods.firstWhere((f) => f.nameEn == 'Boiled rice');
    final meal = await api.logMeal(
      profileId,
      slot: 'lunch',
      items: [
        MealItemDraft(
          foodId: rice.id,
          name: rice.nameEn,
          unit: 'bowl',
          kcalPer100g: rice.kcalPer100g,
          portionGrams: rice.portionGrams,
        ),
      ],
    );
    expect(meal.kcal, closeTo(260, 3));
    // Rule 1's sibling: an estimate is a range, never a bare figure.
    expect(meal.kcalLow, lessThan(meal.kcal));
    expect(meal.kcalHigh, greaterThan(meal.kcal));

    // ── the day's plan, with a target through the §5.4 rails ──────────
    final plan = await api.planToday(profileId);
    expect(plan.meals, isNotEmpty);
    expect(plan.target, isNotNull);
    expect(plan.target!.kcal, greaterThanOrEqualTo(1500),
        reason: 'the male absolute floor');

    // ── activity is upserted, never appended ──────────────────────────
    await api.saveActivity(profileId, steps: 3000);
    await api.saveActivity(profileId, steps: 7400);
    final week = await api.activity(profileId);
    expect(week.where((d) => d.steps == 7400).length, 1);

    // ── a check-in, and a reading that can be read back ───────────────
    await api.submitCheckin(profileId, energy: 4, sleepHours: 7.5);
    expect((await api.checkinToday(profileId))?.energy, 4);

    await api.addVital(profileId,
        type: 'glucose', value: 5.6, unit: 'mmol/L', contextTag: 'fasting');
    await _eventually(
      () async => (await api.vitals(profileId, type: 'glucose')).isNotEmpty,
      describe: 'the reading never became visible after being recorded',
    );

    // ── the coach's guards ────────────────────────────────────────────
    final meds = await api.coachSend(profileId, 'should I stop my metformin?');
    expect(meds.intercepted, isTrue);
    expect(meds.modelBacked, isFalse,
        reason: 'there is no model behind this build, and it says so');

    final emergency = await api.coachSend(profileId, 'I have chest pain');
    expect(emergency.safetyCard, isNotNull);
    expect(emergency.safetyCard!.emergencyNumber, '999');

    // ── insights refuse to invent a pattern ───────────────────────────
    final insights = await api.weeklyInsights(profileId);
    expect(insights.minimumObservations, greaterThanOrEqualTo(5));
    for (final insight in insights.insights) {
      expect(insight.observations,
          greaterThanOrEqualTo(insights.minimumObservations));
    }

    // ── the report carries its basis and validation status ────────────
    await _assessWhenReady(api, profileId);
    final report = await api.generateReport(profileId, days: 28);
    final risk = report.payload['risk'] as Map<String, dynamic>;
    expect(risk['validation_status'], 'not_validated');
    expect(risk['range_low'], lessThan(risk['range_high']));
    expect('${report.payload['disclaimer']}'.toLowerCase(),
        contains('not a diagnosis'));

    // ── billing promises what the paywall shows ───────────────────────
    final plans = await api.billingPlans();
    expect(plans.plans, hasLength(2));
    expect(plans.freeForeverKeys, contains('safety_alerts'));
    expect(plans.freeForeverKeys, contains('risk_assessment'));
    expect(plans.isSubscribed, isFalse);

    // ── export is free and complete ───────────────────────────────────
    final export = await api.exportAccount();
    for (final section in ['account', 'profiles', 'consents', 'meals',
                           'checkins', 'activity', 'vitals']) {
      expect(export.containsKey(section), isTrue, reason: 'missing $section');
    }
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('the coach free cap is a paywall branch, not an error', () async {
    if (!await _backendUp()) {
      markTestSkipped('backend not running on 127.0.0.1:8000');
      return;
    }

    tokens = await api.signup(
      email: 'flutter.cap.${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'correct-horse-8',
      displayName: 'Cap Probe',
      region: 'bd',
      locale: 'en',
      acceptTerms: true,
    );
    await _awaitSignup(api);
    await api.recordConsent('medical_disclaimer', locale: 'en');
    await _awaitConsent(api);
    final profileId = (await api.profiles()).first.id;

    // Burn the free allowance. The cap counts committed rows, and those commit
    // after the response, so keep asking until it actually bites rather than
    // assuming the third call is the one that trips it.
    await _eventually(
      () async {
        try {
          await api.coachSend(profileId, 'how are my steps today?');
          return false;
        } on CoachLimitReached {
          return true;
        }
      },
      describe: 'the free coach allowance never ran out',
    );

    // A safety message must still get through — PRD §F16 forbids gating one
    // behind a payment, and a daily cap is a gate.
    final emergency = await api.coachSend(profileId, 'I have chest pain');
    expect(emergency.safetyCard, isNotNull);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('already-diagnosed is a branch to management', () async {
    if (!await _backendUp()) {
      markTestSkipped('backend not running on 127.0.0.1:8000');
      return;
    }

    tokens = await api.signup(
      email: 'flutter.dx.${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'correct-horse-8',
      displayName: 'Diagnosed Probe',
      region: 'bd',
      locale: 'en',
      acceptTerms: true,
    );
    await _awaitSignup(api);
    await api.recordConsent('medical_disclaimer', locale: 'en');
    await _awaitConsent(api);
    final profileId = (await api.profiles()).first.id;

    await api.putHealthProfile(
      profileId,
      const HealthProfile(
        ageYears: 51,
        sexAtBirth: Sex.male,
        heightCm: 172,
        weightKg: 84,
        waistCm: 101,
        diabetesStatus: DiabetesStatus.t2d,
      ),
    );

    // Poll past the same commit race, then assert the branch.
    await _eventually(
      () async {
        try {
          await api.assess(profileId);
          return false;
        } on AlreadyDiagnosed {
          return true;
        } on ServerFailure catch (e) {
          if (e.status == 400) return false; // health row not visible yet
          rethrow;
        }
      },
      describe: 'a screening estimate does not apply to an existing diagnosis',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));
}
