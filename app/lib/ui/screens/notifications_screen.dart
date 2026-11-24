/// 09b · Notifications — the inbox behind the Home bell.
///
/// Today / Earlier groups, All / Reminders / Insights / Account filters with
/// unread counts, mark-all-read, per-item dismiss, and an empty state. Tapping
/// an item marks it read and opens the screen it is about.
///
/// The items come from [Inbox], sample-seeded until the API exists — see
/// `data/notifications.dart`. Bodies never carry a glucose, weight or risk
/// value (§3.4); the footer says so, because the lock screen is the worry.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/typography.dart';
import '../../data/notifications.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/shell.dart';

enum _Filter { all, reminder, insight, account }

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  _Filter _filter = _Filter.all;

  bool _matches(AppNotification x, _Filter f) => switch (f) {
        _Filter.all => true,
        _Filter.reminder => x.kind == NotificationKind.reminder,
        _Filter.insight => x.kind == NotificationKind.insight,
        _Filter.account => x.kind == NotificationKind.account,
      };

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final app = AppScope.of(context);
    final inbox = app.inbox;
    final items = inbox.items;
    final unread = items.where((x) => x.unread).toList();
    final shown = items.where((x) => _matches(x, _filter)).toList();

    return Shell(
      child: ScreenBody(
        topPad: 10,
        bottomPad: 40,
        gap: 0,
        children: [
          _header(c, s, inbox, unread.length),
          const SizedBox(height: 14),
          _filters(c, s, unread),
          for (final g in NotificationGroup.values)
            if (shown.any((x) => x.group == g)) ...[
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(4, 18, 4, 9),
                child: Kicker(g == NotificationGroup.today ? s.nToday : s.nEarlier),
              ),
              VGap(
                9,
                children: [
                  for (final x in shown.where((x) => x.group == g))
                    _Item(
                      item: x,
                      lang: app.lang,
                      onOpen: () {
                        inbox.markRead(x.id);
                        Navigator.of(context).pushNamed(x.route);
                      },
                      onDismiss: () => inbox.dismiss(x.id),
                    ),
                ],
              ),
            ],
          if (shown.isEmpty) _empty(c, s),
          const SizedBox(height: 18),
          _settingsRow(c, s),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(4, 10, 4, 0),
            child: P(s.nPrivacy, style: context.t.footnote, color: c.neutral.c600),
          ),
        ],
      ),
    );
  }

  Widget _header(AppColors c, dynamic s, Inbox inbox, int unread) => HGap(
        12,
        children: [
          CircleIconButton(
            icon: Icons24.chevronLeft,
            semanticLabel: s.back,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  s.nTitle,
                  textAlign: TextAlign.center,
                  style: context.t.cardTitle.copyWith(color: c.text),
                ),
                if (unread > 0)
                  Text(
                    s.nUnread(context.n.digits('$unread')),
                    textAlign: TextAlign.center,
                    style: context.t.footnote.copyWith(
                        color: c.accentRamp.c700, fontWeight: FontWeight.w700),
                  ),
              ],
            ),
          ),
          Opacity(
            opacity: unread > 0 ? 1 : 0.4,
            child: CircleIconButton(
              icon: Icons24.checkCheck,
              semanticLabel: s.nMarkAll,
              onPressed: unread == 0
                  ? null
                  : () {
                      inbox.markAllRead();
                      showToast(context, s.nToastAll);
                    },
            ),
          ),
        ],
      );

  Widget _filters(AppColors c, dynamic s, List<AppNotification> unread) {
    final labels = {
      _Filter.all: s.nFilterAll as String,
      _Filter.reminder: s.nFilterReminders as String,
      _Filter.insight: s.nFilterInsights as String,
      _Filter.account: s.nFilterAccount as String,
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        spacing: 7,
        children: [
          for (final f in _Filter.values)
            _Chip(
              label: labels[f]!,
              on: f == _filter,
              count: unread.where((x) => _matches(x, f)).length,
              onTap: () => setState(() => _filter = f),
            ),
        ],
      ),
    );
  }

  Widget _empty(AppColors c, dynamic s) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 52, 18, 20),
        child: Column(
          children: [
            IconChip(
              icon: Icons24.bell,
              size: 84,
              iconSize: 34,
              bg: c.accent2Ramp.c100,
              border: c.accent2Ramp.c300,
              fg: c.accent2Ramp.c700,
            ),
            const SizedBox(height: 16),
            Text(s.nEmptyHead,
                textAlign: TextAlign.center,
                style: context.t.cardTitle.copyWith(color: c.text)),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: P(s.nEmptySub, align: TextAlign.center),
            ),
          ],
        ),
      );

  Widget _settingsRow(AppColors c, dynamic s) => Material(
        color: c.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: c.neutral.c300),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).pushNamed(Routes.settings),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
            child: HGap(
              12,
              children: [
                LineIcon(Icons24.settings, size: 19, color: c.text),
                Expanded(
                  child: Text(s.nSettings,
                      style: context.t.rowTitle.copyWith(color: c.text)),
                ),
                LineIcon(Icons24.chevronRight,
                    size: 17, color: c.neutral.c600),
              ],
            ),
          ),
        ),
      );
}

