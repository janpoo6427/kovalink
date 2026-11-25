// A full-screen page over the drive screen: the hidden drive screen stops
// its telemetry rebuilds and the 3D view rests, so the page on top scrolls
// smoothly. Back on the drive screen the newest scene shows at once.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/road_view/gpu_road_surface.dart';
import 'package:kovalink/src/features/road_view/renderer_diagnostics.dart';
import 'package:kovalink/src/features/road_view/road_view_screen.dart';
import 'package:kovalink/src/gpu_scene/gpu_road_renderer.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/services/gateway_controller.dart';

class _Sink implements GpuFrameSink {
  int updates = 0;
  RoadScene? last;

  @override
  Future<void> update(GpuFrameInput input) async {
    updates++;
    last = input.scene;
  }

  @override
  Future<void> dispose() async {}
}

/// Native view stand-in that shows a frame and records the render loop
/// being stopped and restarted.
class _Host extends GpuViewHost {
  final sinks = <_Sink>[];
  final drawing = <bool>[];

  @override
  String get label => 'covered-test';

  @override
  GpuPresentationProbe get probe => (boundary) async {
    final px = Uint8List(4 * 16);
    for (var i = 0; i < px.length; i += 4) {
      px
        ..[i] = 60
        ..[i + 1] = 140
        ..[i + 2] = 90
        ..[i + 3] = 255;
    }
    return GpuProbeResult.analyze(px);
  };

  @override
  void setDrawing(bool drawing) => this.drawing.add(drawing);

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
    Timer(const Duration(milliseconds: 20), () {
      if (!mounted) return;
      final sink = _Sink();
      widget.host.sinks.add(sink);
      widget.callbacks.onViewerReady(sink);
      Timer(const Duration(milliseconds: 40), () {
        if (!mounted) return;
        setState(() => _texture = true);
        widget.callbacks.onTextureReady();
      });
    });
  }

  @override
  Widget build(BuildContext context) => _texture
      ? const ColoredBox(color: Color(0xFF3C8D5A))
      : const SizedBox.expand();
}

final _underlay = find.byKey(
  const ValueKey('gpu-software-underlay'),
  skipOffstage: false,
);

Future<void> _run(WidgetTester tester, Duration time) async {
  for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 50)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Route<void> _page() => MaterialPageRoute<void>(
  builder: (_) => Scaffold(
    body: ListView(
      children: [for (var i = 0; i < 40; i++) ListTile(title: Text('줄 $i'))],
    ),
  ),
);

void main() {
  final diag = RendererDiagnostics.instance;
  setUp(diag.reset);

  late GatewayController controller;
  late _Host host;
  final nav = GlobalKey<NavigatorState>();

  Future<void> pumpDrive(WidgetTester tester) async {
    controller = GatewayController()..startDemo();
    host = _Host();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: RoadViewScreen(
          controller: controller,
          gpuViewHost: host,
          gpuRetry: (_, _) => false,
        ),
      ),
    );
  }

  Future<void> done(WidgetTester tester) async {
    controller.stopDemo();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  }

  testWidgets('a page on top stops the 3D updates and the render loop; back '
      'shows the newest scene', (tester) async {
    await pumpDrive(tester);
    await _run(tester, const Duration(seconds: 2));
    expect(_underlay, findsNothing, reason: '3D view confirmed');
    final sink = host.sinks.single;

    final shown = sink.updates;
    await _run(tester, const Duration(seconds: 1));
    expect(sink.updates - shown, greaterThanOrEqualTo(15));

    unawaited(nav.currentState!.push(_page()));
    await _run(tester, const Duration(milliseconds: 800));
    expect(find.byType(RoadViewScreen), findsNothing, reason: 'covered');
    expect(host.drawing, [false]);

    final covered = sink.updates;
    await _run(tester, const Duration(seconds: 2));
    expect(sink.updates, covered, reason: 'no 3D work behind the page');

    nav.currentState!.pop();
    await tester.pump();
    expect(host.drawing, [false, true]);
    expect(sink.updates, greaterThan(covered));
    expect(
      sink.last!.monotonicTimeNanos,
      controller.scene.monotonicTimeNanos,
      reason: 'the first frame back is the newest scene',
    );
    await _run(tester, const Duration(seconds: 1));
    expect(sink.updates - covered, greaterThanOrEqualTo(15));
    expect(_underlay, findsNothing, reason: 'still on the 3D view');
    await done(tester);
  });

  testWidgets('a dialog leaves the road moving behind it', (tester) async {
    await pumpDrive(tester);
    await _run(tester, const Duration(seconds: 2));
    final sink = host.sinks.single;
    unawaited(
      showDialog<void>(
        context: nav.currentContext!,
        builder: (_) => const AlertDialog(content: Text('확인')),
      ),
    );
    await _run(tester, const Duration(milliseconds: 500));
    final before = sink.updates;
    await _run(tester, const Duration(seconds: 1));
    expect(sink.updates - before, greaterThanOrEqualTo(15));
    expect(host.drawing, isEmpty);
    nav.currentState!.pop();
    await _run(tester, const Duration(milliseconds: 500));
    await done(tester);
  });

  testWidgets('a page opened before the 3D view is confirmed: the start check '
      'still finishes, then the 3D view rests', (tester) async {
    await pumpDrive(tester);
    await tester.pump();
    unawaited(nav.currentState!.push(_page()));
    await _run(tester, const Duration(seconds: 3));
    expect(_underlay, findsNothing, reason: 'confirmed, no 2D fallback');
    expect(diag.value.state, isNot(RendererState.software));
    expect(host.drawing, [false]);
    final sink = host.sinks.single;
    final covered = sink.updates;
    await _run(tester, const Duration(seconds: 1));
    expect(sink.updates, covered);

    nav.currentState!.pop();
    await _run(tester, const Duration(milliseconds: 500));
    expect(host.drawing, [false, true]);
    expect(sink.updates, greaterThan(covered));
    await done(tester);
  });

  testWidgets('the drive screen goes away while covered: the render loop '
      'draws again', (tester) async {
    await pumpDrive(tester);
    await _run(tester, const Duration(seconds: 2));
    unawaited(nav.currentState!.push(_page()));
    await _run(tester, const Duration(milliseconds: 800));
    expect(host.drawing, [false]);
    await done(tester);
    expect(host.drawing, [false, true]);
  });
}
