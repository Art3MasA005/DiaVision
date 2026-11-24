/// The notification inbox behind the Home bell.
///
/// THE BACKEND HAS NO NOTIFICATION ENDPOINTS YET. The handoff names
/// `GET /notifications`, `POST /notifications/read` and
/// `DELETE /notifications/:id`. Until they exist the inbox is seeded with the
/// handoff's eight sample items (`NOTIFS` in `Diavision_UI.html`), and read /
/// dismissed state lives in memory for the session. Replace [Inbox.sample]
/// with a loader when the API lands; nothing on the screens needs to change.
///
/// Rules the content must keep (handoff §3.4, F9):
///   * no glucose, weight or risk value in any title or body;
///   * medication reminders are reminders only, with no dosing logic;
///   * the Home badge counts unread items and clears as they are read.
library;

import 'package:flutter/foundation.dart';

enum NotificationKind { reminder, insight, account }

enum NotificationGroup { today, earlier }

@immutable
class AppNotification {
  const AppNotification({
    required this.id,
    required this.kind,
    required this.group,
    required this.route,
    required this.icon,
    required this.unread,
    required this.en,
    required this.bn,
  });

  final String id;
  final NotificationKind kind;
  final NotificationGroup group;

  /// The screen the item is about; tapping it opens this route.
  final String route;

  /// Path data for [LineIcon].
  final String icon;
  final bool unread;

  /// Title, body, time — per language. Other languages fall back to English.
  final (String, String, String) en, bn;

  (String, String, String) copyFor(String lang) => lang == 'bn' ? bn : en;

  AppNotification read() => AppNotification(
        id: id,
        kind: kind,
        group: group,
        route: route,
        icon: icon,
        unread: false,
        en: en,
        bn: bn,
      );
}

class Inbox extends ChangeNotifier {
  Inbox(List<AppNotification> items) : _items = List.of(items);

  /// The handoff's sample inbox. Routes are plain strings so this file does
  /// not depend on the app's route table.
  factory Inbox.sample() => Inbox(_sample);

  final List<AppNotification> _items;

  List<AppNotification> get items => List.unmodifiable(_items);
  int get unreadCount => _items.where((x) => x.unread).length;

  void markRead(String id) {
    final i = _items.indexWhere((x) => x.id == id);
    if (i < 0 || !_items[i].unread) return;
    _items[i] = _items[i].read();
    notifyListeners();
  }

  void markAllRead() {
    if (unreadCount == 0) return;
    for (var i = 0; i < _items.length; i++) {
      _items[i] = _items[i].read();
    }
    notifyListeners();
  }

  void dismiss(String id) {
    final before = _items.length;
    _items.removeWhere((x) => x.id == id);
    if (_items.length != before) notifyListeners();
  }
}

// Icon path data, copied from the handoff's `RAW` icon set so this file stays
// free of widget imports.
const _bowl = 'M3 11h18a9 9 0 0 1-18 0Z|'
    'M8 7c0-1.5 1-2 1-3M12 7c0-1.5 1-2 1-3M16 7c0-1.5 1-2 1-3';
const _msg = 'M20.5 12a8.5 8.5 0 0 1-12.4 7.5L4 20.5l1.1-3.9A8.5 8.5 0 1 1 20.5 12Z';
const _sun = 'M12 8a4 4 0 1 1 0 8 4 4 0 0 1 0-8|M12 2v2|M12 20v2|'
    'm4.9 4.9 1.4 1.4|m17.7 17.7 1.4 1.4|M2 12h2|M20 12h2|m4.9 19.1 1.4-1.4|'
    'm17.7 6.3 1.4-1.4';
const _drop = 'M12 3c3.5 4 6 6.7 6 10a6 6 0 0 1-12 0c0-3.3 2.5-6 6-10Z';
const _spark = 'M4 18 6 7l4.5 4L12 5l1.5 6L18 7l2 11z';
const _walk = 'M13 4.5a1.4 1.4 0 1 0 0-.1|M11 21l1.5-6-2.5-2.5.5-4 3.5 1.5 2 3|'
    'M8 21l2-5';
const _lock = 'M7.5 10.5h9a3 3 0 0 1 3 3v4a3 3 0 0 1-3 3h-9a3 3 0 0 1-3-3v-4a3 3 0 0 1 3-3Z|'
    'M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5';

