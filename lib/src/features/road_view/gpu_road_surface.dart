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

  Widget build(BuildContext context, GpuViewCallbacks callbacks);
}

/// Filament (thermion) texture view.
class ThermionGpuViewHost extends GpuViewHost {
  const ThermionGpuViewHost();

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
  static void useSurfaceTexture() {
    final plugin = ThermionFlutterPlugin.instance;
    final o = plugin.options;
    final n = o.nativeOptions;
    plugin.setOptions(
      ThermionFlutterOptions(
        webOptions: o.webOptions,
        uberarchivePath: o.uberarchivePath,
        nativeOptions: NativeOptions(
          backend: n.backend,
          androidTextureSource: AndroidTextureSource.surfaceTexture,
          renderTargetColorTextureFormat: n.renderTargetColorTextureFormat,
          renderTargetDepthTextureFormat: n.renderTargetDepthTextureFormat,
          createOverlay: n.createOverlay,
        ),
      ),
    );
  }

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
  const GpuFailure(this.stage, this.reason, {this.retryable = true});

  final String stage;
  final String reason;

  /// A different texture path might help (not for plain slowness).
  final bool retryable;

  @override
  String toString() => reason;
}

/// Live Filament view (thermion texture) driven by [GpuRoadRenderer].
/// Frames are coalesced: while one update is in flight only the newest
/// request is kept, so a slow phone drops frames instead of lagging.
///
/// A watchdog requires a confirmed on-screen frame (viewer created, texture
/// registered, first scene drawn, snapshot not blank) within
/// [startTimeout]; otherwise [onFallback] fires so the screen can switch
/// to the software renderer instead of staying black.
class GpuRoadSurface extends StatefulWidget {
  const GpuRoadSurface({
    required this.request,
    this.onFallback,
    this.onVerified,
    this.host = const ThermionGpuViewHost(),
    this.startTimeout = defaultStartTimeout,
    this.probe,
    this.probeDelay = const Duration(milliseconds: 400),
    this.probeTimeout = const Duration(seconds: 2),
    super.key,
  });

  final GpuSurfaceRequest request;

  /// Called once if the GPU view cannot start, shows nothing, or stays too
  /// slow (average update above [slowFrameMs] over [slowWindow] frames).
  final void Function(GpuFailure failure)? onFallback;

  /// Called once when a GPU frame was confirmed on screen.
  final VoidCallback? onVerified;

  final GpuViewHost host;

  /// Time allowed from mount to a drawn, registered first frame.
  final Duration startTimeout;

  /// Null = [GpuViewHost.probe].
  final GpuPresentationProbe? probe;

  /// Wait after the first frame before snapshotting it.
  final Duration probeDelay;
  final Duration probeTimeout;

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

class _GpuRoadSurfaceState extends State<GpuRoadSurface> {
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

  @override
  void initState() {
    super.initState();
    _sinceMount.start();
    _watchdog = Timer(widget.startTimeout, _onTimeout);
    _diag.event('GPU 화면 시작 (${widget.host.label})');
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
    _diag.event('3D 엔진 준비 ${_sinceMount.elapsedMilliseconds} ms');
    _schedule(widget.request);
  }

  void _onTextureReady() {
    if (_textureReady || _failed || !mounted) return;
    _textureReady = true;
    _diag.event('텍스처 등록 ${_sinceMount.elapsedMilliseconds} ms');
    _maybeProbe();
  }

  void _onError(String stage, Object error) {
    _fail(GpuFailure(stage, '$stage 오류: ${_short(error)}'));
  }

  void _onTimeout() {
    if (_verified || _failed || _probing || !mounted) return;
    final secs = (widget.startTimeout.inMilliseconds / 1000).toStringAsFixed(1);
    _fail(GpuFailure(_stage, '$secs초 안에 3D 화면이 안 나옴 (멈춘 단계: $_stage)'));
  }

  void _maybeProbe() {
    if (!_textureReady || !_firstUpdate) return;
    if (_probing || _verified || _failed) return;
    _probing = true;
    _watchdog?.cancel();
    _probeTimer = Timer(widget.probeDelay, () {
      if (!mounted || _failed) return;
      SchedulerBinding.instance.addPostFrameCallback((_) => _runProbe());
      SchedulerBinding.instance.scheduleFrame();
    });
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
    switch (result.verdict) {
      case GpuProbeVerdict.visible:
        _verified = true;
        _diag.event('GPU 화면 확인 ${_sinceMount.elapsedMilliseconds} ms');
        widget.onVerified?.call();
      case GpuProbeVerdict.transparent:
        _fail(GpuFailure('화면 확인', '3D 화면이 비어 있음 (${result.shares})'));
      case GpuProbeVerdict.black:
        _fail(GpuFailure('화면 확인', '3D 화면이 검게 나옴 (${result.shares})'));
      case GpuProbeVerdict.unknown:
        // Cannot tell: keep the GPU view, the software road stays under it.
        _diag.event('화면 확인 못 함 — 소프트웨어 도로를 밑에 둠');
    }
  }

  void _fail(GpuFailure failure) {
    if (_failed) return;
    _failed = true;
    _watchdog?.cancel();
    _diag.event('GPU 포기: ${failure.reason}');
    widget.onFallback?.call(failure);
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
    if (_busy || _sink == null) return;
    unawaited(_pump());
  }

  Future<void> _pump() async {
    _busy = true;
    try {
      while (_pending != null && mounted) {
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
            width: (_size.width * dpr).round().clamp(16, 4096),
            height: (_size.height * dpr).round().clamp(16, 4096),
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
            '첫 장면 ${sw.elapsedMilliseconds} ms '
            '(시작 후 ${_sinceMount.elapsedMilliseconds} ms)',
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
                '느림: 평균 ${avg.round()} ms (기준 ${GpuRoadSurface.slowFrameMs} ms)',
                retryable: false,
              ),
            );
          }
          _frames = 0;
          _totalMs = 0;
        }
      }
    } catch (error) {
      _fail(GpuFailure('장면', '장면 오류: ${_short(error)}'));
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
    _watchdog?.cancel();
    _probeTimer?.cancel();
    unawaited(_sink?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return RepaintBoundary(
          key: _boundary,
          child: widget.host.build(context, _callbacks),
        );
      },
    );
  }
}
