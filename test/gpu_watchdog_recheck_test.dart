// GPU watchdog, part 2 (2026-11-25 phone report: HUD over an empty road):
// the road is never left empty while the 3D view is checked, the whole
// retry chain ends on the 2D road within its time budget, a confirmed view
// is checked again after the app returns to the foreground, and 설정 → 진단
// explains all of it in plain words.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/road_view/gpu_road_surface.dart';
import 'package:kovalink/src/features/road_view/render_quality.dart';
import 'package:kovalink/src/features/road_view/renderer_diagnostics.dart';
import 'package:kovalink/src/features/road_view/road_view_screen.dart';
import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart';
import 'package:kovalink/src/features/settings/renderer_diagnostics_card.dart';
import 'package:kovalink/src/gpu_scene/gpu_road_renderer.dart';
import 'package:kovalink/src/services/gateway_controller.dart';

class _Sink implements GpuFrameSink {
  int updates = 0;
  bool disposed = false;

  @override
  Future<void> update(GpuFrameInput input) async => updates++;

  @override
  Future<void> dispose() async => disposed = true;
}

/// Fake native view. [frameColor] can change while mounted (null = the
/// texture shows nothing); [framesPerTick] fakes the native frame counter.
class _Host extends GpuViewHost {
  _Host({
    this.createsViewer = true,
    this.registersTexture = true,
    this.frameColor = const Color(0xFF3C8D5A),
    this.countsFrames = false,
  });

  final bool createsViewer;
  final bool registersTexture;
  Color? frameColor;
  final bool countsFrames;

  int mounts = 0;
  final sinks = <_Sink>[];

  /// Advanced by the test to fake the native frame scheduler.
  int frames = 0;

  @override
  String get label => 'fake';

  @override
  int get renderedFrames => countsFrames ? frames : -1;

  @override
  GpuPresentationProbe get probe => (boundary) async {
    if (boundary == null) return const GpuProbeResult.unknown('no boundary');
    final color = frameColor;
    final px = Uint8List(4 * 16);
    if (color != null) {
      for (var i = 0; i < px.length; i += 4) {
        px[i] = (color.r * 255).round();
        px[i + 1] = (color.g * 255).round();
        px[i + 2] = (color.b * 255).round();
        px[i + 3] = 255;
      }
    }
    return GpuProbeResult.analyze(px);
  };

  @override
  Widget build(BuildContext context, GpuViewCallbacks callbacks) =>
      _View(host: this, callbacks: callbacks);
}

class _View extends StatefulWidget {
  const _View({required this.host, required this.callbacks});
  final _Host host;
  final GpuViewCallbacks callbacks;

  @override
  State<_View> createState() => _ViewState();
}

class _ViewState extends State<_View> {
  bool _texture = false;

