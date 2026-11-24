/// 02 · Log in / Sign up.
///
/// AUTH IS EMAIL + PASSWORD. The design prototype assumes phone + OTP, which
/// is the better long-term fit for this market, but OTP needs a paid SMS
/// provider and that cost is not worth carrying to ship the first slice. The
/// decision is recorded in `docs/ui_spec.md` and is not re-opened here.
///
/// What survives from the prototype's screen 02: the segmented switcher, the
/// field cards, the layout, and the Terms checkbox exactly as designed. What
/// goes: the phone field, "Send me a one-time code", and "Continue with
/// Google" — neither of the last two is wired to anything.
///
/// **Terms and the medical disclaimer are two separate consent records.** The
/// checkbox here maps to `accept_terms` on signup and nothing else; the
/// disclaimer is its own blocking screen with its own row in the database.
/// Bundling them would misrepresent what the user actually agreed to.
///
/// No health question is asked on this screen.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../data/api.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../illustrations/clear_lens_logo.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/shell.dart';

enum _Tab { login, signup }

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  _Tab _tab = _Tab.login;

  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _terms = false;
  bool _busy = false;

  String? _nameError, _emailError, _passwordError, _formError;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _isSignup => _tab == _Tab.signup;

  /// Client-side checks exist to *prevent* a pointless round trip, not to be
  /// the authority. The server validates everything again.
  bool _validate() {
    final s = context.s;
    final email = _email.text.trim();
    setState(() {
      _nameError = _isSignup && _name.text.trim().isEmpty ? s.errNameEmpty : null;
      _emailError = email.isEmpty
          ? s.errEmailEmpty
          : (!email.contains('@') || !email.contains('.'))
              ? s.errEmailShape
              : null;
      _passwordError =
          _password.text.length < 8 && _isSignup ? s.errPasswordShort : null;
      _formError = null;
    });
    return _nameError == null && _emailError == null && _passwordError == null;
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_validate()) return;

    final app = AppScope.read(context);
    setState(() => _busy = true);

    try {
      final tokens = _isSignup
          ? await app.api.signup(
              email: _email.text.trim(),
              password: _password.text,
              displayName: _name.text.trim(),
              region: app.regionCode,
              locale: app.lang,
              // Terms only. The medical disclaimer is the next screen and its
              // own record.
              acceptTerms: _terms,
            )
          : await app.api.login(
              email: _email.text.trim(),
              password: _password.text,
            );

      await app.onAuthenticated(tokens);
      app.markOffline(false);
      if (!mounted) return;

      // Signup goes to the disclaimer; login goes home, unless the disclaimer
      // is still outstanding for this account.
      var destination = _isSignup ? Routes.disclaimer : Routes.home;
      if (!_isSignup) {
        try {
          final status = await app.api.consentStatus();
          if (!status.mayAnswerHealthQuestions) destination = Routes.disclaimer;
        } on ApiFailure {
          // Leave the destination as home; the server refuses health calls
          // and the app routes to the disclaimer when it does.
        }
      }
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil(destination, (_) => false);
    } on ApiFailure catch (e) {
      if (!mounted) return;
      setState(() => _formError = _messageFor(e));
      app.markOffline(e is NetworkFailure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Every error says what went wrong *and* what to do about it.
  String _messageFor(ApiFailure e) {
    final s = context.s;
    return switch (e) {
      NetworkFailure() => s.errNetwork,
      Unauthorized() => s.errCredentials,
      ServerFailure(status: 401) => s.errCredentials,
      ServerFailure(status: 409) => s.errEmailTaken,
      ServerFailure(status: 422, detail: final d?) => d,
      ServerFailure(detail: final d?) when d.isNotEmpty => d,
      _ => s.errServer,
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;

    // On signup the submit is inert until the Terms box is ticked. Tapping it
    // toasts the reason rather than doing nothing.
    final canSubmit = !_isSignup || _terms;

    return Shell(
      showLanguageSwitch: true,
      child: ScreenBody(
        topPad: 8,
        bottomPad: 40,
        gap: 18,
        children: [
          _brandRow(c),
          Segmented<_Tab>(
            value: _tab,
            options: [(_Tab.login, s.tabLogin), (_Tab.signup, s.tabSignup)],
            onChanged: (v) => setState(() {
              _tab = v;
              _formError = null;
              _nameError = _emailError = _passwordError = null;
            }),
          ),
          VGap(
            8,
            children: [
              Text(_isSignup ? s.signupHead : s.loginHead,
                  style: context.t.screenTitle.copyWith(color: c.text)),
              P(_isSignup ? s.signupSub : s.loginSub),
            ],
          ),
          AutofillGroup(
            child: VGap(
              10,
              children: [
                if (_isSignup)
                  FieldCard(
                    label: s.fieldName,
                    icon: Icons24.user,
                    error: _nameError,
                    child: BareInput(
                      controller: _name,
                      autofillHints: const [AutofillHints.name],
                      textInputAction: TextInputAction.next,
                    ),
                  ),
                FieldCard(
                  label: s.fieldEmail,
                  icon: Icons24.mail,
                  error: _emailError,
                  child: BareInput(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    textInputAction: TextInputAction.next,
                  ),
                ),
                FieldCard(
                  label: s.fieldPassword,
                  icon: Icons24.lock,
                  error: _passwordError,
                  child: BareInput(
                    controller: _password,
                    obscure: true,
                    autofillHints: [
                      _isSignup
                          ? AutofillHints.newPassword
                          : AutofillHints.password,
                    ],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => canSubmit ? _submit() : null,
                  ),
                ),
              ],
            ),
          ),
          if (!_isSignup)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: GhostButton(
                label: s.forgotPassword,
                onPressed: () => Navigator.of(context).pushNamed(
                  Routes.forgotPassword,
                  arguments: _email.text.trim(),
                ),
              ),
            ),
          if (_isSignup)
            CheckRow(
              checked: _terms,
              onChanged: (v) => setState(() => _terms = v),
              label: s.termsLabel,
            ),
          if (_formError != null)
            AppCard(
              radius: 18,
              color: c.cautionTint,
              borderColor: c.cautionBorder,
              child: HGap(
                10,
                cross: CrossAxisAlignment.start,
                children: [
                  LineIcon(Icons24.infoCircle, size: 18, color: c.caution),
                  Expanded(
                    child: P(_formError!,
                        style: context.t.caption, color: c.caution),
                  ),
                ],
              ),
            ),
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
                  label: _isSignup ? s.ctaSignup : s.ctaLogin,
                  enabled: canSubmit,
                  onPressed: _submit,
                  onDisabledTap: () => showToast(context, s.toastAcceptTerms),
                ),
          AppCard(
            radius: 18,
            color: c.neutral.c200,
            borderColor: c.neutral.c300,
            child: P(s.authFootnote,
                style: context.t.footnote, color: c.neutral.c700),
          ),
        ],
      ),
    );
  }

  Widget _brandRow(dynamic c) => HGap(
        12,
        children: [
          // The Clear Lens tile, lifted with shadow-sm as in the handoff.
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: AppShadow.sm(c.isDark),
            ),
            child: const ClearLensLogo(size: 46),
          ),
          Expanded(
            child: VGap(
              2,
              cross: CrossAxisAlignment.start,
              children: [
                Text(context.s.appName,
                    style: context.t.cardTitle.copyWith(color: c.text)),
                Text(
                  context.s.authKicker,
                  style: context.t.footnote.copyWith(
                    color: c.neutral.c600,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
}
