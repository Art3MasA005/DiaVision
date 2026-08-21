/// Renders every screen in scope to a golden, at the prototype's 392×846
/// phone size, so the build can be reviewed as pictures rather than as code.
///
///   flutter test --update-goldens test/screens_golden_test.dart
///
/// A canned HTTP client stands in for the backend, so this runs offline and
/// deterministically. The payloads are copied verbatim from a real
/// `/risk/assess` response — see the probe in the build notes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:diavision/core/theme.dart';
import 'package:diavision/data/api.dart';
import 'package:diavision/data/models.dart';
import 'package:diavision/data/store.dart';
import 'package:diavision/state/app_state.dart';
import 'package:diavision/ui/screens/activity_screen.dart';
import 'package:diavision/ui/screens/auth_screen.dart';
import 'package:diavision/ui/screens/checkin_screen.dart';
import 'package:diavision/ui/screens/coach_screen.dart';
import 'package:diavision/ui/screens/disclaimer_screen.dart';
import 'package:diavision/ui/screens/edge_states.dart';
import 'package:diavision/ui/screens/home_screen.dart';
import 'package:diavision/ui/screens/insights_screen.dart';
import 'package:diavision/ui/screens/labs_screen.dart';
import 'package:diavision/ui/screens/paywall_screen.dart';
import 'package:diavision/ui/screens/population_screen.dart';
import 'package:diavision/ui/screens/risk_screen.dart';
import 'package:diavision/ui/screens/scan_screen.dart';
import 'package:diavision/ui/screens/settings_screen.dart';
import 'package:diavision/ui/screens/tracker_screen.dart';
import 'package:diavision/ui/screens/vitals_screen.dart';
import 'package:diavision/ui/screens/waist_guide_screen.dart';
import 'package:diavision/ui/screens/wizard_screen.dart';
import 'package:diavision/state/wizard_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Verbatim from a live `POST /api/v1/risk/assess`, Tier 1.
const _riskTier1 = {
  'id': 'dd953e46-2742-41df-9edf-6d0c4ee1ab8d',
  'band': 'high',
  'band_label': 'High',
  'probability': 0.3312,
  'range_low': 0.2512,
  'range_high': 0.4112,
  'tier': 1,
  'basis': 'your answers, scored using the published IDRS instrument',
  'validation_status': 'not_validated',
  'region': 'bd',
  'model_version': 'clinical_only:idrs',
  'clinical_score': 'IDRS',
  'clinical_points': 90,
  'clinical_max': 100,
  'modifiable_factors': [
    {'label': 'Sedentary', 'points': 30, 'modifiable': true, 'detail': ''},
    {
      'label': 'Waist 92 cm',
      'points': 20,
      'modifiable': true,
      'detail': 'Well above the South Asian threshold',
    },
  ],
  'fixed_factors': [
    {'label': 'Age 35–49', 'points': 20, 'modifiable': false, 'detail': ''},
    {
      'label': 'Parent or sibling with diabetes',
      'points': 20,
      'modifiable': false,
      'detail': '',
    },
  ],
  'caveats': [
    'Our model is not yet validated for Bangladesh, so this estimate uses the '
        'published IDRS score alone.',
    'Detects PREVALENT undiagnosed diabetes, not future incidence.',
  ],
  'disclaimer': 'This is a statistical estimate, not a diagnosis. Only a blood '
      'test ordered by a doctor can confirm diabetes.',
  'taken_at': '2026-08-15T09:09:04.303695+06:00',
  'lab_findings': <Map<String, dynamic>>[],
  'lab_statement': null,
};

/// The same profile after an HbA1c of 6.1 — measurement-led, Tier 2.
final _riskTier2 = {
  ..._riskTier1,
  'tier': 2,
  'range_low': 0.42,
  'range_high': 0.48,
  'lab_findings': [
    {
      'test': 'HbA1c',
      'value': 6.1,
      'display': '6.1%',
      'band': 'prediabetes',
      'statement': 'Your HbA1c is in the prediabetes range.',
    },
  ],
  'lab_statement': 'Your HbA1c is in the prediabetes range. This is a warning '
      'sign, not a diagnosis, and it is often reversible with diet and '
      'activity changes. Worth discussing with a doctor.',
};