const _sample = <AppNotification>[
  AppNotification(
    id: 'meal',
    kind: NotificationKind.reminder,
    group: NotificationGroup.today,
    route: '/tracker',
    icon: _bowl,
    unread: true,
    en: (
      "Breakfast isn't logged yet",
      'A photo or two taps is enough. Logging early makes lunch easier to plan.',
      '8:30 AM',
    ),
    bn: (
      'সকালের নাস্তা এখনো লগ করা হয়নি',
      'একটা ছবি বা দুই ট্যাপই যথেষ্ট। আগে লগ করলে দুপুরের খাবার পরিকল্পনা সহজ হয়।',
      'সকাল ৮:৩০',
    ),
  ),
  AppNotification(
    id: 'coach',
    kind: NotificationKind.insight,
    group: NotificationGroup.today,
    route: '/coach',
    icon: _msg,
    unread: true,
    en: ('Your coach replied', 'About swapping white rice at dinner.', '7:55 AM'),
    bn: (
      'আপনার কোচ উত্তর দিয়েছে',
      'রাতের খাবারে সাদা ভাতের বদল নিয়ে।',
      'সকাল ৭:৫৫',
    ),
  ),
  AppNotification(
    id: 'checkin',
    kind: NotificationKind.reminder,
    group: NotificationGroup.today,
    route: '/checkin',
    icon: _sun,
    unread: true,
    en: (
      'Daily check-in',
      'Energy, sleep and how you feel. About 30 seconds.',
      '7:00 AM',
    ),
    bn: (
      'দৈনিক চেক-ইন',
      'শক্তি, ঘুম আর কেমন লাগছে। প্রায় ৩০ সেকেন্ড।',
      'সকাল ৭:০০',
    ),
  ),
  AppNotification(
    id: 'water',
    kind: NotificationKind.reminder,
    group: NotificationGroup.today,
    route: '/tracker',
    icon: _drop,
    unread: false,
    en: (
      'Time for a glass of water',
      'Small sips through the day add up.',
      '6:40 AM',
    ),
    bn: (
      'এক গ্লাস পানি খাওয়ার সময়',
      'সারাদিন অল্প অল্প করে খেলেই যথেষ্ট।',
      'সকাল ৬:৪০',
    ),
  ),
  AppNotification(
    id: 'weekly',
    kind: NotificationKind.insight,
    group: NotificationGroup.earlier,
    route: '/insights',
    icon: _spark,
    unread: false,
    en: (
      'Your weekly report is ready',
      'See what changed this week, and share it with your doctor if you like.',
      'Sun, 8:00 PM',
    ),
    bn: (
      'আপনার সাপ্তাহিক রিপোর্ট তৈরি',
      'এই সপ্তাহে কী বদলেছে দেখুন, চাইলে ডাক্তারের সাথে শেয়ার করুন।',
      'রবি, রাত ৮:০০',
    ),
  ),
  AppNotification(
    id: 'move',
    kind: NotificationKind.reminder,
    group: NotificationGroup.earlier,
    route: '/activity',
    icon: _walk,
    unread: false,
    en: (
      'Time to move',
      'A 10-minute walk after a meal is one of the easiest wins.',
      'Yesterday, 2:15 PM',
    ),
    bn: (
      'একটু হাঁটার সময়',
      'খাবারের পর ১০ মিনিট হাঁটা সবচেয়ে সহজ ভালো অভ্যাসগুলোর একটি।',
      'গতকাল, দুপুর ২:১৫',
    ),
  ),
  AppNotification(
    id: 'glucose',
    kind: NotificationKind.reminder,
    group: NotificationGroup.earlier,
    route: '/vitals',
    icon: _drop,
    unread: false,
    en: (
      'Glucose reading reminder',
      'Only if you have a meter at home. Skip it any time.',
      'Yesterday, 7:00 AM',
    ),
    bn: (
      'গ্লুকোজ মাপার রিমাইন্ডার',
      'বাসায় মিটার থাকলেই কেবল। যেকোনো সময় বাদ দিতে পারেন।',
      'গতকাল, সকাল ৭:০০',
    ),
  ),
  AppNotification(
    id: 'device',
    kind: NotificationKind.account,
    group: NotificationGroup.earlier,
    route: '/settings',
    icon: _lock,
    unread: false,
    en: (
      'New sign-in on Android',
      "Dhaka. If this wasn't you, change your password in Settings.",
      'Mon, 10:12 PM',
    ),
    bn: (
      'অ্যান্ড্রয়েডে নতুন সাইন-ইন',
      'ঢাকা। এটি আপনি না হলে সেটিংসে গিয়ে পাসওয়ার্ড বদলান।',
      'সোম, রাত ১০:১২',
    ),
  ),
];
