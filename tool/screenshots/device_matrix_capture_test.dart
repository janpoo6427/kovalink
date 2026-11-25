// Every main screen on a matrix of phone, foldable and tablet sizes, in
// portrait and landscape, with each device's system insets. Saves one PNG
// per device and screen plus layout findings (overflow errors, HUD parts
// off screen / in the insets / covering each other, the camera notice in
// the navigation overlay zone, clipped text) to $KOVA_SHOT_DIR/report.json.
//
// Screens: drive_city (traffic light, turn sign, lanes), drive_city_nolight
// (same road, no light: the blinkers must not move), drive_highway,
// drive_camera (camera view without a camera; the orange box marks where a
// navigation app such as T map floats its overlay, drawn in the capture
// only), connect and the three settings tabs.
//
//   KOVA_SHOT_DIR=out flutter test tool/screenshots/device_matrix_capture_test.dart
//   KOVA_GPU=1        drive screens drawn by the GPU renderer (headless
//                     Filament, see tool/gpu/headless_gpu.dart)
//   KOVA_DEVICES=phone_393x852,tablet_834x1194   only these devices
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:kovalink/src/app/kovalink_home.dart';
import 'package:kovalink/src/features/road_view/gpu_road_surface.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_director.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/gpu_scene/gpu_road_renderer.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/services/vehicle_model_repository.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';

import '../../test/support/device_profiles.dart';
import '../../test/support/fake_kova_gateway.dart';
import '../../test/support/layout_probe.dart';
import '../gpu/headless_gpu.dart';
import 'shot_support.dart';

Duration _s(double seconds) => Duration(milliseconds: (seconds * 1000).round());

final _useGpu = Platform.environment['KOVA_GPU'] == '1';
HeadlessGpu? _gpu;
GpuRoadRenderer? _renderer;

Future<ui.Image> _renderGpu(GpuSurfaceRequest r, int width, int height) async {
  _gpu ??= await HeadlessGpu.create(width, height);
  _renderer ??= GpuRoadRenderer(_gpu!.viewer);
  await _gpu!.resize(width, height);
  await _renderer!.update(
    GpuFrameInput(
      scene: r.scene,
      director: r.director,
      width: width,
      height: height,
      theme: r.theme,
      layers: r.layers,
      vehicle: r.vehicle,
      viewpoint: r.viewpoint,
    ),
  );
  final px = await _gpu!.capture(warmup: 3);
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    px,
    width,
    height,
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  return done.future;
}

/// Drive scenes: the city one has the most HUD parts at once (signal,
/// route card, turn sign, lane guidance); the highway one has the alerts.
const _driveScenes = <(String, DemoRoute, double, SceneTheme)>[
  ('drive_city', DemoRoute.city, 85, SceneTheme.clear),
  ('drive_city_nolight', DemoRoute.city, 58, SceneTheme.clear),
  ('drive_highway', DemoRoute.highway, 20, SceneTheme.clear),
];

class _Shot {
  _Shot(this.device, this.textScale);
  final DeviceProfile device;
  final double textScale;
  String get id => textScale == 1
      ? device.id
      : '${device.id}_text${(textScale * 100).round()}';
}

