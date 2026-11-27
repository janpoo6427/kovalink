import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:kovalink/src/features/road_view/renderer_diagnostics.dart';
import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_director.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/gpu_scene/gpu_road_renderer.dart';
import 'package:kovalink/src/models/ego_vehicle_profile.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:thermion_flutter/thermion_flutter.dart';

/// Everything a GPU surface needs to draw one frame.
class GpuSurfaceRequest {
  const GpuSurfaceRequest({
    required this.scene,
    required this.director,
    required this.theme,
    required this.layers,
    required this.vehicle,
    required this.viewpoint,
    this.egoGlbPath,
    this.egoBodyNode,
    this.egoExcludeNodes = const {},
  });

  final RoadScene scene;
  final DirectorFrame director;
  final SceneTheme theme;
  final SceneLayers layers;
  final EgoVehicleProfile vehicle;
  final SceneViewpoint viewpoint;

  /// GLB of an imported model pack (asset path or file path); null = the
  /// built-in KovaLink SUV with GPU materials.
  final String? egoGlbPath;

  /// Manifest body node of that pack.
  final String? egoBodyNode;
  final Set<String> egoExcludeNodes;
}

/// Builds the GPU surface for a request. Tests and worker captures inject
/// a builder that shows a frame rendered headlessly by the same
/// [GpuRoadRenderer]; the app uses [GpuRoadSurface].
typedef GpuSurfaceBuilder =
    Widget Function(BuildContext context, GpuSurfaceRequest request);

/// Receives scene updates once the native viewer exists.
abstract class GpuFrameSink {
  Future<void> update(GpuFrameInput input);
  Future<void> dispose();
}

/// Stage reports from a [GpuViewHost] to [GpuRoadSurface].
class GpuViewCallbacks {
  const GpuViewCallbacks({
    required this.onViewerReady,
    required this.onTextureReady,
    required this.onError,
  });

  /// The viewer exists; scene updates go to [GpuFrameSink].
  final void Function(GpuFrameSink sink) onViewerReady;

  /// A platform texture is registered with Flutter and a first frame was
  /// submitted into it.
  final VoidCallback onTextureReady;

  /// Any failure while creating the viewer or its texture.
  final void Function(String stage, Object error) onError;
}

/// Hosts the native GPU view. The app uses [ThermionGpuViewHost]; tests
/// inject fakes that never produce a frame, throw, or behave.
abstract class GpuViewHost {
  const GpuViewHost();

  /// Short name of the presentation path for 설정 → 진단.
  String get label;

  /// How to check that this host's frames really reach the screen.
  GpuPresentationProbe get probe => screenProbe;

  /// Frames the native renderer has been asked to draw since the app
  /// started (monotonic); -1 = this host cannot tell.
  int get renderedFrames => -1;

  Widget build(BuildContext context, GpuViewCallbacks callbacks);

  /// Stops ([drawing] false) or restarts the native render loop while a
  /// full-screen page covers the drive screen. Hosts without one ignore it.
  void setDrawing(bool drawing) {}
}

/// Filament (thermion) texture view.
class ThermionGpuViewHost extends GpuViewHost {
  const ThermionGpuViewHost();

  @override
  void setDrawing(bool drawing) {
    final plugin = ThermionFlutterPlugin.instance;
    drawing ? plugin.resumeFrameScheduler() : plugin.pauseFrameScheduler();
  }

  static AndroidTextureSource get textureSource =>
      ThermionFlutterPlugin.instance.options.nativeOptions.androidTextureSource;

  /// True while a SurfaceTexture retry is still possible (Android starts on
  /// SurfaceProducer, see main.dart).
  static bool get canRetryWithSurfaceTexture =>
      !kIsWeb &&
      Platform.isAndroid &&
      textureSource == AndroidTextureSource.surfaceProducer;

  /// Switches later texture allocations to SurfaceTexture (opaque road
  /// scene; Flutter samples it without the ImageReader path).
  static void useSurfaceTexture() =>
      _setTextureSource(AndroidTextureSource.surfaceTexture);

