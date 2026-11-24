/// 11 · Scan food — start → camera → analysing → review.
///
/// **This screen scans food, never "your health".** Implying vitals come from
/// a device sensor is an automatic App Store rejection (rule 3), so the copy
/// says what it is looking at and the footer repeats it.
///
/// **AI proposes, the human disposes.** The photo goes to the vision model
/// (OpenRouter, via our server), which proposes items with portions. Nothing
/// is saved until the user has seen every item, and every quantity, unit and
/// item stays editable. Items the model was unsure of are flagged until the
/// user touches them.
///
/// **The photo leaves the phone only with permission.** The first scan asks
/// once; the server analyses the photo and does not store it. Without
/// permission — or with no model reachable — the screen falls back to search
/// and manual portions rather than inventing items.
///
/// Calories are a range with an "estimate" label throughout: ±24% for a photo
/// portion, ±14% for a manual one, the same widths the server stores.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../widgets/kit.dart';
import '../widgets/line_icon.dart';
import '../widgets/nav_pill.dart';
import '../widgets/shell.dart';

enum _Step { start, camera, analyzing, review }

/// Route arguments: `{'camera': true}` skips Start and opens the camera, as
/// when the tracker's "Add meal" sheet picks Scan; `{'slot': 'lunch'}` presets
/// the meal; `{'day': DateTime}` logs it on a past day the tracker is showing.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, this.previewRecognition, this.clock});

  /// Tests only: open straight on the review step with these proposals.
  @visibleForTesting
  final Recognition? previewRecognition;

  /// Where the time of day comes from, which picks the default meal. Tests
  /// pin it so screenshots do not depend on when they run.
  @visibleForTesting
  final DateTime Function()? clock;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final _search = TextEditingController();
  final _drafts = <MealItemDraft>[];

  /// Where each photo item sits in the photo, keyed by its draft.
  final _boxes = <MealItemDraft, List<double>>{};

  _Step _step = _Step.start;
  late String _slot = _slotFor((widget.clock ?? DateTime.now)());
  bool _argsRead = false;

  /// The day being logged, when the tracker is showing a past day.
  DateTime? _day;

  /// Whether the camera path can work at all (model reachable, region on).
  Recognition? _probe;

  // camera
  CameraController? _cam;
  List<CameraDescription> _cameras = const [];
  int _camIndex = 0;
  FlashMode _flash = FlashMode.off;
  bool _camFailed = false;
  bool _shooting = false;

  // analysis
  Uint8List? _photo;
  double? _photoAspect;
  Recognition? _result;
  int _busyStep = 0;
  Timer? _busyTimer;
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 7),
  );

  // review
  bool _searchOpen = false;
  List<Food> _results = const [];
  bool _saving = false;
  String? _error;

  static String _slotFor(DateTime now) {
    final h = now.hour;
    if (h < 11) return 'breakfast';
    if (h < 16) return 'lunch';
    if (h < 19) return 'snack';
    return 'dinner';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final preview = widget.previewRecognition;
    if (preview != null) _showResult(preview, animate: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkRecognition();
      _searchFoods('');
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsRead) return;
    _argsRead = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      final slot = args['slot'];
      if (slot is String) _slot = slot;
      final day = args['day'];
      if (day is DateTime) _day = day;
      if (args['camera'] == true) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _startScan());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _busyTimer?.cancel();
    _progress.dispose();
    _cam?.dispose();
    _search.dispose();
    super.dispose();
  }

  /// Release the camera when the app goes to the background; reopen on return.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_step != _Step.camera) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _closeCamera();
    } else if (state == AppLifecycleState.resumed && _cam == null) {
      _openCamera();
    }
  }

  // ── data ─────────────────────────────────────────────────────────────

  Future<void> _checkRecognition() async {
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) return;
    try {
      final r = await app.api.recognizeFood(profileId);
      if (mounted) setState(() => _probe = r);
    } on ApiFailure {
      // Search still works; the scan button explains itself when tapped.
    }
  }

  Future<void> _searchFoods(String q) async {
    final app = AppScope.read(context);
    try {
      final foods = await app.api.searchFoods(q: q, region: app.regionCode);
      if (mounted) setState(() => _results = foods);
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
    }
  }

  bool get _modelAvailable => _probe?.modelAvailable ?? true;

  // ── start → camera ──────────────────────────────────────────────────

  /// Asks once before the first photo leaves the phone.
  Future<bool> _ensureConsent() async {
    final app = AppScope.read(context);
    if (app.prefs.photoAnalysisConsent) return true;
    final c = context.c;
    final s = context.s;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: c.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheet) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 22),
          child: VGap(
            14,
            cross: CrossAxisAlignment.start,
            children: [
              IconChip(icon: Icons24.shieldCheck, size: 46),
              Text(s.scanConsentHead,
                  style: context.t.cardTitle.copyWith(color: c.text)),
              P(s.scanConsentBody, style: context.t.caption),
              PillButton(
                label: s.scanConsentAllow,
                onPressed: () => Navigator.of(sheet).pop(true),
              ),
              Center(
                child: GhostButton(
                  label: s.scanSearchInstead,
                  color: c.neutral.c700,
                  onPressed: () => Navigator.of(sheet).pop(false),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok == true) {
      await app.prefs.setPhotoAnalysisConsent(true);
      return true;
    }
    if (mounted) _openManual();
    return false;
  }

  Future<void> _startScan() async {
    if (!_modelAvailable) {
      showToast(context, context.s.scanNoModel);
      return;
    }
    if (!await _ensureConsent() || !mounted) return;
    setState(() => _step = _Step.camera);
    await _openCamera();
  }

  Future<void> _openCamera() async {
    try {
      if (_cameras.isEmpty) _cameras = await availableCameras();
      if (_cameras.isEmpty) throw CameraException('none', 'no camera');
      // Prefer the back camera — this is pointed at a plate.
      if (_cam == null && _camIndex == 0) {
        final back = _cameras.indexWhere(
            (d) => d.lensDirection == CameraLensDirection.back);
        if (back > 0) _camIndex = back;
      }
      final controller = CameraController(
        _cameras[_camIndex % _cameras.length],
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      try {
        await controller.setFlashMode(_flash);
      } catch (_) {
        // Front cameras and some webcams have no flash.
      }
      if (!mounted || _step != _Step.camera) {
        await controller.dispose();
        return;
      }
      setState(() {
        _cam = controller;
        _camFailed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _camFailed = true);
    }
  }

  Future<void> _closeCamera() async {
    final cam = _cam;
    _cam = null;
    if (mounted) setState(() {});
    await cam?.dispose();
  }

  Future<void> _flipCamera() async {
    if (_cameras.length < 2) return;
    await _closeCamera();
    _camIndex = (_camIndex + 1) % _cameras.length;
    await _openCamera();
  }

  Future<void> _toggleFlash() async {
    final next = _flash == FlashMode.off ? FlashMode.torch : FlashMode.off;
    try {
      await _cam?.setFlashMode(next);
      setState(() => _flash = next);
    } catch (_) {}
  }

  Future<void> _shoot() async {
    final cam = _cam;
    if (cam == null || _shooting || !cam.value.isInitialized) return;
    setState(() => _shooting = true);
    try {
      final file = await cam.takePicture();
      final bytes = await file.readAsBytes();
      await _closeCamera();
      await _analyze(bytes);
    } catch (_) {
      if (mounted) showToast(context, context.s.scanFailed);
    } finally {
      if (mounted) setState(() => _shooting = false);
    }
  }

  Future<void> _pickFromGallery() async {
    if (!_modelAvailable) {
      showToast(context, context.s.scanNoModel);
      return;
    }
    if (!await _ensureConsent() || !mounted) return;
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 82,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      await _closeCamera();
      await _analyze(bytes);
    } catch (_) {
      if (mounted) showToast(context, context.s.scanFailed);
    }
  }

  void _openManual() {
    _closeCamera();
    setState(() {
      _step = _Step.review;
      _searchOpen = true;
      _photo = null;
      _result = null;
    });
  }

  // ── analysing ───────────────────────────────────────────────────────

  Future<void> _analyze(Uint8List bytes) async {
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) return;

    setState(() {
      _photo = bytes;
      _photoAspect = null;
      _step = _Step.analyzing;
      _busyStep = 0;
      _error = null;
    });
    unawaited(_measurePhoto(bytes));

    // The first two steps tick on a timer; the last waits for the answer.
    _busyTimer?.cancel();
    _busyTimer = Timer.periodic(const Duration(milliseconds: 900), (t) {
      if (!mounted || _busyStep >= 2) {
        t.cancel();
        return;
      }
      setState(() => _busyStep++);
    });
    _progress
      ..value = 0
      ..animateTo(0.9, curve: Curves.easeOutCubic);

    Recognition result;
    try {
      result = await app.api
          .recognizeFood(profileId, imageBase64: base64Encode(bytes));
      app.markOffline(false);
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
      // The review step words an empty message itself (scanFailed).
      result = const Recognition(
        modelAvailable: false,
        message: '',
        confidenceFloor: 0.55,
      );
    }
    _busyTimer?.cancel();
    if (!mounted) return;
    setState(() => _busyStep = 3);
    await _progress.animateTo(1,
        duration: const Duration(milliseconds: 280));
    if (!mounted) return;
    _showResult(result, animate: true);
  }

  Future<void> _measurePhoto(Uint8List bytes) async {
    try {
      final image = await decodeImageFromList(bytes);
      if (mounted) {
        setState(() => _photoAspect = image.width / image.height);
      }
      image.dispose();
    } catch (_) {}
  }

  void _showResult(Recognition r, {required bool animate}) {
    final drafts = [for (final item in r.items) MealItemDraft.fromRecognized(item)];
    void apply() {
      _result = r;
      _step = _Step.review;
      _drafts
        ..removeWhere((d) => d.fromPhoto)
        ..insertAll(0, drafts);
      _boxes.clear();
      for (var i = 0; i < drafts.length; i++) {
        final box = r.items[i].box;
        if (box != null) _boxes[drafts[i]] = box;
      }
      _searchOpen = drafts.isEmpty;
    }

    if (animate) {
      setState(apply);
    } else {
      apply();
    }
  }

  Future<void> _retake() async {
    setState(() {
      _drafts.removeWhere((d) => d.fromPhoto);
      _boxes.clear();
      _photo = null;
      _result = null;
      _step = _Step.camera;
    });
    await _openCamera();
  }

  // ── review → save ───────────────────────────────────────────────────

  bool get _anyPhoto => _drafts.any((d) => d.fromPhoto);

  double get _estimatedKcal =>
      _drafts.fold(0.0, (sum, d) => sum + d.estimatedKcal);

  Future<void> _save() async {
    if (_drafts.isEmpty || _saving) return;
    final app = AppScope.read(context);
    final profileId = app.profileId;
    if (profileId == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await app.api.logMeal(
        profileId,
        slot: _slot,
        items: _drafts,
        entryMethod: _anyPhoto ? 'photo' : 'manual',
        eatenAt: _day == null ? null : eatenAtFor(_day!),
      );
      app.markOffline(false);
      if (!mounted) return;
      final nav = Navigator.of(context);
      if (nav.canPop()) {
        nav.pop(true);
      } else {
        showToast(context, context.s.scanSaveMeal);
        setState(() {
          _drafts.clear();
          _boxes.clear();
          _photo = null;
          _result = null;
          _step = _Step.start;
        });
      }
    } on ApiFailure catch (e) {
      app.markOffline(e is NetworkFailure);
      if (mounted) {
        setState(() => _error =
            e is NetworkFailure ? context.s.errNetwork : context.s.errServer);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return switch (_step) {
      _Step.camera => _cameraView(context),
      _Step.start => _shell(_startBody(context)),
      _Step.analyzing => _shell(_analyzingBody(context)),
      _Step.review => _shell(_reviewBody(context)),
    };
  }

  Widget _shell(List<Widget> children) => Shell(
        tab: NavTab.scan,
        child: ScreenBody(topPad: 14, gap: 18, children: children),
      );

  Widget _slotPicker(dynamic s) => VGap(
        8,
        children: [
          Kicker(s.scanSlot),
          Segmented<String>(
            value: _slot,
            compact: true,
            options: [
              ('breakfast', s.lang == 'bn' ? 'নাশতা' : 'Breakfast'),
              ('lunch', s.lang == 'bn' ? 'দুপুর' : 'Lunch'),
              ('snack', s.lang == 'bn' ? 'হালকা' : 'Snack'),
              ('dinner', s.lang == 'bn' ? 'রাত' : 'Dinner'),
            ],
            onChanged: (v) => setState(() => _slot = v),
          ),
        ],
      );

  // ── step 1: start ───────────────────────────────────────────────────

  List<Widget> _startBody(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final available = _modelAvailable;

    return [
      Text(s.scanStartHead,
          style: context.t.screenTitleSm.copyWith(color: c.text)),
      P(s.scanStartSub, style: context.t.caption),

      // The plate illustration doubles as the big tap target.
      GestureDetector(
        onTap: available ? _startScan : null,
        child: AppCard(
          radius: 28,
          color: c.accentRamp.c100,
          borderColor: c.accentRamp.c300,
          padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 18),
          child: Column(
            spacing: 14,
            children: [
              Container(
                width: 132,
                height: 132,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.card,
                  border: Border.all(color: c.accentRamp.c300, width: 2),
                ),
                child: Center(
                  child: Container(
                    width: 92,
                    height: 92,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: c.accent2Ramp.c400, width: 2.5),
                    ),
                    child: Center(
                      child: LineIcon(Icons24.navCamera,
                          size: 38, color: c.accentRamp.c700),
                    ),
                  ),
                ),
              ),
              P(
                available
                    ? s.scanViewfinderHint
                    : s.scanNoModel,
                align: TextAlign.center,
                style: context.t.caption,
              ),
            ],
          ),
        ),
      ),

      _slotPicker(s),

      PillButton(
        label: s.scanScanBtn,
        icon: Icons24.navCamera,
        enabled: available,
        onPressed: _startScan,
        onDisabledTap: () => showToast(context, s.scanNoModel),
      ),
      HGap(
        10,
        children: [
          Expanded(
            child: _secondaryButton(
              c,
              icon: Icons24.image,
              label: s.scanGallery,
              onTap: available ? _pickFromGallery : null,
            ),
          ),
          Expanded(
            child: _secondaryButton(
              c,
              icon: Icons24.search,
              label: s.scanSearchInstead,
              onTap: _openManual,
            ),
          ),
        ],
      ),

      AppCard(
        radius: 22,
        child: VGap(
          10,
          cross: CrossAxisAlignment.start,
          children: [
            Kicker(s.scanTipsHead),
            for (final tip in s.scanTips)
              HGap(
                10,
                children: [
                  IconChip(
                    icon: Icons24.check,
                    size: 26,
                    iconSize: 14,
                    bg: c.accent2Ramp.c100,
                    border: c.accent2Ramp.c300,
                    fg: c.accent2Ramp.c700,
                  ),
                  Expanded(child: P(tip, style: context.t.caption)),
                ],
              ),
          ],
        ),
      ),

      P(s.scanPrivacy, style: context.t.footnote),
    ];
  }

  Widget _secondaryButton(dynamic c,
          {required String icon,
          required String label,
          required VoidCallback? onTap}) =>
      Semantics(
        button: true,
        label: label,
        child: GestureDetector(
          onTap: onTap,
          child: Opacity(
            opacity: onTap == null ? 0.45 : 1,
            child: AppCard(
              radius: 99,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                spacing: 8,
                children: [
                  LineIcon(icon, size: 17, color: c.accentRamp.c700),
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: context.t.captionStrong
                          .copyWith(color: c.accentRamp.c800),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  // ── step 2: camera ──────────────────────────────────────────────────

  Widget _cameraView(BuildContext context) {
    final s = context.s;
    final cam = _cam;
    final ready = cam != null && cam.value.isInitialized;
    const fg = Colors.white;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (ready)
            Semantics(
              label: s.scanGuide,
              image: true,
              child: ClipRect(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    // The preview reports landscape sizes; the phone is upright.
                    width: cam.value.previewSize?.height ?? 720,
                    height: cam.value.previewSize?.width ?? 1280,
                    child: CameraPreview(cam),
                  ),
                ),
              ),
            )
          else if (_camFailed)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  s.scanCameraUnavailable,
                  textAlign: TextAlign.center,
                  style: context.t.body.copyWith(color: fg),
                ),
              ),
            )
          else
            const Center(child: CircularProgressIndicator(color: fg)),

          // The plate guide: everything outside the circle is dimmed.
          if (ready)
            IgnorePointer(child: CustomPaint(painter: _PlateGuidePainter())),

          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _camButton(
                        icon: Icons24.close,
                        label: s.scanClose,
                        onTap: () async {
                          await _closeCamera();
                          if (mounted) setState(() => _step = _Step.start);
                        },
                      ),
                      if (ready)
                        _camButton(
                          icon: Icons24.zap,
                          label: s.scanFlash,
                          active: _flash != FlashMode.off,
                          onTap: _toggleFlash,
                        ),
                    ],
                  ),
                ),
                const Spacer(),
                if (ready)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 22),
                    child: Text(
                      s.scanGuide,
                      style: context.t.bodyStrong.copyWith(
                        color: fg,
                        shadows: const [
                          Shadow(blurRadius: 8, color: Colors.black54)
                        ],
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(30, 0, 30, 26),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _camButton(
                        icon: Icons24.image,
                        label: s.scanGallery,
                        onTap: _pickFromGallery,
                      ),
                      Semantics(
                        button: true,
                        label: s.scanShutter,
                        child: GestureDetector(
                          onTap: ready ? _shoot : null,
                          child: Container(
                            width: 78,
                            height: 78,
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: fg, width: 4),
                            ),
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: ready && !_shooting
                                    ? fg
                                    : fg.withValues(alpha: 0.4),
                              ),
                            ),
                          ),
                        ),
                      ),
                      _camButton(
                        icon: Icons24.flipCamera,
                        label: s.scanFlip,
                        onTap: _cameras.length > 1 ? _flipCamera : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _camButton({
    required String icon,
    required String label,
    required VoidCallback? onTap,
    bool active = false,
  }) =>
      Semantics(
        button: true,
        label: label,
        child: GestureDetector(
          onTap: onTap,
          child: Opacity(
            opacity: onTap == null ? 0.35 : 1,
            child: Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active
                    ? Colors.white
                    : Colors.black.withValues(alpha: 0.38),
              ),
              child: Center(
                child: LineIcon(icon,
                    size: 21, color: active ? Colors.black : Colors.white),
              ),
            ),
          ),
        ),
      );

  // ── step 3: analysing ───────────────────────────────────────────────

  List<Widget> _analyzingBody(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final steps = s.scanBusySteps;

    return [
      Text(s.scanBusyHead,
          style: context.t.screenTitleSm.copyWith(color: c.text)),
      if (_photo != null)
        ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: AspectRatio(
            aspectRatio: _photoAspect ?? 4 / 3,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(_photo!, fit: BoxFit.cover, gaplessPlayback: true),
                Container(color: Colors.black.withValues(alpha: 0.28)),
                const Center(
                    child: CircularProgressIndicator(color: Colors.white)),
              ],
            ),
          ),
        ),
      AppCard(
        radius: 22,
        child: VGap(
          12,
          cross: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < steps.length; i++)
              HGap(
                10,
                children: [
                  IconChip(
                    icon: i < _busyStep ? Icons24.check : Icons24.sparkles,
                    size: 28,
                    iconSize: 14,
                    bg: i < _busyStep ? c.accent2Ramp.c100 : c.neutral.c200,
                    border:
                        i < _busyStep ? c.accent2Ramp.c300 : c.neutral.c300,
                    fg: i < _busyStep ? c.accent2Ramp.c700 : c.neutral.c600,
                  ),
                  Expanded(
                    child: Text(
                      steps[i],
                      style: (i <= _busyStep
                              ? context.t.bodyStrong
                              : context.t.body)
                          .copyWith(
                              color: i <= _busyStep
                                  ? c.text
                                  : c.neutral.c600),
                    ),
                  ),
                ],
              ),
            AnimatedBuilder(
              animation: _progress,
              builder: (context, _) => ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: _progress.value,
                  minHeight: 7,
                  color: c.accent,
                  backgroundColor: c.accentRamp.c100,
                ),
              ),
            ),
          ],
        ),
      ),
      P(s.scanBusyFoot,
          align: TextAlign.center, style: context.t.footnote),
    ];
  }

  // ── step 4: review ──────────────────────────────────────────────────

  List<Widget> _reviewBody(BuildContext context) {
    final c = context.c;
    final s = context.s;
    final n = context.n;
    final result = _result;
    final hasPhoto = _photo != null;

    return [
      HGap(
        10,
        children: [
          Expanded(
            child: Text(
              hasPhoto || _anyPhoto ? s.scanReviewHead : s.scanHead,
              style: context.t.screenTitleSm.copyWith(color: c.text),
            ),
          ),
          if (hasPhoto)
            GhostButton(
              label: s.scanRetake,
              icon: Icons24.navCamera,
              onPressed: _retake,
            ),
        ],
      ),
      P(s.scanSub, style: context.t.caption),

      if (hasPhoto) _photoWithBoxes(c),

      if (hasPhoto && result != null && result.modelAvailable &&
          result.items.isNotEmpty)
        _scaleTip(c, s, result.scaleReference),

      // The model was unreachable, or found nothing: say so, then search.
      if (result != null &&
          (!result.modelAvailable || result.items.isEmpty) &&
          hasPhoto)
        AppCard(
          radius: 18,
          color: c.cautionTint,
          borderColor: c.cautionBorder,
          child: P(
            result.modelAvailable ? s.scanNoFood : s.scanFailed,
            style: context.t.caption,
            color: c.caution,
          ),
        ),

      _slotPicker(s),

      if (_drafts.isNotEmpty) ...[
        Kicker(_anyPhoto ? s.scanDetected : s.scanEstimatedTotal),
        VGap(
          9,
          children: [
            for (var i = 0; i < _drafts.length; i++) _draftRow(c, s, n, i),
          ],
        ),
      ],

      // Adding what the camera missed, or the whole meal by hand.
      if (!_searchOpen)
        Center(
          child: GhostButton(
            label: s.scanAddItem,
            icon: Icons24.plus,
            onPressed: () => setState(() => _searchOpen = true),
          ),
        )
      else ...[
        FieldCard(
          label: s.scanSearchFood,
          icon: Icons24.search,
          child: BareInput(
            controller: _search,
            hint: s.lang == 'bn' ? 'ভাত, ডাল, রুটি…' : 'rice, dal, roti…',
            onChanged: _searchFoods,
          ),
        ),
        if (_results.isEmpty && _search.text.isNotEmpty)
          P(s.scanNoResults, style: context.t.caption)
        else
          VGap(
            8,
            children: [
              for (final food in _results.take(6)) _foodRow(c, s, n, food),
            ],
          ),
      ],

      if (_drafts.isNotEmpty) _totalCard(c, s, n),

      if (_error != null)
        AppCard(
          radius: 18,
          color: c.cautionTint,
          borderColor: c.cautionBorder,
          child: P(_error!, style: context.t.caption, color: c.caution),
        ),

      _saving
          ? Center(child: CircularProgressIndicator(color: c.accent))
          : PillButton(
              label: s.scanSaveMeal,
              enabled: _drafts.isNotEmpty,
              onPressed: _save,
              onDisabledTap: () => showToast(context, s.scanSub),
            ),

      // Rule 3, restated where a user can see it.
      AppCard(
        radius: 18,
        color: c.neutral.c200,
        borderColor: c.neutral.c300,
        child: VGap(
          6,
          cross: CrossAxisAlignment.start,
          children: [
            P(s.scanFoot, style: context.t.footnote),
            P(s.scanConfirmNote, style: context.t.footnote),
            P(s.scanPlaceholderNote, style: context.t.footnote),
          ],
        ),
      ),
    ];
  }

  /// The photo, with each detected item outlined and labelled.
  Widget _photoWithBoxes(dynamic c) {
    final s = context.s;
    return Semantics(
      image: true,
      label: s.scanPhotoLabel,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: AspectRatio(
          aspectRatio: _photoAspect ?? 4 / 3,
          child: LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              final h = box.maxHeight;
              final rows = _drafts.where(_boxes.containsKey).toList();
              return Stack(
                children: [
                  Positioned.fill(
                    child: Image.memory(_photo!,
                        fit: BoxFit.cover, gaplessPlayback: true),
                  ),
                  for (final d in rows)
                    Positioned(
                      left: _boxes[d]![0] * w,
                      top: _boxes[d]![1] * h,
                      width: _boxes[d]![2] * w,
                      height: _boxes[d]![3] * h,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: d.needsReview
                                ? c.caution
                                : const Color(0xFFFFFDF9),
                            width: 2,
                          ),
                        ),
                        alignment: AlignmentDirectional.topStart,
                        child: Container(
                          margin: const EdgeInsets.all(5),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            d.displayName(s.lang),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.t.footnote.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _scaleTip(dynamic c, dynamic s, bool found) => AppCard(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        color: found ? c.accent2Ramp.c100 : c.neutral.c200,
        borderColor: found ? c.accent2Ramp.c300 : c.neutral.c300,
        child: HGap(
          10,
          children: [
            LineIcon(found ? Icons24.check : Icons24.ruler,
                size: 17,
                color: found ? c.accent2Ramp.c700 : c.neutral.c600),
            Expanded(
              child: P(found ? s.scanSpoonOk : s.scanSpoonTip,
                  style: context.t.caption),
            ),
          ],
        ),
      );

  Widget _foodRow(dynamic c, dynamic s, dynamic n, Food food) {
    final already = _drafts.any((d) => d.foodId == food.id);
    return GestureDetector(
      onTap: already
          ? null
          : () => setState(() => _drafts.add(MealItemDraft(
                foodId: food.id,
                name: food.nameEn,
                nameLocal: food.nameLocal,
                unit: food.units.isEmpty ? 'serving' : food.units.first,
                kcalPer100g: food.kcalPer100g,
                portionGrams: food.portionGrams,
              ))),
      child: AppCard(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        color: already ? c.accentRamp.c100 : c.card,
        borderColor: already ? c.accentRamp.c300 : c.neutral.c300,
        child: HGap(
          10,
          children: [
            Expanded(
              child: VGap(
                2,
                cross: CrossAxisAlignment.start,
                children: [
                  Text(
                    food.nameLocal != null && s.lang == 'bn'
                        ? food.nameLocal!
                        : food.nameEn,
                    style: context.t.bodyStrong.copyWith(color: c.text),
                  ),
                  Text(
                    '${n.int_(food.kcalPer100g)} kcal / 100 g',
                    style: context.t.footnote.copyWith(color: c.neutral.c600),
                  ),
                ],
              ),
            ),
            LineIcon(already ? Icons24.check : Icons24.plus,
                size: 17, color: c.accentRamp.c700),
          ],
        ),
      ),
    );
  }

  /// An editable portion row. This is the "human disposes" half — the item,
  /// the quantity and the unit are the user's, always.
  Widget _draftRow(dynamic c, dynamic s, dynamic n, int index) {
    final draft = _drafts[index];
    final units = <String>{
      draft.unit,
      ...draft.portionGrams.keys.where((u) => u != 'g' && u != 'gram'),
    }.toList();

    void edit(VoidCallback change) => setState(() {
          change();
          draft.needsReview = false;
        });

    return AppCard(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      color: draft.needsReview ? c.cautionTint : c.card,
      borderColor: draft.needsReview ? c.cautionBorder : c.neutral.c300,
      child: VGap(
        10,
        cross: CrossAxisAlignment.start,
        children: [
          HGap(
            10,
            children: [
              Expanded(
                child: VGap(
                  3,
                  cross: CrossAxisAlignment.start,
                  children: [
                    Text(draft.displayName(s.lang),
                        style: context.t.rowTitle.copyWith(color: c.text)),
                    if (draft.needsReview)
                      Text(s.scanCheckThis,
                          style: context.t.footnote
                              .copyWith(color: c.caution))
                    else if (draft.fromPhoto && draft.foodId == null)
                      Text(s.scanAiEstimate,
                          style: context.t.footnote
                              .copyWith(color: c.neutral.c600)),
                  ],
                ),
              ),
              Text(
                '~${n.int_(draft.estimatedKcal)} kcal',
                style: context.t.captionStrong.copyWith(color: c.neutral.c700),
              ),
              CircleIconButton(
                icon: Icons24.close,
                size: 30,
                iconSize: 13,
                semanticLabel: s.cancel,
                onPressed: () => setState(() {
                  _boxes.remove(draft);
                  _drafts.removeAt(index);
                }),
              ),
            ],
          ),
          HGap(
            10,
            children: [
              CircleIconButton(
                icon: 'M5 12h14',
                size: 32,
                iconSize: 15,
                semanticLabel: '−',
                onPressed: draft.quantity > 0.5
                    ? () => edit(() => draft.quantity -= 0.5)
                    : null,
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48),
                child: Text(
                  n.decimal(draft.quantity, places: 1),
                  textAlign: TextAlign.center,
                  style: context.t.statValue
                      .copyWith(color: c.text, fontSize: 19),
                ),
              ),
              CircleIconButton(
                icon: Icons24.plus,
                size: 32,
                iconSize: 15,
                semanticLabel: '+',
                onPressed: () => edit(() => draft.quantity += 0.5),
              ),
              // Local portion units from the food's own table.
              if (units.length > 1)
                Expanded(
                  child: Segmented<String>(
                    value: draft.unit,
                    compact: true,
                    options: [for (final u in units.take(3)) (u, s.scanUnit(u))],
                    onChanged: (u) => edit(() => draft.unit = u),
                  ),
                )
              else
                Expanded(
                  child: Text(s.scanUnit(draft.unit),
                      style: context.t.caption
                          .copyWith(color: c.neutral.c600)),
                ),
            ],
          ),
          Text('${n.int_(draft.grams)} g',
              style: context.t.footnote.copyWith(color: c.neutral.c600)),
        ],
      ),
    );
  }

  Widget _totalCard(dynamic c, dynamic s, dynamic n) {
    // The same band the server stores: ±24% for a photo meal, ±14% by hand.
    final width = _anyPhoto ? 0.24 : 0.14;
    final low = (_estimatedKcal * (1 - width)).round();
    final high = (_estimatedKcal * (1 + width)).round();
    return AppCard(
      radius: 22,
      color: c.accentRamp.c100,
      borderColor: c.accentRamp.c300,
      child: VGap(
        4,
        cross: CrossAxisAlignment.start,
        children: [
          Kicker(s.trackerEstimate, color: c.accentRamp.c800),
          Text(
            '${n.int_(low)}–${n.int_(high)} kcal',
            style: context.t.statValue.copyWith(color: c.accentRamp.c900),
          ),
        ],
      ),
    );
  }
}

/// Dims everything outside a centred circle — "fit the plate inside".
class _PlateGuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide * 0.40;
    final centre = Offset(size.width / 2, size.height * 0.46);
    final circle = Rect.fromCircle(center: centre, radius: r);
    final dim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addOval(circle);
    canvas.drawPath(dim, Paint()..color = const Color(0x66000000));
    canvas.drawOval(
      circle,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = const Color(0xE6FFFDF9),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
