/// The shared widget kit.
///
/// Layout rules that hold for every widget in here, from the handoff:
///
///   * Flex/grid with `gap` for sibling groups — never margin-per-child.
///   * `start`/`end`, never `left`/`right`. Arabic and Urdu ship in Wave 3 and
///     retrofitting RTL is brutal.
///   * No fixed heights on anything containing text. Bangla runs taller than
///     Latin; German ~35% longer.
///   * `min-width: 0` on flex children holding text, so a long Bangla string
///     ellipsizes rather than blowing the row out.
///   * Focus is a 2px accent outline at 2px offset — never the platform default.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import 'line_icon.dart';

// ── layout primitives ─────────────────────────────────────────────────

/// A vertical group with a real gap. Replaces margin-per-child everywhere.
class VGap extends StatelessWidget {
  const VGap(this.gap, {super.key, required this.children, this.cross});

  final double gap;
  final List<Widget> children;
  final CrossAxisAlignment? cross;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: cross ?? CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: gap,
        children: children,
      );
}

class HGap extends StatelessWidget {
  const HGap(this.gap, {super.key, required this.children, this.cross, this.main});

  final double gap;
  final List<Widget> children;
  final CrossAxisAlignment? cross;
  final MainAxisAlignment? main;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: cross ?? CrossAxisAlignment.center,
        mainAxisAlignment: main ?? MainAxisAlignment.start,
        spacing: gap,
        children: children,
      );
}

/// The standard scrolling screen body: 18px gutter, 128px bottom pad.
class ScreenBody extends StatelessWidget {
  const ScreenBody({
    super.key,
    required this.children,
    this.topPad = 14,
    this.bottomPad = AppSpace.bottomPad,
    this.gap = AppSpace.section,
    this.controller,
  });

  final List<Widget> children;
  final double topPad;
  final double bottomPad;
  final double gap;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) => ListView(
        controller: controller,
        padding: EdgeInsetsDirectional.fromSTEB(
          AppSpace.gutter,
          topPad,
          AppSpace.gutter,
          bottomPad,
        ),
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(height: gap),
            children[i],
          ],
        ],
      );
}

// ── surfaces ──────────────────────────────────────────────────────────

/// The card surface: `--card` fill, a 1px neutral border, and a radius from
/// the 20–30px in-app band.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.radius = 22,
    this.padding = const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
    this.color,
    this.borderColor,
    this.borderWidth = 1,
    this.shadow = false,
    this.dashed = false,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;
  final double borderWidth;
  final bool shadow;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final body = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? c.card,
        borderRadius: BorderRadius.circular(radius),
        border: dashed
            ? null
            : Border.all(
                color: borderColor ?? c.neutral.c300, width: borderWidth),
        boxShadow: shadow ? AppShadow.sm(c.isDark) : null,
      ),
      child: child,
    );
    if (!dashed) return body;
    return CustomPaint(
      painter: _DashedBorder(
        color: borderColor ?? c.accentRamp.c300,
        radius: radius,
        strokeWidth: 1.5,
      ),
      child: body,
    );
  }
}

class _DashedBorder extends CustomPainter {
  _DashedBorder({
    required this.color,
    required this.radius,
    required this.strokeWidth,
  });

  final Color color;
  final double radius;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    const dash = 6.0, gap = 5.0;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(
          metric.extractPath(d, (d + dash).clamp(0, metric.length)),
          paint,
        );
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) => old.color != color;
}

// ── text ──────────────────────────────────────────────────────────────

/// A kicker: 11px, uppercase, wide tracking. Uppercasing is a Latin
/// convention — Bangla has no case, so it is skipped there rather than being
/// applied to no effect.
class Kicker extends StatelessWidget {
  const Kicker(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final isBangla = Directionality.of(context) == TextDirection.ltr &&
        context.s.lang == 'bn';
    return Text(
      isBangla ? text : text.toUpperCase(),
      style: context.t.kicker.copyWith(color: color ?? context.c.neutral.c600),
      textAlign: TextAlign.start,
    );
  }
}

