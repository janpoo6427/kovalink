// GPU (Filament) captures of the full app for review: the same RoadViewScreen,
// HUD and GPU renderer the phone uses, with the GPU frame rendered headlessly
// on the worker (EGL surfaceless + Mesa llvmpipe) and injected through
// RoadViewScreen.gpuSurfaceBuilder.
//
//   KOVA_SHOT_DIR=/path flutter test tool/screenshots/gpu_capture_test.dart
//   KOVA_VIDEO=1 ... also renders the 10 s demo clip frames.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kovalink_home.dart';
import 'package:kovalink/src/features/road_view/gpu_road_surface.dart';
import 'package:kovalink/src/features/road_view/render_quality.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_director.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/gpu_scene/gpu_road_renderer.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/services/vehicle_model_repository.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_mesh/vehicle_mesh_loader.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';
import 'package:kovalink/src/vehicle_pack/zip_writer.dart';

import '../gpu/headless_gpu.dart';
import 'shot_support.dart';

Duration _s(double seconds) => Duration(milliseconds: (seconds * 1000).round());

ThemeData _theme(Brightness brightness) => ThemeData(
  fontFamily: 'Roboto',
  brightness: brightness,
  colorScheme: brightness == Brightness.dark
      ? const ColorScheme.dark(
          primary: Color(0xFF58F2C2),
          surface: Color(0xFF111820),
        )
      : null,
  scaffoldBackgroundColor: brightness == Brightness.dark
      ? const Color(0xFF070B10)
      : null,
  useMaterial3: true,
);

HeadlessGpu? _gpu;
GpuRoadRenderer? _renderer;
final _perf = <String>[];

Future<ui.Image> _renderGpu(
  GpuSurfaceRequest r,
  Size physical, {
  int warmup = 3,
  Uint8List? egoGlb,
  String? egoKey,
  VehicleModelLoadResult? model,
}) async {
  _gpu ??= await HeadlessGpu.create(
    physical.width.toInt(),
    physical.height.toInt(),
  );
  _renderer ??= GpuRoadRenderer(_gpu!.viewer);
  await _gpu!.resize(physical.width.toInt(), physical.height.toInt());
  final sw = Stopwatch()..start();
  await _renderer!.update(
    GpuFrameInput(
      scene: r.scene,
      director: r.director,
      width: physical.width.toInt(),
      height: physical.height.toInt(),
      theme: r.theme,
      layers: r.layers,
      vehicle: r.vehicle,
      viewpoint: r.viewpoint,
      egoPackGlb: egoGlb,
      egoPackKey: egoKey,
      egoBodyNode: model?.manifest.nodes.body,
      egoExcludeNodes: model?.manifest.excludeNodes.toSet() ?? const {},
    ),
  );
  final build = sw.elapsedMilliseconds;
  final px = await _gpu!.capture(warmup: warmup);
  _perf.add(
    '${physical.width.toInt()}x${physical.height.toInt()} build ${build}ms total ${sw.elapsedMilliseconds}ms (warmup $warmup)',
  );
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

/// One app frame: GPU scene + HUD, saved as [name].png.
Future<void> _shot(
  WidgetTester tester, {
  required String name,
  required Size physical,
  required double ratio,
  required DemoRoute route,
  required double t,
  required SceneTheme theme,
  SceneViewpoint viewpoint = SceneViewpoint.chase,
  VehicleModelLoadResult? model,
  SceneDirector? director,
  List<double> history = const [],
}) async {
  await tester.runAsync(loadReviewFonts);
  tester.view.physicalSize = physical;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
  final scenario = DemoDriveScenario(route: route);
  final scene = scenario.sceneAt(_s(t));
  final logical = physical / ratio;
  final profile = (model ?? VehicleModelLoadResult.bundledDefault).profile;
  final d = director ?? SceneDirector();
  // Replay a little history so smoothing (camera, sweep, tones) is live.
  for (final h in history) {
    d.update(
      scenario.sceneAt(_s(h)),
      logical,
      viewpoint: viewpoint,
      vehicle: profile,
    );
  }
  final frame = d.update(
    scene,
    logical,
    viewpoint: viewpoint,
    vehicle: profile,
  );
  final settings = SettingsController(
    store: MemorySettingsStore(),
    initial: AppSettings(
      viewpoint: viewpoint,
      sceneTheme: theme,
      demoRoute: route,
      vehicleModelId: model?.manifest.id,
    ),
  );
  final request = GpuSurfaceRequest(
    scene: scene,
    director: frame,
    theme: theme,
    layers: settings.value.layers,
    vehicle: profile,
    viewpoint: viewpoint,
    egoGlbPath: model?.glbAssetPath,
  );
  Uint8List? glb;
  if (model?.glbAssetPath case final path?) {
    glb = File(Uri.parse(path).toFilePath()).readAsBytesSync();
  }
  final image = (await tester.runAsync(
    () => _renderGpu(
      request,
      physical,
      egoGlb: glb,
      egoKey: model?.manifest.id,
      model: model,
    ),
  ))!;
  final controller = GatewayController();
  controller.scene = scene;
  final library = VehicleModelLibrary(
    storageRoot: () async => Directory.systemTemp,
  );
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      home: RepaintBoundary(
        key: key,
        child: KovaLinkHome(
          controller: controller,
          settings: settings,
          library: library,
          vehicleModel: model == null ? null : ValueNotifier(model),
          director: d,
          gpuSurfaceBuilder: (context, r) =>
              RawImage(image: image, fit: BoxFit.fill),
        ),
      ),
    ),
  );
  await tester.pump();
  await saveBoundary(tester, key, name);
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
}

