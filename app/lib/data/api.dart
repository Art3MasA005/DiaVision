/// The HTTP client for the DiaVision API.
///
/// Three responses are BRANCHES, not errors. The handoff is explicit about
/// this, and treating them as failures would put a user in a dead end:
///
///   403 + `medical_disclaimer_required` → route to the disclaimer screen
///   409 + `already_diagnosed`           → route to management, not the risk screen
///   403/409 + `safety_card`             → show the safety card; the value WAS recorded
///
/// They surface as typed exceptions ([DisclaimerRequired], [AlreadyDiagnosed],
/// [SafetyIntercept]) so a caller has to decide what to do with each one rather
/// than letting it fall into a generic catch.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Where the backend lives. Android emulators cannot reach the host's
/// 127.0.0.1, so they get the well-known alias instead.
String defaultBaseUrl() {
  const override = String.fromEnvironment('API_BASE_URL');
  if (override.isNotEmpty) return override;
  try {
    if (Platform.isAndroid) return 'http://10.0.2.2:8000/api/v1';
  } catch (_) {
    // Platform is unavailable on web; fall through.
  }
  return 'http://127.0.0.1:8000/api/v1';
}

// ── failures ──────────────────────────────────────────────────────────

sealed class ApiFailure implements Exception {
  const ApiFailure(this.message);
  final String message;
  @override
  String toString() => '$runtimeType: $message';
}

/// No connection, DNS failure, timeout. The estimate itself still works —
/// this is a quiet banner, never a blocking dialog.
class NetworkFailure extends ApiFailure {
  const NetworkFailure([super.message = 'offline']);
}

/// 4xx/5xx that is not one of the three branches. [detail] is the server's own
/// sentence where it gave one, because it usually says what to do.
class ServerFailure extends ApiFailure {
  const ServerFailure(this.status, super.message, {this.detail, this.extra});
  final int status;
  final String? detail;

  /// The rest of a structured error body (`attempts_left`, ...), when the
  /// server sent one.
  final Map<String, dynamic>? extra;
}

class Unauthorized extends ApiFailure {
  const Unauthorized([super.message = 'unauthorized']);
}

/// 403 `medical_disclaimer_required`. Route to the disclaimer screen.
class DisclaimerRequired extends ApiFailure {
  const DisclaimerRequired(this.requiredVersion, super.message);
  final String requiredVersion;
}

/// 409 `already_diagnosed`. Route to management — this is a branch in the
/// product, not a failure the user caused.
class AlreadyDiagnosed extends ApiFailure {
  const AlreadyDiagnosed(super.message);
}

/// A red flag fired. The value WAS recorded; the card replaces the response.
class SafetyIntercept extends ApiFailure {
  const SafetyIntercept(this.card, {required this.recorded})
      : super('safety_card');
  final SafetyCard card;
  final bool recorded;
}

// ── client ────────────────────────────────────────────────────────────

typedef TokenReader = Tokens? Function();
typedef TokenWriter = Future<void> Function(Tokens?);

class Api {
  Api({
    String? baseUrl,
    http.Client? client,
    required this.readTokens,
    required this.writeTokens,
  })  : baseUrl = baseUrl ?? defaultBaseUrl(),
        _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;
  final TokenReader readTokens;
  final TokenWriter writeTokens;

  static const _timeout = Duration(seconds: 12);

  /// Set by [get]/[post] on every completed round trip, so the offline banner
  /// reflects what actually happened rather than a periodic ping.
  bool lastCallReachedServer = true;

  Future<Map<String, String>> _headers({bool auth = true}) async {
    final h = {'content-type': 'application/json'};
    if (auth) {
      final t = readTokens();
      if (t != null) h['authorization'] = 'Bearer ${t.accessToken}';
    }
    return h;
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    bool auth = true,
    bool allowRetryAfterRefresh = true,
    Duration? timeout,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    http.Response res;
    try {
      final headers = await _headers(auth: auth);
      final encoded = body == null ? null : jsonEncode(body);
      final future = switch (method) {
        'GET' => _client.get(uri, headers: headers),
        'POST' => _client.post(uri, headers: headers, body: encoded),
        'PUT' => _client.put(uri, headers: headers, body: encoded),
        'PATCH' => _client.patch(uri, headers: headers, body: encoded),
        'DELETE' => _client.delete(uri, headers: headers, body: encoded),
        _ => throw ArgumentError('unsupported method $method'),
      };
      res = await future.timeout(timeout ?? _timeout);
      lastCallReachedServer = true;
    } on TimeoutException {
      lastCallReachedServer = false;
      throw const NetworkFailure('timeout');
    } on http.ClientException catch (e) {
      lastCallReachedServer = false;
      throw NetworkFailure(e.message);
    } on SocketException catch (e) {
      lastCallReachedServer = false;
      throw NetworkFailure(e.message);
    }

    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (res.body.isEmpty) return null;
      try {
        return jsonDecode(utf8.decode(res.bodyBytes));
      } on FormatException catch (e) {
        // A 200 that is not the JSON we expected — a captive portal, a proxy
        // error page, a version skew. Surfacing it as a typed failure means
        // every caller's existing `on ApiFailure` handles it, instead of a
        // raw TypeError taking the screen down.
        throw ServerFailure(res.statusCode, 'malformed_response',
            detail: e.message);
      }
    }

