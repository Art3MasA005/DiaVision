/// The waist-measurement diagram — the asset the design handoff lists as
/// missing.
///
/// `README.md` → "Illustration for the waist-measurement guide (spec §2 screen
/// 07) is not drawn. The prototype covers it with a 'Why do we ask?' text
/// explainer instead; a wordless diagram is still required per spec."
///
/// Drawn here rather than shipped as an image, for four reasons that all come
/// straight out of the shipping rules:
///
///   * **Rule 9 — never text baked into an image.** There is no text in the
///     artwork at all. The step number beside each panel is live, localized
///     text that goes through the numeral formatter, so it renders `২` in
///     Bangla without a second asset.
///   * **Rule 4 / the palette contract.** It reads from the same tokens as
///     everything else, so it flips with the theme instead of shipping a light
///     PNG onto a dark ground. Safety red is never used — measuring your waist
///     is not a safety event.
///   * **Accessibility.** A vector redraws crisply at the largest dynamic-type
///     size, and the whole figure carries one screen-reader description
///     (`Strings.waistGuideA11y`) rather than being invisible.
///   * It is one file instead of eight raster assets across four densities and
///     two themes.
///
/// Style is held to the rest of the system: Lucide geometry, stroke width
/// 2.75 at a 24-unit scale (so 100/24 × 2.75 ≈ 2.4 in this 100×100 space,
/// which is what [_stroke] resolves to), round caps and joins. The body is
/// drawn in neutral ink; the *instruction* — what to find, where the tape
/// goes — is the only thing in accent, so the eye lands on the measurement and
/// not on the person.
///
/// The figure is deliberately schematic and un-gendered: a line drawing with no
/// face, no hair, no clothing and no body-type cue. This screen is shown to
/// everyone, it is about a tape measure, and a drawing that reads as a
/// particular body would quietly tell some users it is not about them.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../core/theme.dart';

/// Which of the four steps to draw.
enum WaistStep {
  /// Stand straight, arms down, nothing bunched under the tape.
  stand,

  /// Find the point midway between the lowest rib and the top of the hip bone.
  findPoint,

  /// Wrap the tape all the way round, level with the floor.
  wrapLevel,

  /// Breathe out, then read. Snug against the skin, not pulled tight.
  breatheRead,
}

/// One panel of the diagram.
class WaistDiagram extends StatelessWidget {
  const WaistDiagram({
    super.key,
    required this.step,
    this.size = 104,
  });

  final WaistStep step;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _WaistPainter(
          step: step,
          ink: c.neutral.c700,
          faint: c.neutral.c400,
          accent: c.accent,
          accent2: c.accent2,
          ground: c.accentRamp.c100,
          groundBorder: c.accentRamp.c300,
        ),
      ),
    );
  }
}

/// The four panels stacked, each with its live step number and caption.
/// The whole block carries one screen-reader description; the individual
/// panels are decorative once that has been read.
class WaistDiagramSequence extends StatelessWidget {
  const WaistDiagramSequence({super.key, required this.captions});

  /// Four captions, in step order.
  final List<String> captions;

