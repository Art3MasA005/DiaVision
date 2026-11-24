/// 02b · Forgot password.
///
/// Three steps and a confirmation: email → 6-digit code → new password →
/// "Password updated", then back to log in.
///
/// The handoff sends the code by SMS to a phone number. This build signs in
/// with email (see `auth_screen.dart`), so the code goes by email instead;
/// the layout, the step bar, the code boxes and the password rules are the
/// handoff's. Google-only accounts do not exist here, so the handoff's
/// Google note is replaced by the no-lookup promise the screen's rules ask
/// for: the same answer whether or not the email has an account.
///
/// The reset calls go through [PasswordReset] (`data/password_reset.dart`).
/// The server's reasons are said in the screen's own words: a wrong code
/// with the tries left, the 30-minute pause after five, a reset that took
/// too long (back to step 1), and reset being unavailable. "Resend" waits
/// out the server's 60 seconds visibly instead of appearing to send nothing.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../data/api.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/shell.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, this.initialEmail});

  /// Carried over from the log-in form so the user does not type it twice.
  final String? initialEmail;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  /// 1 email · 2 code · 3 new password · 4 done.
  int _step = 1;
  bool _busy = false;
  String? _resetToken;

  /// Seconds until the server will send another code. Mirrors its 60 s rule.
  int _resendIn = 0;
  Timer? _resendTimer;

  void _startResendCountdown() {
    _resendTimer?.cancel();
    setState(() => _resendIn = 60);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _resendIn -= 1);
      if (_resendIn <= 0) t.cancel();
    });
  }

  late final _email = TextEditingController(text: widget.initialEmail ?? '');
  final _code = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();

  @override
  void initState() {
    super.initState();
    for (final c in [_email, _code, _pass, _pass2]) {
      c.addListener(_refresh);
    }
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    _resendTimer?.cancel();
    for (final c in [_email, _code, _pass, _pass2]) {
      c.dispose();
    }
    super.dispose();
  }

  // ── readiness ────────────────────────────────────────────────────────

  bool get _emailOk {
    final e = _email.text.trim();
    return e.contains('@') && e.contains('.') && !e.contains(' ');
  }

  bool get _codeOk => _code.text.length == 6;

  bool get _rule1 => _pass.text.length >= 8;
  bool get _rule2 => RegExp(r'[0-9০-৯]').hasMatch(_pass.text);
  bool get _rule3 => _pass.text.isNotEmpty && _pass.text == _pass2.text;

  bool get _ready => switch (_step) {
        1 => _emailOk,
        2 => _codeOk,
        3 => _rule1 && _rule2 && _rule3,
        _ => true,
      };

  // ── actions ──────────────────────────────────────────────────────────

  void _back() {
    if (_step == 2 || _step == 3) {
      setState(() => _step -= 1);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _next() async {
    final s = context.s;
    if (_step == 4) {
      Navigator.of(context).maybePop();
      return;
    }
    if (!_ready) {
      showToast(context, switch (_step) {
        1 => s.fpToastEmail,
        2 => s.fpToastCode,
        _ => s.fpToastPass,
      });
      return;
    }
    if (_busy) return;

    final reset = AppScope.read(context).passwordReset;
    final email = _email.text.trim();
    setState(() => _busy = true);
    try {
      switch (_step) {
        case 1:
          await reset.requestCode(email);
          if (!mounted) return;
          showToast(context, s.fpToastSent);
          _code.clear();
          _startResendCountdown();
        case 2:
          _resetToken = await reset.verifyCode(email, _code.text);
        case 3:
          await reset.setPassword(_resetToken ?? '', _pass.text);
          if (!mounted) return;
          showToast(context, s.fpToastDone);
          // Nothing on this screen needs the password once it is set.
          _pass.clear();
          _pass2.clear();
          _resetToken = null;
      }
      if (mounted) setState(() => _step += 1);
    } on ApiFailure catch (e) {
      if (!mounted) return;
      showToast(context, _messageFor(e));
      // The reset token is gone or stale: only a new code can help now.
      if (e is ServerFailure && e.message == 'invalid_reset_token') {
        setState(() {
          _step = 1;
          _resetToken = null;
          _code.clear();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    if (_busy || _resendIn > 0) return;
    final s = context.s;
    try {
      await AppScope.read(context).passwordReset.requestCode(_email.text.trim());
      if (!mounted) return;
      showToast(context, s.fpToastResent);
      _startResendCountdown();
    } on ApiFailure catch (e) {
      if (mounted) showToast(context, _messageFor(e));
    }
  }

  String _messageFor(ApiFailure e) {
    final s = context.s;
    if (e is NetworkFailure) return s.errNetwork;
    if (e is! ServerFailure) return s.errServer;
    final left = e.extra?['attempts_left'];
    return switch (e.message) {
      'reset_unavailable' => s.fpUnavailable,
      'invalid_code' =>
        s.fpBadCode(left is int ? context.n.digits('$left') : null),
      'too_many_attempts' => s.fpLocked,
      'invalid_reset_token' => s.fpExpired,
      _ => s.errServer,
    };
  }

  // ── build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final done = _step == 4;

    return Shell(
      child: ScreenBody(
        topPad: 14,
        bottomPad: 40,
        gap: 0,
        children: [
          _header(c, s),
          if (!done) ...[
            const SizedBox(height: 26),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: IconChip(
                icon: switch (_step) {
                  1 => Icons24.key,
                  2 => Icons24.message,
                  _ => Icons24.lock,
                },
                size: 56,
                iconSize: 24,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              switch (_step) { 1 => s.fp1Head, 2 => s.fp2Head, _ => s.fp3Head },
              style: context.t.screenTitle.copyWith(color: c.text),
            ),
            const SizedBox(height: 7),
            P(switch (_step) { 1 => s.fp1Sub, 2 => s.fp2Sub, _ => s.fp3Sub }),
          ],
          if (_step == 1) ...[const SizedBox(height: 18), _emailStep(s)],
          if (_step == 2) _codeStep(c, s),
          if (_step == 3) ...[const SizedBox(height: 18), _passwordStep(c, s)],
          if (done) _doneStep(c, s),
          const SizedBox(height: 20),
          _busy
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: SizedBox.square(
                      dimension: 26,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.6, color: c.accent),
                    ),
                  ),
                )
              : PillButton(
                  label: switch (_step) {
                    1 => s.fp1Cta,
                    2 => s.fp2Cta,
                    3 => s.fp3Cta,
                    _ => s.fp4Cta,
                  },
                  enabled: _ready,
                  onPressed: _next,
                  onDisabledTap: _next,
                ),
          if (_step == 1) ...[
            const SizedBox(height: 16),
            AppCard(
              radius: 18,
              color: c.neutral.c200,
              borderColor: c.neutral.c300,
              child: P(s.fp1Note,
                  style: context.t.footnote, color: c.neutral.c800),
            ),
          ],
        ],
      ),
    );
  }

  /// Back button, then — until the flow is done — the step label and a
  /// three-segment progress bar.
  Widget _header(AppColors c, dynamic s) => HGap(
        12,
        children: [
          CircleIconButton(
            icon: Icons24.chevronLeft,
            size: 42,
            semanticLabel: _step == 2 || _step == 3 ? s.back : s.fpBack,
            onPressed: _back,
          ),
          if (_step < 4)
            Expanded(
              child: VGap(
                6,
                cross: CrossAxisAlignment.start,
                children: [
                  Kicker(s.fpStepLabel(
                      context.n.digits('$_step'), context.n.digits('3'))),
                  Row(
                    spacing: 6,
                    children: [
                      for (var i = 1; i <= 3; i++)
                        Expanded(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            height: 5,
                            decoration: BoxDecoration(
                              color: i <= _step ? c.accent : c.neutral.c300,
                              borderRadius: AppRadius.rPill,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      );

  Widget _emailStep(dynamic s) => FieldCard(
        label: s.fieldEmail,
        icon: Icons24.mail,
        child: BareInput(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _next(),
        ),
      );

  Widget _codeStep(AppColors c, dynamic s) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 6),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                _email.text.trim(),
                style: context.t.bodyStrong
                    .copyWith(color: c.text, fontWeight: FontWeight.w700),
              ),
              GhostButton(
                label: s.fp2Change,
                onPressed: () => setState(() {
                  _step = 1;
                  _code.clear();
                }),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Kicker(s.fp2Label),
          const SizedBox(height: 8),
          _CodeBoxes(controller: _code, label: s.fp2Label),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(s.fp2Resend,
                  style: context.t.caption.copyWith(color: c.neutral.c700)),
              GhostButton(
                label: _resendIn > 0
                    ? s.fpResendIn(context.n.digits('$_resendIn'))
                    : s.fp2ResendBtn,
                onPressed: _resendIn > 0 ? null : _resend,
              ),
            ],
          ),
        ],
      );

  Widget _passwordStep(AppColors c, dynamic s) => VGap(
        10,
        children: [
          FieldCard(
            label: s.fp3New,
            icon: Icons24.lock,
            child: BareInput(
              controller: _pass,
              obscure: true,
              hint: s.fp3Ph,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.next,
            ),
          ),
          FieldCard(
            label: s.fp3Confirm,
            icon: Icons24.lock,
            child: BareInput(
              controller: _pass2,
              obscure: true,
              hint: s.fp3Ph2,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _next(),
            ),
          ),
          const SizedBox(height: 4),
          _Rule(ok: _rule1, label: s.fp3R1),
          _Rule(ok: _rule2, label: s.fp3R2),
          _Rule(ok: _rule3, label: s.fp3R3),
        ],
      );

  Widget _doneStep(AppColors c, dynamic s) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 56, 6, 8),
        child: Column(
          children: [
            RiseIn(
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: c.accent2Ramp.c100,
                  shape: BoxShape.circle,
                  border: Border.all(color: c.accent2Ramp.c300),
                ),
                child: Center(
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: c.accent2Ramp.c600,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: LineIcon(Icons24.check,
                          size: 30, color: c.onAccent, strokeWidth: 3.5),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 22),
            Text(
              s.fp4Head,
              textAlign: TextAlign.center,
              style: context.t.screenTitle.copyWith(color: c.text),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: P(s.fp4Sub, align: TextAlign.center),
            ),
          ],
        ),
      );
}

/// Six boxes over one invisible field. The field owns the text, the keyboard
/// and autofill ("one-time code"); the boxes only draw it. Bengali digits are
/// accepted and stored as ASCII, because that is what the server compares.
class _CodeBoxes extends StatefulWidget {
  const _CodeBoxes({required this.controller, required this.label});

  final TextEditingController controller;
  final String label;

  @override
  State<_CodeBoxes> createState() => _CodeBoxesState();
}

class _CodeBoxesState extends State<_CodeBoxes> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
    // Arriving on this step means the user is about to type the code.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final code = widget.controller.text;
    final active = code.length < 6 ? code.length : -1;

    return Stack(
      children: [
        ExcludeSemantics(
          child: Row(
            spacing: 8,
            children: [
              for (var i = 0; i < 6; i++)
                Expanded(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    height: 56,
                    decoration: BoxDecoration(
                      color: i < code.length ? c.accentRamp.c100 : c.card,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        width: 1.5,
                        color: i == active && _focus.hasFocus
                            ? c.accent
                            : i < code.length
                                ? c.accentRamp.c300
                                : c.neutral.c300,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      i < code.length ? context.n.digits(code[i]) : '',
                      style: context.t.screenTitle
                          .copyWith(fontSize: 24, color: c.text),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Positioned.fill(
          child: Semantics(
            label: widget.label,
            textField: true,
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              maxLength: 6,
              showCursor: false,
              enableInteractiveSelection: false,
              inputFormatters: [_AsciiDigits(), LengthLimitingTextInputFormatter(6)],
              style: const TextStyle(color: Colors.transparent, fontSize: 1),
              decoration: const InputDecoration(
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                counterText: '',
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Keeps digits only, mapping Bengali ০–৯ to ASCII 0–9.
class _AsciiDigits extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final out = StringBuffer();
    for (final r in newValue.text.runes) {
      if (r >= 0x30 && r <= 0x39) {
        out.writeCharCode(r);
      } else if (r >= 0x09E6 && r <= 0x09EF) {
        out.writeCharCode(0x30 + r - 0x09E6);
      }
    }
    final text = out.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// One password rule: a ring that fills sage with a check once it is met.
class _Rule extends StatelessWidget {
  const _Rule({required this.ok, required this.label});

  final bool ok;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      checked: ok,
      label: label,
      excludeSemantics: true,
      child: HGap(
        10,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ok ? c.accent2Ramp.c600 : Colors.transparent,
              border: Border.all(
                width: 2,
                color: ok ? c.accent2Ramp.c600 : c.neutral.c400,
              ),
            ),
            child: ok
                ? Center(
                    child: LineIcon(Icons24.check,
                        size: 12, color: c.onAccent, strokeWidth: 3.5),
                  )
                : null,
          ),
          Expanded(
            child: Text(
              label,
              style: context.t.caption.copyWith(
                fontWeight: FontWeight.w600,
                color: ok ? c.text : c.neutral.c700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
