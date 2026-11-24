/// Lucide-style line icons, drawn from the same SVG path data the design
/// prototype uses (`RAW` in `DiaVision App.dc.html`).
///
/// Drawn rather than shipped as a font: an icon font cannot be mirrored per
/// glyph under RTL, and the handoff needs directional glyphs to flip while
/// symmetrical ones stay put. [LineIcon.flipForRtl] marks the directional ones.
///
/// Every icon inherits stroke-width 2.75 with round caps and joins, on a 24×24
/// viewBox, straight from `design-tokens.json`.
library;

import 'package:flutter/widgets.dart';

import '../../core/tokens.dart';

class Icons24 {
  Icons24._();

  static const activity = 'M3 12h4l2-4 3 8 2.5-5 1.5 3h5';
  static const shieldCheck =
      'M12 3l7 3v6c0 4.2-2.9 7.6-7 9-4.1-1.4-7-4.8-7-9V6z|m9 12 2 2 4-4';
  static const user = 'M12 4.4a3.6 3.6 0 1 1 0 7.2 3.6 3.6 0 0 1 0-7.2|'
      'M5 20c0-3.6 3.1-6 7-6s7 2.4 7 6';
  static const mail = 'M3.5 6.5h17v11h-17z|m3.5 7 8.5 6 8.5-6';
  static const lock =
      'M4.5 10.5h15v10a0 0 0 0 1 0 0h-15a0 0 0 0 1 0 0z|M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5';
  static const helpCircle = 'M12 3a9 9 0 1 1 0 18 9 9 0 0 1 0-18|'
      'M9.6 9.4a2.5 2.5 0 1 1 3.3 2.4c-.6.2-.9.7-.9 1.3v.4|M12 17h.01';
  static const infoCircle =
      'M12 3a9 9 0 1 1 0 18 9 9 0 0 1 0-18|M12 16v-4|M12 8h.01';
  static const check = 'm5 12.5 4.5 4.5L19 7.5';
  static const checkCheck = 'M18 7 9.5 15.5 6 12|m22 7-8.5 8.5-1-1';
  static const close = 'M18 6 6 18|M6 6l12 12';
  static const barChart = 'M4 20V9|M10 20V4|M16 20v-7|M22 20h-20';
  static const bell = 'M10.3 21a1.94 1.94 0 0 0 3.4 0|'
      'M18 8a6 6 0 1 0-12 0c0 7-3 9-3 9h18s-3-2-3-9';
  static const key = 'M8 10.5a4.5 4.5 0 1 1 0 9 4.5 4.5 0 0 1 0-9|'
      'm11.2 11.8 8.8-8.8|M16.5 6.5 19 9|M14 9l2 2';
  static const message =
      'M20.5 12a8.5 8.5 0 0 1-12.4 7.5L4 20.5l1.1-3.9A8.5 8.5 0 1 1 20.5 12Z';
  static const chevronLeft = 'm14.5 5-6.5 7 6.5 7';
  static const chevronRight = 'm9.5 5 6.5 7-6.5 7';
  static const chevronDown = 'm5 9 7 6.5L19 9';
  static const arrowRight = 'M4 12h15|m12.5 5.5 6.5 6.5-6.5 6.5';
  static const wifiOff =
      'M5 12.55a11 11 0 0 1 14 0|M8.5 16.4a6 6 0 0 1 7 0|M2 8.82a16 16 0 0 1 5-3.2|m3 3 18 18';
  static const retry = 'M20.5 12a8.5 8.5 0 1 1-2.5-6L21 9|M21 4v5h-5';
  static const triangleAlert =
      'M10.3 4.3 2.6 18a2 2 0 0 0 1.7 3h15.4a2 2 0 0 0 1.7-3L13.7 4.3a2 2 0 0 0-3.4 0Z|'
      'M12 9.5v4|M12 17.5h.01';
  static const phone = 'M4.5 5.5a2 2 0 0 1 2-2h2l1.5 4-2 1.5a12 12 0 0 0 5.5 '
      '5.5l1.5-2 4 1.5v2a2 2 0 0 1-2 2A15.5 15.5 0 0 1 4.5 5.5Z';
  static const stethoscope =
      'M5 3v6a4 4 0 0 0 8 0V3|M5 3H3.5|M13 3h1.5|M9 13v2a5 5 0 0 0 10 0v-1|'
      'M19 8.5a2.5 2.5 0 1 1 0 5 2.5 2.5 0 0 1 0-5';
  static const globe = 'M12 3a9 9 0 1 1 0 18 9 9 0 0 1 0-18|M3 12h18|'
      'M12 3a15 15 0 0 1 0 18 15 15 0 0 1 0-18';
  static const ruler = 'M3.5 14.5 14.5 3.5l6 6-11 11z|M7 11l2 2|M10 8l2 2|M13 5l2 2';
  static const droplet = 'M12 3c3.5 4 6 6.7 6 10a6 6 0 0 1-12 0c0-3.3 2.5-6 6-10Z';
  static const flask = 'M9.5 3v6.2L4.8 18a2 2 0 0 0 1.7 3h11a2 2 0 0 0 1.7-3'
      'l-4.7-8.8V3|M8 3h8|M6.5 14.5h11';
  static const sliders = 'M4 8h9|M17 8h3|M4 16h4|M12 16h8|'
      'M15 5.5a2.5 2.5 0 1 1 0 5 2.5 2.5 0 0 1 0-5|'
      'M10 13.5a2.5 2.5 0 1 1 0 5 2.5 2.5 0 0 1 0-5';
  static const person = 'M12 4.4a3.6 3.6 0 1 1 0 7.2 3.6 3.6 0 0 1 0-7.2|'
      'M5 20c0-3.6 3.1-6 7-6s7 2.4 7 6';
  static const sun = 'M12 8a4 4 0 1 1 0 8 4 4 0 0 1 0-8|M12 2v2|M12 20v2|'
      'm4.9 4.9 1.4 1.4|m17.7 17.7 1.4 1.4|M2 12h2|M20 12h2|m4.9 19.1 1.4-1.4|'
      'm17.7 6.3 1.4-1.4';
  static const moon = 'M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5Z';
  static const settings = 'M12 8.6a3.4 3.4 0 1 1 0 6.8 3.4 3.4 0 0 1 0-6.8|'
      'M19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 '
      '0-2.7 1.1V21a2 2 0 1 1-4 0v-.1A1.6 1.6 0 0 0 7.1 19.6l-.1.1a2 2 0 1 '
      '1-2.8-2.8l.1-.1A1.6 1.6 0 0 0 3 14.9H3a2 2 0 1 1 0-4h.1A1.6 1.6 0 0 0 '
      '4.3 8.2l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 2.7-1.1V4a2 2 0 1 1 '
      '4 0v.1a1.6 1.6 0 0 0 2.7 1.1l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0 '
      '1.1 2.7H21a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1.1z';
  static const logOut = 'M9 21H6a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3|m16 16 4-4-4-4|M20 12H9';
  static const scale = 'M12 4v16|M7 8h10|M5 8l-2 6h4z|M19 8l-2 6h4z';
  static const heart = 'M12 20s-7-4.4-7-9.5A4.5 4.5 0 0 1 12 7a4.5 4.5 0 0 1 7 3.5C19 15.6 12 20 12 20Z';
  static const clipboard = 'M9 4.5h6v2.5H9z|M15 5.5h2.5v15H6.5v-15H9|M9.5 12h5|M9.5 16h3';

