/// App-wide state: language, theme, units, session, connectivity.
///
/// Deliberately a plain [ChangeNotifier] behind an [InheritedNotifier] rather
/// than a state-management package. The whole surface is nine fields; a
/// dependency here would be more machinery than the problem has.
library;

import 'package:flutter/widgets.dart';

import '../core/numerals.dart';
import '../core/typography.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../data/notifications.dart';
import '../data/password_reset.dart';
import '../data/store.dart';
import '../l10n/strings.dart';

enum AppThemeMode { light, dark, system }

class AppState extends ChangeNotifier {
  AppState({
    required this.api,
    required this.secure,
    required this.prefs,
    PasswordReset? passwordReset,
    Inbox? inbox,
  })  : passwordReset = passwordReset ?? HttpPasswordReset(api),
        inbox = inbox ?? Inbox.sample() {
    // The Home badge reads the inbox through AppScope, so an inbox change has
    // to rebuild whatever depends on app state.
    this.inbox.addListener(notifyListeners);
  }

  final Api api;
  final SecureStore secure;
  final PrefsStore prefs;

  /// Behind an interface so tests and screenshots can walk the flow without
  /// a server — see `data/password_reset.dart`.
  final PasswordReset passwordReset;

  /// Sample-seeded until `GET /notifications` exists — see
  /// `data/notifications.dart`.
  final Inbox inbox;

  // ── language and presentation ───────────────────────────────────────

  String _lang = 'en';
  String get lang => _lang;
  Strings get s => Strings.of(_lang);
  Numerals get n => Numerals(_lang, useLocalDigits: _localDigits);
  Script get script => _lang == 'bn' ? Script.bengali : Script.latin;

  bool _localDigits = false;
  bool get localDigits => _localDigits;

  AppThemeMode _themeMode = AppThemeMode.system;
  AppThemeMode get themeMode => _themeMode;

  bool heightUnitCm = true;
  bool weightUnitKg = true;

  // ── session ─────────────────────────────────────────────────────────

  Account? account;
  Profile? profile;
  RegionPack region = RegionPack.fallbackBd;
  RiskResult? lastResult;
  AncestryGroup? ancestry;

  bool get signedIn => secure.cached != null;
  String get regionCode => account?.homeRegion ?? region.code;

  /// The profile every health call must carry.
  ///
  /// Falls back to the id cached at sign-in, so a session restored without a
  /// network still knows whose record it is. Reading `profile?.id` directly
  /// was the bug behind "the population screen does not advance": on any
  /// launch that restored a saved session, [profile] was null until something
  /// fetched it, and every screen that needed an id silently did nothing.
  String? get profileId => profile?.id ?? prefs.profileId;

  /// True after a call failed to reach the server. Drives the quiet banner —
  /// never a blocking dialog, because the app still does useful work offline.
  bool offline = false;

  // ── bootstrap ───────────────────────────────────────────────────────

  Future<void> load(String deviceLocale) async {
    await secure.load();

    // Bangla is the default when the device locale is `bn`, per the spec —
    // but an explicit choice always wins over the device.
    _lang = prefs.lang ?? (deviceLocale.startsWith('bn') ? 'bn' : 'en');
    _localDigits = prefs.localDigits;
    _themeMode = switch (prefs.themeMode) {
      'light' => AppThemeMode.light,
      'dark' => AppThemeMode.dark,
      _ => AppThemeMode.system,
    };
    heightUnitCm = prefs.heightUnitCm;
    weightUnitKg = prefs.weightUnitKg;
    ancestry = prefs.ancestry;
    lastResult = prefs.lastResult;

    // Cold start must not depend on the network. The pack is a nicety; the
    // hard-coded Bangladesh fallback carries the emergency number either way.
    unawaited(_loadRegionPack());
    notifyListeners();
  }

  Future<void> _loadRegionPack() async {
    try {
      region = await api.regionPack(regionCode);
      offline = false;
    } on ApiFailure {
      offline = !api.lastCallReachedServer;
    }
    notifyListeners();
  }

  // ── mutations ───────────────────────────────────────────────────────

  Future<void> setLang(String value) async {
    if (_lang == value) return;
    _lang = value;
    await prefs.setLang(value);
    notifyListeners();
  }

  Future<void> setLocalDigits(bool value) async {
    _localDigits = value;
    await prefs.setLocalDigits(value);
    notifyListeners();
  }

  Future<void> setThemeMode(AppThemeMode value) async {
    _themeMode = value;
    await prefs.setThemeMode(value.name);
    notifyListeners();
  }

  Future<void> setUnits({bool? heightCm, bool? weightKg}) async {
    if (heightCm != null) {
      heightUnitCm = heightCm;
      await prefs.setHeightUnitCm(heightCm);
    }
    if (weightKg != null) {
      weightUnitKg = weightKg;
      await prefs.setWeightUnitKg(weightKg);
    }
    notifyListeners();
  }

  Future<void> setAncestry(AncestryGroup? value) async {
    ancestry = value;
    await prefs.setAncestry(value);
    notifyListeners();
  }

  void markOffline(bool value) {
    if (offline == value) return;
    offline = value;
    notifyListeners();
  }

  /// Called after signup or login. Fetches the account and its self profile so
  /// every later health call can carry an explicit `profile_id` — the server
  /// never infers it from the session.
  Future<void> onAuthenticated(Tokens tokens) async {
    await secure.save(tokens);
    await restoreSession();
    if (account != null) unawaited(_loadRegionPack());
  }

  /// Re-fetch the account and profile for an already-valid token.
  ///
  /// [load] deliberately does not do this — cold start must not depend on the
  /// network — so the splash screen calls it once a destination is being
  /// resolved. Without it, a launch that restores a saved session has a token
  /// but no profile, and every health screen quietly has nothing to act on.
  ///
  /// Failure is not fatal: [profileId] falls back to the cached id, so the app
  /// still works offline with the last known profile.
  Future<void> restoreSession() async {
    if (!signedIn) return;
    try {
      account = await api.me();
      final list = await api.profiles();
      if (list.isNotEmpty) {
        profile = list.first;
        await prefs.setProfileId(profile!.id);
      }
      offline = false;
    } on ApiFailure catch (e) {
      offline = e is NetworkFailure;
    }
    notifyListeners();
  }

  /// Switch which family member's record the app is reading and writing.
  ///
  /// The home header's avatar is the only way in, and the id is persisted so
  /// the next cold start opens on the same person rather than silently
  /// reverting to whoever `GET /profiles` happens to list first. The cached
  /// result belongs to the old profile, so it is dropped rather than shown
  /// under a new name.
  Future<void> setProfile(Profile value) async {
    if (profile?.id == value.id) return;
    profile = value;
    lastResult = null;
    await prefs.setProfileId(value.id);
    await prefs.clearLastResult();
    notifyListeners();
  }

  Future<void> saveResult(RiskResult result) async {
    lastResult = result;
    await prefs.setLastResult(result.encode());
    notifyListeners();
  }

  Future<void> signOut() async {
    await secure.save(null);
    await prefs.clearSession();
    account = null;
    profile = null;
    lastResult = null;
    notifyListeners();
  }
}

/// Fire-and-forget without importing dart:async at every call site.
void unawaited(Future<void> f) {
  f.catchError((_) {});
}

/// Provides [AppState] and rebuilds the tree when it changes.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing above this widget');
    return scope!.notifier!;
  }

  /// Reads the state without subscribing — for callbacks, not for build().
  static AppState read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing above this widget');
    return scope!.notifier!;
  }
}
