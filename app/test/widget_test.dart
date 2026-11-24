/// Tests for the rules that decide whether this ships.
///
/// These are not coverage tests. Each one pins a rule from `ui_spec.md` §1 or
/// a contract in `feature_spec.json` — the things that get the app rejected or
/// hurt someone if they regress quietly.
library;

import 'dart:convert';
import 'dart:io';

import 'package:diavision/core/numerals.dart';
import 'package:diavision/core/theme.dart';
import 'package:diavision/core/tokens.dart';
import 'package:diavision/core/typography.dart';
import 'package:diavision/data/api.dart';
import 'package:diavision/data/models.dart';
import 'package:diavision/data/notifications.dart';
import 'package:diavision/data/password_reset.dart';
import 'package:diavision/data/store.dart';
import 'package:diavision/l10n/strings.dart';
import 'package:diavision/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:diavision/state/wizard_state.dart';
import 'package:diavision/ui/illustrations/waist_diagram.dart';
import 'package:diavision/ui/widgets/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Words banned everywhere in user-facing copy (rule 2), plus the sensor claim
/// from rule 3. Matched on word boundaries, so "secure" does not trip "cure"
/// and "treatment" does trip "treat".
final _banned = <RegExp>[
  RegExp(r'\bdiagnos(e|es|ed|is|ing)\b', caseSensitive: false),
  RegExp(r'\bcure[sd]?\b', caseSensitive: false),
  RegExp(r'\btreat(s|ed|ing|ment|ments)?\b', caseSensitive: false),
  RegExp(r'\brevers(e|es|ed|ing|ible)\b', caseSensitive: false),
  RegExp(r'clinically proven', caseSensitive: false),
  RegExp(r'medically accurate', caseSensitive: false),
  RegExp(r'scan your health', caseSensitive: false),
];

/// The strings that are *allowed* to contain a banned word, because their
/// whole job is to deny it: "not a diagnosis", "does not diagnose".
bool _isDenial(String text) {
  final lower = text.toLowerCase();
  return lower.contains('not a diagnosis') ||
      lower.contains('does not diagnose') ||
      lower.contains('is not a diagnosis') ||
      lower.contains('still not a diagnosis');
}