/// A logged day — two meals against a computed target.
const _planToday = {
  'day': '2026-08-15',
  'target': {
    'kcal': 2100,
    'carbs_g': 236,
    'protein_g': 105,
    'fat_g': 82,
    'fibre_g': 29,
    'glycemic_load_ceiling': 100,
    'maintenance_kcal': 2500,
    'was_clamped': false,
    'clamp_reason': null,
    'weight_loss_disabled': false,
    'notes': <String>[],
  },
  'totals': {
    'kcal': 1340,
    'carbs_g': 168.0,
    'protein_g': 54.0,
    'fat_g': 41.0,
    'fibre_g': 18.0,
    'glycemic_load': 88.0,
    'kcal_low': 1152,
    'kcal_high': 1528,
  },
  'meals': [
    {
      'id': 'm1',
      'slot': 'breakfast',
      'eaten_at': '2026-08-15T08:10:00+06:00',
      'eaten_on': '2026-08-15',
      'entry_method': 'manual',
      'note': null,
      'items': [
        {
          'id': 'i1',
          'name_snapshot': 'Roti (wheat)',
          'quantity': 2.0,
          'unit': 'piece',
          'grams': 80.0,
          'kcal': 238.0,
          'carbs_g': 40.8,
          'protein_g': 8.8,
          'fat_g': 3.2,
          'fibre_g': 6.4,
          'glycemic_load': 21.3,
          'recognition_confidence': null,
        }
      ],
      'kcal': 238.0,
      'carbs_g': 40.8,
      'protein_g': 8.8,
      'fat_g': 3.2,
      'fibre_g': 6.4,
      'glycemic_load': 21.3,
      'kcal_low': 205,
      'kcal_high': 271,
    },
    {
      'id': 'm2',
      'slot': 'lunch',
      'eaten_at': '2026-08-15T13:30:00+06:00',
      'eaten_on': '2026-08-15',
      'entry_method': 'manual',
      'note': null,
      'items': [
        {
          'id': 'i2',
          'name_snapshot': 'Boiled rice',
          'quantity': 1.0,
          'unit': 'bowl',
          'grams': 200.0,
          'kcal': 260.0,
          'carbs_g': 56.0,
          'protein_g': 5.4,
          'fat_g': 0.6,
          'fibre_g': 0.8,
          'glycemic_load': 40.3,
          'recognition_confidence': null,
        },
        {
          'id': 'i3',
          'name_snapshot': 'Fish curry',
          'quantity': 1.0,
          'unit': 'bowl',
          'grams': 180.0,
          'kcal': 261.0,
          'carbs_g': 7.2,
          'protein_g': 30.6,
          'fat_g': 12.6,
          'fibre_g': 1.1,
          'glycemic_load': null,
          'recognition_confidence': null,
        },
      ],
      'kcal': 521.0,
      'carbs_g': 63.2,
      'protein_g': 36.0,
      'fat_g': 13.2,
      'fibre_g': 1.9,
      'glycemic_load': 40.3,
      'kcal_low': 448,
      'kcal_high': 594,
    },
  ],
  'safety_card': null,
};

const _billingPlans = {
  'plans': [
    {
      'code': 'monthly',
      'name': 'Monthly',
      'price_minor': 29900,
      'currency': 'BDT',
      'period': 'month',
      'trial_days': 14,
      'rails': ['bkash', 'nagad', 'card'],
    },
    {
      'code': 'annual',
      'name': 'Annual',
      'price_minor': 249900,
      'currency': 'BDT',
      'period': 'year',
      'trial_days': 14,
      'rails': ['bkash', 'nagad', 'card'],
    },
  ],
  'free_forever': [
    'Risk assessment',
    'Meal logging',
    'Safety alerts',
    'Export of your own data',
  ],
  'free_forever_keys': [
    'risk_assessment',
    'meal_logging',
    'safety_alerts',
    'data_export',
  ],
  'current_status': 'free',
};