void main() {
  const land = Size(1200, 945);
  const city = Size(1081, 1200);
  const phone = Size(1080, 2340);
  final stills =
      <(String, Size, double, DemoRoute, double, SceneTheme, List<double>)>[
        (
          'gpu_highway_clear_1200x945',
          land,
          1,
          DemoRoute.highway,
          20,
          SceneTheme.clear,
          [19.0, 19.5],
        ),
        (
          'gpu_highway_blindspot_1200x945',
          land,
          1,
          DemoRoute.highway,
          45.6,
          SceneTheme.clear,
          [44.8, 45.2],
        ),
        (
          'gpu_highway_lane_change_1200x945',
          land,
          1,
          DemoRoute.highway,
          53.5,
          SceneTheme.clear,
          [52.5, 53.0],
        ),
        (
          'gpu_city_overcast_1081x1200',
          city,
          1,
          DemoRoute.city,
          2,
          SceneTheme.overcast,
          [],
        ),
        (
          'gpu_city_lead_close_1081x1200',
          city,
          1,
          DemoRoute.city,
          49.5,
          SceneTheme.overcast,
          [48.5, 49.0],
        ),
        (
          'gpu_city_turn_cyclist_1081x1200',
          city,
          1,
          DemoRoute.city,
          64,
          SceneTheme.clear,
          [63.0, 63.5],
        ),
        (
          'gpu_highway_sunset_1200x945',
          land,
          1,
          DemoRoute.highway,
          20,
          SceneTheme.sunset,
          [19.0, 19.5],
        ),
        (
          'gpu_city_night_1081x1200',
          city,
          1,
          DemoRoute.city,
          30,
          SceneTheme.night,
          [29.0, 29.5],
        ),
        (
          'gpu_highway_night_1200x945',
          land,
          1,
          DemoRoute.highway,
          70,
          SceneTheme.night,
          [69.0, 69.5],
        ),
        (
          'gpu_city_rain_1081x1200',
          city,
          1,
          DemoRoute.city,
          46,
          SceneTheme.rain,
          [45.0, 45.5],
        ),
        (
          'gpu_highway_rain_1200x945',
          land,
          1,
          DemoRoute.highway,
          30,
          SceneTheme.rain,
          [29.0, 29.5],
        ),
        (
          'gpu_phone_highway_1080x2340',
          phone,
          2.625,
          DemoRoute.highway,
          20,
          SceneTheme.clear,
          [19.0, 19.5],
        ),
        (
          'gpu_phone_city_night_1080x2340',
          phone,
          2.625,
          DemoRoute.city,
          30,
          SceneTheme.night,
          [29.0, 29.5],
        ),
      ];
  final only = Platform.environment['KOVA_ONLY']?.split(',');
  for (final (name, size, ratio, route, t, theme, history) in stills) {
    if (only != null && !only.contains(name)) continue;
    testWidgets('capture $name', (tester) async {
      await _shot(
        tester,
        name: name,
        physical: size,
        ratio: ratio,
        route: route,
        t: t,
        theme: theme,
        history: history,
      );
    }, timeout: const Timeout(Duration(minutes: 5)));
  }

  testWidgets('capture imported ToyCar (GPU)', (tester) async {
    if (only != null && !only.contains('gpu_import_toycar')) return;
    final root = await tester.runAsync(
      () => Directory.systemTemp.createTemp('kl_import_'),
    );
    final library = VehicleModelLibrary(storageRoot: () async => root!);
    final model = await tester.runAsync(() async {
      const dir = 'assets/vehicles/toy_car';
      final manifest =
          jsonDecode(File('$dir/vehicle.json').readAsStringSync())
              as Map<String, dynamic>;
      manifest['id'] = 'toy-car-import';
      manifest['displayName'] = 'Toy Car (가져온 팩)';
      final archive = ZipWriter.build([
        ZipWriterEntry('vehicle.json', utf8.encode(jsonEncode(manifest))),
        ZipWriterEntry(
          'vehicle.glb',
          File('$dir/vehicle.glb').readAsBytesSync(),
        ),
        ZipWriterEntry('LICENSE.md', File('$dir/LICENSE.md').readAsBytesSync()),
      ]);
      final outcome = await library.importPack(archive);
      expect(outcome.imported, isTrue);
      final loaded = await library.load('toy-car-import');
      final mesh = await VehicleMeshLoader.load(
        loaded.glbAssetPath,
        loaded.manifest,
      );
      return loaded.withMesh(mesh.mesh, mesh.warnings);
    });
    await _shot(
      tester,
      name: 'gpu_import_toycar_highway_1200x945',
      physical: land,
      ratio: 1,
      route: DemoRoute.highway,
      t: 20,
      theme: SceneTheme.clear,
      model: model,
      history: [19.0, 19.5],
    );
    await _shot(
      tester,
      name: 'gpu_import_toycar_city_night_1081x1200',
      physical: city,
      ratio: 1,
      route: DemoRoute.city,
      t: 30,
      theme: SceneTheme.night,
      model: model,
      history: [29.0, 29.5],
    );
    await tester.runAsync(() => root!.delete(recursive: true));
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets(
    'capture software (절약) comparison',
    (tester) async {
      if (only != null && !only.contains('saver')) return;
      for (final (name, size, route, t, theme) in [
        (
          'saver_highway_clear_1200x945',
          land,
          DemoRoute.highway,
          20.0,
          SceneTheme.clear,
        ),
        (
          'saver_city_night_1081x1200',
          city,
          DemoRoute.city,
          30.0,
          SceneTheme.night,
        ),
        (
          'saver_city_rain_1081x1200',
          city,
          DemoRoute.city,
          46.0,
          SceneTheme.rain,
        ),
      ]) {
        await tester.runAsync(loadReviewFonts);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        final controller = GatewayController();
        final scenario = DemoDriveScenario(route: route);
        controller.scene = scenario.sceneAt(_s(t));
        final d = SceneDirector()..update(scenario.sceneAt(_s(t - 0.5)), size);
        final settings = SettingsController(
          store: MemorySettingsStore(),
          initial: AppSettings(
            sceneTheme: theme,
            demoRoute: route,
            renderQuality: RenderQuality.saver,
          ),
        );
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _theme(Brightness.light),
            home: RepaintBoundary(
              key: key,
              child: KovaLinkHome(
                controller: controller,
                settings: settings,
                library: VehicleModelLibrary(
                  storageRoot: () async => Directory.systemTemp,
                ),
                director: d,
              ),
            ),
          ),
        );
        await tester.pump();
        await saveBoundary(tester, key, name);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
      tester.view.reset();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets('demo video frames (GPU)', (tester) async {
    if (Platform.environment['KOVA_VIDEO'] != '1') return;
    const size = Size(960, 756);
    const fps = 24;
    const start = 43.0, seconds = 10.0;
    final route = DemoRoute.highway;
    final theme = SceneTheme.values.byName(
      Platform.environment['KOVA_VIDEO_THEME'] ?? 'sunset',
    );
    await tester.runAsync(loadReviewFonts);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scenario = DemoDriveScenario(route: route);
    final director = SceneDirector();
    final controller = GatewayController();
    final settings = SettingsController(
      store: MemorySettingsStore(),
      initial: AppSettings(sceneTheme: theme, demoRoute: route),
    );
    final profile = VehicleModelLoadResult.bundledDefault.profile;
    final library = VehicleModelLibrary(
      storageRoot: () async => Directory.systemTemp,
    );
    ui.Image? current;
    final key = GlobalKey();
    final tick = ValueNotifier<int>(0);
    final dir = Directory('$shotDirectory/video_frames')
      ..createSync(recursive: true);
    for (var i = 0; i < seconds * fps; i++) {
      final t = start + i / fps;
      final scene = scenario.sceneAt(_s(t));
      final frame = director.update(scene, size, vehicle: profile);
      final request = GpuSurfaceRequest(
        scene: scene,
        director: frame,
        theme: theme,
        layers: settings.value.layers,
        vehicle: profile,
        viewpoint: SceneViewpoint.chase,
      );
      current = (await tester.runAsync(
        () => _renderGpu(request, size, warmup: i == 0 ? 3 : 0),
      ))!;
      controller.scene = scene;
      tick.value = i;
      if (i == 0) {
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _theme(Brightness.light),
            home: RepaintBoundary(
              key: key,
              // GatewayController.scene is a plain field; rebuild the home
              // every frame so the road view reads the new scene.
              child: ValueListenableBuilder<int>(
                valueListenable: tick,
                builder: (context, _, _) => KovaLinkHome(
                  controller: controller,
                  settings: settings,
                  library: library,
                  director: director,
                  gpuSurfaceBuilder: (context, r) =>
                      RawImage(image: current, fit: BoxFit.fill),
                ),
              ),
            ),
          ),
        );
      }
      await tester.pump(const Duration(milliseconds: 1000 ~/ fps));
      await saveBoundary(
        tester,
        key,
        'video_frames/f_${i.toString().padLeft(4, '0')}',
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    expect(dir.listSync().length, greaterThanOrEqualTo(seconds * fps));
    final first = File('${dir.path}/f_0000.png').readAsBytesSync();
    final mid = File(
      '${dir.path}/f_${(seconds * fps ~/ 2).toString().padLeft(4, '0')}.png',
    ).readAsBytesSync();
    expect(first, isNot(mid), reason: 'video frames must move');
  }, timeout: const Timeout(Duration(minutes: 60)));

  tearDownAll(() async {
    File('$shotDirectory/gpu_perf.txt').writeAsStringSync(_perf.join('\n'));
  });
}
