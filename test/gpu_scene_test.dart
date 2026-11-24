import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_director.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/gpu_scene/gltf_scene_builder.dart';
import 'package:kovalink/src/gpu_scene/road_world_glb.dart';
import 'package:kovalink/src/gpu_scene/scene_look.dart';
import 'package:kovalink/src/gpu_scene/vehicle_gpu_glb.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/vehicle_mesh/builtin_figures.dart';
import 'package:kovalink/src/vehicle_mesh/builtin_vehicles.dart';
import 'package:kovalink/src/vehicle_mesh/vehicle_mesh.dart';

Map<String, dynamic> _json(Uint8List glb) {
  final bd = ByteData.sublistView(glb);
  expect(bd.getUint32(0, Endian.little), 0x46546C67);
  expect(bd.getUint32(4, Endian.little), 2);
  expect(bd.getUint32(8, Endian.little), glb.length);
  final len = bd.getUint32(12, Endian.little);
  return jsonDecode(utf8.decode(glb.sublist(20, 20 + len)))
      as Map<String, dynamic>;
}

RoadScene _demo(DemoRoute route, double seconds) => DemoDriveScenario(
  route: route,
).sceneAt(Duration(milliseconds: (seconds * 1000).round()));

void main() {
  group('GltfSceneBuilder', () {
    test('writes a valid, deterministic GLB with extensions', () {
      GltfSceneBuilder make() {
        final b = GltfSceneBuilder();
        final m = b.material({
          'name': 'M',
          'pbrMetallicRoughness': {
            'baseColorFactor': [1, 1, 1, 1],
          },
          'extensions': {
            'KHR_materials_clearcoat': {'clearcoatFactor': 1.0},
          },
        });
        final buf = PrimitiveBuffer(withColors: true);
        final a = buf.vertex(0, 0, 0, 0, 1, 0, [1, 0, 0, 1]);
        final c = buf.vertex(1, 0, 0, 0, 1, 0);
        final d = buf.vertex(0, 0, 1, 0, 1, 0);
        buf.tri(a, d, c);
        b.node(
          'N',
          mesh: b.mesh('Tri', [buf.build(m)]),
          translation: [1, 2, 3],
        );
        return b;
      }

      final glb = make().toGlb();
      expect(glb, make().toGlb());
      final json = _json(glb);
      expect(json['extensionsUsed'], ['KHR_materials_clearcoat']);
      final prim = json['meshes'][0]['primitives'][0] as Map<String, dynamic>;
      expect(
        (prim['attributes'] as Map).keys,
        containsAll(['POSITION', 'NORMAL', 'COLOR_0']),
      );
      expect(json['nodes'][0]['translation'], [1, 2, 3]);
    });
  });

  group('VehicleGpuGlb', () {
    test('SUV: paint/glass/lamp roles, four wheel pivots, unit normals', () {
      final asset = VehicleGpuGlb.build(
        BuiltinVehicles.builderFor(BuiltinBody.suv),
        rearAxleX: 0,
      );
      final roles = asset.roles.values.expand((r) => r).toSet();
      expect(
        roles,
        containsAll([
          MeshRole.paint,
          MeshRole.glass,
          MeshRole.brake,
          MeshRole.tire,
        ]),
      );
      expect(asset.wheelPivots.keys.toSet(), {
        'Wheel_FL',
        'Wheel_FR',
        'Wheel_RL',
        'Wheel_RR',
      });
      for (final p in asset.wheelPivots.values) {
        expect(p[1], greaterThan(0.2)); // wheel center above ground
      }
      expect(asset.length, closeTo(BuiltinVehicles.suv.size.$1, 0.05));
      expect(asset.rearX, closeTo(0, 0.05));
      final json = _json(asset.glb);
      final materials = json['materials'] as List<dynamic>;
      final paint =
          materials.firstWhere((m) => m['name'] == 'KL_BodyPaint')
              as Map<String, dynamic>;
      expect(
        (paint['extensions'] as Map).containsKey('KHR_materials_clearcoat'),
        isTrue,
      );
      final glass =
          materials.firstWhere((m) => m['name'] == 'KL_Glass')
              as Map<String, dynamic>;
      expect(glass['alphaMode'], 'BLEND');
    });

    test('smooth normals are unit length and keep outward orientation', () {
      final b = BuiltinVehicles.builderFor(BuiltinBody.sedan);
      final glb = VehicleGpuGlb.write(b, rearAxleX: 0);
      final json = _json(glb);
      final bd = ByteData.sublistView(glb);
      final jsonLen = bd.getUint32(12, Endian.little);
      final binStart = 20 + jsonLen + 8;
      final body = (json['nodes'] as List).indexWhere(
        (n) => n['name'] == 'Body',
      );
      final mesh =
          json['meshes'][json['nodes'][body]['mesh']] as Map<String, dynamic>;
      final prim = mesh['primitives'][0] as Map<String, dynamic>;
      final acc =
          json['accessors'][prim['attributes']['NORMAL']]
              as Map<String, dynamic>;
      final view =
          json['bufferViews'][acc['bufferView']] as Map<String, dynamic>;
      final normals = Float32List.sublistView(
        glb,
        binStart + (view['byteOffset'] as int),
        binStart + (view['byteOffset'] as int) + (view['byteLength'] as int),
      );
      for (var i = 0; i < normals.length; i += 3) {
        final l = math.sqrt(
          normals[i] * normals[i] +
              normals[i + 1] * normals[i + 1] +
              normals[i + 2] * normals[i + 2],
        );
        expect(l, closeTo(1, 1e-3));
      }
    });

    test('pedestrian, cyclist and cone figures build', () {
      expect(BuiltinFigures.pedestrian.triangleCount, greaterThan(300));
      expect(BuiltinFigures.pedestrian.size.$3, closeTo(1.76, 0.1));
      final cyclist = VehicleGpuGlb.build(
        BuiltinFigures.cyclistBuilder(),
        rearAxleX: 0,
      );
      expect(cyclist.wheelPivots.keys, containsAll(['Wheel_R', 'Wheel_F']));
      expect(BuiltinFigures.coneBuilder().triangleCount, greaterThan(50));
    });
  });

  group('RoadWorldGlb', () {
    test('highway and city worlds build for every theme', () {
      for (final route in DemoRoute.values) {
        final scene = _demo(route, 30);
        for (final theme in SceneTheme.values) {
          final world = RoadWorldGlb.build(
            scene,
            SceneLook.resolve(theme, scene.roadType),
          );
          expect(world.triangles, greaterThan(5000), reason: '$route $theme');
          final json = _json(world.glb);
          final names = [for (final n in json['nodes'] as List) n['name']];
          expect(names, containsAll(['Asphalt', 'Ground', 'Shoulders']));
          expect(
            names,
            contains(route == DemoRoute.city ? 'Buildings' : 'Foliage'),
          );
        }
      }
    });

    test(
      'wet themes make the asphalt glossy and translucent for reflections',
      () {
        final scene = _demo(DemoRoute.city, 40);
        Map<String, dynamic> asphalt(SceneTheme t) {
          final json = _json(
            RoadWorldGlb.build(scene, SceneLook.resolve(t, RoadType.city)).glb,
          );
          return (json['materials'] as List).firstWhere(
                (m) => m['name'] == 'KL_Asphalt',
              )
              as Map<String, dynamic>;
        }

        final dry = asphalt(SceneTheme.clear), wet = asphalt(SceneTheme.rain);
        expect(dry['alphaMode'], isNull);
        expect(wet['alphaMode'], 'BLEND');
        expect(
          wet['pbrMetallicRoughness']['roughnessFactor'],
          lessThan(dry['pbrMetallicRoughness']['roughnessFactor'] as num),
        );
      },
    );

    test(
      'ribbon-only mode builds just the glowing path, tinted by lead tone',
      () {
        final scene = _demo(DemoRoute.highway, 70);
        final look = SceneLook.resolve(SceneTheme.clear, RoadType.highway);
        final calm = RoadWorldGlb.build(scene, look, ribbonOnly: true);
        final close = RoadWorldGlb.build(
          scene,
          look,
          ribbonOnly: true,
          path: const PathStyle(leadTone: 1),
        );
        final names = [
          for (final n in _json(calm.glb)['nodes'] as List) n['name'],
        ];
        expect(names, ['PathRibbon']);
        expect(calm.glb, isNot(close.glb));
      },
    );

    test('street lamps are reported for the renderer lights', () {
      final world = RoadWorldGlb.build(
        _demo(DemoRoute.city, 30),
        SceneLook.resolve(SceneTheme.night, RoadType.city),
      );
      expect(world.lamps, isNotEmpty);
      expect(world.lamps.every((l) => l.z > 7), isTrue);
    });
  });

  group('SceneLook', () {
    test(
      'exposure: night is many stops darker than day, lights only when needed',
      () {
        final day = SceneLook.resolve(SceneTheme.clear, RoadType.highway);
        final night = SceneLook.resolve(SceneTheme.night, RoadType.highway);
        final rain = SceneLook.resolve(SceneTheme.rain, RoadType.city);
        expect(day.ev100, inInclusiveRange(13.5, 15.5));
        expect(night.ev100, lessThan(day.ev100 - 8));
        expect(day.headlights, isFalse);
        expect(night.headlights && night.streetLights, isTrue);
        expect(rain.wetness, 1);
        expect(rain.rain, isTrue);
        expect(night.headlightLumens, greaterThan(1000));
      },
    );

    test('sky is blue above, brighter at the horizon, darker below', () {
      final day = SceneLook.resolve(SceneTheme.clear, RoadType.highway);
      final up = day.skyRadiance(0, 0, 1);
      final horizon = day.skyRadiance(1, 0, 0.01);
      final down = day.skyRadiance(0, 0, -1);
      expect(up[2], greaterThan(up[0]));
      expect(horizon[0], greaterThan(up[0]));
      expect(down[1], lessThan(horizon[1]));
    });
  });

  group('SceneDirector', () {
    const size = Size(1200, 945);

    test('camera rises and widens with speed', () {
      final slow = SceneDirector.chaseCamera(size, 0);
      final fast = SceneDirector.chaseCamera(size, 30);
      expect(fast.eye.z, greaterThan(slow.eye.z));
      expect(
        fast.horizontalFov(size.width),
        greaterThan(slow.horizontalFov(size.width)),
      );
    });

    test(
      'portrait camera is lower than a plain chase camera (less top-down)',
      () {
        const phone = Size(1080, 2340);
        final hero = SceneDirector.chaseCamera(phone, 10);
        final plain = PerspectiveCamera.chase(phone);
        expect(hero.pitchRadians, lessThan(plain.pitchRadians));
      },
    );

    test('speed is smoothed between frames', () {
      final d = SceneDirector();
      final a = _demo(DemoRoute.city, 5.9);
      d.update(a, size);
      RoadScene at(double s) => _demo(DemoRoute.city, s);
      final after = d.update(at(6.0), size).camera as PerspectiveCamera;
      expect(
        after.eye.z,
        closeTo(SceneDirector.chaseCamera(size, a.speedMps).eye.z, 0.05),
      );
    });

    test('lead tone is calm far away and alarming when close', () {
      final far = _demo(DemoRoute.highway, 70);
      expect(SceneDirector.leadToneFor(far), lessThan(0.2));
      final near = _demo(DemoRoute.city, 50);
      expect(SceneDirector.leadToneFor(near), greaterThan(0.3));
    });

    test('engage sweep runs once when steering assist turns on', () {
      final d = SceneDirector();
      d.update(_demo(DemoRoute.city, 5.5), size);
      d.update(_demo(DemoRoute.city, 5.9), size);
      final on = d.update(_demo(DemoRoute.city, 6.3), size);
      expect(on.path.sweep, inInclusiveRange(0.0, 1.0));
      final later = () {
        DirectorFrame? f;
        for (var t = 6.4; t <= 9.0; t += 0.1) {
          f = d.update(_demo(DemoRoute.city, t), size);
        }
        return f!;
      }();
      expect(later.path.sweep, -1);
    });

    test('turn ahead leans the camera toward the turn', () {
      final d = SceneDirector();
      final turn = _demo(DemoRoute.city, 86);
      expect(turn.tbt!.maneuver, TbtManeuver.turnLeft);
      final frame = d.update(turn, size);
      if (turn.tbt!.distanceMeters < 140) {
        expect(frame.rollRadians, greaterThan(0));
      }
    });

    test('blind spot: car beside in the adjacent lane is detected', () {
      const scene = RoadScene(
        monotonicTimeNanos: 0,
        speedMps: 20,
        setSpeedMps: 25,
        steeringAngleDegrees: 0,
        engaged: true,
        plannedPath: [],
        leftLane: [],
        rightLane: [],
        objects: [
          TrackedObject(
            distanceMeters: -5,
            leftMeters: 3.5,
            relativeSpeedMps: 0,
          ),
          TrackedObject(
            distanceMeters: 30,
            leftMeters: -3.5,
            relativeSpeedMps: 0,
          ),
        ],
      );
      expect(SceneDirector.blindSpotObject(scene, left: true), isNotNull);
      expect(SceneDirector.blindSpotObject(scene, left: false), isNull);
      final frame = SceneDirector().update(scene, size);
      expect(frame.blindSpots.single.left, isTrue);
    });
  });
}
