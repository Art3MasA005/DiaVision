/// 17 · Paywall.
///
/// Shown after first value, never on launch.
///
/// Two things are load-bearing and both come from the server rather than being
/// written into this file:
///
///   * **The free-forever list.** Meal logging, risk assessment, safety alerts
///     and data export stay free on every tier. It arrives in the payload so
///     the screen cannot drift from what the backend actually promises.
///   * **A safety alert is never gated.** Stated on the screen, and enforced
///     in the API — a red-flag interception bypasses the coach's daily cap
///     entirely.
///
/// A "stay on the free plan" exit is always present and is never styled as the
/// lesser choice.
///
/// **No payment rail is connected.** Subscribing moves the account to `trial`
/// so the entitlement path is exercisable end to end; it takes no money.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/shell.dart';

class PaywallScreen extends StatefulWidget {
  const PaywallScreen({super.key});

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  Plans? _plans;
  String _selected = 'annual';
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    try {
      final plans = await app.api.billingPlans();
      app.markOffline(false);
      if (mounted) {
        setState(() {
          _plans = plans;
          _loading = false;
        });
      }
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _subscribe() async {
    if (_busy) return;
    final app = AppScope.read(context);
    setState(() => _busy = true);
    try {
      await app.api.subscribe(_selected);
      app.markOffline(false);
      if (!mounted) return;
      showToast(context, context.s.paywallSubscribed);
      Navigator.of(context).maybePop();
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
      if (mounted) showToast(context, context.s.errNetwork);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final n = context.n;
    final plans = _plans;

    return Shell(
      child: Column(
        children: [
          ScreenHeader(title: s.paywallHead),
          Expanded(
            child: _loading
                ? Center(child: CircularProgressIndicator(color: c.accent))
                : ScreenBody(
                    topPad: 12,
                    bottomPad: 24,
                    gap: 18,
                    children: [
                      P(s.paywallSub, style: context.t.bodyLarge),

                      if (plans?.isSubscribed ?? false)
                        AppCard(
                          radius: 22,
                          color: c.accent2Ramp.c100,
                          borderColor: c.accent2Ramp.c300,
                          child: HGap(
                            10,
                            children: [
                              LineIcon(Icons24.check,
                                  size: 18, color: c.accent2Ramp.c700),
                              Expanded(
                                child: Text(s.paywallSubscribed,
                                    style: context.t.bodyStrong
                                        .copyWith(color: c.accent2Ramp.c900)),
                              ),
                            ],
                          ),
                        ),

                      for (final plan in plans?.plans ?? const <Plan>[])
                        _planCard(c, s, n, plan),

                      // The list comes from the server, not from this file.
                      if (plans != null) _freeForever(c, s, plans),

                      AppCard(
                        radius: 20,
                        color: c.neutral.c200,
                        borderColor: c.neutral.c300,
                        child: HGap(
                          10,
                          cross: CrossAxisAlignment.start,
                          children: [
                            LineIcon(Icons24.shieldCheck,
                                size: 17, color: c.neutral.c600),
                            Expanded(
                              child: P(s.paywallNeverGated,
                                  style: context.t.footnote),
                            ),
                          ],
                        ),
                      ),

                      Text(
                        s.paywallRails,
                        textAlign: TextAlign.center,
                        style:
                            context.t.footnote.copyWith(color: c.neutral.c600),
                      ),
                    ],
                  ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(18, 8, 18, 12),
            child: VGap(
              8,
              children: [
                if (!(plans?.isSubscribed ?? false))
                  _busy
                      ? Center(child: CircularProgressIndicator(color: c.accent))
                      : PillButton(
                          label: s.paywallStartTrial,
                          onPressed: _subscribe,
                        ),
                // Always present, never styled as the lesser choice.
                GhostButton(
                  label: s.paywallStayFree,
                  color: c.neutral.c700,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _planCard(dynamic c, dynamic s, dynamic n, Plan plan) {
    final on = plan.code == _selected;
    return GestureDetector(
      onTap: () => setState(() => _selected = plan.code),
      child: AppCard(
        radius: 26,
        color: on ? c.accentRamp.c100 : c.card,
        borderColor: on ? c.accent : c.neutral.c300,
        borderWidth: 1.5,
        padding: const EdgeInsets.fromLTRB(17, 16, 17, 16),
        child: HGap(
          12,
          cross: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: on ? c.accent : c.neutral.c400, width: 2),
                ),
                child: Center(
                  child: Container(
                    width: 11,
                    height: 11,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: on ? c.accent : Colors.transparent,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: VGap(
                4,
                cross: CrossAxisAlignment.start,
                children: [
                  Text(
                    plan.code == 'annual' ? s.paywallAnnual : s.paywallMonthly,
                    style: context.t.rowTitle.copyWith(color: c.text),
                  ),
                  Text(
                    // The period arrives as a stable key; the wording is ours.
                    s.paywallPrice(
                        n.int_(plan.price), s.billingPeriod(plan.period)),
                    style: context.t.statValue
                        .copyWith(color: c.text, fontSize: 20),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: c.accent2Ramp.c200,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      s.paywallTrial(n.int_(plan.trialDays)),
                      style: context.t.footnote
                          .copyWith(color: c.accent2Ramp.c800),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _freeForever(dynamic c, dynamic s, Plans plans) => AppCard(
        radius: 24,
        color: c.accent2Ramp.c100,
        borderColor: c.accent2Ramp.c300,
        padding: const EdgeInsets.all(16),
        child: VGap(
          10,
          cross: CrossAxisAlignment.start,
          children: [
            Kicker(s.paywallFreeForever, color: c.accent2Ramp.c800),
            // Render from the server's keys, falling back to its English for
            // any key this build predates.
            for (var i = 0; i < plans.freeForever.length; i++)
              HGap(
                9,
                cross: CrossAxisAlignment.start,
                children: [
                  LineIcon(Icons24.check,
                      size: 16, color: c.accent2Ramp.c700, strokeWidth: 3),
                  Expanded(
                    child: Text(
                      i < plans.freeForeverKeys.length
                          ? s.freeForeverItem(
                              plans.freeForeverKeys[i], plans.freeForever[i])
                          : plans.freeForever[i],
                      style: context.t.caption
                          .copyWith(color: c.accent2Ramp.c900),
                    ),
                  ),
                ],
              ),
          ],
        ),
      );
}
