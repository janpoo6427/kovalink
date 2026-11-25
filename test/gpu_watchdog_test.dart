import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/road_view/gpu_road_surface.dart';
import 'package:kovalink/src/features/road_view/render_quality.dart';
import 'package:kovalink/src/features/road_view/renderer_diagnostics.dart';
import 'package:kovalink/src/features/road_view/road_view_screen.dart';
import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart';
import 'package:kovalink/src/features/settings/renderer_diagnostics_card.dart';
import 'package:kovalink/src/gpu_scene/gpu_road_renderer.dart';
import 'package:kovalink/src/services/gateway_controller.dart';

/// Scene updates received by a fake viewer.
class _FakeSink implements GpuFrameSink {
  int updates = 0;
  bool disposed = false;
  Object? throwOnUpdate;

  @override
  Future<void> update(GpuFrameInput input) async {
    if (throwOnUpdate != null) throw throwOnUpdate!;
    updates++;
  }

  @override
  Future<void> dispose() async => disposed = true;
}

/// Native view stand-in: may never create a viewer, throw while creating
/// it, never register a texture, or show a blank/opaque frame.
class _FakeHost extends GpuViewHost {
  _FakeHost({
    this.createsViewer = true,
    this.viewerError,
    this.registersTexture = true,
    this.frameColor = const Color(0xFF3C8D5A),
  });

  final bool createsViewer;
  final Object? viewerError;
  final bool registersTexture;

  /// Null = the texture stays empty (nothing composited).
  final Color? frameColor;

  int mounts = 0;
  final sinks = <_FakeSink>[];

  @override
  String get label => 'fake';

  @override
  GpuPresentationProbe get probe => _probeFor(this);

  @override
  Widget build(BuildContext context, GpuViewCallbacks callbacks) =>
      _FakeView(host: this, callbacks: callbacks);
}

class _FakeView extends StatefulWidget {
  const _FakeView({required this.host, required this.callbacks});
  final _FakeHost host;
  final GpuViewCallbacks callbacks;

  @override
  State<_FakeView> createState() => _FakeViewState();
}

class _FakeViewState extends State<_FakeView> {
  bool _texture = false;