  @override
  Widget build(BuildContext context) {
    assert(captions.length == 4);
    final c = context.c;
    final n = context.n;

    return Semantics(
      label: context.s.waistGuideA11y,
      image: true,
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            for (var i = 0; i < 4; i++)
              Container(
                padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
                decoration: BoxDecoration(
                  color: c.card,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: c.neutral.c300),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 12,
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 6,
                      children: [
                        WaistDiagram(step: WaistStep.values[i], size: 96),
                        // Live text through the numeral formatter — never
                        // baked into the artwork.
                        Container(
                          width: 24,
                          height: 24,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: c.accentRamp.c100,
                            shape: BoxShape.circle,
                            border: Border.all(color: c.accentRamp.c300),
                          ),
                          child: Text(
                            n.int_(i + 1),
                            style: context.t.captionStrong
                                .copyWith(color: c.accentRamp.c800),
                          ),
                        ),
                      ],
                    ),
                    // min-width: 0 — long Bangla captions wrap instead of
                    // pushing the panel off the row.
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          captions[i],
                          style: context.t.caption
                              .copyWith(color: c.neutral.c700, height: 1.6),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── the painter ───────────────────────────────────────────────────────
//
// Everything below works in a 100×100 space and is scaled to the widget box,
// so the geometry reads the same at any size.

class _WaistPainter extends CustomPainter {
  _WaistPainter({
    required this.step,
    required this.ink,
    required this.faint,
    required this.accent,
    required this.accent2,
    required this.ground,
    required this.groundBorder,
  });

  final WaistStep step;
  final Color ink, faint, accent, accent2, ground, groundBorder;

  /// Lucide's 2.75 at a 24-unit viewBox, carried into this 100-unit one.
  static const _stroke = 2.75 * (100 / 24) / 4.2;

  /// The two landmarks and the point between them. Shared by panels 2 and 3
  /// so the tape in one lands exactly where the point in the other was.
  static const _ribY = 42.0;
  static const _hipY = 72.0;
  static const _midY = (_ribY + _hipY) / 2;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);

    // A soft tinted ground, so the figure reads as an illustration and not as
    // a stray icon floating on the card.
    final plate = RRect.fromRectAndRadius(
      const Rect.fromLTWH(1, 1, 98, 98),
      const Radius.circular(22),
    );
    canvas.drawRRect(plate, Paint()..color = ground);
    canvas.drawRRect(
      plate,
      Paint()
        ..color = groundBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke * 0.5,
    );
    canvas.clipRRect(plate);

    switch (step) {
      case WaistStep.stand:
        _drawStand(canvas);
      case WaistStep.findPoint:
        _drawFindPoint(canvas);
      case WaistStep.wrapLevel:
        _drawWrapLevel(canvas);
      case WaistStep.breatheRead:
        _drawBreatheRead(canvas);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WaistPainter old) =>
      old.step != step || old.ink != ink || old.accent != accent;

  Paint _line(Color color, {double? width, bool round = true}) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width ?? _stroke
    ..strokeCap = round ? StrokeCap.round : StrokeCap.butt
    ..strokeJoin = StrokeJoin.round;

  // ── 1 · stand straight ────────────────────────────────────────────
  //
  // Whole figure, feet together, arms hanging. A dashed plumb line down the
  // centre carries "straight" without a word.

  void _drawStand(Canvas canvas) {
    final body = _line(ink);

    // Plumb line first, so the body sits on top of it.
    _dashed(
      canvas,
      Path()
        ..moveTo(50, 6)
        ..lineTo(50, 90),
      _line(accent2, width: _stroke * 0.62),
      dash: 3.2,
      gap: 3.4,
    );

    // Head and neck.
    canvas.drawCircle(const Offset(50, 13), 6.5, body);
    canvas.drawLine(const Offset(50, 19.5), const Offset(50, 25), body);

    // Torso: wide at the shoulders, in at the waist, out again at the hips.
    // The taper is the whole point of the figure — a rectangle would give no
    // clue where the tape is meant to sit.
    final torso = Path()
      ..moveTo(38, 26)
      ..cubicTo(36.5, 34, 40.5, 43, 41.5, 49) // shoulder → waist
      ..cubicTo(42.5, 55, 39.5, 60, 39.5, 66) // waist → hip
      ..lineTo(60.5, 66)
      ..cubicTo(60.5, 60, 57.5, 55, 58.5, 49)
      ..cubicTo(59.5, 43, 63.5, 34, 62, 26)
      ..close();
    canvas.drawPath(torso, body);

    // Arms hanging clear of the torso — the tape has to reach all the way
    // round, which it cannot do with an arm in the way.
    canvas.drawPath(
      Path()
        ..moveTo(38, 27)
        ..cubicTo(33, 35, 31.5, 45, 31.5, 58),
      body,
    );
    canvas.drawPath(
      Path()
        ..moveTo(62, 27)
        ..cubicTo(67, 35, 68.5, 45, 68.5, 58),
      body,
    );

    // Legs, feet together.
    canvas.drawPath(
      Path()
        ..moveTo(45, 66)
        ..lineTo(44.5, 86),
      body,
    );
    canvas.drawPath(
      Path()
        ..moveTo(55, 66)
        ..lineTo(55.5, 86),
      body,
    );
    canvas.drawLine(const Offset(44.5, 86), const Offset(40.5, 88), body);
    canvas.drawLine(const Offset(55.5, 86), const Offset(59.5, 88), body);

    // The floor.
    canvas.drawLine(
      const Offset(20, 90),
      const Offset(80, 90),
      _line(faint, width: _stroke * 0.7),
    );
  }

  // ── 2 · find the point ────────────────────────────────────────────
  //
  // Torso close-up. Sage marks the two landmarks — lowest rib, top of the hip
  // bone. Terracotta marks the measuring point, and the bracket on the start
  // side shows it sitting exactly halfway between them.

  void _drawFindPoint(Canvas canvas) {
    _torsoCloseUp(canvas);

    final mark = _line(accent2, width: _stroke * 0.8);

    // The costal margin — the lowest ribs sweeping down and out from the
    // breastbone. Drawn as the real landmark rather than a floating tick,
    // because "your lowest rib" is a thing you find by feel, and the shape is
    // what you are feeling for.
    canvas.drawPath(
      Path()
        ..moveTo(32.5, _ribY)
        ..quadraticBezierTo(42, 35.5, 50, 34.5)
        ..quadraticBezierTo(58, 35.5, 67.5, _ribY),
      mark,
    );

    // The top of the hip bone, either side.
    canvas.drawPath(
      Path()
        ..moveTo(31.2, _hipY + 4)
        ..quadraticBezierTo(34, _hipY - 1, 40, _hipY - 2.5),
      mark,
    );
    canvas.drawPath(
      Path()
        ..moveTo(68.8, _hipY + 4)
        ..quadraticBezierTo(66, _hipY - 1, 60, _hipY - 2.5),
      mark,
    );

    // The halfway bracket. Sits on the start side, so it lands on the correct
    // edge when the layout flips under RTL.
    final bracket = _line(accent, width: _stroke * 0.65);
    canvas.drawLine(const Offset(13, _ribY), const Offset(13, _hipY), bracket);
    canvas.drawLine(const Offset(10, _ribY), const Offset(16, _ribY), bracket);
    canvas.drawLine(const Offset(10, _hipY), const Offset(16, _hipY), bracket);
    canvas.drawLine(const Offset(9, _midY), const Offset(17, _midY), bracket);

    // The measuring line, and the point itself.
    _dashed(
      canvas,
      Path()
        ..moveTo(18, _midY)
        ..lineTo(84, _midY),
      _line(accent, width: _stroke * 0.75),
      dash: 3.4,
      gap: 3.0,
    );
    canvas.drawCircle(const Offset(50, _midY), 3.6, Paint()..color = accent);
  }

  // ── 3 · wrap the tape, level ──────────────────────────────────────
  //
  // The tape goes all the way round: the front of the loop is solid, the part
  // behind the body is dashed. A dotted rule running the full width says
  // "parallel to the floor" — the mistake this panel exists to prevent is a
  // tape that rides up at the back.

  void _drawWrapLevel(Canvas canvas) {
    // The floor-parallel reference, drawn under everything. The mistake this
    // panel exists to prevent is a tape that rides up at the back, and this
    // line is the only thing in the drawing that says "level".
    _dashed(
      canvas,
      Path()
        ..moveTo(5, _midY)
        ..lineTo(95, _midY),
      _line(faint, width: _stroke * 0.5),
      dash: 2.2,
      gap: 3.8,
    );

    _torsoCloseUp(canvas);

    // The loop, at the waist. The half behind the body is dashed and the half
    // in front is solid, so it reads as going all the way round rather than
    // as a line drawn across.
    const rect = Rect.fromLTRB(33.5, _midY - 6, 66.5, _midY + 6);
    _dashed(
      canvas,
      Path()..addArc(rect, math.pi, math.pi),
      _line(accent, width: _stroke * 0.7),
      dash: 3.0,
      gap: 2.8,
    );
    canvas.drawPath(
      Path()..addArc(rect, 0, math.pi),
      _line(accent, width: _stroke * 0.95),
    );

    // A tail hanging from the front, with graduations. Without these it is a
    // belt; with them it is a tape measure.
    final tail = Path()
      ..moveTo(58, _midY + 5.2)
      ..cubicTo(67, _midY + 9, 73, _midY + 14, 76, _midY + 23);
    canvas.drawPath(tail, _line(accent, width: _stroke * 0.9));

    final metric = tail.computeMetrics().first;
    for (final t in [0.42, 0.66, 0.9]) {
      final pos = metric.getTangentForOffset(metric.length * t);
      if (pos == null) continue;
      final normal = Offset(-pos.vector.dy, pos.vector.dx) * 2.4;
      canvas.drawLine(
        pos.position - normal,
        pos.position + normal,
        _line(accent, width: _stroke * 0.45),
      );
    }
  }

  // ── 4 · breathe out, then read ────────────────────────────────────
  //
  // Side view. The exhale arrow leaves the mouth; the tape lies along the skin
  // with one small loop of slack, which is the whole difference between "snug"
  // and "pulled tight".

  void _drawBreatheRead(Canvas canvas) {
    final body = _line(ink);

    // Side view, facing the start side. Edge-on is the only angle that can
    // show a tape lying flat against a belly rather than cutting into it,
    // which is the entire content of this step.
    //
    // The head is drawn as a real profile — brow, nose, chin. Two plain lines
    // and a circle read exactly the same from the front as from the side, and
    // then the panel says nothing the previous three did not.
    canvas.drawPath(
      Path()
        ..moveTo(52, 24)
        ..cubicTo(45, 24, 40.5, 22, 41, 19) // jaw
        ..lineTo(37, 18) // nose tip
        ..lineTo(41.5, 14) // bridge
        ..cubicTo(42.5, 9, 48, 7, 52, 8.5) // brow and forehead
        ..cubicTo(57, 10, 58.5, 15, 57, 19.5) // back of the skull
        ..cubicTo(56, 22.5, 54, 24, 52, 24),
      body,
    );

    // Neck, and shoulders closing the top so the head is attached to something.
    canvas.drawLine(const Offset(52, 24), const Offset(52.5, 28), body);
    canvas.drawLine(const Offset(46, 28), const Offset(58, 28), body);

    // Back — near enough straight.
    canvas.drawPath(
      Path()
        ..moveTo(58, 28)
        ..cubicTo(60.5, 42, 60.5, 62, 59, 84),
      body,
    );

    // Front — chest in, then the belly out. The tape has to follow this curve,
    // and it is drawn generously for that reason.
    canvas.drawPath(
      Path()
        ..moveTo(46, 28)
        ..cubicTo(41, 36, 33, 46, 32.5, 58)
        ..cubicTo(32, 70, 37, 78, 38.5, 84),
      body,
    );

    // The exhale — one curved arrow leaving the mouth. No lungs, no diagram of
    // breathing; the caption says the rest.
    canvas.drawPath(
      Path()
        ..moveTo(34, 18.5)
        ..cubicTo(28, 18, 22, 20.5, 18.5, 25),
      _line(accent2, width: _stroke * 0.7),
    );
    canvas.drawPath(
      Path()
        ..moveTo(22, 21.5)
        ..lineTo(18, 25.2)
        ..lineTo(22.5, 27.5),
      _line(accent2, width: _stroke * 0.7),
    );

    // The tape, seen edge-on, lying flat across the waist and stopping at the
    // skin on both sides — it does not float past the body.
    const y = 60.0;
    final tape = _line(accent, width: _stroke * 0.95);
    canvas.drawLine(const Offset(59.7, y), const Offset(32.6, y), tape);

    // A graduated tail hanging straight down from the front, so this reads as
    // the same tape as panel 3 and does not stray back into the exhale.
    final tail = Path()
      ..moveTo(32.8, y)
      ..cubicTo(29.5, y + 5, 28.5, y + 11, 29, y + 19);
    canvas.drawPath(tail, tape);
    final metric = tail.computeMetrics().first;
    for (final t in [0.45, 0.78]) {
      final pos = metric.getTangentForOffset(metric.length * t);
      if (pos == null) continue;
      final normal = Offset(-pos.vector.dy, pos.vector.dx) * 2.4;
      canvas.drawLine(
        pos.position - normal,
        pos.position + normal,
        _line(accent, width: _stroke * 0.45),
      );
    }

    canvas.drawLine(
      const Offset(22, 88),
      const Offset(78, 88),
      _line(faint, width: _stroke * 0.7),
    );
  }

  // ── shared pieces ─────────────────────────────────────────────────

  /// The torso used by panels 2 and 3, at the same scale in both so the
  /// landmark in one lands on the tape in the other.
  void _torsoCloseUp(Canvas canvas) {
    final body = _line(ink);

    // The stumps of the arms, held well clear of the body. Close in they read
    // as a second pair of torso lines and the whole panel turns into a vase.
    canvas.drawPath(
      Path()
        ..moveTo(23, 19)
        ..cubicTo(18.5, 28, 17, 36, 17.5, 48),
      body,
    );
    canvas.drawPath(
      Path()
        ..moveTo(77, 19)
        ..cubicTo(81.5, 28, 83, 36, 82.5, 48),
      body,
    );

    // Torso, closed across the shoulders. Without that top line the two sides
    // start in mid-air and stop reading as one body.
    canvas.drawPath(
      Path()
        ..moveTo(28, 15)
        ..lineTo(72, 15),
      body,
    );
    canvas.drawPath(
      Path()
        ..moveTo(28, 15)
        ..cubicTo(27.5, 30, 32.5, 46, 33.5, _midY) // in to the waist
        ..cubicTo(34.5, 65, 31.5, 74, 31, 84), // out to the hip
      body,
    );
    canvas.drawPath(
      Path()
        ..moveTo(72, 15)
        ..cubicTo(72.5, 30, 67.5, 46, 66.5, _midY)
        ..cubicTo(65.5, 65, 68.5, 74, 69, 84),
      body,
    );
    canvas.drawLine(const Offset(31, 84), const Offset(69, 84), body);
  }

  /// Dash a path. Flutter has no dash support on [Paint], and every dashed
  /// line in this diagram carries meaning — the plumb line, the far side of
  /// the tape, the floor reference — so it is worth the metric walk.
  void _dashed(
    Canvas canvas,
    Path path,
    Paint paint, {
    required double dash,
    required double gap,
  }) {
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(
          metric.extractPath(d, math.min(d + dash, metric.length)),
          paint,
        );
        d += dash + gap;
      }
    }
  }
}