/// A paragraph. Always `text-wrap: pretty`-ish and never height-constrained.
class P extends StatelessWidget {
  const P(this.text, {super.key, this.style, this.color, this.align});

  final String text;
  final TextStyle? style;
  final Color? color;
  final TextAlign? align;

  @override
  Widget build(BuildContext context) => Text(
        text,
        textAlign: align ?? TextAlign.start,
        style: (style ?? context.t.body)
            .copyWith(color: color ?? context.c.neutral.c700),
      );
}

// ── buttons ───────────────────────────────────────────────────────────

/// The full-width pill. `enabled: false` renders grey and, when tapped, calls
/// [onDisabledTap] so the screen can toast the reason — the handoff is explicit
/// that a disabled submit must say why rather than doing nothing.
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    this.onPressed,
    this.onDisabledTap,
    this.enabled = true,
    this.icon,
    this.tone = PillTone.accent,
    this.compact = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final VoidCallback? onDisabledTap;
  final bool enabled;
  final String? icon;
  final PillTone tone;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (bg, fg, border) = switch (tone) {
      PillTone.accent => (c.accent, c.onAccent, null),
      PillTone.pill => (c.pill, c.pillFg, null),
      PillTone.outline => (Colors.transparent, c.text, c.neutral.c400),
      PillTone.card => (c.card, c.text, c.neutral.c300),
      PillTone.safety => (c.safety, c.isDark ? c.bg : const Color(0xFFFFFDF9), null),
    };
    final off = !enabled;

    return _Pressable(
      onTap: off ? onDisabledTap : onPressed,
      borderRadius: AppRadius.rPill,
      hoverColor: tone == PillTone.accent ? null : c.accentRamp.c100,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: 18,
          vertical: compact ? 13 : 16,
        ),
        decoration: BoxDecoration(
          color: off ? c.neutral.c300 : bg,
          borderRadius: AppRadius.rPill,
          border: border == null && !off
              ? null
              : Border.all(color: off ? c.neutral.c300 : border!, width: 1.5),
        ),
        child: HGap(
          9,
          main: MainAxisAlignment.center,
          children: [
            if (icon != null)
              LineIcon(icon!, size: 19, color: off ? c.neutral.c600 : fg),
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: (compact ? context.t.body.copyWith(fontWeight: FontWeight.w700) : context.t.button)
                    .copyWith(color: off ? c.neutral.c600 : fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum PillTone { accent, pill, outline, card, safety }

/// A borderless text button — "Skip", "Later", "Why do we ask?".
class GhostButton extends StatelessWidget {
  const GhostButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color,
  });

  final String label;
  final VoidCallback? onPressed;
  final String? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final fg = color ?? context.c.accentRamp.c700;
    return _Pressable(
      onTap: onPressed,
      borderRadius: AppRadius.rMd,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        // A ghost button appears both as the non-flex child of another Row
        // (the wizard and risk headers, where the incoming width is unbounded
        // and a Flexible child would assert) and as a full-width row of its
        // own (the edge states, where a long Bangla label has to wrap rather
        // than overflow). Which of the two decides how the label is laid out.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final text = Text(
              label,
              style: context.t.caption
                  .copyWith(color: fg, fontWeight: FontWeight.w700),
            );
            return Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 6,
              children: [
                if (icon != null) LineIcon(icon!, size: 16, color: fg),
                if (constraints.hasBoundedWidth)
                  Flexible(child: text)
                else
                  text,
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A circular icon button — the wizard's back chevron, the stepper's −/+.
class CircleIconButton extends StatelessWidget {
  const CircleIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.size = 40,
    this.iconSize = 19,
    this.semanticLabel,
  });

  final String icon;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final off = onPressed == null;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: _Pressable(
        onTap: onPressed,
        borderRadius: AppRadius.rPill,
        hoverColor: c.accentRamp.c100,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: c.card,
            shape: BoxShape.circle,
            border: Border.all(color: c.neutral.c300, width: 1.5),
          ),
          child: Center(
            child: LineIcon(
              icon,
              size: iconSize,
              color: off ? c.neutral.c400 : c.text,
            ),
          ),
        ),
      ),
    );
  }
}