  // ── the five nav destinations ───────────────────────────────────────
  // Traced from the design prototype's own `RAW` icon set, so the pill reads
  // exactly as designed rather than borrowing approximate glyphs.

  static const navHome = 'M4 10.5 12 4l8 6.5V20a1 1 0 0 1-1 1h-4v-6H9v6H5a1 1 0 0 1-1-1z';
  static const navBowl = 'M3 11h18a9 9 0 0 1-18 0Z|'
      'M8 7c0-1.5 1-2 1-3M12 7c0-1.5 1-2 1-3M16 7c0-1.5 1-2 1-3';
  static const navCamera =
      'M3 8.5A2 2 0 0 1 5 6.5h2l1.5-2h7L17 6.5h2a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z|'
      'M12 9.4a3.6 3.6 0 1 1 0 7.2 3.6 3.6 0 0 1 0-7.2';
  static const navWalk = 'M13 3v6l5 2-2 10|M8 21v-5l-3-3 1-6 4-2|'
      'M16 2.4a1.6 1.6 0 1 1 0 3.2 1.6 1.6 0 0 1 0-3.2';
  static const navChat = 'M21 12a8 8 0 0 1-11.4 7.2L4 21l1.8-5.6A8 8 0 1 1 21 12Z';

  // The camera flow (Lucide: image, search, zap, refresh-cw, plus, sparkles).
  static const image = 'M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z|'
      'M9 7a2 2 0 1 1 0 4 2 2 0 0 1 0-4|m21 15-3.1-3.1a2 2 0 0 0-2.8 0L6 21';
  static const search = 'M11 3a8 8 0 1 1 0 16 8 8 0 0 1 0-16|m21 21-4.3-4.3';
  static const zap = 'M13 2 3 14h9l-1 8 10-12h-9l1-8z';
  static const flipCamera = 'M3 12a9 9 0 0 1 15-6.7L21 8|M21 3v5h-5|'
      'M21 12a9 9 0 0 1-15 6.7L3 16|M8 16H3v5';
  static const plus = 'M12 5v14|M5 12h14';
  static const minus = 'M5 12h14';
  static const star = 'M12 2.8l2.85 5.78 6.38.93-4.62 4.5 1.09 6.35L12 17.36l-5.7 3 1.09-6.35-4.62-4.5 6.38-.93z';
  static const sparkles =
      'M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z|M19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z';

  /// Icons that must mirror under RTL. Symmetrical glyphs are left alone —
  /// flipping a droplet or a globe is noise, not localization.
  static const directional = {
    chevronLeft,
    chevronRight,
    arrowRight,
    logOut,
  };
}