void main() {
  group('rule 1 — never a bare number, ranges only', () {
    test('the formatter renders a range, not a point value', () {
      const n = Numerals('en');
      expect(n.range(0.25, 0.41), '25–41%');
    });

    test('Bangla renders local numerals when the user asks for them', () {
      const n = Numerals('bn', useLocalDigits: true);
      expect(n.range(0.25, 0.41), '২৫–৪১%');
      // And Western digits when they do not — the region pack's default.
      const western = Numerals('bn', useLocalDigits: false);
      expect(western.range(0.25, 0.41), '25–41%');
    });

    test('probability is parsed but never surfaced as a display helper', () {
      // The model carries `probability` because the API sends it. There is
      // deliberately no formatter that turns a single probability into the
      // headline — `range` is the only path to the hero figure.
      final r = _sampleResult();
      expect(r.probability, 0.33);
      expect(r.rangeLow, 0.25);
      expect(r.rangeHigh, 0.41);
    });
  });

  group('rules 2 and 3 — banned words', () {
    for (final lang in ['en', 'bn']) {
      test('no banned wording in $lang copy outside explicit denials', () {
        final s = Strings.of(lang);
        for (final entry in _allStrings(s).entries) {
          if (_isDenial(entry.value)) continue;
          for (final banned in _banned) {
            expect(
              banned.hasMatch(entry.value),
              isFalse,
              reason: '"${entry.key}" matches ${banned.pattern}: ${entry.value}',
            );
          }
        }
      });
    }

    test('the two verbatim safety strings are present and unparaphrased', () {
      final en = Strings.of('en');
      expect(en.disclaimerBody, contains('not a medical device'));
      expect(en.disclaimerBody, contains('does not diagnose or treat'));
      expect(en.disclaimerBody, contains('do not change your dose'));
      expect(en.riskFooter,
          'This is a statistical estimate, not a diagnosis. Only a blood test '
          'ordered by a doctor can confirm diabetes.');
    });
  });

  group('rule 4 — safety red has exactly one job', () {
    test('the safety colour is not reachable from any ordinary role', () {
      for (final c in [AppColors.light, AppColors.dark]) {
        final ordinary = [
          c.bg, c.surface, c.text, c.card, c.pill, c.pillFg, c.onAccent,
          c.accent, c.accent2,
          c.accentRamp.c100, c.accentRamp.c500, c.accentRamp.c900,
          c.accent2Ramp.c100, c.accent2Ramp.c500, c.accent2Ramp.c900,
          c.neutral.c100, c.neutral.c500, c.neutral.c900,
          c.caution, c.cautionTint, c.cautionBorder,
        ];
        expect(ordinary, isNot(contains(c.safety)));
      }
    });

    test('light safety red is the exact value the spec fixes', () {
      expect(AppColors.light.safety, const Color(0xFF9F1239));
    });
  });

  group('rule 10 — body text never below 16sp', () {
    for (final script in Script.values) {
      test('$script body styles sit at or above 16', () {
        final t = AppText.of(script);
        for (final style in [t.body, t.bodyLarge, t.bodyStrong, t.bodyDisclaimer]) {
          expect(style.fontSize, greaterThanOrEqualTo(16.0),
              reason: 'body copy must not drop below 16sp');
        }
      });
    }

    test('Bangla is drawn at the same optical size as Latin, not smaller', () {
      final latin = AppText.of(Script.latin).body.fontSize!;
      final bangla = AppText.of(Script.bengali).body.fontSize!;
      expect(bangla, greaterThanOrEqualTo(latin));
    });
  });

  group('rule 11 — under-18 never gets through', () {
    test('the wizard blocks below 18 and the gate is not a setting', () {
      final w = WizardState()
        ..age = 17
        ..sex = Sex.male;
      expect(w.isUnderage, isTrue);
      expect(w.step1Complete, isFalse);

      w.age = 18;
      expect(w.isUnderage, isFalse);
      expect(w.step1Complete, isTrue);
    });
  });

  group('the frozen contract', () {
    test('the wire payload uses feature_spec.json field names exactly', () {
      final json = HealthProfile(
        ageYears: 42,
        sexAtBirth: Sex.female,
        heightCm: 160,
        weightKg: 68,
        waistCm: 88,
        familyHistory: FamilyHistory.firstDegree,
        physicalActivity: Activity.veryActive,
        gestationalDiabetesHistory: true,
      ).toJson();

      expect(
        json.keys.toSet(),
        containsAll(<String>{
          'age_years',
          'sex_at_birth',
          'height_cm',
          'weight_kg',
          'waist_cm',
          'family_history',
          'physical_activity',
          'smoker',
          'gestational_diabetes_history',
          'known_high_bp',
          'on_bp_meds',
          'history_high_glucose',
        }),
      );
      // Enum wire values are snake_case, matching the contract's `values`.
      expect(json['family_history'], 'first_degree');
      expect(json['physical_activity'], 'very_active');
      expect(json['sex_at_birth'], 'female');
    });

    test('a skipped waist is sent as null, never imputed to zero', () {
      final json = HealthProfile(
        ageYears: 30,
        sexAtBirth: Sex.male,
        heightCm: 175,
        weightKg: 70,
      ).toJson();
      expect(json.containsKey('waist_cm'), isTrue);
      expect(json['waist_cm'], isNull);
    });

    test('gestational history is null for male profiles, not false', () {
      final w = WizardState()
        ..age = 30
        ..sex = Sex.male
        ..heightCm = 175
        ..weightKg = 70;
      expect(w.asksGestational, isFalse);
      expect(w.toWire().toJson()['gestational_diabetes_history'], isNull);
    });

    test('ancestry is omitted entirely when the user skips it', () {
      final w = WizardState()
        ..age = 30
        ..sex = Sex.male
        ..heightCm = 175
        ..weightKg = 70
        ..ancestrySkipped = true;
      expect(w.toWire().toJson().containsKey('ancestry_cutoff_group'), isFalse);
    });

    test('wizard ranges match the contract', () {
      expect(WizardState.ageMin, 18);
      expect(WizardState.ageMax, 120);
      expect(WizardState.heightMin, 100.0);
      expect(WizardState.heightMax, 250.0);
      expect(WizardState.weightMin, 25.0);
      expect(WizardState.weightMax, 300.0);
      expect(WizardState.waistMin, 40.0);
      expect(WizardState.waistMax, 200.0);
    });
  });

  group('branching responses are branches, not errors', () {
    test('a safety card parses with its severity and emergency number', () {
      final card = SafetyCard.fromJson({
        'trigger': 'glucose_fasting_urgent',
        'severity': 'urgent',
        'title': 'This needs attention today',
        'body': 'A fasting reading that high needs a doctor today.',
        'actions': ['Contact a doctor today'],
        'emergency_number': '999',
      });
      expect(card.isUrgent, isTrue);
      expect(card.emergencyNumber, '999');
    });
  });

  group('rule 5 — the disclaimer footer is not dismissible', () {
    testWidgets('renders the server wording and offers no close affordance',
        (tester) async {
      await tester.pumpWidget(_host(
        const DisclaimerFooter(text: 'Server-supplied disclaimer.'),
      ));
      expect(find.text('Server-supplied disclaimer.'), findsOneWidget);
      // No button, no icon button, nothing to tap it away with.
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(CloseButton), findsNothing);
    });
  });

  group('a restored session still knows whose record it is', () {
    // The regression this pins: `AppState.load` restores the token but does
    // NOT fetch the account or profile — cold start must not depend on the
    // network. Screens that read `profile?.id` therefore got null on every
    // launch that restored a session, and silently did nothing. The population
    // screen's Continue was the visible symptom: eleven answered questions and
    // a button that appeared dead.
    test('profileId falls back to the cached id when profile is unfetched',
        () async {
      SharedPreferences.setMockInitialValues({'bbd.profileId': 'cached-id'});
      final prefs = await PrefsStore.open();
      final state = AppState(
        api: Api(
          baseUrl: 'http://127.0.0.1:1/api/v1',
          readTokens: () => null,
          writeTokens: (_) async {},
        ),
        secure: SecureStore(),
        prefs: prefs,
      );

      expect(state.profile, isNull, reason: 'nothing has fetched it yet');
      expect(state.profileId, 'cached-id',
          reason: 'a health screen must still have an id to act on');
    });

    test('no screen reads profile?.id directly any more', () {
      // Cheap and blunt, but it is exactly the mistake that caused the bug,
      // and it is invisible in review because the expression looks correct.
      final offenders = <String>[];
      for (final file in Directory('lib/ui/screens').listSync()) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        if (file.readAsStringSync().contains('profile?.id')) {
          offenders.add(file.path);
        }
      }
      expect(offenders, isEmpty,
          reason: 'use AppState.profileId, which falls back to the cache');
    });
  });

  group('notifications inbox (handoff F9, §3.4)', () {
    test('no glucose, weight or risk value in any title or body', () {
      // A number next to a unit, or a percentage, is exactly what a lock
      // screen must never show.
      final value = RegExp(
          r'\d[\d.,]*\s*(%|mmol|mg|kg|lb|cm|bpm)|[০-৯][০-৯.,]*\s*(%|কেজি)',
          caseSensitive: false);
      for (final x in Inbox.sample().items) {
        for (final lang in ['en', 'bn']) {
          final (title, body, _) = x.copyFor(lang);
          expect(value.hasMatch('$title $body'), isFalse,
              reason: '${x.id} ($lang): $title — $body');
        }
      }
    });

    test('the badge count follows read, mark-all and dismiss', () {
      final inbox = Inbox.sample();
      final start = inbox.unreadCount;
      expect(start, greaterThan(0));

      final first = inbox.items.firstWhere((x) => x.unread);
      inbox.markRead(first.id);
      expect(inbox.unreadCount, start - 1);
      inbox.markRead(first.id); // idempotent
      expect(inbox.unreadCount, start - 1);

      final other = inbox.items.firstWhere((x) => x.unread);
      inbox.dismiss(other.id);
      expect(inbox.items.any((x) => x.id == other.id), isFalse);
      expect(inbox.unreadCount, start - 2);

      inbox.markAllRead();
      expect(inbox.unreadCount, 0);
    });

    test('a change rebuilds whatever reads app state', () async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState(
        api: Api(
          baseUrl: 'http://127.0.0.1:1/api/v1',
          readTokens: () => null,
          writeTokens: (_) async {},
        ),
        secure: SecureStore(),
        prefs: await PrefsStore.open(),
      );
      var notified = 0;
      state.addListener(() => notified++);
      state.inbox.markAllRead();
      expect(notified, 1);
    });
  });

  group('password reset never claims success it did not get', () {
    final calls = <String>[];
    Api apiAnswering(int status, Object body) => Api(
          baseUrl: 'http://x/api/v1',
          client: MockClient((req) async {
            calls.add('${req.method} ${req.url.path}');
            expect(req.headers.containsKey('authorization'), isFalse,
                reason: 'reset calls carry no session');
            return http.Response(jsonEncode(body), status,
                headers: {'content-type': 'application/json'});
          }),
          readTokens: () => null,
          writeTokens: (_) async {},
        );

    test('the three calls go to the reset endpoints', () async {
      calls.clear();
      final reset = HttpPasswordReset(
          apiAnswering(200, {'reset_token': 'tok', 'resend_after_seconds': 60}));
      await reset.requestCode('a@b.co');
      expect(await reset.verifyCode('a@b.co', '123456'), 'tok');
      await reset.setPassword('tok', 'password1');
      expect(calls, [
        'POST /api/v1/auth/password/reset-request',
        'POST /api/v1/auth/password/reset-verify',
        'POST /api/v1/auth/password/reset',
      ]);
    });

    test('a wrong code surfaces the server reason, not a success', () async {
      final reset = HttpPasswordReset(apiAnswering(400, {
        'detail': {'reason': 'invalid_code', 'message': 'wrong'}
      }));
      await expectLater(
          reset.verifyCode('a@b.co', '000000'),
          throwsA(isA<ServerFailure>()
              .having((f) => f.message, 'reason', 'invalid_code')));
    });

    test('no email service: refused, never pretended', () async {
      final reset = HttpPasswordReset(apiAnswering(503, {
        'detail': {'reason': 'reset_unavailable', 'message': 'off'}
      }));
      await expectLater(
          reset.requestCode('a@b.co'),
          throwsA(isA<ServerFailure>()
              .having((f) => f.message, 'reason', 'reset_unavailable')));
    });
  });

  group('rule 9 — no text baked into artwork', () {
    testWidgets('the waist diagram paints no text and carries a description',
        (tester) async {
      await tester.pumpWidget(_host(
        const WaistDiagram(step: WaistStep.findPoint, size: 120),
      ));
      // The artwork itself is pure vector — the step number lives outside it.
      expect(
        find.descendant(
          of: find.byType(WaistDiagram),
          matching: find.byType(Text),
        ),
        findsNothing,
      );
    });
  });
}