/// A circular chip holding an icon — the disclaimer shield, the safety triangle.
class IconChip extends StatelessWidget {
  const IconChip({
    super.key,
    required this.icon,
    this.size = 52,
    this.bg,
    this.border,
    this.fg,
    this.iconSize,
  });

  final String icon;
  final double size;
  final Color? bg, border, fg;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg ?? c.accentRamp.c100,
        shape: BoxShape.circle,
        border: Border.all(color: border ?? c.accentRamp.c300, width: 1),
      ),
      child: Center(
        child: LineIcon(
          icon,
          size: iconSize ?? size * 0.44,
          color: fg ?? c.accentRamp.c700,
        ),
      ),
    );
  }
}

/// Hover, press and focus, applied uniformly. Focus is the 2px accent outline
/// the handoff asks for; Material's default is invisible on this ground.
class _Pressable extends StatefulWidget {
  const _Pressable({
    required this.child,
    required this.onTap,
    required this.borderRadius,
    this.hoverColor,
  });

  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;
  final Color? hoverColor;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _hover = false, _down = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Focus(
      canRequestFocus: widget.onTap != null,
      onFocusChange: (v) => setState(() => _focused = v),
      child: MouseRegion(
        cursor: widget.onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              borderRadius: widget.borderRadius,
              color: (_hover && widget.hoverColor != null)
                  ? widget.hoverColor
                  : null,
              border: _focused
                  ? Border.all(color: c.accent, width: 2)
                  : null,
            ),
            foregroundDecoration: _down
                ? BoxDecoration(
                    borderRadius: widget.borderRadius,
                    color: c.text.withValues(alpha: 0.06),
                  )
                : null,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

// ── inputs ────────────────────────────────────────────────────────────

/// A labelled field card: 11px uppercase label, then an icon + borderless
/// input. The whole card is the tap target.
class FieldCard extends StatelessWidget {
  const FieldCard({
    super.key,
    required this.label,
    required this.child,
    this.icon,
    this.error,
    this.trailing,
  });

  final String label;
  final Widget child;
  final String? icon;
  final String? error;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bad = error != null && error!.isNotEmpty;
    return VGap(
      6,
      children: [
        AppCard(
          radius: 22,
          borderWidth: 1.5,
          borderColor: bad ? c.caution : c.neutral.c300,
          padding: const EdgeInsets.fromLTRB(16, 11, 16, 13),
          child: VGap(
            4,
            children: [
              Kicker(label),
              HGap(
                10,
                children: [
                  if (icon != null)
                    LineIcon(icon!, size: 17, color: c.accentRamp.c700),
                  Expanded(child: child),
                  if (trailing != null) trailing!,
                ],
              ),
            ],
          ),
        ),
        // Errors say what went wrong AND how to fix it. Caution amber, never
        // safety red — a mistyped email is not a safety event.
        if (bad)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4),
            child: P(error!,
                style: context.t.footnote, color: c.caution),
          ),
      ],
    );
  }
}

/// A borderless text input sized for a [FieldCard].
class BareInput extends StatelessWidget {
  const BareInput({
    super.key,
    required this.controller,
    this.obscure = false,
    this.keyboardType,
    this.hint,
    this.onChanged,
    this.autofillHints,
    this.textInputAction,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final bool obscure;
  final TextInputType? keyboardType;
  final String? hint;
  final ValueChanged<String>? onChanged;
  final Iterable<String>? autofillHints;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      autofillHints: autofillHints,
      textInputAction: textInputAction,
      style: context.t.bodyStrong.copyWith(color: c.text),
      cursorColor: c.accent,
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: EdgeInsets.zero,
        hintText: hint,
        hintStyle: context.t.bodyStrong.copyWith(color: c.neutral.c500),
      ),
    );
  }
}

