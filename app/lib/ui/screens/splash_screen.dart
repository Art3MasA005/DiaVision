/// 01 · Splash.
///
/// Covers the load while the region pack and the session come up. Brand only.
///
/// Rules this screen exists under: no health claim, no number, no risk figure
/// — consent does not exist yet. Cold start must not depend on the network,
/// and it moves on to the next screen within 3s rather than hanging.
///
/// The intro is transcribed from the handoff's CSS (`sp-*` keyframes): the
/// lens rim draws, the glass fills, the drop focuses in, the handle slides
/// home, a highlight strokes on, two ripples pulse out, and the name, tagline
/// and footer rise in out of a blur. The name then carries a slow sheen and
/// the halo breathes. Everything runs off one clock so the stages stay in
/// step; reduced motion shows the finished frame.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../illustrations/clear_lens_logo.dart';
import '../widgets/language_sheet.dart';
import '../widgets/line_icon.dart';

/// Splash colours are brand colours from the handoff, fixed across light and
/// dark — the screen is its own sage world either way.
abstract final class _SplashColors {
  static const groundInner = Color(0xFF728157); // accent-2 600
  static const groundMid = Color(0xFF56633F); // accent-2 700
  static const groundOuter = Color(0xFF3D472B); // accent-2 800
  static const blobLight = Color(0xFF8FA073);
  static const blobDark = Color(0xFF272E1B);
  static const blobWarm = Color(0xFFD67F48);
  static const cream = Color(0xFFFFFDF9);
  static const mist = Color(0xFFE1EECC); // accent-2 200
  static const sheen = Color(0xFFCCDBB2); // accent-2 300
  static const deepShadow = Color(0xFF141A0C);
}

/// The handoff's easing curves.
abstract final class _Ease {
  static const expoOut = Cubic(0.16, 1, 0.3, 1);
  static const draw = Cubic(0.65, 0, 0.35, 1);
  static const backOut = Cubic(0.34, 1.56, 0.64, 1);
  static const ripple = Cubic(0.2, 0.7, 0.2, 1);
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  /// Seconds since the splash appeared. Drives every animation on the screen.
  final _clock = ValueNotifier<double>(0);
  late final Ticker _ticker;

  /// The footer has finished rising at 2.25s; hold a beat past it.
  static const _minHold = Duration(milliseconds: 2600);

  /// The network gets this long, then the splash moves on regardless.
  static const _networkCap = Duration(seconds: 3);