class LineIcon extends StatelessWidget {
  const LineIcon(
    this.path, {
    super.key,
    this.size = 20,
    required this.color,
    this.strokeWidth = AppIcon.strokeWidth,
    this.fill,
  });

  /// One or more 24×24 SVG subpaths, joined by `|`.
  final String path;
  final double size;
  final Color color;
  final double strokeWidth;

  /// Only the check inside a filled chip uses this; every other icon is a
  /// stroke, per the Lucide setting in `design-tokens.json`.
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final flip = rtl && Icons24.directional.contains(path);
    return SizedBox.square(
      dimension: size,
      child: Transform.scale(
        scaleX: flip ? -1 : 1,
        child: CustomPaint(
          painter: _LinePainter(
            path: path,
            color: color,
            strokeWidth: strokeWidth,
            fill: fill,
          ),
        ),
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.path,
    required this.color,
    required this.strokeWidth,
    this.fill,
  });

  final String path;
  final Color color;
  final double strokeWidth;
  final Color? fill;

  static final _cache = <String, Path>{};

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24.0;
    canvas.save();
    canvas.scale(scale);

    for (final segment in path.split('|')) {
      final p = _cache.putIfAbsent(segment, () => _parse(segment));
      if (fill != null) {
        canvas.drawPath(p, Paint()..color = fill!..style = PaintingStyle.fill);
      }
      canvas.drawPath(
        p,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = AppIcon.cap
          ..strokeJoin = AppIcon.join,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.color != color || old.path != path || old.fill != fill;

  // ── a small SVG path parser ─────────────────────────────────────────
  //
  // Covers M m L l H h V v C c S s A a Z z — the subset Lucide emits. Not a
  // general SVG implementation, and it does not need to be.

  static Path _parse(String d) {
    final path = Path();
    final tokens = RegExp(r'([MmLlHhVvCcSsAaZz])|(-?\d*\.?\d+(?:e-?\d+)?)')
        .allMatches(d)
        .map((m) => m.group(0)!)
        .toList();

    var i = 0;
    var cx = 0.0, cy = 0.0, sx = 0.0, sy = 0.0;
    var lastCtrlX = 0.0, lastCtrlY = 0.0;
    String? cmd;

    double num_() => double.parse(tokens[i++]);
    bool isCmd(String t) => RegExp(r'^[MmLlHhVvCcSsAaZz]$').hasMatch(t);

    while (i < tokens.length) {
      if (isCmd(tokens[i])) {
        cmd = tokens[i++];
      } else if (cmd == null) {
        i++;
        continue;
      } else if (cmd == 'M') {
        cmd = 'L';
      } else if (cmd == 'm') {
        cmd = 'l';
      }

      switch (cmd) {
        case 'M':
          cx = num_();
          cy = num_();
          sx = cx;
          sy = cy;
          path.moveTo(cx, cy);
        case 'm':
          cx += num_();
          cy += num_();
          sx = cx;
          sy = cy;
          path.moveTo(cx, cy);
        case 'L':
          cx = num_();
          cy = num_();
          path.lineTo(cx, cy);
        case 'l':
          cx += num_();
          cy += num_();
          path.lineTo(cx, cy);
        case 'H':
          cx = num_();
          path.lineTo(cx, cy);
        case 'h':
          cx += num_();
          path.lineTo(cx, cy);
        case 'V':
          cy = num_();
          path.lineTo(cx, cy);
        case 'v':
          cy += num_();
          path.lineTo(cx, cy);
        case 'C':
        case 'c':
          final rel = cmd == 'c';
          final x1 = num_() + (rel ? cx : 0), y1 = num_() + (rel ? cy : 0);
          final x2 = num_() + (rel ? cx : 0), y2 = num_() + (rel ? cy : 0);
          final x = num_() + (rel ? cx : 0), y = num_() + (rel ? cy : 0);
          path.cubicTo(x1, y1, x2, y2, x, y);
          lastCtrlX = x2;
          lastCtrlY = y2;
          cx = x;
          cy = y;
        case 'S':
        case 's':
          final rel = cmd == 's';
          final x1 = 2 * cx - lastCtrlX, y1 = 2 * cy - lastCtrlY;
          final x2 = num_() + (rel ? cx : 0), y2 = num_() + (rel ? cy : 0);
          final x = num_() + (rel ? cx : 0), y = num_() + (rel ? cy : 0);
          path.cubicTo(x1, y1, x2, y2, x, y);
          lastCtrlX = x2;
          lastCtrlY = y2;
          cx = x;
          cy = y;
        case 'A':
        case 'a':
          final rel = cmd == 'a';
          final rx = num_(), ry = num_();
          final rot = num_();
          final largeArc = num_() != 0, sweep = num_() != 0;
          final x = num_() + (rel ? cx : 0), y = num_() + (rel ? cy : 0);
          path.arcToPoint(
            Offset(x, y),
            radius: Radius.elliptical(rx, ry),
            rotation: rot,
            largeArc: largeArc,
            clockwise: sweep,
          );
          cx = x;
          cy = y;
        case 'Z':
        case 'z':
          path.close();
          cx = sx;
          cy = sy;
        default:
          i++;
      }
    }
    return path;
  }
}
