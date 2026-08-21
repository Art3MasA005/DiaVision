/// 03 · Medical disclaimer — BLOCKING.
///
/// The hard gate before any health question. Four things are load-bearing:
///
///   * **No scroll-past, no pre-ticked box, no dismiss.** There is no back
///     button and no skip; [PopScope] blocks the system back gesture too.
///   * **The body text must not be paraphrased or shrunk.** It is verbatim
///     from `ui_spec.md` §7 and renders at [AppText.bodyDisclaimer], the one
///     block in the app that is explicitly larger than the 16sp floor.
///   * **This is its own consent record**, separate from the Terms accepted at
///     signup. The server writes a row with the version and the timestamp.
///   * **The server enforces this too.** A client that skips the screen gets a
///     403 `medical_disclaimer_required` on the next health call, not a silent
///     success.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/api.dart';
import '../../l10n/strings.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/shell.dart';

class DisclaimerScreen extends StatefulWidget {
  const DisclaimerScreen({super.key});

  @override
  State<DisclaimerScreen> createState() => _DisclaimerScreenState();
}

class _DisclaimerScreenState extends State<DisclaimerScreen> {
  /// Never pre-set. The whole point of the record is that a person tapped it.
  bool _ticked = false;

  bool _busy = false;
  String? _error;

  Future<void> _accept() async {
    if (_busy || !_ticked) return;
    final app = AppScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await app.api.recordConsent('medical_disclaimer', locale: app.lang);
      app.markOffline(false);
      if (!mounted) return;
      showToast(context, context.s.toastConsentRecorded);
      Navigator.of(context)
          .pushNamedAndRemoveUntil(Routes.wizard, (_) => false);
    } on ApiFailure catch (e) {
      if (!mounted) return;
      // Consent has to reach the server — it is a legal record, and queuing it
      // locally would mean health questions render against a consent that does
      // not exist yet. So this one call does block on the network.
      setState(() => _error =
          e is NetworkFailure ? context.s.errNetwork : context.s.errServer);
      app.markOffline(e is NetworkFailure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;

    return PopScope(
      // No way around the gate, including the platform back gesture.
      canPop: false,
      child: Shell(
        showLanguageSwitch: true,
        child: ScreenBody(
          topPad: 14,
          bottomPad: 40,
          gap: 18,
          children: [
            IconChip(icon: Icons24.shieldCheck, size: 52),
            Text(s.disclaimerHead,
                style: context.t.screenTitle.copyWith(color: c.text)),

            // The one block that must not be shrunk.
            AppCard(
              radius: 26,
              shadow: true,
              padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 18),
              child: P(
                s.disclaimerBody,
                style: context.t.bodyDisclaimer,
                color: c.text,
              ),
            ),

            if (clinicianReviewPending && s.lang != 'en')
              _reviewPendingNote(c),

            CheckRow(
              checked: _ticked,
              onChanged: (v) => setState(() => _ticked = v),
              label: s.disclaimerTick,
            ),

            if (_error != null)
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
                      child: P(_error!,
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
                    label: s.disclaimerCta,
                    enabled: _ticked,
                    onPressed: _accept,
                    onDisabledTap: () => showToast(context, s.disclaimerTick),
                  ),

            Text(
              s.disclaimerFootnote,
              textAlign: TextAlign.center,
              style: context.t.footnote.copyWith(color: c.neutral.c600),
            ),
          ],
        ),
      ),
    );
  }

  /// An honest note while the Bangla safety strings are still awaiting a
  /// native-speaking clinician's review (`ui_spec.md` §7). This is a
  /// development-visible flag, not a shipping state — the English wording
  /// stays reachable so nothing is lost in the meantime.
  Widget _reviewPendingNote(dynamic c) => AppCard(
        radius: 18,
        color: c.neutral.c200,
        borderColor: c.neutral.c300,
        child: HGap(
          10,
          cross: CrossAxisAlignment.start,
          children: [
            LineIcon(Icons24.infoCircle, size: 17, color: c.neutral.c600),
            Expanded(
              child: P(
                'Bangla safety wording is pending clinician review. '
                'Read it in English:',
                style: context.t.footnote,
                color: c.neutral.c700,
              ),
            ),
            GhostButton(
              label: 'EN',
              onPressed: () => showDialog<void>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  backgroundColor: c.card,
                  content: P(Strings.of('en').disclaimerBody,
                      style: context.t.body, color: c.text),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: Text(context.s.done),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
}