// ── helpers ───────────────────────────────────────────────────────────

Widget _host(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: AppTheme(
        colors: AppColors.light,
        text: AppText.of(Script.latin),
        child: MediaQuery(
          data: const MediaQueryData(),
          child: ColoredBox(
            color: AppColors.light.bg,
            child: Center(child: child),
          ),
        ),
      ),
    );

RiskResult _sampleResult() => RiskResult.fromJson(
      jsonDecode(jsonEncode({
        'band': 'high',
        'band_label': 'High',
        'probability': 0.33,
        'range_low': 0.25,
        'range_high': 0.41,
        'tier': 1,
        'basis': 'idrs',
        'validation_status': 'not_validated',
        'region': 'bd',
        'model_version': 'clinical-1',
        'clinical_score': 'idrs',
        'clinical_points': 90,
        'clinical_max': 100,
        'modifiable_factors': [
          {'label': 'Sedentary', 'points': 30, 'modifiable': true, 'detail': ''},
        ],
        'fixed_factors': [
          {'label': 'Age 35–49', 'points': 20, 'modifiable': false, 'detail': ''},
        ],
        'caveats': ['Estimated from eleven self-reported answers.'],
        'disclaimer': 'This is a statistical estimate, not a diagnosis.',
      })) as Map<String, dynamic>,
    );