  /// Source chosen at start-up (main.dart), restored after a failed
  /// SurfaceTexture retry so the transparent vehicle overlay keeps alpha.
  static AndroidTextureSource? _startSource;

  static void restoreTextureSource() {
    final start = _startSource;
    if (start != null && start != textureSource) _setTextureSource(start);
  }

  static void _setTextureSource(AndroidTextureSource source) {
    final plugin = ThermionFlutterPlugin.instance;
    final o = plugin.options;
    final n = o.nativeOptions;
    _startSource ??= n.androidTextureSource;
    plugin.setOptions(
      ThermionFlutterOptions(
        webOptions: o.webOptions,
        uberarchivePath: o.uberarchivePath,
        nativeOptions: NativeOptions(
          backend: n.backend,
          androidTextureSource: source,
          renderTargetColorTextureFormat: n.renderTargetColorTextureFormat,
          renderTargetDepthTextureFormat: n.renderTargetDepthTextureFormat,
          createOverlay: n.createOverlay,
        ),
      ),
    );
  }

  @override
  int get renderedFrames => ThermionFlutterPlugin.instance.renderedFrameCount;

  @override
  String get label {
    if (kIsWeb) return 'web';
    if (!Platform.isAndroid) return Platform.operatingSystem;
    return switch (textureSource) {
      AndroidTextureSource.surfaceProducer => 'SurfaceProducer',
      AndroidTextureSource.surfaceTexture => 'SurfaceTexture',
    };
  }

  @override
  Widget build(BuildContext context, GpuViewCallbacks callbacks) {
    return ThermionWidget.create(
      viewerFactory: () async {
        try {
          final viewer = await ThermionFlutterPlugin.createViewer();
          await viewer.setRendering(true);
          callbacks.onViewerReady(_RendererSink(GpuRoadRenderer(viewer)));
          return viewer;
        } catch (error) {
          callbacks.onError('3D 엔진 시작', error);
          rethrow;
        }
      },
      onTextureReady: callbacks.onTextureReady,
      onError: (error) => callbacks.onError('텍스처', error),
    );
  }
}

class _RendererSink implements GpuFrameSink {
  _RendererSink(this.renderer);
  final GpuRoadRenderer renderer;

  @override
  Future<void> update(GpuFrameInput input) => renderer.update(input);

  @override
  Future<void> dispose() => renderer.dispose();
}

enum GpuProbeVerdict { visible, transparent, black, unknown }

/// What a downscaled snapshot of the GPU texture showed.
@immutable
class GpuProbeResult {
  const GpuProbeResult(
    this.verdict, {
    this.coverage = 0,
    this.lit = 0,
    this.note,
  });

  const GpuProbeResult.unknown(String note)
    : this(GpuProbeVerdict.unknown, note: note);

  final GpuProbeVerdict verdict;

  /// Share of pixels with any alpha.
  final double coverage;

  /// Share of covered pixels that are not near-black.
  final double lit;
  final String? note;

  /// Below this coverage the texture is treated as not shown at all.
  static const minCoverage = 0.5;

  /// Below this share of non-black pixels the frame counts as black.
  static const minLit = 0.02;

