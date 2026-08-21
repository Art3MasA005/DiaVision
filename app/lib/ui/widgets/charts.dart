/// The small data visualisations: progress rings and the weekly bar row.
///
/// Two rules from the design govern every one of them, and they are the reason
/// these are hand-drawn rather than pulled from a charting package:
///
///   * **Never red for "over target".** Going past a calorie goal is not a
///     safety event and must not be styled as one. Over-target reads in the
///     caution amber at most, and usually just in accent.
///   * **Every figure has a text equivalent.** Each chart carries a semantics
///     label, because a ring is invisible to a screen reader and the number it
///     encodes is the whole point.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';

/// Two concentric rings — calories outside, glycemic load inside — with a
/// pill-coloured badge at the centre.
class DualRing extends StatelessWidget {
  const DualRing({
    super.key,
    required this.outer,
    required this.inner,
    required this.centre,
    required this.caption,
    required this.semanticLabel,
    this.size = 210,
    this.innerColor,
  });

  /// 0–1+, clamped for drawing but not for meaning: 1.2 draws a full ring.
  final double outer;
  final double inner;

  final String centre;
  final String caption;
  final String semanticLabel;
  final double size;
  final Color? innerColor;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: Size.square(size),
                painter: _DualRingPainter(
                  outer: outer,
                  inner: inner,
                  track: c.neutral.c300,
                  // Over target is accent, never safety red. Rule 4.
                  outerColor: outer > 1 ? c.caution : c.accent,
                  innerColor: innerColor ?? c.accent2,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 2,
                children: [
                  Text(centre,
                      style: context.t.heroNumber
                          .copyWith(fontSize: size * 0.17, color: c.text)),
                  Text(caption,
                      textAlign: TextAlign.center,
                      style: context.t.footnote.copyWith(color: c.neutral.c600)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DualRingPainter extends CustomPainter {
  _DualRingPainter({
    required this.outer,
    required this.inner,
    required this.track,
    required this.outerColor,
    required this.innerColor,
  });

  final double outer, inner;
  final Color track, outerColor, innerColor;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final rOuter = size.width * 0.44;
    final rInner = size.width * 0.33;
    final stroke = size.width * 0.055;

    void ring(double radius, double value, Color colour) {
      final rect = Rect.fromCircle(center: centre, radius: radius);
      canvas.drawArc(rect, 0, 2 * math.pi, false, Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke);
      if (value <= 0) return;
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * value.clamp(0.0, 1.0),
        false,
        Paint()
          ..color = colour
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round,
      );
    }

    ring(rOuter, outer, outerColor);
    ring(rInner, inner, innerColor);
  }

  @override
  bool shouldRepaint(_DualRingPainter old) =>
      old.outer != outer || old.inner != inner || old.outerColor != outerColor;
}

/// A single progress ring — the activity step goal.
class GoalRing extends StatelessWidget {
  const GoalRing({
    super.key,
    required this.value,
    required this.centre,
    required this.caption,
    required this.semanticLabel,
    this.size = 190,
  });

  final double value;
  final String centre, caption, semanticLabel;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: Size.square(size),
                painter: _DualRingPainter(
                  outer: value,
                  inner: 0,
                  track: c.neutral.c300,
                  outerColor: c.accent2,
                  innerColor: Colors.transparent,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 2,
                children: [
                  Text(centre,
                      style: context.t.heroNumber
                          .copyWith(fontSize: size * 0.19, color: c.text)),
                  Text(caption,
                      style: context.t.footnote.copyWith(color: c.neutral.c600)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A week of bars. Used for steps and for glucose spread.
class WeekBars extends StatelessWidget {
  const WeekBars({
    super.key,
    required this.values,
    required this.labels,
    required this.semanticLabel,
    this.goal,
    this.height = 96,
    this.color,
  });

  final List<double> values;
  final List<String> labels;
  final String semanticLabel;

  /// Drawn as a dotted rule across the bars. Above it is not a failure.
  final double? goal;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final peak = [
      ...values,
      if (goal != null) goal!,
      1.0,
    ].reduce(math.max);

    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            SizedBox(
              height: height,
              child: Stack(
                children: [
                  if (goal != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: height * (goal! / peak),
                      child: CustomPaint(
                        painter: _DottedRule(colour: c.neutral.c400),
                        size: const Size(double.infinity, 1),
                      ),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    spacing: 6,
                    children: [
                      for (final v in values)
                        Expanded(
                          child: Container(
                            height: math.max(4, height * (v / peak)),
                            decoration: BoxDecoration(
                              color: v <= 0
                                  ? c.neutral.c200
                                  : (color ?? c.accent2),
                              borderRadius: AppRadius.rSm,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Row(
              spacing: 6,
              children: [
                for (final label in labels)
                  Expanded(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: context.t.footnote
                          .copyWith(color: c.neutral.c600, fontSize: 11),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DottedRule extends CustomPainter {
  _DottedRule({required this.colour});

  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = colour
      ..strokeWidth = 1.4;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, 0), Offset(x + 4, 0), paint);
      x += 9;
    }
  }

  @override
  bool shouldRepaint(_DottedRule old) => old.colour != colour;
}

/// A macro chip — carbs / protein / GL along the bottom of the tracker.
class MacroChip extends StatelessWidget {
  const MacroChip({
    super.key,
    required this.label,
    required this.value,
    this.tone,
  });

  final String label;
  final String value;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.neutral.c200,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 2,
        children: [
          Text(label,
              style: context.t.footnote
                  .copyWith(color: c.neutral.c600, fontSize: 11)),
          Text(value,
              style: context.t.captionStrong
                  .copyWith(color: tone ?? c.text, fontSize: 15)),
        ],
      ),
    );
  }
}