const _weeklyInsights = {
  'period_start': '2026-08-09',
  'period_end': '2026-08-15',
  'insights': [
    {
      'key': 'intake',
      'headline': 'A steadier week than the last one',
      'detail': 'Averaging about 1780 kcal across 6 logged days.',
      'observations': 6,
      'direction': 'flat',
    },
    {
      'key': 'activity',
      'headline': 'You moved more this week',
      'detail': 'About 7400 steps a day across 6 days. Activity is one of only '
          'four things the clinical score reads.',
      'observations': 6,
      'direction': 'up',
    },
  ],
  'insufficient_data': false,
  'minimum_observations': 5,
};

/// Two assessments, three weeks apart, so Home can draw a trajectory.
const _riskHistory = [
  {
    'id': 'r2',
    'taken_at': '2026-08-15T09:09:04+06:00',
    'risk_probability': 0.3312,
    'risk_band': 'high',
    'confidence_low': 0.2512,
    'confidence_high': 0.4112,
    'model_version': 'clinical_only:idrs',
    'validation_status': 'not_validated',
  },
  {
    'id': 'r1',
    'taken_at': '2026-07-24T09:00:00+06:00',
    'risk_probability': 0.3812,
    'risk_band': 'high',
    'confidence_low': 0.3012,
    'confidence_high': 0.4612,
    'model_version': 'clinical_only:idrs',
    'validation_status': 'not_validated',
  },
];

const _activityWeek = [
  {'id': 'a1', 'activity_on': '2026-08-15', 'steps': 7400,
   'active_minutes': 38, 'distance_km': 5.1, 'source': 'manual',
   'updated_at': '2026-08-15T20:00:00+06:00'},
  {'id': 'a2', 'activity_on': '2026-08-14', 'steps': 9100,
   'active_minutes': 45, 'distance_km': 6.3, 'source': 'manual',
   'updated_at': '2026-08-14T20:00:00+06:00'},
  {'id': 'a3', 'activity_on': '2026-08-13', 'steps': 5200,
   'active_minutes': 22, 'distance_km': 3.6, 'source': 'manual',
   'updated_at': '2026-08-13T20:00:00+06:00'},
];

const _foods = [
  {'id': 'f1', 'name_en': 'Boiled rice', 'name_local': 'ভাত',
   'kcal_per_100g': 130.0, 'carbs_g_per_100g': 28.0, 'protein_g_per_100g': 2.7,
   'fat_g_per_100g': 0.3, 'fibre_g_per_100g': 0.4, 'glycemic_index': 73.0,
   'portion_grams': {'cup': 158.0, 'bowl': 200.0, 'ladle': 90.0},
   'source': 'placeholder'},
  {'id': 'f2', 'name_en': 'Lentil dal', 'name_local': 'ডাল',
   'kcal_per_100g': 116.0, 'carbs_g_per_100g': 20.0, 'protein_g_per_100g': 9.0,
   'fat_g_per_100g': 0.4, 'fibre_g_per_100g': 8.0, 'glycemic_index': 29.0,
   'portion_grams': {'bowl': 180.0, 'ladle': 80.0, 'cup': 150.0},
   'source': 'placeholder'},
  {'id': 'f3', 'name_en': 'Roti (wheat)', 'name_local': 'রুটি',
   'kcal_per_100g': 297.0, 'carbs_g_per_100g': 51.0, 'protein_g_per_100g': 11.0,
   'fat_g_per_100g': 4.0, 'fibre_g_per_100g': 8.0, 'glycemic_index': 62.0,
   'portion_grams': {'piece': 40.0}, 'source': 'placeholder'},
];