  @override
  void initState() {
    super.initState();
    final host = widget.host;
    host.mounts++;
    Timer(const Duration(milliseconds: 20), () {
      if (!mounted || !host.createsViewer) return;
      final sink = _Sink();
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

final _softwareRoad = find.byWidgetPredicate(
  (w) => w is CustomPaint && w.painter is RoadWorldPainter,
);
final _underlay = find.byKey(const ValueKey('gpu-software-underlay'));

Future<void> _toBackgroundAndBack(WidgetTester tester) async {
  final binding = tester.binding;
  for (final s in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    binding.handleAppLifecycleStateChanged(s);
  }
  await tester.pump();
}

void main() {
  final diag = RendererDiagnostics.instance;
  setUp(diag.reset);

  Widget app(
    GatewayController controller,
    GpuViewHost host, {
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

  group('road never left empty', () {
    testWidgets(
      'blank 3D with one retry: 2D road on every frame, 2D only by 6.1 s',
      (tester) async {
        final controller = GatewayController();
        final host = _Host(frameColor: null, registersTexture: false);
        final retries = <int>[];
        await tester.pumpWidget(
          app(
            controller,
            host,
            retry: (failure, attempt) {
              retries.add(attempt);
              return attempt == 0;
            },
          ),
        );
        var elapsed = Duration.zero;
        Duration? softwareOnlyAt;
        const step = Duration(milliseconds: 100);
        while (elapsed < const Duration(seconds: 7)) {
          // The phone symptom was a frame with no road at all.
          expect(
            _softwareRoad,
            findsOneWidget,
            reason: 'no road drawn at $elapsed',
          );
          if (softwareOnlyAt == null &&
              find.byType(GpuRoadSurface).evaluate().isEmpty) {
            softwareOnlyAt = elapsed;
          }
          await tester.pump(step);
          elapsed += step;
        }
        expect(retries, [0, 1]);
        expect(host.mounts, 2);
        expect(softwareOnlyAt, isNotNull);
        // Two 3.0 s watchdog windows, nothing more.
        expect(
          softwareOnlyAt!,
          lessThanOrEqualTo(const Duration(seconds: 6, milliseconds: 100)),
        );
        expect(
          softwareOnlyAt,
          greaterThanOrEqualTo(const Duration(seconds: 6)),
        );
        expect(diag.value.state, RendererState.fallback);
        expect(diag.value.headline, '3D 화면이 안 나와서 2D 도로로 바꿨어요');
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      },
    );

    testWidgets('engine that never starts: 2D only within 3.1 s', (
      tester,
    ) async {
      final controller = GatewayController();
      final host = _Host(createsViewer: false, countsFrames: true);
      await tester.pumpWidget(app(controller, host));
      expect(_underlay, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 3000));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(GpuRoadSurface), findsNothing);
      expect(_softwareRoad, findsOneWidget);
      // Plain words: what stopped, and that the engine drew nothing.
      expect(diag.value.note, startsWith('3.0초 동안 3D 엔진이 켜지지 않았어요.'));
      expect(diag.value.note, contains('한 장도 그리지 않았어요'));
      expect(diag.value.frames?.count, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });

    testWidgets('engine draws but nothing reaches the screen', (tester) async {
      final controller = GatewayController();
      final host = _Host(frameColor: null, countsFrames: true);
      await tester.pumpWidget(app(controller, host));
      for (var i = 0; i < 6; i++) {
        host.frames += 6;
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump();
      expect(find.byType(GpuRoadSurface), findsNothing);
      expect(diag.value.reason, contains('비어 있음'));
      expect(diag.value.note, contains('3D 그림이 화면까지 오지 못했어요'));
      // The counter moved while the texture stayed empty.
      expect(diag.value.frames!.count, greaterThan(0));
      expect(diag.value.note, contains('${diag.value.frames!.count}장을 그렸어요'));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  });

  group('foreground re-check', () {
    testWidgets('still drawing after resume: confirmed again', (tester) async {
      final controller = GatewayController();
      final host = _Host();
      await tester.pumpWidget(app(controller, host));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(_underlay, findsNothing);
      expect(diag.value.state, RendererState.gpu);

      await _toBackgroundAndBack(tester);
      await tester.pump();
      // Road underneath again until the view is confirmed.
      expect(_underlay, findsOneWidget);
      expect(diag.value.state, RendererState.checking);
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump();
      expect(_underlay, findsNothing);
      expect(find.byType(GpuRoadSurface), findsOneWidget);
      expect(diag.value.state, RendererState.gpu);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });

    testWidgets('blank after resume: back to the 2D road', (tester) async {
      final controller = GatewayController();
      final host = _Host();
      await tester.pumpWidget(app(controller, host));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(diag.value.state, RendererState.gpu);

      host.frameColor = null; // surface lost in the background
      await _toBackgroundAndBack(tester);
      await tester.pump();
      expect(_underlay, findsOneWidget);
      // Three blank checks 0.8 s apart, then the software road.
      for (var i = 0; i < 3; i++) {
        expect(find.byType(GpuRoadSurface), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 800));
        await tester.pump();
      }
      await tester.pump();
      expect(find.byType(GpuRoadSurface), findsNothing);
      expect(_softwareRoad, findsOneWidget);
      expect(diag.value.state, RendererState.fallback);
      expect(diag.value.reason, contains('앱으로 돌아온 뒤'));
      expect(diag.value.note, contains('다시 나오지 않았어요'));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  });

  testWidgets('choosing a quality again after a fallback retries 3D', (
    tester,
  ) async {
    final controller = GatewayController();
    final host = _Host(createsViewer: false);
    await tester.pumpWidget(app(controller, host));
    await tester.pump(const Duration(milliseconds: 3100));
    await tester.pump();
    expect(find.byType(GpuRoadSurface), findsNothing);
    expect(host.mounts, 1);
    await tester.pumpWidget(app(controller, host, quality: RenderQuality.high));
    await tester.pump();
    expect(find.byType(GpuRoadSurface), findsOneWidget);
    expect(host.mounts, 2);
    expect(diag.value.state, RendererState.checking);
    expect(diag.value.reason, isNull);
    // Let the fake view's start timer run before the tree goes away.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  group('diagnostics in plain words', () {
    Future<void> card(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: RendererDiagnosticsCard()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    String text(WidgetTester tester, String key) =>
        (tester.widget(find.byKey(ValueKey(key))) as Text).data!;

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            RendererDiagnostics.channel,
            (call) async => null,
          );
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(RendererDiagnostics.channel, null);
    });

    testWidgets('fallback: what happened, why, and what to do', (tester) async {
      diag
        ..setQuality('자동')
        ..setFrames(const RendererFrames(0, 3000))
        ..setState(
          RendererState.fallback,
          reason: '3.0초 안에 3D 화면이 안 나왔어요 (멈춘 단계: 텍스처 등록)',
          note: '3D 엔진은 켜졌지만 3.0초 동안 화면에 연결되지 않았어요.',
        );
      await card(tester);
      expect(text(tester, 'diagnostics-headline'), '3D 화면이 안 나와서 2D 도로로 바꿨어요');
      final why = text(tester, 'diagnostics-explanation');
      expect(why, startsWith('3D 엔진은 켜졌지만 3.0초 동안 화면에 연결되지 않았어요.'));
      expect(why, contains('화질을 다시 고르면 3D를 다시 시도해요.'));
      expect(find.text('0장 (3.0초 동안)'), findsOneWidget);
      final copy = diag.value.toText();
      expect(copy, contains('요약: 3D 화면이 안 나와서 2D 도로로 바꿨어요'));
      expect(copy, contains('설명: 3D 엔진은 켜졌지만'));
      expect(copy, contains('3D 그림: 0장 (3.0초 동안)'));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('each state has a sentence in 해요체', (tester) async {
      final cases = {
        RendererState.checking: '3D 화면을 켜고 있어요',
        RendererState.gpu: '3D 화면이 잘 나오고 있어요',
        RendererState.software: '이 기기에서는 2D 도로로 그리고 있어요',
      };
      for (final e in cases.entries) {
        diag
          ..reset()
          ..setQuality('자동')
          ..setState(e.key);
        await card(tester);
        expect(text(tester, 'diagnostics-headline'), e.value);
        expect(e.value, endsWith('요'));
      }
      diag
        ..reset()
        ..setQuality('절약')
        ..setState(RendererState.software);
      await card(tester);
      expect(text(tester, 'diagnostics-headline'), '절약 화질이라 2D 도로로 그리고 있어요');
      expect(
        text(tester, 'diagnostics-explanation'),
        '화질을 자동이나 고품질로 바꾸면 3D로 그려요.',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('watchdog timeline reads as sentences, not raw ms', (
      tester,
    ) async {
      final controller = GatewayController();
      await tester.pumpWidget(app(controller, _Host()));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      final lines = diag.value.events.map((e) => '$e').toList();
      expect(
        lines.first,
        matches(RegExp(r'^\d+\.\d\d초 3D 화면 켜기 시작 \(fake\)$')),
      );
      expect(lines.any((l) => l.contains('3D 엔진 켜짐')), isTrue);
      expect(lines.any((l) => l.contains('화면 연결됨')), isTrue);
      expect(lines.any((l) => l.contains('3D 화면 확인됨')), isTrue);
      expect(lines.where((l) => l.contains(' ms')), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  });
}