void main() {
  final only = Platform.environment['KOVA_DEVICES']?.split(',');
  final shots =
      <_Shot>[
        for (final d in allDevices) _Shot(d, 1),
        _Shot(portraitDevices.first, 1.3),
        _Shot(portraitDevices[2], 1.3),
        _Shot(landscapeDevices[2], 1.3),
      ].where(
        (s) =>
            only == null || only.contains(s.id) || only.contains(s.device.id),
      );
  final results = <String, Object>{};

  tearDownAll(() {
    final file = File('$shotDirectory/report.json');
    file.parent.createSync(recursive: true);
    final previous = file.existsSync()
        ? jsonDecode(file.readAsStringSync()) as Map<String, dynamic>
        : <String, dynamic>{};
    previous.addAll(results);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(previous),
    );
  });

  for (final shot in shots) {
    final device = shot.device;
    testWidgets('device ${shot.id}', (tester) async {
      await tester.runAsync(loadReviewFonts);
      device.apply(tester);
      addTearDown(tester.view.reset);
      if (shot.textScale != 1) {
        setTextScale(tester, shot.textScale);
        addTearDown(() => resetTextScale(tester));
      }
      final pixelRatio = math.min(device.dpr, 2.0);
      final perScreen = <String, Object>{};
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('kl_dev_'),
      ))!;

      // Road view area: the home screen keeps the top/side insets clear.
      final p = device.padding;
      final road = Size(device.width - p.left - p.right, device.height - p.top);

      for (final (name, route, t, theme) in _driveScenes) {
        final scenario = DemoDriveScenario(route: route);
        final scene = scenario.sceneAt(_s(t));
        final director = SceneDirector();
        for (final h in [t - 1, t - 0.5]) {
          director.update(scenario.sceneAt(_s(h)), road);
        }
        GpuSurfaceBuilder? gpuBuilder;
        if (_useGpu) {
          final frame = director.update(scene, road);
          final settingsValue = AppSettings(sceneTheme: theme);
          final request = GpuSurfaceRequest(
            scene: scene,
            director: frame,
            theme: theme,
            layers: settingsValue.layers,
            vehicle: VehicleModelLoadResult.bundledDefault.profile,
            viewpoint: SceneViewpoint.chase,
          );
          final w = (road.width * pixelRatio).round();
          final h = (road.height * pixelRatio).round();
          final image = (await tester.runAsync(
            () => _renderGpu(request, w, h),
          ))!;
          gpuBuilder = (context, r) => RawImage(image: image, fit: BoxFit.fill);
        }
        final report = LayoutReport();
        report.errors.addAll(
          await collectFlutterErrors(() async {
            await _pumpHome(
              tester,
              scene: scene,
              route: route,
              theme: theme,
              root: root,
              director: director,
              gpuBuilder: gpuBuilder,
            );
            checkDriveScreen(tester, report);
            checkVisibleText(tester, report);
            await saveBoundary(
              tester,
              _key,
              '${shot.id}/$name',
              pixelRatio: pixelRatio,
            );
          }),
        );
        perScreen[name] = report.toJson();
        await tester.pumpWidget(const SizedBox.shrink());
      }

      // Connect, then the three settings tabs, on a city scene.
      final scene = DemoDriveScenario().sceneAt(_s(85));

      // Camera view with no camera connected: the notice card.
      {
        final report = LayoutReport();
        report.errors.addAll(
          await collectFlutterErrors(() async {
            await _pumpHome(
              tester,
              scene: scene,
              route: DemoRoute.city,
              theme: SceneTheme.clear,
              root: root,
              navZone: navOverlayZoneOf(
                Rect.fromLTRB(
                  p.left,
                  p.top,
                  device.width - p.right,
                  device.height,
                ),
              ),
            );
            await tester.tap(find.byTooltip('카메라 화면으로 바꾸기'));
            await tester.pump();
            checkDriveScreen(tester, report);
            checkVisibleText(tester, report);
            await saveBoundary(
              tester,
              _key,
              '${shot.id}/drive_camera',
              pixelRatio: pixelRatio,
            );
          }),
        );
        _dedupe(report);
        perScreen['drive_camera'] = report.toJson();
        await tester.pumpWidget(const SizedBox.shrink());
      }

      for (final name in [
        'connect',
        'settings_app',
        'settings_session',
        'settings_kovapilot',
      ]) {
        final report = LayoutReport();
        report.errors.addAll(
          await collectFlutterErrors(() async {
            await _pumpHome(
              tester,
              scene: scene,
              route: DemoRoute.city,
              theme: SceneTheme.clear,
              root: root,
            );
            if (name == 'connect') {
              await tester.tap(find.byTooltip('장치 연결'));
            } else {
              await tester.tap(find.byTooltip('설정'));
            }
            await _settle(tester);
            final tabs = find.byKey(const ValueKey('settings-tabs'));
            if (name == 'settings_session') {
              await tester.tap(
                find.descendant(of: tabs, matching: find.text('연결 상태')),
              );
              await _settle(tester);
            } else if (name == 'settings_kovapilot') {
              await tester.tap(
                find.descendant(of: tabs, matching: find.text('kovapilot')),
              );
              await _settle(tester);
              await tester.tap(find.byKey(const ValueKey('kova-connect')));
              await tester.pump();
              await _settle(tester);
            }
            checkVisibleText(tester, report);
            checkBackButton(tester, report);
            await saveBoundary(
              tester,
              _key,
              '${shot.id}/$name',
              pixelRatio: pixelRatio,
            );
            // Lay out the rest of the list too (ListView builds lazily).
            final scrollable = find
                .byType(Scrollable)
                .hitTestable(at: Alignment.center);
            if (scrollable.evaluate().isNotEmpty) {
              for (var i = 0; i < 40; i++) {
                final state = tester.state<ScrollableState>(scrollable.first);
                final position = state.position;
                if (position.pixels >= position.maxScrollExtent - 1) break;
                position.jumpTo(
                  math.min(
                    position.maxScrollExtent,
                    position.pixels + position.viewportDimension * 0.8,
                  ),
                );
                await tester.pump();
                checkVisibleText(tester, report);
              }
            }
          }),
        );
        _dedupe(report);
        perScreen[name] = report.toJson();
        await tester.pumpWidget(const SizedBox.shrink());
      }
      results[shot.id] = {
        'label': device.label,
        'size': device.sizeLabel,
        'width': device.width,
        'height': device.height,
        'dpr': device.dpr,
        'group': device.group.name,
        'landscape': device.landscape,
        'textScale': shot.textScale,
        'padding': [p.left, p.top, p.right, p.bottom],
        'screens': perScreen,
      };
      _kova?.dispose();
      _kova = null;
      await tester.runAsync(() => root.delete(recursive: true));
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}

