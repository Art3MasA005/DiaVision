/// Password reset: email → 6-digit code → new password.
///
/// Backed by `POST /auth/password/reset-request`, `/reset-verify` and
/// `/reset` (backend/app/api/password_reset.py). The server keeps the rules
/// the handoff sets for screen "forgot":
///
///   * the same answer whether or not the email has an account, so the
///     screen cannot be used to look people up;
///   * the code expires after 10 minutes; 5 wrong tries pause reset for 30;
///   * a new code goes out at most once every 60 seconds;
///   * a successful reset signs out every other session.
///
/// Failures arrive as [ServerFailure] whose `message` is the server's
/// `reason`: `reset_unavailable`, `invalid_code`, `too_many_attempts` or
/// `invalid_reset_token`. The screen turns those into its own words.
library;

import 'api.dart';

abstract interface class PasswordReset {
  /// Ask for a code to be sent. Completes the same way whether or not
  /// [email] has an account.
  Future<void> requestCode(String email);

  /// Check [code] for [email]. Returns a token that authorises [setPassword].
  Future<String> verifyCode(String email, String code);

  /// Replace the password. The server signs out every other session.
  Future<void> setPassword(String resetToken, String newPassword);
}

/// The real thing.
class HttpPasswordReset implements PasswordReset {
  const HttpPasswordReset(this.api);

  final Api api;

  @override
  Future<void> requestCode(String email) => api.requestPasswordReset(email);

  @override
  Future<String> verifyCode(String email, String code) =>
      api.verifyPasswordReset(email, code);

  @override
  Future<void> setPassword(String resetToken, String newPassword) =>
      api.setPasswordWithReset(resetToken, newPassword);
}

/// For tests and screenshots: accepts any well-formed input after a short,
/// realistic pause, and changes nothing.
class DemoPasswordReset implements PasswordReset {
  const DemoPasswordReset();

  static const _pause = Duration(milliseconds: 600);

  @override
  Future<void> requestCode(String email) => Future<void>.delayed(_pause);

  @override
  Future<String> verifyCode(String email, String code) =>
      Future<String>.delayed(_pause, () => 'demo-reset-token');

  @override
  Future<void> setPassword(String resetToken, String newPassword) =>
      Future<void>.delayed(_pause);
}