  /// Classifies RGBA bytes (premultiplied or straight).
  static GpuProbeResult analyze(Uint8List rgba) {
    final pixels = rgba.length ~/ 4;
    if (pixels == 0) return const GpuProbeResult.unknown('빈 이미지');
    var covered = 0;
    var lit = 0;
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      if (rgba[i + 3] <= 16) continue;
      covered++;
      if (math.max(rgba[i], math.max(rgba[i + 1], rgba[i + 2])) > 14) lit++;
    }
    final coverage = covered / pixels;
    final litShare = covered == 0 ? 0.0 : lit / covered;
    final verdict = coverage < minCoverage
        ? GpuProbeVerdict.transparent
        : litShare < minLit
        ? GpuProbeVerdict.black
        : GpuProbeVerdict.visible;
    return GpuProbeResult(verdict, coverage: coverage, lit: litShare);
  }

  /// Coverage and lit shares in percent.
  String get shares =>
      '보임 ${(coverage * 100).round()}%, 밝음 ${(lit * 100).round()}%';

  String get describe {
    final pct = shares;
    return switch (verdict) {
      GpuProbeVerdict.visible => '정상 ($pct)',
      GpuProbeVerdict.transparent => '비어 있음 ($pct)',
      GpuProbeVerdict.black => '검은 화면 ($pct)',
      GpuProbeVerdict.unknown => '확인 못 함${note == null ? '' : ' ($note)'}',
    };
  }
}

/// Reads what is actually composited for the GPU texture.
typedef GpuPresentationProbe =
    Future<GpuProbeResult> Function(RenderRepaintBoundary? boundary);

/// Default probe: a ~64 px snapshot of the texture layer.
Future<GpuProbeResult> screenProbe(RenderRepaintBoundary? boundary) async {
  if (boundary == null || !boundary.attached || boundary.size.isEmpty) {
    return const GpuProbeResult.unknown('화면 영역 없음');
  }
  final longest = math.max(boundary.size.width, boundary.size.height);
  final image = await boundary.toImage(
    pixelRatio: (64 / longest).clamp(0.01, 1.0),
  );
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return const GpuProbeResult.unknown('픽셀 없음');
    return GpuProbeResult.analyze(data.buffer.asUint8List());
  } finally {
    image.dispose();
  }
}

/// Why the GPU view gave up.
@immutable
class GpuFailure {
  const GpuFailure(this.stage, this.reason, {this.retryable = true, this.note});

  final String stage;

  /// Short technical line (설정 → 진단 ‘바꾼 이유’, logcat).
  final String reason;

  /// The same in plain words for people (해요체); null = [reason] only.
  final String? note;

  /// A different texture path might help (not for plain slowness).
  final bool retryable;

  @override
  String toString() => reason;
}

/// Plain-language sentence for a watchdog timeout at [stage].
String gpuTimeoutNote(String stage, String secs) => switch (stage) {
  '3D 엔진 시작' => '$secs초 동안 3D 엔진이 켜지지 않았어요.',
  '텍스처 등록' => '3D 엔진은 켜졌지만 $secs초 동안 화면에 연결되지 않았어요.',
  '첫 장면 그리기' => '화면은 연결됐지만 $secs초 동안 첫 장면을 다 그리지 못했어요.',
  '화면 확인' => '$secs초 안에 3D 화면을 확인하지 못했어요.',
  _ => '3D 엔진은 켜졌지만 $secs초 동안 화면 연결도, 첫 장면도 끝나지 않았어요.',
};

/// Live Filament view (thermion texture) driven by [GpuRoadRenderer].
/// Frames are coalesced: while one update is in flight only the newest
/// request is kept, so a slow phone drops frames instead of lagging.
///
/// A watchdog requires a confirmed on-screen frame (viewer created, texture
/// registered, first scene drawn, snapshot not blank) within
/// [startTimeout]; otherwise [onFallback] fires so the screen can switch
/// to the software renderer instead of staying black. After the app comes
/// back to the foreground a confirmed view is checked again (the surface
/// may have been recreated), with [onUnverified] in between.
class GpuRoadSurface extends StatefulWidget {
  const GpuRoadSurface({
    required this.request,
    this.onFallback,
    this.onVerified,
    this.onUnverified,
    this.host = const ThermionGpuViewHost(),
    this.startTimeout = defaultStartTimeout,
    this.probe,
    this.probeDelay = const Duration(milliseconds: 400),
    this.probeTimeout = const Duration(seconds: 2),
    this.resumeProbeDelay = const Duration(milliseconds: 800),
    this.resumeProbes = 3,
    super.key,
  });