final _key = GlobalKey();
KovaParamsController? _kova;

Future<void> _pumpHome(
  WidgetTester tester, {
  required RoadScene scene,
  required DemoRoute route,
  required SceneTheme theme,
  required Directory root,
  SceneDirector? director,
  GpuSurfaceBuilder? gpuBuilder,
  Rect? navZone,
}) async {
  final controller = GatewayController()..scene = scene;
  addTearDown(controller.dispose);
  final settings = SettingsController(
    store: MemorySettingsStore(),
    initial: AppSettings(
      sceneTheme: theme,
      demoRoute: route,
      settingsEndpoint: 'http://127.0.0.1:18082',
    ),
  );
  _kova?.dispose();
  final gateway = FakeKovaGateway();
  _kova = KovaParamsController(
    clientFactory: (endpoint, onError) => KovaParamsClient.tryCreate(
      endpoint,
      transport: gateway,
      onError: onError,
    ),
    pollInterval: null,
  );
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: KovaLinkApp.theme(Brightness.dark),
        home: RepaintBoundary(
          key: _key,
          child: Stack(
            fit: StackFit.expand,
            children: [
              KovaLinkHome(
                controller: controller,
                settings: settings,
                library: VehicleModelLibrary(storageRoot: () async => root),
                kovaParams: _kova,
                director: director,
                gpuSurfaceBuilder: gpuBuilder,
              ),
              if (navZone != null)
                IgnorePointer(
                  child: CustomPaint(painter: _NavZonePainter(navZone)),
                ),
            ],
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await tester.pump();
}

/// Lets tab and page transitions finish (no pumpAndSettle: the HUD and
/// kovapilot panel may keep animating).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// Capture-only marker for where a navigation app's overlay floats.
class _NavZonePainter extends CustomPainter {
  _NavZonePainter(this.zone);

  final Rect zone;

  @override
  void paint(Canvas canvas, Size size) {
    const orange = Color(0xFFFF9F43);
    final box = RRect.fromRectAndRadius(
      zone.deflate(4),
      const Radius.circular(10),
    );
    canvas.drawRRect(box, Paint()..color = const Color(0x22FF9F43));
    final edge = Paint()
      ..color = orange
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final path = Path()..addRRect(box);
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 14) {
        canvas.drawPath(metric.extractPath(d, d + 8), edge);
      }
    }
    final label = TextPainter(
      text: const TextSpan(
        text: '내비 오버레이 자리\n(캡처 표시)',
        style: TextStyle(
          fontFamily: 'Roboto',
          color: orange,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1.25,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
    )..layout(maxWidth: zone.width - 16);
    label.paint(
      canvas,
      Offset(zone.right - 8 - label.width, zone.bottom - 8 - label.height),
    );
  }

  @override
  bool shouldRepaint(_NavZonePainter old) => old.zone != zone;
}

/// Scrolling re-checks the same text; keep each finding once.
void _dedupe(LayoutReport report) {
  for (final list in [
    report.clippedText,
    report.ellipsized,
    report.wrappedLabels,
    report.overlaps,
  ]) {
    final unique = list.toSet().toList();
    list
      ..clear()
      ..addAll(unique);
  }
}