  @override
  void initState() {
    super.initState();
    final host = widget.host;
    host.mounts++;
    Timer(const Duration(milliseconds: 20), () {
      if (!mounted) return;
      if (host.viewerError != null) {
        widget.callbacks.onError('3D 엔진 시작', host.viewerError!);
        return;
      }
      if (!host.createsViewer) return;
      final sink = _FakeSink();
      host.sinks.add(sink);
      widget.callbacks.onViewerReady(sink);
      if (!host.registersTexture) return;
      Timer(const Duration(milliseconds: 40), () {
        if (!mounted) return;
        setState(() => _texture = true);
        widget.callbacks.onTextureReady();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.host.frameColor;
    if (!_texture || color == null) return const SizedBox.expand();
    return ColoredBox(key: const ValueKey('fake-gpu-frame'), color: color);
  }
}

/// Probe without a raster snapshot (fake-async widget tests): reports what
/// the fake view composites.
GpuPresentationProbe _probeFor(_FakeHost host) => (boundary) async {
  final color = host.frameColor;
  if (boundary == null) return const GpuProbeResult.unknown('no boundary');
  if (color == null) {
    return GpuProbeResult.analyze(Uint8List(4 * 16));
  }
  final px = Uint8List(4 * 16);
  for (var i = 0; i < px.length; i += 4) {
    px[i] = (color.r * 255).round();
    px[i + 1] = (color.g * 255).round();
    px[i + 2] = (color.b * 255).round();
    px[i + 3] = 255;
  }
  return GpuProbeResult.analyze(px);
};

final _softwareRoad = find.byWidgetPredicate(
  (w) => w is CustomPaint && w.painter is RoadWorldPainter,
);
final _underlay = find.byKey(const ValueKey('gpu-software-underlay'));

void main() {
  final diag = RendererDiagnostics.instance;
  setUp(diag.reset);

  group('GPU probe analysis', () {
    Uint8List fill(int r, int g, int b, int a, {int n = 64}) {
      final px = Uint8List(n * 4);
      for (var i = 0; i < px.length; i += 4) {
        px
          ..[i] = r
          ..[i + 1] = g
          ..[i + 2] = b
          ..[i + 3] = a;
      }
      return px;
    }

    test('empty texture reads as transparent', () {
      final r = GpuProbeResult.analyze(fill(0, 0, 0, 0));
      expect(r.verdict, GpuProbeVerdict.transparent);
      expect(r.coverage, 0);
    });

    test('opaque black frame reads as black', () {
      expect(
        GpuProbeResult.analyze(fill(3, 4, 6, 255)).verdict,
        GpuProbeVerdict.black,
      );
    });

    test('a road scene reads as visible', () {
      final px = fill(40, 60, 90, 255);
      expect(GpuProbeResult.analyze(px).verdict, GpuProbeVerdict.visible);
      // A night frame: mostly dark with a few lit lane marks still passes.
      final night = fill(2, 3, 5, 255, n: 100);
      for (var i = 0; i < 5 * 4; i += 4) {
        night[i] = night[i + 1] = night[i + 2] = 200;
      }
      expect(GpuProbeResult.analyze(night).verdict, GpuProbeVerdict.visible);
    });
  });

  group('GPU watchdog', () {
    Widget app(
      GatewayController controller,
      _FakeHost host, {
      RenderQuality quality = RenderQuality.auto,
      bool Function(GpuFailure, int)? retry,
    }) => MaterialApp(
      home: RoadViewScreen(
        controller: controller,
        renderQuality: quality,
        gpuViewHost: host,
        gpuRetry: retry ?? (_, _) => false,
      ),
    );

    testWidgets('viewer that never shows a frame falls back to software', (
      tester,
    ) async {
      final controller = GatewayController();
      final host = _FakeHost(createsViewer: false);
      await tester.pumpWidget(app(controller, host));
      // Road visible from the first frame, GPU view mounted on top.
      expect(_underlay, findsOneWidget);
      expect(find.byType(GpuRoadSurface), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2900));
      expect(find.byType(GpuRoadSurface), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(find.byType(GpuRoadSurface), findsNothing);
      expect(_softwareRoad, findsOneWidget);
      expect(diag.value.state, RendererState.fallback);
      expect(diag.value.reason, contains('3D 엔진 시작'));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });

    testWidgets('texture never registered: times out at that stage', (
      tester,
    ) async {
      final controller = GatewayController();
      final host = _FakeHost(registersTexture: false);
      await tester.pumpWidget(app(controller, host));
      await tester.pump(const Duration(milliseconds: 100));
      expect(host.sinks.single.updates, greaterThan(0));
      await tester.pump(GpuRoadSurface.defaultStartTimeout);
      await tester.pump();
      expect(find.byType(GpuRoadSurface), findsNothing);
      expect(diag.value.state, RendererState.fallback);
      expect(diag.value.reason, contains('텍스처 등록'));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });

    testWidgets('viewer error switches immediately', (tester) async {
      final controller = GatewayController();
      final host = _FakeHost(viewerError: StateError('no EGL context'));
      await tester.pumpWidget(app(controller, host));
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump();
      expect(find.byType(GpuRoadSurface), findsNothing);
      expect(_softwareRoad, findsOneWidget);
      expect(diag.value.reason, contains('no EGL context'));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });

    testWidgets('scene update error switches to software', (tester) async {
      final controller = GatewayController();
      final host = _FakeHost(registersTexture: false);
      await tester.pumpWidget(
        MaterialApp(
          home: RoadViewScreen(
            controller: controller,
            gpuViewHost: _ThrowingHost(host),
            gpuRetry: (_, _) => false,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump();
      expect(find.byType(GpuRoadSurface), findsNothing);
      expect(diag.value.reason, contains('장면 오류'));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });

    testWidgets('healthy viewer is confirmed and the underlay goes away', (
      tester,
    ) async {
      final controller = GatewayController();
      final host = _FakeHost();
      await tester.pumpWidget(
        MaterialApp(
          home: RoadViewScreen(
            controller: controller,
            gpuViewHost: host,
            gpuRetry: (_, _) => false,
          ),
        ),
      );
      expect(_underlay, findsOneWidget);
      expect(diag.value.state, RendererState.checking);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('fake-gpu-frame')), findsOneWidget);
      expect(_underlay, findsNothing);
      expect(find.byType(GpuRoadSurface), findsOneWidget);
      expect(diag.value.state, RendererState.gpu);
      expect(diag.value.probe, startsWith('정상'));
      // Long after the start timeout it is still the GPU view.
      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(GpuRoadSurface), findsOneWidget);
      expect(host.sinks.single.updates, greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(host.sinks.single.disposed, isTrue);
      controller.dispose();
    });

    testWidgets('blank texture: one retry, then software', (tester) async {
      final controller = GatewayController();
      final host = _FakeHost(frameColor: null);
      final retries = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: RoadViewScreen(
            controller: controller,
            gpuViewHost: host,
            gpuRetry: (failure, attempt) {
              retries.add(attempt);
              return attempt == 0;
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.pump();
      // First attempt saw an empty texture; the view was remounted.
      expect(retries, [0]);
      expect(host.mounts, 2);
      expect(find.byKey(const ValueKey('gpu-road-1')), findsOneWidget);
      expect(_underlay, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.pump();
      expect(retries, [0, 1]);
      expect(find.byType(GpuRoadSurface), findsNothing);
      expect(_softwareRoad, findsOneWidget);
      expect(diag.value.state, RendererState.fallback);
      expect(diag.value.reason, contains('비어 있음'));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });

    testWidgets('high quality keeps trying GPU but the road stays visible', (
      tester,
    ) async {
      final controller = GatewayController();
      final host = _FakeHost(createsViewer: false);
      await tester.pumpWidget(
        app(controller, host, quality: RenderQuality.high),
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(find.byType(GpuRoadSurface), findsOneWidget);
      expect(_underlay, findsOneWidget);
      expect(diag.value.state, RendererState.checking);
      expect(diag.value.reason, contains('고품질'));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });

    testWidgets('saver never mounts the GPU view', (tester) async {
      final controller = GatewayController();
      final host = _FakeHost();
      await tester.pumpWidget(
        app(controller, host, quality: RenderQuality.saver),
      );
      await tester.pump();
      expect(find.byType(GpuRoadSurface), findsNothing);
      expect(host.mounts, 0);
      expect(diag.value.state, RendererState.software);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  });

  group('screen probe (real snapshot)', () {
    Future<GpuProbeResult> snapshot(WidgetTester tester, Widget child) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 200,
              height: 120,
              child: RepaintBoundary(key: key, child: child),
            ),
          ),
        ),
      );
      late GpuProbeResult result;
      await tester.runAsync(() async {
        result = await screenProbe(
          key.currentContext!.findRenderObject() as RenderRepaintBoundary,
        );
      });
      return result;
    }

    testWidgets('empty texture area is reported as blank', (tester) async {
      final r = await snapshot(tester, const SizedBox.expand());
      expect(r.verdict, GpuProbeVerdict.transparent);
    });

    testWidgets('drawn frame is reported as visible', (tester) async {
      final r = await snapshot(
        tester,
        const ColoredBox(color: Color(0xFF5B87B5)),
      );
      expect(r.verdict, GpuProbeVerdict.visible);
      expect(r.coverage, greaterThan(0.9));
    });

    testWidgets('opaque black frame is reported as black', (tester) async {
      final r = await snapshot(tester, const ColoredBox(color: Colors.black));
      expect(r.verdict, GpuProbeVerdict.black);
    });
  });

  group('diagnostics', () {
    testWidgets('card shows the renderer and copies a report', (tester) async {
      final logged = <String>[];
      String? copied;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(RendererDiagnostics.channel, (
        call,
      ) async {
        switch (call.method) {
          case 'log':
            logged.add(call.arguments as String);
            return null;
          case 'deviceInfo':
            return {
              'manufacturer': 'Acme',
              'model': 'Phone 9',
              'release': '15',
              'sdk': '35',
              'glRenderer': 'Mali-G78',
              'flutterBackend': 'Impeller Vulkan',
            };
          case 'recentLog':
            return ['E/flutter: texture failed'];
        }
        return null;
      });
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      diag.setQuality('자동');
      diag.event('GPU 포기: 3.0초 안에 3D 화면이 안 나옴');
      diag.setState(RendererState.fallback, reason: '3.0초 안에 3D 화면이 안 나옴');
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: RendererDiagnosticsCard()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('대체 화면(소프트웨어)'), findsOneWidget);
      expect(find.text('3.0초 안에 3D 화면이 안 나옴'), findsOneWidget);
      expect(find.textContaining('Acme Phone 9 · Android 15'), findsOneWidget);
      expect(find.textContaining('Mali-G78'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('diagnostics-copy')));
      await tester.pump();
      await tester.pump();
      expect(copied, contains('렌더러: 대체 화면(소프트웨어)'));
      expect(copied, contains('전환 이유: 3.0초 안에 3D 화면이 안 나옴'));
      expect(copied, contains('glRenderer=Mali-G78'));
      expect(copied, contains('E/flutter: texture failed'));
      // Same facts went to logcat (tag kovalink on Android).
      expect(logged.any((l) => l.contains('대체 화면')), isTrue);
      expect(logged.any((l) => l.contains('진단 복사')), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      messenger.setMockMethodCallHandler(RendererDiagnostics.channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
  });
}

/// Viewer whose scene updates throw.
class _ThrowingHost extends GpuViewHost {
  _ThrowingHost(this.inner);
  final _FakeHost inner;

  @override
  String get label => 'fake-throwing';

  @override
  GpuPresentationProbe get probe => inner.probe;

  @override
  Widget build(BuildContext context, GpuViewCallbacks callbacks) => inner.build(
    context,
    GpuViewCallbacks(
      onViewerReady: (sink) {
        (sink as _FakeSink).throwOnUpdate = StateError('material missing');
        callbacks.onViewerReady(sink);
      },
      onTextureReady: callbacks.onTextureReady,
      onError: callbacks.onError,
    ),
  );
}