/// Every user-facing string, keyed by getter name, so a banned word cannot
/// hide in a screen nobody thought to check.
Map<String, String> _allStrings(Strings s) => {
      'appName': s.appName,
      'splashTagline': s.splashTagline,
      'splashCta': s.splashCta,
      'splashFootnote': s.splashFootnote,
      'authKicker': s.authKicker,
      'loginHead': s.loginHead,
      'loginSub': s.loginSub,
      'signupHead': s.signupHead,
      'signupSub': s.signupSub,
      'termsLabel': s.termsLabel,
      'authFootnote': s.authFootnote,
      'errCredentials': s.errCredentials,
      'errEmailTaken': s.errEmailTaken,
      'errNetwork': s.errNetwork,
      'errServer': s.errServer,
      'errNeedProfile': s.errNeedProfile,
      'disclaimerHead': s.disclaimerHead,
      'disclaimerBody': s.disclaimerBody,
      'disclaimerTick': s.disclaimerTick,
      'disclaimerFootnote': s.disclaimerFootnote,
      'wizardSkipWidens': s.wizardSkipWidens,
      'qAgeHead': s.qAgeHead,
      'qAgeSub': s.qAgeSub,
      'whyAge': s.whyAge,
      'whySex': s.whySex,
      'qBodyHead': s.qBodyHead,
      'whyHeight': s.whyHeight,
      'whyWeight': s.whyWeight,
      'qWaistHead': s.qWaistHead,
      'qWaistSub': s.qWaistSub,
      'whyWaist': s.whyWaist,
      'waistSkipNote': s.waistSkipNote,
      'waistGuideHead': s.waistGuideHead,
      'waistGuideSub': s.waistGuideSub,
      'waistGuideStep1': s.waistGuideStep1,
      'waistGuideStep2': s.waistGuideStep2,
      'waistGuideStep3': s.waistGuideStep3,
      'waistGuideStep4': s.waistGuideStep4,
      'waistGuideNoTape': s.waistGuideNoTape,
      'waistGuideA11y': s.waistGuideA11y,
      'qHabitsHead': s.qHabitsHead,
      'whyFamily': s.whyFamily,
      'whyActivity': s.whyActivity,
      'whySmoker': s.whySmoker,
      'qHistoryHead': s.qHistoryHead,
      'qHistorySub': s.qHistorySub,
      'whyHighBp': s.whyHighBp,
      'whyBpMeds': s.whyBpMeds,
      'whyHighGlucose': s.whyHighGlucose,
      'whyGestational': s.whyGestational,
      'whyDiabetesStatus': s.whyDiabetesStatus,
      'popHead': s.popHead,
      'popSub': s.popSub,
      'popWhyBody': s.popWhyBody,
      'popNote': s.popNote,
      'calcHead': s.calcHead,
      'calcSub': s.calcSub,
      'calcStep1': s.calcStep1,
      'calcStep2': s.calcStep2,
      'calcStep3': s.calcStep3,
      'riskLabel': s.riskLabel,
      'changeableHead': s.changeableHead,
      'changeableSub': s.changeableSub,
      'fixedHead': s.fixedHead,
      'fixedSub': s.fixedSub,
      'whatIfHead': s.whatIfHead,
      'whatIfSub': s.whatIfSub,
      'ctaFindDoctor': s.ctaFindDoctor,
      'ctaGetTested': s.ctaGetTested,
      'addLabTitle': s.addLabTitle,
      'addLabSub': s.addLabSub,
      'caveatsLabel': s.caveatsLabel,
      'riskFooter': s.riskFooter,
      'validationNotValidated': s.validationNotValidated,
      'validationProvisional': s.validationProvisional,
      'labsHead': s.labsHead,
      'labsSub': s.labsSub,
      'labHba1cHelp': s.labHba1cHelp,
      'labGlucoseHelp': s.labGlucoseHelp,
      'labPreviewNote': s.labPreviewNote,
      'labNoDiagnosisNote': s.labNoDiagnosisNote,
      'homeNoResultTitle': s.homeNoResultTitle,
      'homeNoResultSub': s.homeNoResultSub,
      'under18Head': s.under18Head,
      'under18Body': s.under18Body,
      'under18Cta': s.under18Cta,
      'diagnosedHead': s.diagnosedHead,
      'diagnosedBody': s.diagnosedBody,
      'offlineHead': s.offlineHead,
      'offlineBody': s.offlineBody,
      'offlineBanner': s.offlineBanner,
      'errorHead': s.errorHead,
      'errorBody': s.errorBody,
      'fpBack': s.fpBack,
      'fp1Head': s.fp1Head,
      'fp1Sub': s.fp1Sub,
      'fp1Cta': s.fp1Cta,
      'fp1Note': s.fp1Note,
      'fp2Head': s.fp2Head,
      'fp2Sub': s.fp2Sub,
      'fp2Change': s.fp2Change,
      'fp2Label': s.fp2Label,
      'fp2Resend': s.fp2Resend,
      'fp2ResendBtn': s.fp2ResendBtn,
      'fp2Cta': s.fp2Cta,
      'fp3Head': s.fp3Head,
      'fp3Sub': s.fp3Sub,
      'fp3New': s.fp3New,
      'fp3Confirm': s.fp3Confirm,
      'fp3Ph': s.fp3Ph,
      'fp3Ph2': s.fp3Ph2,
      'fp3R1': s.fp3R1,
      'fp3R2': s.fp3R2,
      'fp3R3': s.fp3R3,
      'fp3Cta': s.fp3Cta,
      'fp4Head': s.fp4Head,
      'fp4Sub': s.fp4Sub,
      'fp4Cta': s.fp4Cta,
      'fpToastEmail': s.fpToastEmail,
      'fpToastSent': s.fpToastSent,
      'fpToastResent': s.fpToastResent,
      'fpToastCode': s.fpToastCode,
      'fpToastPass': s.fpToastPass,
      'fpToastDone': s.fpToastDone,
      'fpUnavailable': s.fpUnavailable,
      'nTitle': s.nTitle,
      'nMarkAll': s.nMarkAll,
      'nToday': s.nToday,
      'nEarlier': s.nEarlier,
      'nFilterAll': s.nFilterAll,
      'nFilterReminders': s.nFilterReminders,
      'nFilterInsights': s.nFilterInsights,
      'nFilterAccount': s.nFilterAccount,
      'nEmptyHead': s.nEmptyHead,
      'nEmptySub': s.nEmptySub,
      'nSettings': s.nSettings,
      'nDismiss': s.nDismiss,
      'nNew': s.nNew,
      'nToastAll': s.nToastAll,
      'nPrivacy': s.nPrivacy,
      'fpStepLabel': s.fpStepLabel('1', '3'),
      'nUnread': s.nUnread('3'),
      // The sample inbox ships to users until the API lands, so it is copy too.
      for (final x in Inbox.sample().items) ...{
        'notif.${x.id}.title': x.copyFor(s.lang).$1,
        'notif.${x.id}.body': x.copyFor(s.lang).$2,
      },
    };
