/// The "Clear Lens" logo: a magnifying lens with a blood drop inside.
///
/// Transcribed from the handoff SVG (viewBox 120×120): white tile with a 30
/// corner radius, sage handle, terracotta rim, peach glass, terracotta drop
/// and a short highlight stroke. The colours are brand colours, not theme
/// roles — the mark looks the same in light and dark.
///
/// [LogoReveal] exposes each part's progress so the splash can draw the mark
/// in stages. Everywhere else uses [LogoReveal.done].
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// How far along each part of the mark is, 0 → 1.
@immutable
class LogoReveal {
  const LogoReveal({
    this.glass = 1,
    this.rim = 1,
    this.dropScale = 1,
    this.dropOpacity = 1,
    this.dropBlur = 0,
    this.handle = 1,
    this.shine = 1,
  });

  /// Fill of the glass disc.
  final double glass;

  /// How much of the rim is drawn, clockwise from 12 o'clock.
  final double rim;

  /// Scale of the drop about its lower-centre (may overshoot 1).
  final double dropScale;
  final double dropOpacity;

  /// Blur on the drop, in viewBox units.
  final double dropBlur;

  /// Handle slide-in: opacity, and a −12,−12 offset that closes to zero.
  final double handle;

  /// How much of the highlight stroke is drawn.
  final double shine;

  static const done = LogoReveal();
}

class ClearLensLogo extends StatelessWidget {
  const ClearLensLogo({
    super.key,
    this.size = 112,
    this.reveal = LogoReveal.done,
    this.semanticLabel,
  });

  final double size;
  final LogoReveal reveal;

  /// Null hides the mark from assistive tech (use when a wordmark sits next
  /// to it and would be read twice).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final paint = CustomPaint(
      size: Size.square(size),
      painter: _ClearLensPainter(reveal),
    );
    if (semanticLabel == null) return ExcludeSemantics(child: paint);
    return Semantics(label: semanticLabel, image: true, child: paint);
  }
}

class _ClearLensPainter extends CustomPainter {
  _ClearLensPainter(this.r);

  final LogoReveal r;

  static const _tile = Color(0xFFFFFDF9);
  static const _terracotta = Color(0xFFC67139);
  static const _sage = Color(0xFF7A8A5E);
  static const _glass = Color(0xFFFFF2EB);
  static const _shine = Color(0xFFF6A06B);

  static const _lens = Offset(52, 52);
  static const _lensR = 29.0;

  /// The drop's transform-origin (50% 62% of its box) in viewBox units.
  static const _dropOrigin = Offset(52, 55.31);

  static final Path _drop = () {
    final p = Path()
      ..moveTo(60, 18)
      ..cubicTo(60, 18, 30, 50, 30, 72)
      ..cubicTo(30, 89, 43, 102, 60, 102)
      ..cubicTo(77, 102, 90, 89, 90, 72)
      ..cubicTo(90, 50, 60, 18, 60, 18)
      ..close();
    // translate(52 53) scale(0.38) translate(-60 -64)
    final m = Matrix4.identity()
      ..translateByDouble(52, 53, 0, 1)
      ..scaleByDouble(0.38, 0.38, 1, 1)
      ..translateByDouble(-60, -64, 0, 1);
    return p.transform(m.storage);
  }();

  static final Path _shinePath = Path()
    ..moveTo(36, 44)
    ..quadraticBezierTo(38, 36, 46, 33);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 120);

    canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(0, 0, 120, 120), const Radius.circular(30)),
      Paint()..color = _tile,
    );

    final handle = r.handle.clamp(0.0, 1.0);
    if (handle > 0) {
      final d = -12 * (1 - r.handle);
      canvas
        ..save()
        ..translate(d, d)
        ..translate(81, 85)
        ..rotate(-math.pi / 4)
        ..translate(-81, -85)
        ..drawRRect(
          RRect.fromRectAndRadius(
              const Rect.fromLTWH(74, 66, 14, 38), const Radius.circular(7)),
          Paint()..color = _sage.withValues(alpha: handle),
        )
        ..restore();
    }

    final glass = r.glass.clamp(0.0, 1.0);
    if (glass > 0) {
      canvas.drawCircle(
          _lens, _lensR, Paint()..color = _glass.withValues(alpha: glass));
    }

    final rim = r.rim.clamp(0.0, 1.0);
    if (rim > 0) {
      final stroke = Paint()
        ..color = _terracotta
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round;
      if (rim >= 1) {
        canvas.drawCircle(_lens, _lensR, stroke);
      } else {
        canvas.drawArc(Rect.fromCircle(center: _lens, radius: _lensR),
            -math.pi / 2, 2 * math.pi * rim, false, stroke);
      }
    }

    final dropOpacity = r.dropOpacity.clamp(0.0, 1.0);
    if (dropOpacity > 0) {
      final fill = Paint()..color = _terracotta.withValues(alpha: dropOpacity);
      if (r.dropBlur > 0.05) {
        fill.maskFilter = ui.MaskFilter.blur(BlurStyle.normal, r.dropBlur);
      }
      canvas
        ..save()
        ..translate(_dropOrigin.dx, _dropOrigin.dy)
        ..scale(r.dropScale)
        ..translate(-_dropOrigin.dx, -_dropOrigin.dy)
        ..drawPath(_drop, fill)
        ..restore();
    }

    final shine = r.shine.clamp(0.0, 1.0);
    if (shine > 0) {
      final metric = _shinePath.computeMetrics().first;
      canvas.drawPath(
        metric.extractPath(0, metric.length * shine),
        Paint()
          ..color = _shine
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.5
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_ClearLensPainter old) =>
      old.r.glass != r.glass ||
      old.r.rim != r.rim ||
      old.r.dropScale != r.dropScale ||
      old.r.dropOpacity != r.dropOpacity ||
      old.r.dropBlur != r.dropBlur ||
      old.r.handle != r.handle ||
      old.r.shine != r.shine;
}
