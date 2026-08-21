/// 01 · Splash.
///
/// Covers the ~1.2s while the region pack and the session load. Brand only.
///
/// Rules this screen exists under: no health claim, no number, no risk figure
/// — consent does not exist yet. Cold start must not depend on the network,
/// and it times out to auth after 3s rather than hanging.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/language_sheet.dart';
import '../widgets/line_icon.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: AppMotion.blobDrift,
  )..repeat(reverse: true);

  late final AnimationController _load = AnimationController(
    vsync: this,
    duration: AppMotion.loadSlide,
  )..repeat();

  late final AnimationController _mark = AnimationController(
    vsync: this,
    duration: AppMotion.markIn,
  )..forward();

  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _resolveDestination();
  }

  /// Where to go next, decided without blocking on the network.
  ///
  ///   no session          → auth
  ///   session, no consent → the disclaimer, which is the gate
  ///   session, consented  → home
  ///
  /// A failed consent check falls through to home rather than stranding the
  /// user on the splash; the server refuses health calls anyway, and the app
  /// routes to the disclaimer when it does.
  Future<void> _resolveDestination() async {
    final app = AppScope.read(context);
    final started = DateTime.now();

    String destination = Routes.auth;
    if (app.signedIn) {
      destination = Routes.home;
      // Re-fetch the account and profile. A restored token alone is not a
      // usable session: without a profile id, every health screen has nothing
      // to act on and the wizard cannot submit.
      await app.restoreSession();
      try {
        final status = await app.api.consentStatus();
        if (!status.mayAnswerHealthQuestions) destination = Routes.disclaimer;
        app.markOffline(false);
      } catch (_) {
        app.markOffline(!app.api.lastCallReachedServer);
      }
    }

    // Hold the brand for at least a beat, and never longer than three seconds.
    final elapsed = DateTime.now().difference(started);
    final remaining = const Duration(milliseconds: 1200) - elapsed;
    if (remaining > Duration.zero) await Future<void>.delayed(remaining);

    if (!mounted) return;
    setState(() => _ready = true);
    Navigator.of(context).pushReplacementNamed(destination);
  }

  @override
  void dispose() {
    _drift.dispose();
    _load.dispose();
    _mark.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final app = AppScope.of(context);

    // Full-bleed over the whole screen including the status bar.
    return Scaffold(
      backgroundColor: c.accentRamp.c800,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _blobs(c),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 34),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                spacing: 24,
                children: [
                  const Spacer(),
                  _mark_(c),
                  Text(
                    context.s.appName,
                    textAlign: TextAlign.center,
                    style: context.t.wordmark
                        .copyWith(color: const Color(0xFFFFFDF9)),
                  ),
                  RiseIn(
                    delay: const Duration(milliseconds: 220),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 290),
                      child: Text(
                        context.s.splashTagline,
                        textAlign: TextAlign.center,
                        style: context.t.body
                            .copyWith(color: c.accentRamp.c200, height: 1.55),
                      ),
                    ),
                  ),
                  _loader(c),
                  const Spacer(),
                  // The button exists so a slow cold start is never a dead
                  // end, but it is only offered once there is somewhere to go.
                  AnimatedOpacity(
                    opacity: _ready ? 1 : 0.45,
                    duration: AppMotion.riseIn,
                    child: PillButton(
                      label: context.s.splashCta,
                      tone: PillTone.card,
                      onPressed: _ready
                          ? () => Navigator.of(context)
                              .pushReplacementNamed(Routes.auth)
                          : null,
                    ),
                  ),
                  Text(
                    context.s.splashFootnote,
                    textAlign: TextAlign.center,
                    style: context.t.footnote
                        .copyWith(color: c.accentRamp.c300, fontSize: 11.5),
                  ),
                  // Language is reachable before anything else, because a
                  // Bangla-first user should never have to read English to
                  // find Bangla.
                  GhostButton(
                    label: supportedLanguageName(app.lang),
                    icon: Icons24.globe,
                    color: c.accentRamp.c200,
                    onPressed: () => showLanguageSheet(context),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Three soft decorative circles, `blobDrift` 9–11s.
  Widget _blobs(dynamic c) => AnimatedBuilder(
        animation: _drift,
        builder: (context, _) {
          final t = Curves.easeInOut.transform(_drift.value);
          return Stack(
            children: [
              PositionedDirectional(
                start: -70 + t * 10,
                top: -40 + t * 14,
                child: _blob(250, c.accentRamp.c700, 0.55),
              ),
              PositionedDirectional(
                end: -90 - t * 12,
                bottom: 120 - t * 16,
                child: _blob(290, c.accentRamp.c900, 0.45),
              ),
              PositionedDirectional(
                end: 44,
                top: 118 + t * 8,
                child: _blob(56, c.accent2Ramp.c500, 0.5),
              ),
            ],
          );
        },
      );

  Widget _blob(double size, Color color, double opacity) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color.withValues(alpha: opacity),
          shape: BoxShape.circle,
        ),
      );

  /// The logo mark — `markIn`, opacity 0→1 and scale .84→1 over 700ms.
  Widget _mark_(dynamic c) => AnimatedBuilder(
        animation: _mark,
        builder: (context, child) {
          final v = AppMotion.markCurve.transform(_mark.value);
          return Opacity(
            opacity: v,
            child: Transform.scale(scale: 0.84 + 0.16 * v, child: child),
          );
        },
        child: Container(
          width: 104,
          height: 104,
          decoration: BoxDecoration(
            color: const Color(0xFFFFFDF9),
            shape: BoxShape.circle,
            boxShadow: AppShadow.lg(false),
          ),
          child: Center(
            child: LineIcon(Icons24.activity,
                size: 50, color: c.accentRamp.c700, strokeWidth: 2.4),
          ),
        ),
      );

  /// `loadSlide` — a 32%-wide bar sweeping a 132×5 track.
  Widget _loader(dynamic c) => SizedBox(
        width: 132,
        height: 5,
        child: ClipRRect(
          borderRadius: AppRadius.rPill,
          child: Stack(
            children: [
              Container(color: c.accentRamp.c700),
              AnimatedBuilder(
                animation: _load,
                builder: (context, _) {
                  final v = Curves.easeInOut.transform(_load.value);
                  return Align(
                    alignment: Alignment(-1 + 2 * v * 1.32 - 0.16 * 2, 0),
                    child: FractionallySizedBox(
                      widthFactor: 0.32,
                      child: Container(color: c.accent2Ramp.c300),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      );
}
