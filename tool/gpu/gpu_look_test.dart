// Look-development capture of the GPU road renderer (worker only).
//
//   KOVA_SHOT_DIR=out flutter test tool/gpu/gpu_look_test.dart
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kovalink/src/features/road_view/scene3d/scene_director.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/gpu_scene/gpu_road_renderer.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/vehicle_model_repository.dart';

import 'headless_gpu.dart';

void main() {
  test('gpu look', () async {
    final out = Platform.environment['KOVA_SHOT_DIR'] ?? 'build/gpu_look';
    Directory(out).createSync(recursive: true);
    final only = Platform.environment['KOVA_LOOK']?.split(',');
    const w = 1200, h = 945;
    final gpu = await HeadlessGpu.create(w, h);
    final renderer = GpuRoadRenderer(gpu.viewer);
    final shots = <(String, DemoRoute, double, SceneTheme)>[
      ('highway_clear', DemoRoute.highway, 70, SceneTheme.clear),
      ('city_overcast', DemoRoute.city, 46, SceneTheme.overcast),
      ('highway_sunset', DemoRoute.highway, 20, SceneTheme.sunset),
      ('city_night', DemoRoute.city, 30, SceneTheme.night),
      ('highway_night', DemoRoute.highway, 70, SceneTheme.night),
      ('city_rain', DemoRoute.city, 46, SceneTheme.rain),
    ];
    for (final (name, route, t, theme) in shots) {
      if (only != null && !only.contains(name)) continue;
      final scene = DemoDriveScenario(
        route: route,
      ).sceneAt(Duration(milliseconds: (t * 1000).round()));
      final director = SceneDirector().update(scene, const Size(1200, 945));
      final sw = Stopwatch()..start();
      final stats = await renderer.update(
        GpuFrameInput(
          scene: scene,
          director: director,
          width: w,
          height: h,
          theme: theme,
          vehicle: VehicleModelLoadResult.bundledDefault.profile,
        ),
      );
      final build = sw.elapsedMilliseconds;
      final px = await gpu.capture(warmup: 3);
      final total = sw.elapsedMilliseconds;
      final im = img.Image.fromBytes(
        width: w,
        height: h,
        bytes: px.buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
      File('$out/look_$name.png').writeAsBytesSync(img.encodePng(im));
      // ignore: avoid_print
      print(
        '$name build=${build}ms total=${total}ms tris=${stats.worldTriangles} vehicles=${stats.vehicles} lights=${stats.lights}',
      );
    }
    await renderer.dispose();
  }, timeout: const Timeout(Duration(minutes: 20)));
}
