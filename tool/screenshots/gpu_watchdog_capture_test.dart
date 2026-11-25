// Captures of the GPU watchdog for review (2026-11-25 phone report: HUD over
// an empty, nearly black road view). Same app widgets as the phone; the GPU
// frame comes from the worker's headless Filament (EGL surfaceless).
//
//   KOVA_SHOT_DIR=/path flutter test tool/screenshots/gpu_watchdog_capture_test.dart
//
// black3d_before   old behaviour: GPU texture never shows, no fallback
// black3d_checking new: same blank GPU view, software road underneath
// black3d_fallback new: after the start timeout, software renderer only
// black3d_gpu_ok   new: healthy GPU frame confirmed, underlay removed
// probe_calibration.txt  probe verdict on real GPU frames of every theme
// black3d_diagnostics_card  설정 → 진단 after a fallback (example values)
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kovalink_home.dart';
import 'package:kovalink/src/features/road_view/gpu_road_surface.dart';
import 'package:kovalink/src/features/road_view/renderer_diagnostics.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_director.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/features/settings/renderer_diagnostics_card.dart';
import 'package:kovalink/src/gpu_scene/gpu_road_renderer.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';

import '../gpu/headless_gpu.dart';
import 'shot_support.dart';

const _physical = Size(1080, 2400);
const _ratio = 2.625;

ThemeData _theme() => ThemeData(
  fontFamily: 'Roboto',
  brightness: Brightness.dark,
  colorScheme: const ColorScheme.dark(
    primary: Color(0xFF58F2C2),
    surface: Color(0xFF111820),
  ),
  scaffoldBackgroundColor: const Color(0xFF070B10),
  useMaterial3: true,
);

HeadlessGpu? _gpu;
GpuRoadRenderer? _renderer;

Future<Uint8List> _gpuPixels(
  RoadScene scene,
  DirectorFrame frame,
  SceneTheme theme,
  Size physical,
) async {
  _gpu ??= await HeadlessGpu.create(
    physical.width.toInt(),
    physical.height.toInt(),
  );
  _renderer ??= GpuRoadRenderer(_gpu!.viewer);
  await _gpu!.resize(physical.width.toInt(), physical.height.toInt());
  await _renderer!.update(
    GpuFrameInput(
      scene: scene,
      director: frame,
      width: physical.width.toInt(),
      height: physical.height.toInt(),
      theme: theme,
    ),
  );
  return _gpu!.capture(warmup: 3);
}

Future<ui.Image> _decode(Uint8List px, Size physical) {
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    px,
    physical.width.toInt(),
    physical.height.toInt(),
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  return done.future;
}

/// Host that never gets a frame on screen (the phone's symptom).
class _BlankHost extends GpuViewHost {
  @override
  String get label => 'SurfaceProducer (흉내: 화면 안 나옴)';

  @override
  Widget build(BuildContext context, GpuViewCallbacks callbacks) =>
      const SizedBox.expand();
}

/// Host showing a headless GPU frame; the probe analyses those pixels.
class _HeadlessHost extends GpuViewHost {
  _HeadlessHost(this.image, this.pixels);
  final ui.Image image;
  final Uint8List pixels;

  @override
  String get label => 'headless Filament';

  @override
  GpuPresentationProbe get probe =>
      (_) async => GpuProbeResult.analyze(pixels);

  @override
  Widget build(BuildContext context, GpuViewCallbacks callbacks) =>
      _HeadlessView(host: this, callbacks: callbacks);
}

class _HeadlessView extends StatefulWidget {
  const _HeadlessView({required this.host, required this.callbacks});
  final _HeadlessHost host;
  final GpuViewCallbacks callbacks;

  @override
  State<_HeadlessView> createState() => _HeadlessViewState();
}

class _NullSink implements GpuFrameSink {
  @override
  Future<void> update(GpuFrameInput input) async {}
  @override
  Future<void> dispose() async {}
}

class _HeadlessViewState extends State<_HeadlessView> {
  @override
  void initState() {
    super.initState();
    Timer(const Duration(milliseconds: 30), () {
      widget.callbacks.onViewerReady(_NullSink());
      widget.callbacks.onTextureReady();
    });
  }

  @override
  Widget build(BuildContext context) =>
      RawImage(image: widget.host.image, fit: BoxFit.fill);
}

