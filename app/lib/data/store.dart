/// Local persistence.
///
/// Two stores, split by sensitivity:
///
///   [SecureStore]  tokens only — the keychain / keystore.
///   [PrefsStore]   preferences and the last risk result — plain prefs.
///
/// The last risk result is cached so the result screen still renders with no
/// connection. It is stored with the timestamp the server stamped on it, and
/// the UI says how old it is rather than passing it off as fresh.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class SecureStore {
  SecureStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _kTokens = 'bbd.tokens.v1';

  /// In-memory mirror. Every request reads the token synchronously, and an
  /// async keychain hit per request would be both slow and pointless.
  Tokens? cached;

  Future<Tokens?> load() async {
    try {
      cached = Tokens.decode(await _storage.read(key: _kTokens));
    } catch (_) {
      // A locked or unavailable keystore is not a reason to crash on launch;
      // it just means the user signs in again.
      cached = null;
    }
    return cached;
  }

  Future<void> save(Tokens? tokens) async {
    cached = tokens;
    try {
      if (tokens == null) {
        await _storage.delete(key: _kTokens);
      } else {
        await _storage.write(key: _kTokens, value: tokens.encode());
      }
    } catch (_) {
      // Keep the in-memory copy so the session survives this run.
    }
  }
}

class PrefsStore {
  PrefsStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<PrefsStore> open() async =>
      PrefsStore(await SharedPreferences.getInstance());

  static const _kLang = 'bbd.lang';
  static const _kTheme = 'bbd.theme';
  static const _kLocalDigits = 'bbd.localDigits';
  static const _kProfileId = 'bbd.profileId';
  static const _kLastResult = 'bbd.lastResult';
  static const _kAncestry = 'bbd.ancestry';
  static const _kHeightUnitCm = 'bbd.heightUnitCm';
  static const _kWeightUnitKg = 'bbd.weightUnitKg';

  String? get lang => _prefs.getString(_kLang);
  Future<void> setLang(String v) => _prefs.setString(_kLang, v);

  /// `light` · `dark` · `system`.
  String get themeMode => _prefs.getString(_kTheme) ?? 'system';
  Future<void> setThemeMode(String v) => _prefs.setString(_kTheme, v);

  bool get localDigits => _prefs.getBool(_kLocalDigits) ?? false;
  Future<void> setLocalDigits(bool v) => _prefs.setBool(_kLocalDigits, v);

  String? get profileId => _prefs.getString(_kProfileId);
  Future<void> setProfileId(String? v) async =>
      v == null ? _prefs.remove(_kProfileId) : _prefs.setString(_kProfileId, v);

  bool get heightUnitCm => _prefs.getBool(_kHeightUnitCm) ?? true;
  Future<void> setHeightUnitCm(bool v) => _prefs.setBool(_kHeightUnitCm, v);

  bool get weightUnitKg => _prefs.getBool(_kWeightUnitKg) ?? true;
  Future<void> setWeightUnitKg(bool v) => _prefs.setBool(_kWeightUnitKg, v);

  /// The declared cutoff group. Held client-side because the backend does not
  /// yet persist it — see the gap noted in the app README. `null` means
  /// skipped, which is a real answer here, not an unanswered question.
  AncestryGroup? get ancestry {
    final raw = _prefs.getString(_kAncestry);
    if (raw == null) return null;
    for (final g in AncestryGroup.values) {
      if (g.wire == raw) return g;
    }
    return null;
  }

  Future<void> setAncestry(AncestryGroup? v) async => v == null
      ? _prefs.remove(_kAncestry)
      : _prefs.setString(_kAncestry, v.wire);

  RiskResult? get lastResult {
    final raw = _prefs.getString(_kLastResult);
    if (raw == null) return null;
    try {
      return RiskResult.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> setLastResult(String rawJson) =>
      _prefs.setString(_kLastResult, rawJson);

  Future<void> clearSession() async {
    await _prefs.remove(_kProfileId);
    await _prefs.remove(_kLastResult);
  }
}