/// A filter pill; the selected one inverts to the ink `--pill` colour.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.on,
    required this.count,
    required this.onTap,
  });

  final String label;
  final bool on;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      selected: on,
      button: true,
      child: Material(
        color: on ? c.pill : c.card,
        shape: StadiumBorder(
          side: BorderSide(color: on ? c.pill : c.neutral.c300, width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 7,
              children: [
                Text(
                  label,
                  style: context.t.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: on ? c.pillFg : c.text,
                  ),
                ),
                if (count > 0)
                  Container(
                    constraints: const BoxConstraints(minWidth: 18),
                    height: 18,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: on ? c.accent : c.accentRamp.c100,
                      borderRadius: AppRadius.rPill,
                    ),
                    child: Text(
                      context.n.digits('$count'),
                      style: context.t.footnote.withTabular().copyWith(
                            fontSize: 11,
                            height: 1,
                            fontWeight: FontWeight.w800,
                            color: on ? c.onAccent : c.accentRamp.c800,
                          ),
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

/// One notification card: tone-tinted icon, title with an unread dot, body,
/// time, and a dismiss button on the end edge.
class _Item extends StatelessWidget {
  const _Item({
    required this.item,
    required this.lang,
    required this.onOpen,
    required this.onDismiss,
  });

  final AppNotification item;
  final String lang;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final (title, body, time) = item.copyFor(lang);
    final un = item.unread;
    final (tint, ink) = switch (item.kind) {
      NotificationKind.reminder => (c.accentRamp.c100, c.accentRamp.c700),
      NotificationKind.insight => (c.accent2Ramp.c100, c.accent2Ramp.c700),
      NotificationKind.account => (c.neutral.c200, c.neutral.c700),
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      decoration: BoxDecoration(
        color: un ? c.card : c.neutral.c100,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: un ? c.accentRamp.c300 : c.neutral.c300),
        boxShadow: AppShadow.sm(c.isDark),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: InkWell(
                onTap: onOpen,
                borderRadius: BorderRadius.circular(22),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(14, 13, 4, 13),
                  child: HGap(
                    12,
                    cross: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration:
                            BoxDecoration(color: tint, shape: BoxShape.circle),
                        child: Center(
                          child: LineIcon(item.icon, size: 19, color: ink),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              spacing: 7,
                              children: [
                                Flexible(
                                  child: Text(
                                    title,
                                    style: context.t.rowTitle.copyWith(
                                      color: c.text,
                                      fontWeight:
                                          un ? FontWeight.w800 : FontWeight.w700,
                                    ),
                                  ),
                                ),
                                if (un)
                                  Semantics(
                                    label: s.nNew,
                                    child: Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        color: c.accent,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(body,
                                style: context.t.caption
                                    .copyWith(color: c.neutral.c700)),
                            const SizedBox(height: 6),
                            Text(
                              time,
                              style: context.t.footnote.copyWith(
                                  color: c.neutral.c600,
                                  fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.only(top: 8, end: 8),
              child: SizedBox.square(
                dimension: 34,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  tooltip: '${s.nDismiss} · $title',
                  onPressed: onDismiss,
                  icon: LineIcon(Icons24.close, size: 16, color: c.neutral.c600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