void main() {
  final scenario = DemoDriveScenario(route: DemoRoute.city);
  const t = 49.5;

  Future<void> shot(
    WidgetTester tester,
    String name, {
    GpuSurfaceBuilder? builder,
    GpuViewHost? host,
    Duration wait = Duration.zero,
  }) async {
    await tester.runAsync(loadReviewFonts);
    tester.view.physicalSize = _physical;
    tester.view.devicePixelRatio = _ratio;
    addTearDown(tester.view.reset);
    RendererDiagnostics.instance.reset();
    final controller = GatewayController();
    controller.scene = scenario.sceneAt(
      Duration(milliseconds: (t * 1000).round()),
    );
    final settings = SettingsController(
      store: MemorySettingsStore(),
      initial: const AppSettings(sceneTheme: SceneTheme.clear),
    );
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        home: RepaintBoundary(
          key: key,
          child: KovaLinkHome(
            controller: controller,
            settings: settings,
            library: VehicleModelLibrary(
              storageRoot: () async => Directory.systemTemp,
            ),
            gpuSurfaceBuilder: builder,
            gpuViewHost: host,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    if (wait > Duration.zero) await tester.pump(wait);
    await tester.pump();
    await tester.pump();
    await saveBoundary(tester, key, name);
    final report = RendererDiagnostics.instance.value;
    File('$shotDirectory/$name.txt')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(report.toText());
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  }

  testWidgets('black3d_before (old: blank texture, no fallback)', (
    tester,
  ) async {
    await shot(
      tester,
      'black3d_before_1080x2400',
      builder: (context, r) => const SizedBox.expand(),
    );
  });

  testWidgets('black3d_checking (blank GPU, software road under it)', (
    tester,
  ) async {
    await shot(tester, 'black3d_checking_1080x2400', host: _BlankHost());
  });

  testWidgets('black3d_fallback (after the start timeout)', (tester) async {
    await shot(
      tester,
      'black3d_fallback_1080x2400',
      host: _BlankHost(),
      wait: GpuRoadSurface.defaultStartTimeout + const Duration(seconds: 1),
    );
  });

  testWidgets('black3d_gpu_ok (headless GPU frame confirmed)', (tester) async {
    final logical = _physical / _ratio;
    final scene = scenario.sceneAt(Duration(milliseconds: (t * 1000).round()));
    final frame = SceneDirector().update(scene, logical);
    final px = (await tester.runAsync(
      () => _gpuPixels(scene, frame, SceneTheme.clear, _physical),
    ))!;
    final image = (await tester.runAsync(() => _decode(px, _physical)))!;
    await shot(
      tester,
      'black3d_gpu_ok_1080x2400',
      host: _HeadlessHost(image, px),
      wait: const Duration(seconds: 1),
    );
  });

  testWidgets('probe calibration on real GPU frames', (tester) async {
    const size = Size(540, 1200);
    final lines = <String>[];
    for (final route in DemoRoute.values) {
      for (final theme in SceneTheme.values) {
        for (final at in [5.0, 30.0, 70.0]) {
          final s = DemoDriveScenario(
            route: route,
          ).sceneAt(Duration(milliseconds: (at * 1000).round()));
          final f = SceneDirector().update(s, size / 2);
          final px = (await tester.runAsync(
            () => _gpuPixels(s, f, theme, size),
          ))!;
          // Same downscale as the on-phone probe (~64 px long side).
          final small = _downscale(px, size, 64);
          final r = GpuProbeResult.analyze(small);
          lines.add('${route.name} ${theme.name} t=$at: ${r.describe}');
        }
      }
    }
    File('$shotDirectory/probe_calibration.txt')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${lines.join('\n')}\n');
    expect(lines.where((l) => !l.contains('정상')), isEmpty, reason: '$lines');
  });

  testWidgets('diagnostics card after a fallback', (tester) async {
    await tester.runAsync(loadReviewFonts);
    tester.view.physicalSize = const Size(1080, 1900);
    tester.view.devicePixelRatio = _ratio;
    addTearDown(tester.view.reset);
    final diag = RendererDiagnostics.instance..reset();
    final messenger = tester.binding.defaultBinaryMessenger;
    // Example facts only (no real phone was attached to the worker).
    messenger.setMockMethodCallHandler(RendererDiagnostics.channel, (
      call,
    ) async {
      return switch (call.method) {
        'deviceInfo' => {
          'manufacturer': 'samsung',
          'model': 'SM-S000 (예시)',
          'release': '15',
          'sdk': '35',
          'glRenderer': 'Adreno (예시)',
          'flutterBackend': 'Impeller Vulkan',
        },
        'recentLog' => <String>[],
        _ => null,
      };
    });
    addTearDown(
      () =>
          messenger.setMockMethodCallHandler(RendererDiagnostics.channel, null),
    );
    // Example of the phone symptom after both texture paths: the engine
    // started and drew frames, but nothing reached the screen.
    diag
      ..setQuality('자동')
      ..setTexture('SurfaceTexture', 1)
      ..event('3D 화면 켜기 시작 (SurfaceProducer)')
      ..event('3D 엔진 켜짐 (0.41초)')
      ..event('첫 장면 그림 (0.10초 걸림, 시작 후 0.52초)')
      ..event('3D 포기: 3.0초 안에 3D 화면이 안 나왔어요 (멈춘 단계: 텍스처 등록)')
      ..event('다른 연결 방식(SurfaceTexture)으로 3D를 다시 시도해요 (2번째)')
      ..event('3D 화면 켜기 시작 (SurfaceTexture)')
      ..event('화면 연결됨 (0.38초)')
      ..event('3D 포기: 3D 화면이 비어 있음 (보임 0%, 밝음 0%)')
      ..setProbe('비어 있음 (보임 0%, 밝음 0%)')
      ..setFrames(const RendererFrames(24, 460))
      ..setState(
        RendererState.fallback,
        reason: '3D 화면이 비어 있음 (보임 0%, 밝음 0%)',
        note:
            '3D 화면이 비어 있었어요. 3D 그림이 화면까지 오지 못했어요. '
            '그동안 3D 엔진은 24장을 그렸어요.',
      );
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        home: RepaintBoundary(
          key: key,
          child: const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(20, 40, 20, 20),
              child: RendererDiagnosticsCard(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await saveBoundary(tester, key, 'black3d_diagnostics_card');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  tearDownAll(() async {
    await _gpu?.dispose();
  });
}

/// Nearest-neighbour downscale of RGBA [px] to [longest] pixels.
Uint8List _downscale(Uint8List px, Size size, int longest) {
  final w = size.width.toInt(), h = size.height.toInt();
  final scale = longest / (w > h ? w : h);
  final sw = (w * scale).round(), sh = (h * scale).round();
  final out = Uint8List(sw * sh * 4);
  for (var y = 0; y < sh; y++) {
    for (var x = 0; x < sw; x++) {
      final sx = (x / scale).floor().clamp(0, w - 1);
      final sy = (y / scale).floor().clamp(0, h - 1);
      final si = (sy * w + sx) * 4, di = (y * sw + x) * 4;
      out.setRange(di, di + 4, px, si);
    }
  }
  return out;
}