  final GpuSurfaceRequest request;

  /// Called once if the GPU view cannot start, shows nothing, or stays too
  /// slow (average update above [slowFrameMs] over [slowWindow] frames).
  final void Function(GpuFailure failure)? onFallback;

  /// Called when a GPU frame was confirmed on screen (again after a
  /// foreground re-check).
  final VoidCallback? onVerified;

  /// Called when a confirmed view needs to be checked again (app back in
  /// the foreground); the caller shows its software road meanwhile.
  final VoidCallback? onUnverified;

  final GpuViewHost host;

  /// Time allowed from mount to a drawn, registered first frame.
  final Duration startTimeout;

  /// Null = [GpuViewHost.probe].
  final GpuPresentationProbe? probe;

  /// Wait after the first frame before snapshotting it.
  final Duration probeDelay;
  final Duration probeTimeout;

  /// Foreground re-check: wait before each snapshot, and how many blank
  /// snapshots in a row count as failure (Android may need a moment to
  /// hand back the surface).
  final Duration resumeProbeDelay;
  final int resumeProbes;

  static const defaultStartTimeout = Duration(milliseconds: 3000);
  static const slowFrameMs = 70;
  static const slowWindow = 90;

  /// Platforms where the thermion plugin renders into a Flutter texture
  /// (the real OS, so widget tests on a desktop host stay on software).
  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  State<GpuRoadSurface> createState() => _GpuRoadSurfaceState();
}