const _vitals = [
  {'id': 'v1', 'type': 'glucose', 'value': 5.8, 'unit': 'mmol/L',
   'context_tag': 'fasting', 'recorded_at': '2026-08-15T07:10:00+06:00'},
  {'id': 'v2', 'type': 'glucose', 'value': 6.2, 'unit': 'mmol/L',
   'context_tag': 'fasting', 'recorded_at': '2026-08-14T07:05:00+06:00'},
  {'id': 'v3', 'type': 'glucose', 'value': 5.4, 'unit': 'mmol/L',
   'context_tag': 'fasting', 'recorded_at': '2026-08-13T07:20:00+06:00'},
];

const _profiles = [
  {'id': '38d83ef7-4dfe-41cc-9fd0-9c27aacc2e9f', 'display_name': 'Rumana',
   'region_pack': 'bd', 'relationship': 'self', 'is_self': true,
   'created_at': '2026-07-01T09:00:00+06:00'},
];

List<Object?> _listFor(String path) {
  if (path.endsWith('/risk/history')) return _riskHistory;
  if (path.endsWith('/activity')) return _activityWeek;
  if (path.endsWith('/foods')) return _foods;
  if (path.endsWith('/vitals')) return _vitals;
  if (path.endsWith('/profiles')) return _profiles;
  if (path.endsWith('/meals')) return _planToday['meals'] as List;
  return const [];
}

