/// 18 · Settings.
///
/// Account, appearance, language, units, notifications, consent, subscription,
/// export and deletion in one place.
///
/// Three rules that are not preferences:
///
///   * **Notifications never carry a health value.** No glucose, weight or risk
///     figure on a lock screen. Said on the screen, because a user cannot
///     otherwise know it.
///   * **Export is free on every tier.** A regulatory requirement, not a
///     premium feature, and the copy says so.
///   * **Deletion needs the account's own email typed back.** A health record
///     removed by a mistyped tap is not recoverable.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../l10n/strings.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/language_sheet.dart';
import '../widgets/line_icon.dart';
import '../widgets/shell.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ConsentStatus? _consents;
  bool _exporting = false;

  // Local until there is a notification service to talk to. Wiring these to a
  // push provider is real work, and a toggle that silently does nothing would
  // be worse than one that is honestly local.
  final _notifications = <String, bool>{
    'checkin': true,
    'meals': true,
    'insights': true,
    'safety': true,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadConsents());
  }

  Future<void> _loadConsents() async {
    final app = AppScope.read(context);
    try {
      final status = await app.api.consentStatus();
      if (mounted) setState(() => _consents = status);
    } on ApiFailure {
      // The rest of the screen works without it.
    }
  }

  Future<void> _export() async {
    if (_exporting) return;
    final app = AppScope.read(context);
    setState(() => _exporting = true);
    try {
      final data = await app.api.exportAccount();
      if (!mounted) return;
      // Handed to the user as a readable summary. Writing a file and invoking
      // a share sheet needs a platform channel; this at least proves the data
      // is theirs and complete.
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: context.c.card,
          title: Text(context.s.settingsExportDone,
              style: context.t.cardTitle.copyWith(color: context.c.text)),
          content: SingleChildScrollView(
            child: Text(
              data.entries
                  .map((e) => '${e.key}: '
                      '${e.value is List ? (e.value as List).length : 1}')
                  .join('\n'),
              style: context.t.caption.copyWith(color: context.c.text),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(context.s.done),
            ),
          ],
        ),
      );
    } on ApiFailure {
      if (mounted) showToast(context, context.s.errNetwork);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _confirmDelete() async {
    final app = AppScope.read(context);
    final controller = TextEditingController();
    final c = context.c;
    final s = context.s;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: c.card,
        title: Text(s.settingsDelete,
            style: context.t.cardTitle.copyWith(color: c.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            P(s.settingsDeleteWarn, style: context.t.caption),
            TextField(
              controller: controller,
              decoration: InputDecoration(hintText: s.settingsDeleteConfirm),
              style: context.t.body.copyWith(color: c.text),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(s.settingsDelete, style: TextStyle(color: c.safety)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    try {
      await app.api.deleteAccount(controller.text.trim());
      await app.signOut();
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil(Routes.auth, (_) => false);
    } on ApiFailure catch (e) {
      if (mounted) {
        showToast(
            context,
            e is ServerFailure && e.detail != null
                ? e.detail!
                : context.s.errServer);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final app = AppScope.of(context);

    return Shell(
      child: Column(
        children: [
          ScreenHeader(title: s.settingsHead),
          Expanded(
            child: ScreenBody(
              topPad: 12,
              bottomPad: 28,
              gap: 20,
              children: [
                _section(c, s.settingsAccount, [
                  _row(c, s.fieldEmail, app.account?.email ?? '—'),
                  _row(c, s.settingsSubscription,
                      app.account?.subscriptionLabel ?? 'free'),
                  _link(c, s.coachUpgrade,
                      () => Navigator.of(context).pushNamed(Routes.paywall)),
                ]),

                _section(c, s.settingsApp, [
                  VGap(
                    8,
                    cross: CrossAxisAlignment.start,
                    children: [
                      Text(s.homeTheme,
                          style: context.t.bodyStrong.copyWith(color: c.text)),
                      Segmented<AppThemeMode>(
                        value: app.themeMode,
                        compact: true,
                        options: [
                          (AppThemeMode.light, s.themeLight),
                          (AppThemeMode.dark, s.themeDark),
                          (AppThemeMode.system, s.themeSystem),
                        ],
                        onChanged: app.setThemeMode,
                      ),
                    ],
                  ),
                  _link(c, '${s.languageLabel} · ${supportedLanguageName(app.lang)}',
                      () => showLanguageSheet(context)),
                  _toggle(c, s.homeNumerals, app.localDigits,
                      app.setLocalDigits),
                ]),

                _section(c, s.settingsUnits, [
                  VGap(
                    8,
                    cross: CrossAxisAlignment.start,
                    children: [
                      Text(s.settingsUnitsWeight,
                          style: context.t.bodyStrong.copyWith(color: c.text)),
                      Segmented<bool>(
                        value: app.weightUnitKg,
                        compact: true,
                        options: const [(true, 'kg'), (false, 'lb')],
                        onChanged: (v) => app.setUnits(weightKg: v),
                      ),
                    ],
                  ),
                  _row(c, s.settingsUnitsGlucose, app.region.glucoseUnit),
                ]),

                _section(c, s.settingsNotifications, [
                  _toggle(c, s.settingsNotifCheckin, _notifications['checkin']!,
                      (v) => setState(() => _notifications['checkin'] = v)),
                  _toggle(c, s.settingsNotifMeals, _notifications['meals']!,
                      (v) => setState(() => _notifications['meals'] = v)),
                  _toggle(c, s.settingsNotifInsights,
                      _notifications['insights']!,
                      (v) => setState(() => _notifications['insights'] = v)),
                  // Safety alerts are not optional.
                  _row(c, s.settingsNotifSafety, s.yes),
                  P(s.settingsNotifRule, style: context.t.footnote),
                ]),

                if (_consents != null)
                  _section(c, s.settingsConsents, [
                    _row(c, s.settingsConsentTerms,
                        _consents!.accepted['terms'] ?? '—'),
                    _row(c, s.settingsConsentDisclaimer,
                        _consents!.accepted['medical_disclaimer'] ?? '—'),
                  ]),

                _section(c, s.settingsDataPrivacy, [
                  P(s.settingsExportNote, style: context.t.footnote),
                  _exporting
                      ? Center(
                          child: CircularProgressIndicator(color: c.accent))
                      : PillButton(
                          label: s.settingsExport,
                          tone: PillTone.card,
                          compact: true,
                          onPressed: _export,
                        ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: GhostButton(
                      label: s.settingsDelete,
                      // The one non-safety-card place the safety colour is
                      // allowed to appear is nowhere — this uses caution.
                      color: c.caution,
                      onPressed: _confirmDelete,
                    ),
                  ),
                ]),

                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: GhostButton(
                    label: s.signOut,
                    icon: Icons24.logOut,
                    color: c.neutral.c700,
                    onPressed: () async {
                      final navigator = Navigator.of(context);
                      await app.signOut();
                      if (!mounted) return;
                      navigator.pushNamedAndRemoveUntil(
                          Routes.auth, (_) => false);
                    },
                  ),
                ),

                if (clinicianReviewPending)
                  AppCard(
                    radius: 18,
                    color: c.neutral.c200,
                    borderColor: c.neutral.c300,
                    child: P(
                      'Bangla safety strings are awaiting review by a '
                      'native-speaking clinician.',
                      style: context.t.footnote,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(dynamic c, String title, List<Widget> children) => VGap(
        10,
        children: [
          Kicker(title),
          AppCard(
            radius: 22,
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
            child: VGap(14, children: children),
          ),
        ],
      );

  Widget _row(dynamic c, String label, String value) => HGap(
        12,
        children: [
          Expanded(
            child: Text(label,
                style: context.t.bodyStrong.copyWith(color: c.text)),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: context.t.caption.copyWith(color: c.neutral.c600),
            ),
          ),
        ],
      );

  Widget _toggle(
          dynamic c, String label, bool value, ValueChanged<bool> onChanged) =>
      HGap(
        12,
        children: [
          Expanded(
            child: Text(label,
                style: context.t.bodyStrong.copyWith(color: c.text)),
          ),
          Switch(
            value: value,
            activeThumbColor: c.onAccent,
            activeTrackColor: c.accent,
            onChanged: onChanged,
          ),
        ],
      );

  Widget _link(dynamic c, String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: HGap(
          12,
          children: [
            Expanded(
              child: Text(label,
                  style: context.t.bodyStrong.copyWith(color: c.text)),
            ),
            LineIcon(Icons24.chevronRight, size: 17, color: c.neutral.c500),
          ],
        ),
      );
}
