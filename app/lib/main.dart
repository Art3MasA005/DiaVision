/// DiaVision — onboarding to risk.
///
/// Scope is the design handoff's screens 01–09: splash, auth, the blocking
/// disclaimer, the eleven-question wizard, population guidelines, calculating,
/// the risk result with the what-if simulator, lab entry, and home. Handoff
/// screens 10–19 are PRD Phase 2–4 and are deliberately absent.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/theme.dart';
import 'data/api.dart';
import 'data/store.dart';
import 'state/app_state.dart';
import 'ui/screens/activity_screen.dart';
import 'ui/screens/auth_screen.dart';
import 'ui/screens/calculating_screen.dart';
import 'ui/screens/checkin_screen.dart';
import 'ui/screens/coach_screen.dart';
import 'ui/screens/disclaimer_screen.dart';
import 'ui/screens/edge_states.dart';
import 'ui/screens/home_screen.dart';
import 'ui/screens/insights_screen.dart';
import 'ui/screens/labs_screen.dart';
import 'ui/screens/paywall_screen.dart';
import 'ui/screens/population_screen.dart';
import 'ui/screens/risk_screen.dart';
import 'ui/screens/scan_screen.dart';
import 'ui/screens/settings_screen.dart';
import 'ui/screens/splash_screen.dart';
import 'ui/screens/tracker_screen.dart';
import 'ui/screens/vitals_screen.dart';
import 'ui/screens/wizard_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final secure = SecureStore();
  final prefs = await PrefsStore.open();
  late final Api api;
  api = Api(
    readTokens: () => secure.cached,
    writeTokens: secure.save,
  );

  final state = AppState(api: api, secure: secure, prefs: prefs);
  await state.load(
    WidgetsBinding.instance.platformDispatcher.locale.languageCode,
  );

  runApp(DiaVisionApp(state: state));
}

class DiaVisionApp extends StatelessWidget {
  const DiaVisionApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: ThemeHost(
        builder: (context, colors) {
          SystemChrome.setSystemUIOverlayStyle(
            colors.isDark
                ? SystemUiOverlayStyle.light.copyWith(
                    systemNavigationBarColor: colors.bg)
                : SystemUiOverlayStyle.dark.copyWith(
                    systemNavigationBarColor: colors.bg),
          );
          return MaterialApp(
            title: 'DiaVision',
            debugShowCheckedModeBanner: false,
            theme: materialTheme(colors),
            // Bangla and English are both first-class. Direction comes from
            // the language so the Wave 3 RTL locales need no layout changes.
            locale: Locale(state.lang),
            supportedLocales: const [Locale('en'), Locale('bn')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: clampScaler(context)),
              child: child ?? const SizedBox.shrink(),
            ),
            initialRoute: Routes.splash,
            routes: Routes.table,
          );
        },
      ),
    );
  }
}

abstract final class Routes {
  static const splash = '/';
  static const auth = '/auth';
  static const disclaimer = '/disclaimer';
  static const wizard = '/wizard';
  static const population = '/population';
  static const calculating = '/calculating';
  static const risk = '/risk';
  static const labs = '/labs';
  static const home = '/home';
  static const under18 = '/blocked/under-18';
  static const diagnosed = '/blocked/diagnosed';

  // Phase 2 screens — the other half of the 19-screen design.
  static const tracker = '/tracker';
  static const scan = '/scan';
  static const checkin = '/checkin';
  static const activity = '/activity';
  static const vitals = '/vitals';
  static const coach = '/coach';
  static const insights = '/insights';
  static const paywall = '/paywall';
  static const settings = '/settings';

  static final table = <String, WidgetBuilder>{
    splash: (_) => const SplashScreen(),
    auth: (_) => const AuthScreen(),
    disclaimer: (_) => const DisclaimerScreen(),
    wizard: (_) => const WizardScreen(),
    population: (_) => const PopulationScreen(),
    calculating: (_) => const CalculatingScreen(),
    risk: (_) => const RiskScreen(),
    labs: (_) => const LabsScreen(),
    home: (_) => const HomeScreen(),
    under18: (_) => const Under18Screen(),
    diagnosed: (_) => const AlreadyDiagnosedScreen(),
    tracker: (_) => const TrackerScreen(),
    scan: (_) => const ScanScreen(),
    checkin: (_) => const CheckinScreen(),
    activity: (_) => const ActivityScreen(),
    vitals: (_) => const VitalsScreen(),
    coach: (_) => const CoachScreen(),
    insights: (_) => const InsightsScreen(),
    paywall: (_) => const PaywallScreen(),
    settings: (_) => const SettingsScreen(),
  };
}