http.Client _cannedClient() => MockClient((request) async {
      final path = request.url.path;
      Map<String, dynamic> body;
      if (path.endsWith('/risk/assess')) {
        body = Map<String, dynamic>.from(_riskTier1);
      } else if (path.endsWith('/consents/current')) {
        body = {
          'accepted': {'terms': '1.0'},
          'outstanding': <String>[],
          'current_versions': {'terms': '1.0', 'medical_disclaimer': '1.0'},
          'may_answer_health_questions': true,
        };
      } else if (path.contains('/regions/')) {
        body = {
          'code': 'bd',
          'country': 'Bangladesh',
          'languages': ['bn', 'en'],
          'default_language': 'bn',
          'units_default': {'glucose': 'mmol/L'},
          'safety_thresholds': {'emergency_number': '999', 'min_age': 18},
        };
      } else if (path.endsWith('/plan/today')) {
        body = _planToday;
      } else if (path.endsWith('/billing/plans')) {
        body = _billingPlans;
      } else if (path.endsWith('/insights/weekly')) {
        body = _weeklyInsights;
      } else if (path.endsWith('/checkins/today')) {
        // No check-in yet today — Home shows the prompt.
        return http.Response.bytes(utf8.encode('null'), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      } else if (path.endsWith('/risk/history') ||
          path.endsWith('/coach/history') ||
          path.endsWith('/activity') ||
          path.endsWith('/profiles') ||
          path.endsWith('/vitals') ||
          path.endsWith('/foods') ||
          path.endsWith('/meals')) {
        return http.Response.bytes(utf8.encode(jsonEncode(_listFor(path))), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      } else {
        body = {};
      }
      return http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

/// `flutter test` ships a placeholder font, so without this every golden is a
/// wall of black boxes and tells you nothing about the typography — which is
/// half of what these images exist to check. Loads the real bundled faces
/// straight off disk.
Future<void> _loadFonts() async {
  for (final entry in {
    'Figtree': 'assets/fonts/Figtree-Variable.ttf',
    'Caprasimo': 'assets/fonts/Caprasimo-Regular.ttf',
    'NotoSansBengali': 'assets/fonts/NotoSansBengali-Variable.ttf',
  }.entries) {
    final bytes = File(entry.value).readAsBytesSync();
    await (FontLoader(entry.key)
          ..addFont(Future.value(ByteData.sublistView(bytes))))
        .load();
  }
}

/// `flutter_secure_storage` talks over a platform channel with no
/// implementation in the test host, so its futures never complete and every
/// screen that touches the session hangs. Answering the channel with an empty
/// store is the whole fix.
void _mockSecureStorage() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => switch (call.method) {
      'readAll' => <String, String>{},
      'read' => null,
      'containsKey' => false,
      _ => null,
    },
  );
}

Future<AppState> _state(String lang) async {
  _mockSecureStorage();
  SharedPreferences.setMockInitialValues({'bbd.lang': lang});
  final prefs = await PrefsStore.open();
  final secure = SecureStore();
  final api = Api(
    baseUrl: 'http://127.0.0.1:8000/api/v1',
    client: _cannedClient(),
    readTokens: () => secure.cached,
    writeTokens: secure.save,
  );
  final state = AppState(api: api, secure: secure, prefs: prefs);
  await state.load(lang);
  state.profile = const Profile(
    id: '38d83ef7-4dfe-41cc-9fd0-9c27aacc2e9f',
    displayName: 'Rumana',
    regionPack: 'bd',
  );
  return state;
}

void main() {
  /// One screen, at phone size, in the given language and theme.
  Future<void> shoot(
    WidgetTester tester, {
    required String name,
    required Widget screen,
    String lang = 'en',
    bool dark = false,
    Duration settle = const Duration(milliseconds: 400),
    Future<void> Function(WidgetTester)? before,
  }) async {
    tester.view.physicalSize = const Size(392 * 2, 846 * 2);
    tester.view.devicePixelRatio = 2.0;
    tester.platformDispatcher.platformBrightnessTestValue =
        dark ? Brightness.dark : Brightness.light;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await _loadFonts();
    final state = await _state(lang);
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: ThemeHost(
          builder: (context, colors) => MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: materialTheme(colors),
            locale: Locale(lang),
            supportedLocales: const [Locale('en'), Locale('bn')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: screen,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(settle);
    if (before != null) await before(tester);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/screens/$name.png'),
    );
  }

  testWidgets('02 auth — login, English', (t) async {
    await shoot(t, name: '02_auth_login_en', screen: const AuthScreen());
  });

  testWidgets('02 auth — signup, Bangla', (t) async {
    await shoot(t,
        name: '02_auth_signup_bn',
        screen: const AuthScreen(),
        lang: 'bn',
        // The screen opens on Log in; switch to Sign up so the golden shows
        // the name field and the Terms tick, which is the half that matters.
        before: (tester) async {
          await tester.tap(find.text('নিবন্ধন'));
          await tester.pumpAndSettle();
        });
  });

  testWidgets('03 disclaimer — blocking, English', (t) async {
    await shoot(t, name: '03_disclaimer_en', screen: const DisclaimerScreen());
  });

  testWidgets('03 disclaimer — blocking, Bangla dark', (t) async {
    await shoot(t,
        name: '03_disclaimer_bn_dark',
        screen: const DisclaimerScreen(),
        lang: 'bn',
        dark: true);
  });

  testWidgets('04 wizard — step 1, English', (t) async {
    await shoot(t, name: '04_wizard_step1_en', screen: const WizardScreen());
  });

  testWidgets('04 wizard — step 1, Bangla', (t) async {
    await shoot(t,
        name: '04_wizard_step1_bn', screen: const WizardScreen(), lang: 'bn');
  });

  testWidgets('waist guide — the new illustration, English', (t) async {
    await shoot(t,
        name: '04b_waist_guide_en',
        screen: const Scaffold(body: WaistGuideSheet()));
  });

  testWidgets('waist guide — the new illustration, Bangla dark', (t) async {
    await shoot(t,
        name: '04b_waist_guide_bn_dark',
        screen: const Scaffold(body: WaistGuideSheet()),
        lang: 'bn',
        dark: true);
  });

  testWidgets('05 population guidelines, English', (t) async {
    await shoot(t,
        name: '05_population_en',
        screen: WizardScope(
          state: WizardState(),
          child: const PopulationScreenBody(),
        ));
  });

  testWidgets('07 risk result — Tier 1, English', (t) async {
    await shoot(t,
        name: '07_risk_tier1_en',
        screen: RiskScreen(
          result: RiskResult.fromJson(Map<String, dynamic>.from(_riskTier1)),
          profileId: 'p1',
        ));
  });

  testWidgets('07 risk result — Tier 1, Bangla dark', (t) async {
    await shoot(t,
        name: '07_risk_tier1_bn_dark',
        screen: RiskScreen(
          result: RiskResult.fromJson(Map<String, dynamic>.from(_riskTier1)),
          profileId: 'p1',
        ),
        lang: 'bn',
        dark: true);
  });

  testWidgets('07 risk result — Tier 2, measurement-led', (t) async {
    await shoot(t,
        name: '07_risk_tier2_en',
        screen: RiskScreen(
          result: RiskResult.fromJson(Map<String, dynamic>.from(_riskTier2)),
          profileId: 'p1',
        ));
  });

  testWidgets('08 labs, English', (t) async {
    await shoot(t,
        name: '08_labs_en',
        screen: LabsScreen(
          profileId: 'p1',
          current: RiskResult.fromJson(Map<String, dynamic>.from(_riskTier1)),
        ));
  });

  testWidgets('09 home, English', (t) async {
    await shoot(t, name: '09_home_en', screen: const HomeScreen());
  });

  // The home redesign inverts three ramps and swaps the weekday labels, so
  // the dark Bangla shot is the one that catches a role used the wrong way up.
  testWidgets('09 home, Bangla dark', (t) async {
    await shoot(t,
        name: '09_home_bn_dark',
        screen: const HomeScreen(),
        lang: 'bn',
        dark: true);
  });

  testWidgets('edge — safety card, urgent', (t) async {
    await shoot(t,
        name: '19_safety_urgent_en',
        screen: const SafetyCardScreen(
          card: SafetyCard(
            trigger: 'hyperglycaemia',
            severity: 'urgent',
            title: 'These numbers are high',
            body: 'This reading is high enough that a doctor should see it '
                'today. Do not change any medication on your own.',
            actions: ['Find a doctor'],
            emergencyNumber: '999',
          ),
          emergencyNumber: '999',
          country: 'Bangladesh',
        ));
  });

  testWidgets('edge — under 18', (t) async {
    await shoot(t, name: '19_under18_en', screen: const Under18Screen());
  });

  // ── the Phase 2 half of the design ──────────────────────────────────

  testWidgets('10 tracker, English', (t) async {
    await shoot(t, name: '10_tracker_en', screen: const TrackerScreen());
  });

  testWidgets('10 tracker, Bangla dark', (t) async {
    await shoot(t,
        name: '10_tracker_bn_dark',
        screen: const TrackerScreen(),
        lang: 'bn',
        dark: true);
  });

  testWidgets('11 scan / add a meal, English', (t) async {
    await shoot(t, name: '11_scan_en', screen: const ScanScreen());
  });

  testWidgets('12 daily check-in, English', (t) async {
    await shoot(t, name: '12_checkin_en', screen: const CheckinScreen());
  });

  testWidgets('12 daily check-in, Bangla', (t) async {
    await shoot(t,
        name: '12_checkin_bn', screen: const CheckinScreen(), lang: 'bn');
  });

  testWidgets('13 activity, English', (t) async {
    await shoot(t, name: '13_activity_en', screen: const ActivityScreen());
  });

  testWidgets('14 glucose & vitals, English', (t) async {
    await shoot(t, name: '14_vitals_en', screen: const VitalsScreen());
  });

  testWidgets('15 coach, English', (t) async {
    await shoot(t, name: '15_coach_en', screen: const CoachScreen());
  });

  testWidgets('16 insights, English', (t) async {
    await shoot(t, name: '16_insights_en', screen: const InsightsScreen());
  });

  testWidgets('17 paywall, English', (t) async {
    await shoot(t, name: '17_paywall_en', screen: const PaywallScreen());
  });

  testWidgets('17 paywall, Bangla dark', (t) async {
    await shoot(t,
        name: '17_paywall_bn_dark',
        screen: const PaywallScreen(),
        lang: 'bn',
        dark: true);
  });

  testWidgets('18 settings, English', (t) async {
    await shoot(t, name: '18_settings_en', screen: const SettingsScreen());
  });
}
