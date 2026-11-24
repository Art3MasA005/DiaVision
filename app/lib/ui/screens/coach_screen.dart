/// 15 · Coach.
///
/// A guarded AI chat over the user's own data.
///
/// The server hands the model this profile's data itself — profile, risk
/// estimate, readings, meals, check-ins, activity — so the user never has to
/// type their own numbers in. The banner says so, and says the messages are
/// processed by an AI service. When the model is unreachable the server falls
/// back to fixed wording and returns `model_backed: false`; the banner then
/// switches to say that, so the client never presents fixed text as AI.
///
/// Three guards run server-side, in this order: red flags before any
/// responder sees the message; medication and dose questions deflected to a
/// doctor; the "do I have diabetes?" question refused outright. A safety
/// interception is **never** rate-limited — PRD §F16 forbids putting a safety
/// message behind a payment, and a daily cap is a payment gate.
///
/// Coaching content is suppressed entirely whenever a safety card is showing.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../main.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/nav_pill.dart';
import '../widgets/shell.dart';
import 'edge_states.dart';

class CoachScreen extends StatefulWidget {
  const CoachScreen({super.key});

  @override
  State<CoachScreen> createState() => _CoachScreenState();
}

class _CoachScreenState extends State<CoachScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  List<CoachTurn> _turns = const [];
  int? _remaining;
  bool _sending = false;
  bool _loading = true;

  /// The last answer came from the fixed-wording fallback, not the model.
  bool _fallback = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final history = await app.api.coachHistory(profileId);
      app.markOffline(false);
      if (mounted) {
        setState(() {
          _turns = history;
          _loading = false;
        });
      }
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) return;

    setState(() {
      _sending = true;
      _turns = [
        ..._turns,
        CoachTurn(
          role: 'user',
          body: text,
          intercepted: false,
          createdAt: DateTime.now(),
        ),
      ];
      _input.clear();
    });
    _scrollToEnd();

    try {
      final reply = await app.api.coachSend(profileId, text);
      app.markOffline(false);
      if (!mounted) return;

      // A safety card replaces the screen and suppresses coaching entirely.
      if (reply.safetyCard != null) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SafetyCardScreen(
              card: reply.safetyCard!,
              emergencyNumber: reply.safetyCard!.emergencyNumber ??
                  app.region.emergencyNumber,
              country: app.region.country,
            ),
          ),
        );
        return;
      }

      setState(() {
        _turns = [
          ..._turns,
          CoachTurn(
            role: 'coach',
            body: reply.reply,
            intercepted: reply.intercepted,
            createdAt: DateTime.now(),
          ),
        ];
        _remaining = reply.questionsRemaining;
        if (!reply.intercepted) _fallback = !reply.modelBacked;
      });
      _scrollToEnd();
    } on CoachLimitReached {
      if (mounted) _showLimit();
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
      if (mounted) showToast(context, context.s.errNetwork);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 220), curve: Curves.ease);
      }
    });
  }

  void _showLimit() {
    final c = context.c;
    final s = context.s;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
          child: VGap(
            14,
            children: [
              Text(s.coachLimitTitle,
                  style: context.t.cardTitle.copyWith(color: c.text)),
              P(s.coachLimitBody, style: context.t.caption),
              PillButton(
                label: s.coachUpgrade,
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  Navigator.of(context).pushNamed(Routes.paywall);
                },
              ),
              GhostButton(
                label: s.cancel,
                color: c.neutral.c700,
                onPressed: () => Navigator.of(sheetContext).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final n = context.n;

    return Shell(
      tab: NavTab.coach,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(18, 12, 18, 0),
            child: HGap(
              12,
              children: [
                Expanded(
                  child: Text(s.coachHead,
                      style: context.t.screenTitleSm.copyWith(color: c.text)),
                ),
                if (_remaining != null)
                  Text(
                    s.coachRemaining(n.int_(_remaining!)),
                    style:
                        context.t.footnote.copyWith(color: c.neutral.c600),
                  ),
              ],
            ),
          ),

          // The honest banner about what this actually is.
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(18, 12, 18, 0),
            child: AppCard(
              radius: 18,
              color: c.neutral.c200,
              borderColor: c.neutral.c300,
              child: HGap(
                10,
                cross: CrossAxisAlignment.start,
                children: [
                  LineIcon(Icons24.infoCircle,
                      size: 17, color: c.neutral.c600),
                  Expanded(
                    child: P(_fallback ? s.coachNotAModel : s.coachAiBanner,
                        style: context.t.footnote),
                  ),
                ],
              ),
            ),
          ),

          Expanded(
            child: _loading
                ? Center(child: CircularProgressIndicator(color: c.accent))
                : _turns.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: P(s.coachEmpty,
                              align: TextAlign.center,
                              style: context.t.caption),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(18, 16, 18, 130),
                        itemCount: _turns.length + (_sending ? 1 : 0),
                        itemBuilder: (context, i) => i < _turns.length
                            ? _bubble(c, _turns[i])
                            : _thinking(c, s),
                      ),
          ),

          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(18, 0, 18, 96),
            child: HGap(
              10,
              children: [
                Expanded(
                  child: AppCard(
                    radius: 22,
                    borderWidth: 1.5,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: BareInput(
                      controller: _input,
                      hint: s.coachPlaceholder,
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                ),
                CircleIconButton(
                  icon: Icons24.arrowRight,
                  size: 48,
                  iconSize: 20,
                  semanticLabel: s.next,
                  onPressed: _sending ? null : _send,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The model takes a few seconds; say so rather than look frozen.
  Widget _thinking(dynamic c, dynamic s) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: c.neutral.c300),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: c.accent),
                ),
                Text(s.coachThinking,
                    style: context.t.caption.copyWith(color: c.neutral.c600)),
              ],
            ),
          ),
        ),
      );

  Widget _bubble(dynamic c, CoachTurn turn) {
    final mine = turn.isUser;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Align(
        alignment:
            mine ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
            decoration: BoxDecoration(
              // An intercepted answer is visually distinct — it is a guard
              // speaking, not the coach.
              color: mine
                  ? c.accentRamp.c100
                  : (turn.intercepted ? c.cautionTint : c.card),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: mine
                    ? c.accentRamp.c300
                    : (turn.intercepted ? c.cautionBorder : c.neutral.c300),
              ),
            ),
            child: P(
              turn.body,
              style: context.t.caption.copyWith(height: 1.6),
              color: turn.intercepted && !mine ? c.caution : c.text,
            ),
          ),
        ),
      ),
    );
  }
}