    // One silent refresh, then give up. A refresh loop on a dead token would
    // hammer the server and still land the user on the same screen.
    if (res.statusCode == 401 && auth && allowRetryAfterRefresh) {
      if (await _tryRefresh()) {
        return _send(method, path,
            body: body,
            auth: auth,
            allowRetryAfterRefresh: false,
            timeout: timeout);
      }
      await writeTokens(null);
      throw const Unauthorized();
    }

    throw _decodeFailure(res);
  }

  ApiFailure _decodeFailure(http.Response res) {
    dynamic detail;
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      detail = decoded is Map ? decoded['detail'] : decoded;
    } catch (_) {
      detail = null;
    }

    if (detail is Map) {
      final card = detail['safety_card'];
      if (card is Map) {
        return SafetyIntercept(
          SafetyCard.fromJson(card.cast<String, dynamic>()),
          recorded: detail['recorded'] as bool? ?? true,
        );
      }
      final reason = detail['reason'];
      final message = '${detail['message'] ?? ''}';
      if (reason == 'medical_disclaimer_required') {
        return DisclaimerRequired(
            '${detail['required_version'] ?? ''}', message);
      }
      if (reason == 'already_diagnosed') {
        return AlreadyDiagnosed(message);
      }
    }

    if (res.statusCode == 401) return const Unauthorized();

    // FastAPI validation errors arrive as a list of objects; the first `msg`
    // is the useful half.
    String? text;
    if (detail is String) {
      text = detail;
    } else if (detail is List && detail.isNotEmpty) {
      final first = detail.first;
      if (first is Map) text = '${first['msg'] ?? ''}';
    }
    // A `reason` is the server's machine-readable code; screens that know it
    // say it in their own words. Otherwise the status is all there is.
    final reason = detail is Map ? detail['reason'] : null;
    return ServerFailure(
        res.statusCode, reason is String ? reason : 'http_${res.statusCode}',
        detail: text, extra: detail is Map ? detail.cast<String, dynamic>() : null);
  }

  Future<bool> _tryRefresh() async {
    final t = readTokens();
    if (t == null) return false;
    try {
      final res = await _client
          .post(
            Uri.parse('$baseUrl/auth/refresh'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'refresh_token': t.refreshToken}),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return false;
      await writeTokens(
          Tokens.fromJson(jsonDecode(res.body) as Map<String, dynamic>));
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── auth ────────────────────────────────────────────────────────────

  Future<Tokens> signup({
    required String email,
    required String password,
    required String displayName,
    required String region,
    required String locale,
    required bool acceptTerms,
  }) async {
    final json = await _send('POST', '/auth/signup', auth: false, body: {
      'email': email,
      'password': password,
      'display_name': displayName,
      'region': region,
      'locale': locale,
      // Terms only. The medical disclaimer is a SEPARATE consent record made
      // on its own blocking screen — never bundle the two.
      'accept_terms': acceptTerms,
    });
    return Tokens.fromJson(json as Map<String, dynamic>);
  }

  Future<Tokens> login({required String email, required String password}) async {
    final json = await _send('POST', '/auth/login',
        auth: false, body: {'email': email, 'password': password});
    return Tokens.fromJson(json as Map<String, dynamic>);
  }

  Future<Account> me() async =>
      Account.fromJson(await _send('GET', '/me') as Map<String, dynamic>);

  // ── password reset (see data/password_reset.dart) ───────────────────

  Future<void> requestPasswordReset(String email) => _send(
      'POST', '/auth/password/reset-request',
      auth: false, body: {'email': email});

  Future<String> verifyPasswordReset(String email, String code) async {
    final json = await _send('POST', '/auth/password/reset-verify',
        auth: false, body: {'email': email, 'code': code});
    return (json as Map<String, dynamic>)['reset_token'] as String;
  }

  Future<void> setPasswordWithReset(String resetToken, String newPassword) =>
      _send('POST', '/auth/password/reset',
          auth: false,
          body: {'reset_token': resetToken, 'new_password': newPassword});

  // ── consent ─────────────────────────────────────────────────────────

  Future<void> recordConsent(String kind, {required String locale}) =>
      _send('POST', '/consents', body: {'kind': kind, 'locale': locale});

  Future<ConsentStatus> consentStatus() async => ConsentStatus.fromJson(
      await _send('GET', '/consents/current') as Map<String, dynamic>);

  // ── profiles ────────────────────────────────────────────────────────

  Future<List<Profile>> profiles() async {
    final json = await _send('GET', '/profiles') as List;
    return json
        .map((e) => Profile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> putHealthProfile(String profileId, HealthProfile body) =>
      _send('PUT', '/profiles/$profileId/health', body: body.toJson());

  // ── risk ────────────────────────────────────────────────────────────

  Future<RiskResult> assess(String profileId, {String? region}) async {
    final json = await _send('POST', '/risk/assess', body: {
      'profile_id': profileId,
      if (region != null) 'region': region,
    });
    return RiskResult.fromJson(json as Map<String, dynamic>);
  }

  /// Past assessments, newest first. Two points a few weeks apart are what
  /// make a trajectory worth drawing.
  Future<List<RiskHistoryPoint>> riskHistory(String profileId) async {
    final json = await _send(
        'GET', '/risk/history${_qs({'profile_id': profileId})}') as List;
    return json
        .map((e) => RiskHistoryPoint.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── labs ────────────────────────────────────────────────────────────

  Future<void> addLabs(
    String profileId, {
    double? hba1cPercent,
    double? fastingGlucoseMmolL,
  }) =>
      _send('POST', '/labs', body: {
        'profile_id': profileId,
        if (hba1cPercent != null) 'hba1c_percent': hba1cPercent,
        if (fastingGlucoseMmolL != null)
          'fasting_glucose_mmol_l': fastingGlucoseMmolL,
      });

  // ── regions ─────────────────────────────────────────────────────────

  Future<RegionPack> regionPack(String code) async {
    final json = await _send('GET', '/regions/$code/pack', auth: false);
    return RegionPack.fromJson(json as Map<String, dynamic>);
  }

  // ── vitals, read side ───────────────────────────────────────────────

  Future<List<Vital>> vitals(String profileId,
      {String? type, int days = 30}) async {
    final query = <String, String>{
      'profile_id': profileId,
      'days': '$days',
      if (type != null) 'type': type,
    };
    final json = await _send('GET', '/vitals${_qs(query)}') as List;
    return json.map((e) => Vital.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Records one reading. A glucose value outside the region pack's thresholds
  /// comes back as a [SafetyIntercept] — the value IS still stored, and the
  /// card replaces the normal response.
  Future<void> addVital(
    String profileId, {
    required String type,
    required double value,
    required String unit,
    String? contextTag,
    String? note,
  }) =>
      _send('POST', '/vitals', body: {
        'profile_id': profileId,
        'type': type,
        'value': value,
        'unit': unit,
        if (contextTag != null) 'context_tag': contextTag,
        if (note != null) 'note': note,
      });

  // ── food and meals ──────────────────────────────────────────────────

  Future<List<Food>> searchFoods({String q = '', String region = 'bd'}) async {
    final json = await _send(
        'GET', '/foods${_qs({'q': q, 'region': region})}') as List;
    return json.map((e) => Food.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Meal> logMeal(
    String profileId, {
    required String slot,
    required List<MealItemDraft> items,
    String entryMethod = 'manual',
    String? note,
    DateTime? eatenAt,
  }) async {
    final json = await _send('POST', '/meals', body: {
      'profile_id': profileId,
      'slot': slot,
      'entry_method': entryMethod,
      if (note != null) 'note': note,
      if (eatenAt != null) 'eaten_at': eatenAt.toUtc().toIso8601String(),
      'items': items.map((i) => i.toJson()).toList(),
    });
    return Meal.fromJson(json as Map<String, dynamic>);
  }

  Future<List<Meal>> meals(String profileId, {DateTime? on, int days = 1}) async {
    final json = await _send('GET', '/meals${_qs({
          'profile_id': profileId,
          'days': '$days',
          if (on != null) 'on': _date(on),
        })}') as List;
    return json.map((e) => Meal.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> deleteMeal(String mealId) => _send('DELETE', '/meals/$mealId');

  /// ± on a logged item. The server scales its stored nutrition.
  Future<Meal> updateMealItem(String mealId, String itemId,
      {required double quantity}) async {
    final json = await _send('PATCH', '/meals/$mealId/items/$itemId',
        body: {'quantity': quantity});
    return Meal.fromJson(json as Map<String, dynamic>);
  }

  /// Removes one item; a meal left empty is removed with it.
  Future<void> deleteMealItem(String mealId, String itemId) =>
      _send('DELETE', '/meals/$mealId/items/$itemId');

  /// "Same as yesterday" — copies [from]'s meals (or one [slot]) onto [to].
  /// A 404 means there was nothing to copy.
  Future<List<Meal>> copyMeals(String profileId,
      {required DateTime from, required DateTime to, String? slot}) async {
    final json = await _send('POST', '/meals/copy', body: {
      'profile_id': profileId,
      'from_day': _date(from),
      'to_day': _date(to),
      'slot': ?slot,
    }) as List;
    return json.map((e) => Meal.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Food>> _foodList(String path, String profileId) async {
    final json =
        await _send('GET', '$path${_qs({'profile_id': profileId})}') as List;
    return json.map((e) => Food.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Food>> recentFoods(String profileId) =>
      _foodList('/foods/recent', profileId);

  Future<List<Food>> frequentFoods(String profileId) =>
      _foodList('/foods/frequent', profileId);

  Future<List<Food>> favouriteFoods(String profileId) =>
      _foodList('/foods/favourites', profileId);

  Future<void> setFavourite(String profileId, String foodId, bool on) => _send(
      on ? 'PUT' : 'DELETE',
      '/foods/$foodId/favourite${_qs({'profile_id': profileId})}');

  /// Water for a day: the new total of glasses, not an increment.
  Future<WaterDay> setWater(String profileId,
      {required int glasses, DateTime? on}) async {
    final json = await _send('PUT', '/water', body: {
      'profile_id': profileId,
      'glasses': glasses,
      if (on != null) 'day': _date(on),
    });
    return WaterDay.fromJson(json as Map<String, dynamic>);
  }

  /// The goal sheet. Null resets to the computed goal. The answer is the
  /// target after the §5.4 rails, which may differ from what was asked.
  Future<DailyTarget?> setGoal(String profileId, int? kcal) async {
    final json = await _send('PUT', '/plan/goal',
        body: {'profile_id': profileId, 'kcal': kcal});
    return json == null
        ? null
        : DailyTarget.fromJson(json as Map<String, dynamic>);
  }

  /// Photo recognition. With no [imageBase64] this is a capability probe:
  /// `modelAvailable` says whether the camera path can work right now. With a
  /// photo it returns proposed items — proposals only, nothing is saved.
  ///
  /// The photo is analysed by the vision model and not stored by the server.
  Future<Recognition> recognizeFood(String profileId,
      {String? imageBase64}) async {
    final json = await _send(
      'POST',
      '/food/recognize${_qs({'profile_id': profileId})}',
      body: imageBase64 == null ? null : {'image_base64': imageBase64},
      // A vision model needs longer than an ordinary round trip.
      timeout: imageBase64 == null ? null : const Duration(seconds: 60),
    );
    return Recognition.fromJson(json as Map<String, dynamic>);
  }

  Future<PlanToday> planToday(String profileId, {DateTime? on}) async {
    final json = await _send('GET', '/plan/today${_qs({
          'profile_id': profileId,
          if (on != null) 'on': _date(on),
        })}');
    return _parse(json, PlanToday.fromJson);
  }

  // ── check-ins ───────────────────────────────────────────────────────

  Future<Checkin> submitCheckin(
    String profileId, {
    int? energy,
    double? sleepHours,
    int? mood,
    List<String> symptoms = const [],
    String? note,
  }) async {
    final json = await _send('POST', '/checkins', body: {
      'profile_id': profileId,
      if (energy != null) 'energy': energy,
      if (sleepHours != null) 'sleep_hours': sleepHours,
      if (mood != null) 'mood': mood,
      'symptoms': symptoms,
      if (note != null && note.isNotEmpty) 'note': note,
    });
    return Checkin.fromJson(json as Map<String, dynamic>);
  }

  Future<Checkin?> checkinToday(String profileId) async {
    final json = await _send(
        'GET', '/checkins/today${_qs({'profile_id': profileId})}');
    if (json == null) return null;
    return Checkin.fromJson(json as Map<String, dynamic>);
  }

  // ── activity ────────────────────────────────────────────────────────

  Future<ActivityDay> saveActivity(
    String profileId, {
    required int steps,
    int activeMinutes = 0,
    double? distanceKm,
    DateTime? on,
  }) async {
    final json = await _send('POST', '/activity', body: {
      'profile_id': profileId,
      'steps': steps,
      'active_minutes': activeMinutes,
      if (distanceKm != null) 'distance_km': distanceKm,
      if (on != null) 'activity_on': _date(on),
    });
    return ActivityDay.fromJson(json as Map<String, dynamic>);
  }

  Future<List<ActivityDay>> activity(String profileId, {int days = 7}) async {
    final json = await _send('GET', '/activity${_qs({
          'profile_id': profileId,
          'days': '$days',
        })}') as List;
    return json
        .map((e) => ActivityDay.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── coach ───────────────────────────────────────────────────────────

  /// Sends one turn. A 402 becomes [CoachLimitReached] — a branch to the
  /// paywall, not an error. Safety interceptions are never rate-limited, so
  /// they come back 200 with a card even when the allowance is spent.
  Future<CoachReply> coachSend(String profileId, String message) async {
    try {
      final json = await _send('POST', '/coach/message',
          body: {'profile_id': profileId, 'message': message});
      return CoachReply.fromJson(json as Map<String, dynamic>);
    } on ServerFailure catch (e) {
      if (e.status == 402) throw CoachLimitReached(e.detail ?? '');
      rethrow;
    }
  }

  Future<List<CoachTurn>> coachHistory(String profileId) async {
    final json = await _send(
        'GET', '/coach/history${_qs({'profile_id': profileId})}') as List;
    return json
        .map((e) => CoachTurn.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── insights and reports ────────────────────────────────────────────

  Future<WeeklyInsights> weeklyInsights(String profileId, {int days = 7}) async {
    final json = await _send('GET', '/insights/weekly${_qs({
          'profile_id': profileId,
          'days': '$days',
        })}');
    return _parse(json, WeeklyInsights.fromJson);
  }

  Future<DoctorReport> generateReport(String profileId, {int days = 28}) async {
    final json = await _send('POST', '/reports/generate',
        body: {'profile_id': profileId, 'days': days});
    return DoctorReport.fromJson(json as Map<String, dynamic>);
  }

  // ── billing ─────────────────────────────────────────────────────────

  Future<Plans> billingPlans() async =>
      _parse(await _send('GET', '/billing/plans'), Plans.fromJson);

  Future<Account> subscribe(String planCode) async => Account.fromJson(
      await _send('POST', '/billing/subscribe', body: {'plan_code': planCode})
          as Map<String, dynamic>);

  // ── account ─────────────────────────────────────────────────────────

  Future<Account> updatePreferences({String? locale, Map? unitsPrefs}) async =>
      Account.fromJson(await _send('PATCH', '/me/preferences', body: {
        if (locale != null) 'locale': locale,
        if (unitsPrefs != null) 'units_prefs': unitsPrefs,
      }) as Map<String, dynamic>);

  /// Everything this account holds. Free on every tier — a legal requirement.
  Future<Map<String, dynamic>> exportAccount() async =>
      (await _send('POST', '/me/export')) as Map<String, dynamic>;

  Future<void> deleteAccount(String confirmEmail) =>
      _send('DELETE', '/me${_qs({'confirm_email': confirmEmail})}');

  // ── helpers ─────────────────────────────────────────────────────────

  /// Runs a `fromJson` and turns a shape mismatch into a typed failure.
  ///
  /// Mobile clients outlive the build they were released with: a user on an
  /// old version will meet a payload it was not written for. Without this a
  /// missing key is a raw `TypeError` that takes the screen down; with it,
  /// every caller's existing `on ApiFailure` handles it and shows the error
  /// state that already exists.
  static T _parse<T>(dynamic json, T Function(Map<String, dynamic>) fromJson) {
    try {
      return fromJson((json as Map).cast<String, dynamic>());
    } on ApiFailure {
      rethrow;
    } catch (e) {
      throw ServerFailure(200, 'unexpected_shape', detail: '$e');
    }
  }

  static String _qs(Map<String, String> params) {
    if (params.isEmpty) return '';
    final pairs = params.entries
        .map((e) => '${Uri.encodeQueryComponent(e.key)}='
            '${Uri.encodeQueryComponent(e.value)}');
    return '?${pairs.join('&')}';
  }

  /// A plain calendar date. The server keys days on this rather than on an
  /// instant, so totals do not shift when the user crosses a timezone.
  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  void close() => _client.close();
}
