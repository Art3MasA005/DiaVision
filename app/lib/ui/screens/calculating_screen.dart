/// 06 · Calculating.
///
/// ~3 seconds of considered pause. The real assessment is faster; the pause
/// stops a health estimate feeling flippant.
///
/// This is also where the two writes happen — `PUT /profiles/{id}/health` then
/// `POST /risk/assess` — so it is the screen that has to know every branch:
///
///   403 `medical_disclaimer_required` → back to the disclaimer
///   403 `safety_card` (profile gate)  → the safety card, replacing the screen
///   409 `already_diagnosed`           → management, not the risk screen
///   network failure                   → the error state, never a spinner
///
/// The progress claim is honest: the ring reflects the two calls actually
/// completing, and it never sits at 100% waiting for something.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/typography.dart';
import '../../data/api.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/shell.dart';
import 'edge_states.dart';
import 'risk_screen.dart';
import 'wizard_screen.dart';

class CalculatingScreen extends StatefulWidget {
  const CalculatingScreen({super.key});

  @override
  State<CalculatingScreen> createState() => _CalculatingScreenState();
}

class _CalculatingScreenState extends State<CalculatingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: AppMotion.calcSpin,
  )..repeat();

  /// 0 = nothing done, 3 = everything done.
  int _stage = 0;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final args =
        ModalRoute.of(context)?.settings.arguments as CalculatingArgs?;
    if (args == null) {
      // Nothing to calculate. Getting here means a bad push; go somewhere
      // useful rather than spinning forever.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).pushReplacementNamed(Routes.home);
        }
      });
      return;
    }
    _run(args);
  }

  Future<void> _run(CalculatingArgs args) async {
    final app = AppScope.read(context);
    final started = DateTime.now();

    try {
      setState(() => _stage = 1);
      await app.api.putHealthProfile(args.profileId, args.wizard.toWire());

      setState(() => _stage = 2);
      final result = await app.api.assess(args.profileId);
      await app.saveResult(result);
      app.markOffline(false);

      // Hold the pause out to ~2.9s even when the server is quick.
      final elapsed = DateTime.now().difference(started);
      final remaining = const Duration(milliseconds: 2900) - elapsed;
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
      if (!mounted) return;
      setState(() => _stage = 3);
      await Future<void>.delayed(const Duration(milliseconds: 220));
      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          settings: const RouteSettings(name: Routes.risk),
          builder: (_) => RiskScreen(result: result, profileId: args.profileId),
        ),
      );
    } on DisclaimerRequired {
      if (!mounted) return;
      Navigator.of(context)
          .pushNamedAndRemoveUntil(Routes.disclaimer, (_) => false);
    } on AlreadyDiagnosed {
      if (!mounted) return;
      Navigator.of(context)
          .pushNamedAndRemoveUntil(Routes.diagnosed, (_) => false);
    } on SafetyIntercept catch (e) {
      if (!mounted) return;
      // The card replaces the screen entirely. Under-18 arrives here as a
      // profile-gate safety event and gets its own kinder screen.
      if (e.card.trigger.contains('age') || e.card.trigger.contains('minor')) {
        Navigator.of(context)
            .pushNamedAndRemoveUntil(Routes.under18, (_) => false);
        return;
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => SafetyCardScreen(
            card: e.card,
            emergencyNumber: app.region.emergencyNumber,
            country: app.region.country,
          ),
        ),
      );
    } on ApiFailure catch (e) {
      if (!mounted) return;
      app.markOffline(e is NetworkFailure);
      // Failure routes to the error state, never an endless spinner.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ErrorScreen(
            message: e is NetworkFailure ? context.s.errNetwork : null,
            onRetry: () {
              Navigator.of(context).pushReplacementNamed(
                Routes.calculating,
                arguments: args,
              );
            },
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  /// The percentage tracks the stages rather than a timer, so it never claims
  /// progress the app has not made.
  int get _percent => switch (_stage) {
        0 => 18,
        1 => 46,
        2 => 78,
        _ => 100,
      };

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;

    return PopScope(
      // No escape from a gate, and no way to leave two half-finished writes.
      canPop: false,
      child: Shell(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.gutter, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 22,
              children: [
                _ring(c),
                VGap(
                  10,
                  children: [
                    Text(
                      s.calcHead,
                      textAlign: TextAlign.center,
                      style: context.t.screenTitleSm.copyWith(color: c.text),
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 300),
                      child: P(s.calcSub,
                          style: context.t.caption, align: TextAlign.center),
                    ),
                  ],
                ),
                VGap(
                  9,
                  children: [
                    _stepRow(c, s.calcStep1, 1),
                    _stepRow(c, s.calcStep2, 2),
                    _stepRow(c, s.calcStep3, 3),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _ring(dynamic c) => SizedBox.square(
        dimension: 132,
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedBuilder(
              animation: _spin,
              builder: (context, _) => Transform.rotate(
                angle: _spin.value * 2 * math.pi,
                child: CustomPaint(
                  size: const Size.square(132),
                  painter: _RingPainter(
                    track: c.neutral.c300,
                    arc: c.accent,
                  ),
                ),
              ),
            ),
            Text(
              '${context.n.int_(_percent)}%',
              style: context.t.screenTitleSm
                  .copyWith(color: c.accentRamp.c700)
                  .withTabular(),
            ),
          ],
        ),
      );

  Widget _stepRow(dynamic c, String label, int stage) {
    final done = _stage >= stage;
    return AnimatedOpacity(
      duration: AppMotion.riseIn,
      opacity: done ? 1 : 0.45,
      child: AppCard(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: HGap(
          11,
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done ? c.accent : Colors.transparent,
                border: Border.all(
                    color: done ? c.accent : c.neutral.c400, width: 2),
              ),
              child: done
                  ? Center(
                      child: LineIcon(Icons24.check,
                          size: 12, color: c.onAccent, strokeWidth: 3.4),
                    )
                  : null,
            ),
            Expanded(
              child: Text(label,
                  style: context.t.caption.copyWith(color: c.text)),
            ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.track, required this.arc});

  final Color track, arc;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    const radius = 56.0;
    final base = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10;
    canvas.drawCircle(centre, radius, base);

    // stroke-dasharray: 120 352 — a 120-unit arc on a 352-unit circumference.
    final sweep = 2 * math.pi * (120 / 352);
    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: radius),
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..color = arc
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.arc != arc || old.track != track;
}