/// The segmented switcher — Log in / Sign up, cm / in, kg / lb.
class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.compact = false,
  });

  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.neutral.c200,
        borderRadius: AppRadius.rPill,
      ),
      child: Row(
        spacing: 4,
        children: [
          for (final (v, label) in options)
            Expanded(
              child: Semantics(
                selected: v == value,
                button: true,
                child: _Pressable(
                  onTap: () => onChanged(v),
                  borderRadius: AppRadius.rPill,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: EdgeInsets.symmetric(
                        vertical: compact ? 8 : 11, horizontal: 8),
                    decoration: BoxDecoration(
                      color: v == value ? c.card : Colors.transparent,
                      borderRadius: AppRadius.rPill,
                      boxShadow: v == value ? AppShadow.sm(c.isDark) : null,
                    ),
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: context.t.caption.copyWith(
                        fontWeight: FontWeight.w700,
                        color: v == value ? c.text : c.neutral.c600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The tick row. Never pre-ticked — the disclaimer and the Terms both depend
/// on that, and the backend records the version and timestamp of a real tap.
class CheckRow extends StatelessWidget {
  const CheckRow({
    super.key,
    required this.checked,
    required this.onChanged,
    required this.label,
    this.boxed = true,
    this.boxSize = 26,
  });

  final bool checked;
  final ValueChanged<bool> onChanged;
  final String label;
  final bool boxed;
  final double boxSize;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final row = HGap(
      12,
      cross: CrossAxisAlignment.start,
      children: [
        Container(
          width: boxSize,
          height: boxSize,
          decoration: BoxDecoration(
            color: checked ? c.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(boxSize * 0.34),
            border: Border.all(
              color: checked ? c.accent : c.neutral.c400,
              width: 2,
            ),
          ),
          child: checked
              ? Center(
                  child: LineIcon(Icons24.check,
                      size: boxSize * 0.52, color: c.onAccent, strokeWidth: 3.2),
                )
              : null,
        ),
        // min-width: 0 equivalent — the long Bangla Terms string wraps here
        // instead of overflowing the row.
        Expanded(
          child: P(label,
              style: context.t.caption.copyWith(fontWeight: FontWeight.w600),
              color: c.neutral.c700),
        ),
      ],
    );

    return Semantics(
      checked: checked,
      label: label,
      child: ExcludeSemantics(
        child: _Pressable(
          onTap: () => onChanged(!checked),
          borderRadius: BorderRadius.circular(22),
          child: boxed
              ? Container(
                  padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: checked ? c.accentRamp.c300 : c.neutral.c300,
                      width: 1.5,
                    ),
                    color: checked ? c.accentRamp.c100 : Colors.transparent,
                  ),
                  child: row,
                )
              : Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: row,
                ),
        ),
      ),
    );
  }
}

/// A radio-style option row — the population screen and every single-choice
/// wizard question.
class OptionRow<T> extends StatelessWidget {
  const OptionRow({
    super.key,
    required this.value,
    required this.groupValue,
    required this.label,
    required this.onChanged,
    this.sub,
  });

  final T value;
  final T? groupValue;
  final String label;
  final String? sub;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final selected = value == groupValue;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: selected,
      label: sub == null ? label : '$label. $sub',
      child: ExcludeSemantics(
        child: _Pressable(
          onTap: () => onChanged(value),
          borderRadius: BorderRadius.circular(20),
          hoverColor: c.accentRamp.c100,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
            decoration: BoxDecoration(
              color: selected ? c.accentRamp.c100 : c.card,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: selected ? c.accent : c.neutral.c300,
                width: 1.5,
              ),
            ),
            child: HGap(
              12,
              cross: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? c.accent : c.neutral.c400,
                        width: 2,
                      ),
                    ),
                    child: Center(
                      child: Container(
                        width: 11,
                        height: 11,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: selected ? c.accent : Colors.transparent,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: VGap(
                    3,
                    children: [
                      Text(label,
                          style: context.t.bodyStrong.copyWith(color: c.text)),
                      if (sub != null)
                        P(sub!,
                            style: context.t.footnote, color: c.neutral.c600),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A Yes / No pair. Its own widget because eight of the eleven questions are
/// this shape and a generic [Segmented] would lose the semantics.
class YesNo extends StatelessWidget {
  const YesNo({
    super.key,
    required this.value,
    required this.onChanged,
    required this.yes,
    required this.no,
  });

  final bool? value;
  final ValueChanged<bool> onChanged;
  final String yes, no;

  @override
  Widget build(BuildContext context) => HGap(
        9,
        children: [
          Expanded(child: _chip(context, true, yes)),
          Expanded(child: _chip(context, false, no)),
        ],
      );

  Widget _chip(BuildContext context, bool v, String label) {
    final c = context.c;
    final on = value == v;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: on,
      button: true,
      label: label,
      child: ExcludeSemantics(
        child: _Pressable(
          onTap: () => onChanged(v),
          borderRadius: AppRadius.rPill,
          hoverColor: c.accentRamp.c100,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 12),
            decoration: BoxDecoration(
              color: on ? c.accentRamp.c100 : c.card,
              borderRadius: AppRadius.rPill,
              border: Border.all(
                color: on ? c.accent : c.neutral.c300,
                width: 1.5,
              ),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: context.t.bodyStrong.copyWith(
                color: on ? c.accentRamp.c800 : c.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The slider. Track 8px, thumb 24px with a 3px card ring — same spec in the
/// wizard and the what-if simulator, so it lives here once.
class AppSlider extends StatelessWidget {
  const AppSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.semanticFormatter,
    this.label,
  });

  final double value;
  final double min, max;
  final ValueChanged<double> onChanged;
  final int? divisions;
  final String Function(double)? semanticFormatter;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      slider: true,
      label: label,
      value: semanticFormatter?.call(value),
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 8,
          activeTrackColor: c.accent,
          inactiveTrackColor: c.neutral.c300,
          thumbColor: c.accent,
          overlayColor: c.accent.withValues(alpha: 0.14),
          thumbShape: _RingThumb(ring: c.card),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
          trackShape: const RoundedRectSliderTrackShape(),
          tickMarkShape: SliderTickMarkShape.noTickMark,
          showValueIndicator: ShowValueIndicator.never,
        ),
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _RingThumb extends SliderComponentShape {
  const _RingThumb({required this.ring});

  final Color ring;

  @override
  Size getPreferredSize(bool enabled, bool discrete) => const Size(24, 24);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    canvas.drawCircle(
      center,
      12,
      Paint()
        ..color = const Color(0xFF2E2B25).withValues(alpha: 0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.drawCircle(center, 12, Paint()..color = ring);
    canvas.drawCircle(
        center, 9, Paint()..color = sliderTheme.thumbColor ?? ring);
  }
}

// ── disclosure ────────────────────────────────────────────────────────

/// The "Why do we ask?" affordance. Required by App Store guideline 1.4.1 on
/// every health field — not decoration, and never omitted to save space.
class WhyDoWeAsk extends StatefulWidget {
  const WhyDoWeAsk({super.key, required this.body, this.label});

  final String body;
  final String? label;

  @override
  State<WhyDoWeAsk> createState() => _WhyDoWeAskState();
}

class _WhyDoWeAskState extends State<WhyDoWeAsk> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return VGap(
      8,
      cross: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: GhostButton(
            label: widget.label ?? context.s.whyDoWeAsk,
            icon: Icons24.helpCircle,
            onPressed: () => setState(() => _open = !_open),
          ),
        ),
        AnimatedSize(
          duration: AppMotion.riseIn,
          curve: AppMotion.riseCurve,
          alignment: AlignmentDirectional.topStart,
          child: _open
              ? AppCard(
                  radius: 16,
                  color: c.accentRamp.c100,
                  borderColor: c.accentRamp.c300,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  child: P(widget.body,
                      style: context.t.caption.copyWith(height: 1.6),
                      color: c.accentRamp.c900),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// A collapsible row — the caveats list on the risk screen. Collapsible is
/// fine; one tap away is not optional.
class Disclosure extends StatefulWidget {
  const Disclosure({super.key, required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  State<Disclosure> createState() => _DisclosureState();
}

class _DisclosureState extends State<Disclosure> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return AppCard(
      radius: 20,
      padding: EdgeInsets.zero,
      child: VGap(
        0,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            child: _Pressable(
              onTap: () => setState(() => _open = !_open),
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
                child: HGap(
                  10,
                  children: [
                    Expanded(
                      child: Text(widget.label,
                          style: context.t.rowTitle.copyWith(color: c.text)),
                    ),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: AppMotion.riseIn,
                      child: LineIcon(Icons24.chevronDown,
                          size: 18, color: c.neutral.c600),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: AppMotion.riseIn,
            curve: AppMotion.riseCurve,
            alignment: AlignmentDirectional.topStart,
            child: _open
                ? Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(15, 0, 15, 15),
                    child: VGap(9, children: widget.children),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

// ── the persistent bits ───────────────────────────────────────────────

/// The disclaimer footer. Rule 5: visible on every screen showing a risk
/// figure, and never dismissible. There is deliberately no close affordance
/// on this widget at all.
class DisclaimerFooter extends StatelessWidget {
  const DisclaimerFooter({super.key, this.text});

  /// The server's own `disclaimer` string when we have one, so the wording
  /// stays whatever the backend recorded for that assessment.
  final String? text;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      liveRegion: false,
      label: text ?? context.s.riskFooter,
      child: AppCard(
        radius: 18,
        color: c.neutral.c200,
        borderColor: c.neutral.c300,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
        child: P(
          text ?? context.s.riskFooter,
          style: context.t.footnote.copyWith(height: 1.55),
          color: c.neutral.c800,
        ),
      ),
    );
  }
}

/// The offline strip. Quiet and persistent, never a blocking dialog — the
/// estimate still renders from cache, and writes queue.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: c.neutral.c200,
        border: Border(bottom: BorderSide(color: c.neutral.c300)),
      ),
      child: HGap(
        8,
        main: MainAxisAlignment.center,
        children: [
          LineIcon(Icons24.wifiOff, size: 15, color: c.neutral.c700),
          Flexible(
            child: Text(
              context.s.offlineBanner,
              style: context.t.footnote.copyWith(color: c.neutral.c700),
            ),
          ),
        ],
      ),
    );
  }
}

/// Screen-enter motion: `riseIn` — opacity 0→1, translateY 10px→0, 280ms ease.
class RiseIn extends StatefulWidget {
  const RiseIn({super.key, required this.child, this.delay = Duration.zero});

  final Widget child;
  final Duration delay;

  @override
  State<RiseIn> createState() => _RiseInState();
}

class _RiseInState extends State<RiseIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: AppMotion.riseIn,
  );

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _c, curve: AppMotion.riseCurve);
    return AnimatedBuilder(
      animation: curved,
      builder: (_, child) => Opacity(
        opacity: curved.value,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - curved.value)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// A toast. Confirms a side effect in plain language and auto-dismisses at
/// 2600ms, per `design-tokens.json`.
void showToast(BuildContext context, String message) {
  final c = context.c;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: context.t.caption.copyWith(color: c.pillFg),
        ),
        backgroundColor: c.pill,
        behavior: SnackBarBehavior.floating,
        duration: AppMotion.toast,
        margin: const EdgeInsets.fromLTRB(22, 0, 22, 24),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(18)),
        ),
      ),
    );
}