  late final Future<String> _destination;
  bool _left = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(
        (elapsed) => _clock.value = elapsed.inMicroseconds / 1e6);
    _destination = _resolveDestination();
    Future.wait([_destination, Future<void>.delayed(_minHold)])
        .then((_) => _leave());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      if (_ticker.isActive) _ticker.stop();
      _clock.value = _introEnd;
    } else if (!_ticker.isActive && _clock.value < _introEnd) {
      _ticker.start();
    }
  }

  static const _introEnd = 3.0;

  /// Where to go next, decided without blocking on the network.
  ///
  ///   no session          → auth
  ///   session, no consent → the disclaimer, which is the gate
  ///   session, consented  → home
  ///
  /// A failed or slow consent check falls through to home rather than
  /// stranding the user on the splash; the server refuses health calls
  /// anyway, and the app routes to the disclaimer when it does.
  Future<String> _resolveDestination() async {
    final app = AppScope.read(context);
    if (!app.signedIn) return Routes.auth;

    Future<String> check() async {
      // Re-fetch the account and profile. A restored token alone is not a
      // usable session: without a profile id, every health screen has nothing
      // to act on and the wizard cannot submit.
      await app.restoreSession();
      try {
        final status = await app.api.consentStatus();
        app.markOffline(false);
        return status.mayAnswerHealthQuestions
            ? Routes.home
            : Routes.disclaimer;
      } catch (_) {
        app.markOffline(!app.api.lastCallReachedServer);
        return Routes.home;
      }
    }

    // The checks keep running in the background if they miss the cap; their
    // results still land in AppState.
    return check().timeout(_networkCap, onTimeout: () => Routes.home);
  }

  /// Leave once — whether the timer or the button gets there first.
  Future<void> _leave() async {
    final destination = await _destination;
    if (!mounted || _left) return;
    _left = true;
    Navigator.of(context).pushReplacementNamed(destination);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _SplashColors.groundOuter,
        body: ValueListenableBuilder<double>(
          valueListenable: _clock,
          builder: (context, t, _) => Stack(
            fit: StackFit.expand,
            children: [
              const CustomPaint(painter: _GroundPainter()),
              _blobs(reduced ? 0 : t),
              SafeArea(
                child: CustomScrollView(
                  slivers: [
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _content(context, t, reduced),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, double t, bool reduced) {
    final app = AppScope.of(context);
    final s = context.s;
    final foot = _rise(t, 1.45, 0.8);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 34),
      child: Column(
        children: [
          // Language is reachable before anything else, because a
          // Bangla-first user should never have to read English to find
          // Bangla. Not in the handoff mock, whose language switch lives in
          // the prototype chrome; it rises with the footer to stay quiet.
          _Risen(
            rise: foot,
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _LanguageChip(
                  label: supportedLanguageName(app.lang),
                  onPressed: () => showLanguageSheet(context),
                ),
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _mark(t, reduced),
                    const SizedBox(height: 28),
                    _Risen(
                      rise: _rise(t, 0.85, 1.0),
                      child: _name(context, t, reduced),
                    ),
                    const SizedBox(height: 10),
                    _Risen(
                      rise: _rise(t, 1.15, 0.9),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 290),
                        child: Text(
                          s.splashTagline,
                          textAlign: TextAlign.center,
                          style: context.t.body.copyWith(
                              color: _SplashColors.mist, height: 1.55),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _Risen(
            rise: foot,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 30),
              child: Column(
                spacing: 11,
                children: [
                  _CreamPill(label: s.splashCta, onPressed: _leave),
                  Text(
                    s.splashFootnote,
                    textAlign: TextAlign.center,
                    style: context.t.footnote
                        .copyWith(color: _SplashColors.mist),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── the mark ─────────────────────────────────────────────────────────

  Widget _mark(double t, bool reduced) {
    // spMarkIn 1s: opacity and blur settle by 60%, the lift and scale run
    // the whole second.
    final p = _lin(t, 0, 1.0);
    final settle = _Ease.expoOut.transform((p / 0.6).clamp(0.0, 1.0));
    final move = _Ease.expoOut.transform(p);

    // spFocus .8s @ .7s, overshooting.
    final dp = _lin(t, 0.7, 0.8);
    final dropSettle = _Ease.backOut.transform((dp / 0.6).clamp(0.0, 1.0));

    final reveal = LogoReveal(
      glass: Curves.ease.transform(_lin(t, 0.35, 0.5)),
      rim: _Ease.draw.transform(_lin(t, 0.25, 0.9)),
      dropScale: 0.3 + 0.7 * _Ease.backOut.transform(dp),
      dropOpacity: dropSettle,
      dropBlur: 4 * (1 - dropSettle).clamp(0.0, 1.0),
      handle: _Ease.expoOut.transform(_lin(t, 0.95, 0.6)),
      shine: Curves.easeOut.transform(_lin(t, 1.3, 0.45)),
    );

    final mark = Container(
      width: 112,
      height: 112,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: _SplashColors.deepShadow.withValues(alpha: 0.45),
            offset: const Offset(0, 18),
            blurRadius: 40,
          ),
        ],
      ),
      child: ClearLensLogo(
        size: 112,
        reveal: reveal,
        semanticLabel: context.s.appName,
      ),
    );

    return SizedBox.square(
      dimension: 112,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          _halo(t, reduced),
          if (!reduced) ...[
            _ripple(t, 1.05, const Color(0xB3F0FAE1)),
            _ripple(t, 1.30, const Color(0x80CCDBB2)),
          ],
          Opacity(
            opacity: settle,
            child: Transform.translate(
              offset: Offset(0, 14 * (1 - move)),
              child: Transform.scale(
                scale: 0.72 + 0.28 * move,
                child: _blur(10 * (1 - settle), mark),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// A soft glow behind the mark: fades in, then breathes 1 → 1.12.
  Widget _halo(double t, bool reduced) {
    final fade = Curves.ease.transform(_lin(t, 0.3, 0.9));
    final breathe = (reduced || t < 1.2) ? 0.0 : _pingPong(t - 1.2, 4.2);
    return Positioned(
      left: -74,
      top: -74,
      width: 260,
      height: 260,
      child: IgnorePointer(
        child: Opacity(
          opacity: fade,
          child: Transform.scale(
            scale: 1 + 0.12 * breathe,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    Color(0x61E1EECC), // .38
                    Color(0x1AE1EECC), // .10
                    Color(0x00E1EECC),
                  ],
                  stops: [0, 0.38, 0.66],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// One outward pulse from the tile's edge, 1.5s.
  Widget _ripple(double t, double delay, Color color) {
    final p = _lin(t, delay, 1.5);
    if (p <= 0 || p >= 1) return const SizedBox.shrink();
    final opacity = p < 0.15
        ? 0.9 * _Ease.ripple.transform(p / 0.15)
        : 0.9 * (1 - _Ease.ripple.transform((p - 0.15) / 0.85));
    return Positioned.fill(
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: 1 + 0.9 * _Ease.ripple.transform(p),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: color, width: 2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── the wordmark ─────────────────────────────────────────────────────

  /// The name in cream, with a pale-sage highlight sweeping across it every
  /// 5.5s from 1.9s on.
  Widget _name(BuildContext context, double t, bool reduced) {
    final text = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        context.s.appName,
        textAlign: TextAlign.center,
        style: context.t.wordmark.copyWith(
          fontSize: 40,
          height: 1.1,
          color: _SplashColors.cream,
        ),
      ),
    );
    if (reduced || t < 1.9) return text;

    final cycle = ((t - 1.9) % 5.5) / 5.5;
    final sweep = Curves.easeInOut.transform((cycle / 0.3).clamp(0.0, 1.0));
    if (sweep >= 1) return text;

    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) {
        // background-size 300%, background-position 100% → 0%.
        final w = bounds.width;
        return const LinearGradient(
          colors: [
            _SplashColors.cream,
            _SplashColors.cream,
            _SplashColors.sheen,
            _SplashColors.cream,
            _SplashColors.cream,
          ],
          stops: [0, 0.42, 0.5, 0.58, 1],
          transform: GradientRotation(15 * 3.1415926535 / 180),
        ).createShader(
            Rect.fromLTWH(-2 * w * (1 - sweep), 0, 3 * w, bounds.height));
      },
      child: text,
    );
  }

  // ── the ground ───────────────────────────────────────────────────────

  /// Three soft circles drifting on 9, 11 and 13s loops.
  Widget _blobs(double t) => IgnorePointer(
        child: Stack(
          children: [
            PositionedDirectional(
              start: -70,
              top: -40,
              child: _blob(t, 9, 250, _SplashColors.blobLight, 0.4),
            ),
            PositionedDirectional(
              end: -90,
              bottom: 120,
              child: _blob(t, 11, 290, _SplashColors.blobDark, 0.45),
            ),
            PositionedDirectional(
              end: 44,
              top: 118,
              child: _blob(t, 13, 56, _SplashColors.blobWarm, 0.55),
            ),
          ],
        ),
      );

  /// `blobDrift`: drifts to (−10, 14) and 1.06× at the half-way point.
  Widget _blob(double t, double period, double size, Color color, double a) {
    final k = _pingPong(t, period);
    return Transform.translate(
      offset: Offset(-10 * k, 14 * k),
      child: Transform.scale(
        scale: 1 + 0.06 * k,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color.withValues(alpha: a),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  // ── timing helpers ───────────────────────────────────────────────────

  /// Linear progress of a stage that starts at [delay] and lasts [dur].
  static double _lin(double t, double delay, double dur) =>
      ((t - delay) / dur).clamp(0.0, 1.0);

  /// `spRise`: eased progress of a rise-out-of-blur stage.
  static double _rise(double t, double delay, double dur) =>
      _Ease.expoOut.transform(_lin(t, delay, dur));

  /// 0 → 1 → 0 over [period], eased in and out each way.
  static double _pingPong(double t, double period) {
    final phase = (t % period) / period;
    return Curves.easeInOut
        .transform(phase < 0.5 ? phase * 2 : (1 - phase) * 2);
  }
}

/// Blur [child] by [sigma] logical pixels; a no-op once it has cleared.
Widget _blur(double sigma, Widget child) => sigma < 0.05
    ? child
    : ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: child,
      );

/// `spRise`: fades in, lifts 16px and un-blurs 12px as [rise] goes 0 → 1.
class _Risen extends StatelessWidget {
  const _Risen({required this.rise, required this.child});

  final double rise;
  final Widget child;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: rise.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, 16 * (1 - rise)),
          child: _blur(12 * (1 - rise), child),
        ),
      );
}

/// Globe + current language. A plain Row rather than the kit's GhostButton,
/// whose LayoutBuilder cannot answer the intrinsic-height query that
/// SliverFillRemaining makes.
class _LanguageChip extends StatelessWidget {
  const _LanguageChip({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadius.rMd,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 6,
              children: [
                const LineIcon(Icons24.globe,
                    size: 16, color: _SplashColors.mist),
                Text(
                  label,
                  style: context.t.caption.copyWith(
                      color: _SplashColors.mist, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      );
}

/// The splash's cream pill: dark-sage label, deep soft shadow.
class _CreamPill extends StatelessWidget {
  const _CreamPill({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  static const _ink = Color(0xFF3D472B);

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: AppRadius.rPill,
          boxShadow: [
            BoxShadow(
              color: _SplashColors.deepShadow.withValues(alpha: 0.35),
              offset: const Offset(0, 10),
              blurRadius: 24,
            ),
          ],
        ),
        child: Material(
          color: _SplashColors.cream,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            splashColor: _ink.withValues(alpha: 0.10),
            highlightColor: _ink.withValues(alpha: 0.06),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: SizedBox(
                width: double.infinity,
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: context.t.button.copyWith(color: _ink),
                ),
              ),
            ),
          ),
        ),
      );
}

/// `radial-gradient(120% 75% at 50% 40%, #728157, #56633f 52%, #3d472b)` —
/// an ellipse 1.2× the width and 0.75× the height, centred 40% down.
class _GroundPainter extends CustomPainter {
  const _GroundPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas
      ..save()
      ..clipRect(rect)
      ..translate(size.width / 2, size.height * 0.4)
      ..scale(size.width * 1.2, size.height * 0.75);
    final unit = Rect.fromCircle(center: Offset.zero, radius: 1);
    canvas
      ..drawRect(
        // Large enough to cover the screen in the scaled space.
        const Rect.fromLTRB(-2, -2, 2, 2),
        Paint()
          ..shader = const RadialGradient(
            colors: [
              _SplashColors.groundInner,
              _SplashColors.groundMid,
              _SplashColors.groundOuter,
            ],
            stops: [0, 0.52, 1],
          ).createShader(unit),
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_GroundPainter old) => false;
}