class _GpuRoadSurfaceState extends State<GpuRoadSurface>
    with WidgetsBindingObserver {
  final _diag = RendererDiagnostics.instance;
  final _boundary = GlobalKey();
  late final GpuViewCallbacks _callbacks = GpuViewCallbacks(
    onViewerReady: _onViewerReady,
    onTextureReady: _onTextureReady,
    onError: _onError,
  );

  GpuFrameSink? _sink;
  bool _busy = false;
  GpuSurfaceRequest? _pending;
  Size _size = Size.zero;
  String? _glbPath;
  Uint8List? _glb;

  Timer? _watchdog;
  Timer? _probeTimer;
  bool _textureReady = false;
  bool _firstUpdate = false;
  bool _probing = false;
  bool _verified = false;
  bool _failed = false;
  final _sinceMount = Stopwatch();

  /// [GpuViewHost.renderedFrames] when this check window started.
  int _framesAtStart = -1;
  final _sinceCheck = Stopwatch();

  /// Foreground re-check in progress: blank snapshots seen so far.
  int? _resumeBlank;

  /// Ticker mode where the surface sits: off while a full-screen page
  /// covers the drive screen.
  ValueListenable<TickerModeData>? _tickerMode;

  /// Covered after the 3D view was confirmed: scene updates wait and the
  /// native loop is stopped. Never while starting or re-checking, so
  /// those checks still see frames.
  bool _held = false;

  /// Surfaces holding right now; the native loop draws again when none is
  /// left (an attempt replaced while covered hands over without a gap).
  static final Set<_GpuRoadSurfaceState> _holding = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mode = TickerMode.getValuesNotifier(context);
    if (!identical(mode, _tickerMode)) {
      _tickerMode?.removeListener(_syncHold);
      _tickerMode = mode..addListener(_syncHold);
    }
    _syncHold();
  }

  void _syncHold() {
    final covered = !(_tickerMode?.value.enabled ?? true);
    _setHeld(covered && _verified && !_failed && mounted);
  }

  void _setHeld(bool held) {
    if (held == _held) return;
    _held = held;
    final drewBefore = _holding.isEmpty;
    held ? _holding.add(this) : _holding.remove(this);
    if (drewBefore != _holding.isEmpty) {
      widget.host.setDrawing(_holding.isEmpty);
    }
    if (held) {
      _diag.event('화면이 가려져서 3D를 쉬어요');
      return;
    }
    _diag.event('3D를 다시 그려요');
    if (mounted && _pending != null) {
      // Shown again: draw the newest scene that waited.
      scheduleMicrotask(() {
        if (mounted && !_held && _pending != null) _schedule(_pending!);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sinceMount.start();
    _startFrameWindow();
    _watchdog = Timer(widget.startTimeout, _onTimeout);
    _diag.setFrames(null);
    _diag.event('3D 화면 켜기 시작 (${widget.host.label})');
  }

  static String _secs(int ms) => '${(ms / 1000).toStringAsFixed(2)}초';

  void _startFrameWindow() {
    _framesAtStart = widget.host.renderedFrames;
    _sinceCheck
      ..reset()
      ..start();
  }

  /// Frames drawn in the current check window (null = host cannot tell).
  RendererFrames? _frameWindow() {
    final now = widget.host.renderedFrames;
    if (_framesAtStart < 0 || now < 0) return null;
    return RendererFrames(
      now - _framesAtStart,
      _sinceCheck.elapsedMilliseconds,
    );
  }

  String get _stage {
    if (_sink == null) return '3D 엔진 시작';
    if (!_textureReady && !_firstUpdate) return '텍스처 만들기·첫 장면 그리기';
    if (!_textureReady) return '텍스처 등록';
    if (!_firstUpdate) return '첫 장면 그리기';
    return '화면 확인';
  }

  void _onViewerReady(GpuFrameSink sink) {
    if (!mounted || _failed) {
      unawaited(sink.dispose());
      return;
    }
    _sink = sink;
    _diag.event('3D 엔진 켜짐 (${_secs(_sinceMount.elapsedMilliseconds)})');
    _schedule(widget.request);
  }

  void _onTextureReady() {
    if (_failed || !mounted) return;
    // Texture preparation also resets the native camera projection. Reapply
    // the scene camera after every allocation, not only the initial one.
    _scheduleAfterLayout();
    if (_textureReady) return;
    _textureReady = true;
    _diag.event('화면 연결됨 (${_secs(_sinceMount.elapsedMilliseconds)})');
    _maybeProbe();
  }

  void _onError(String stage, Object error) {
    final what = stage == '텍스처' ? '3D 화면을 연결하다가' : '3D 엔진을 켜다가';
    _fail(
      GpuFailure(
        stage,
        '$stage 중 오류가 났어요: ${_short(error)}',
        note: '$what 오류가 났어요.',
      ),
    );
  }

  void _onTimeout() {
    if (_verified || _failed || _probing || !mounted) return;
    final secs = (widget.startTimeout.inMilliseconds / 1000).toStringAsFixed(1);
    final stage = _stage;
    _fail(
      GpuFailure(
        stage,
        '$secs초 안에 3D 화면이 안 나왔어요 (멈춘 단계: $stage)',
        note: gpuTimeoutNote(stage, secs),
      ),
    );
  }

  void _maybeProbe() {
    if (!_textureReady || !_firstUpdate) return;
    if (_probing || _verified || _failed) return;
    _probing = true;
    _watchdog?.cancel();
    _probeTimer = Timer(widget.probeDelay, _probeAfterFrame);
  }

  void _probeAfterFrame() {
    if (!mounted || _failed) return;
    SchedulerBinding.instance.addPostFrameCallback((_) => _runProbe());
    SchedulerBinding.instance.scheduleFrame();
  }

  Future<void> _runProbe() async {
    if (!mounted || _failed) return;
    final boundary =
        _boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    GpuProbeResult result;
    try {
      final probe = widget.probe ?? widget.host.probe;
      result = await probe(boundary).timeout(widget.probeTimeout);
    } catch (error) {
      result = GpuProbeResult.unknown(_short(error));
    }
    if (!mounted || _failed) return;
    _diag.setProbe(result.describe);
    final resumeBlank = _resumeBlank;
    if (resumeBlank != null) {
      _onResumeProbe(result, resumeBlank);
      return;
    }
    switch (result.verdict) {
      case GpuProbeVerdict.visible:
        _verified = true;
        _syncHold();
        _diag.setFrames(_frameWindow());
        _diag.event('3D 화면 확인됨 (${_secs(_sinceMount.elapsedMilliseconds)})');
        widget.onVerified?.call();
      case GpuProbeVerdict.transparent:
        _fail(
          GpuFailure(
            '화면 확인',
            '3D 화면이 비어 있음 (${result.shares})',
            note: '3D 화면이 비어 있었어요. 3D 그림이 화면까지 오지 못했어요.',
          ),
        );
      case GpuProbeVerdict.black:
        _fail(
          GpuFailure(
            '화면 확인',
            '3D 화면이 검게 나왔어요 (${result.shares})',
            note: '3D 화면이 까맣게만 나왔어요.',
          ),
        );
      case GpuProbeVerdict.unknown:
        // Cannot tell: keep the GPU view, the software road stays under it.
        _diag.setFrames(_frameWindow());
        _diag.event('3D 화면을 확인할 수 없어서 2D 도로를 밑에 깔아 둬요');
    }
  }

  bool _layoutUpdateScheduled = false;

  void _scheduleAfterLayout() {
    if (_layoutUpdateScheduled || !mounted || _failed) return;
    _layoutUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _layoutUpdateScheduled = false;
      if (mounted && !_failed && !_size.isEmpty) _schedule(widget.request);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void didChangeMetrics() => _scheduleAfterLayout();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _scheduleAfterLayout();
    if (!_verified || _failed || !mounted) return;
    // Android may hand the texture a new surface after the app was in the
    // background; confirm frames reach the screen again.
    _verified = false;
    _syncHold();
    _resumeBlank = 0;
    _startFrameWindow();
    _diag.event('앱으로 돌아와서 3D 화면을 다시 확인해요');
    widget.onUnverified?.call();
    _probeTimer?.cancel();
    _probeTimer = Timer(widget.resumeProbeDelay, _probeAfterFrame);
  }

  void _onResumeProbe(GpuProbeResult result, int blank) {
    switch (result.verdict) {
      case GpuProbeVerdict.visible:
        _resumeBlank = null;
        _verified = true;
        _syncHold();
        _diag.setFrames(_frameWindow());
        _diag.event('돌아온 뒤 3D 화면 확인됨');
        widget.onVerified?.call();
      case GpuProbeVerdict.unknown:
        // Same as at start: keep GPU with the software road underneath.
        _resumeBlank = null;
        _diag.event('3D 화면을 확인할 수 없어서 2D 도로를 밑에 깔아 둬요');
      case GpuProbeVerdict.transparent || GpuProbeVerdict.black:
        if (blank + 1 < widget.resumeProbes) {
          _resumeBlank = blank + 1;
          _probeTimer = Timer(widget.resumeProbeDelay, _probeAfterFrame);
          return;
        }
        _resumeBlank = null;
        _fail(
          GpuFailure(
            '다시 확인',
            '앱으로 돌아온 뒤 3D 화면이 ${result.describe}',
            note: '앱으로 돌아온 뒤 3D 화면이 다시 나오지 않았어요.',
          ),
        );
    }
  }

  void _fail(GpuFailure failure) {
    if (_failed) return;
    _failed = true;
    _watchdog?.cancel();
    _probeTimer?.cancel();
    // Frame counts explain start/re-check failures, not later slowness.
    final frames = _verified ? null : _frameWindow();
    if (frames != null) _diag.setFrames(frames);
    _diag.event('3D 포기: ${failure.reason}');
    widget.onFallback?.call(_withFrames(failure, frames));
  }

  /// Adds what the frame counter says to the plain-language note: "never
  /// drew" and "drew but nothing showed" point at different causes.
  static GpuFailure _withFrames(GpuFailure failure, RendererFrames? frames) {
    if (frames == null || failure.note == null) return failure;
    final extra = frames.count == 0
        ? '그동안 3D 엔진이 그림을 한 장도 그리지 않았어요.'
        : '그동안 3D 엔진은 ${frames.count}장을 그렸어요.';
    return GpuFailure(
      failure.stage,
      failure.reason,
      retryable: failure.retryable,
      note: '${failure.note} $extra',
    );
  }

  static String _short(Object error) {
    final text = '$error'.replaceAll('\n', ' ');
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }

  @override
  void didUpdateWidget(covariant GpuRoadSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule(widget.request);
  }

  void _schedule(GpuSurfaceRequest request) {
    _pending = request;
    if (_busy || _sink == null || _held) return;
    unawaited(_pump());
  }

  Future<void> _pump() async {
    _busy = true;
    try {
      while (_pending != null && mounted && !_held) {
        final request = _pending!;
        _pending = null;
        if (request.egoGlbPath != _glbPath) {
          _glbPath = request.egoGlbPath;
          _glb = await _readGlb(request.egoGlbPath);
        }
        if (!mounted) return;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final sw = Stopwatch()..start();
        await _sink!.update(
          GpuFrameInput(
            scene: request.scene,
            director: request.director,
            // Match ThermionWidget's physical texture dimensions exactly.
            // Independent axis clamps change aspect on tall/high-DPI phones.
            width: (_size.width * dpr).ceil(),
            height: (_size.height * dpr).ceil(),
            theme: request.theme,
            layers: request.layers,
            vehicle: request.vehicle,
            viewpoint: request.viewpoint,
            egoPackGlb: _glb,
            egoPackKey: _glbPath,
            egoBodyNode: request.egoBodyNode,
            egoExcludeNodes: request.egoExcludeNodes,
          ),
        );
        if (!_firstUpdate) {
          _firstUpdate = true;
          _diag.event(
            '첫 장면 그림 (${_secs(sw.elapsedMilliseconds)} 걸림, '
            '시작 후 ${_secs(_sinceMount.elapsedMilliseconds)})',
          );
          _maybeProbe();
        }
        _frames++;
        _totalMs += sw.elapsedMilliseconds;
        if (_frames == GpuRoadSurface.slowWindow) {
          final avg = _totalMs / _frames;
          if (avg > GpuRoadSurface.slowFrameMs) {
            _fail(
              GpuFailure(
                '장면',
                '느려요: 한 장에 평균 ${avg.round()} ms '
                    '(기준 ${GpuRoadSurface.slowFrameMs} ms)',
                retryable: false,
                note:
                    '3D가 너무 느렸어요(한 장에 평균 ${avg.round()} ms). '
                    '부드럽게 보이도록 2D로 바꿨어요.',
              ),
            );
          }
          _frames = 0;
          _totalMs = 0;
        }
      }
    } catch (error) {
      _fail(
        GpuFailure(
          '장면',
          '장면 오류가 났어요: ${_short(error)}',
          note: '도로 장면을 그리다가 오류가 났어요.',
        ),
      );
    } finally {
      _busy = false;
    }
  }

  int _frames = 0;
  int _totalMs = 0;

  static Future<Uint8List?> _readGlb(String? path) async {
    if (path == null) return null;
    if (path.startsWith('asset://')) {
      final data = await rootBundle.load(path.substring(8));
      return data.buffer.asUint8List();
    }
    final file = File(
      path.startsWith('file://') ? Uri.parse(path).toFilePath() : path,
    );
    return file.existsSync() ? file.readAsBytes() : null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tickerMode?.removeListener(_syncHold);
    if (_held && _holding.remove(this) && _holding.isEmpty) {
      widget.host.setDrawing(true);
    }
    _watchdog?.cancel();
    _probeTimer?.cancel();
    unawaited(_sink?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_size != constraints.biggest) {
          _size = constraints.biggest;
          _scheduleAfterLayout();
        }
        return RepaintBoundary(
          key: _boundary,
          child: widget.host.build(context, _callbacks),
        );
      },
    );
  }
}
