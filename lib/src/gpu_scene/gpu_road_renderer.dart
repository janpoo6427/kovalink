import 'dart:async';
import 'dart:math' as math;

import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart'
    show RoadWorldPainter, SceneLayers;
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_director.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/gpu_scene/glb_bounds.dart';
import 'package:kovalink/src/gpu_scene/road_world_glb.dart';
import 'package:kovalink/src/gpu_scene/scene_look.dart';
import 'package:kovalink/src/gpu_scene/vehicle_gpu_glb.dart';
import 'package:kovalink/src/models/ego_vehicle_profile.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/vehicle_mesh/builtin_figures.dart';
import 'package:kovalink/src/vehicle_mesh/builtin_vehicles.dart';
import 'package:kovalink/src/vehicle_mesh/vehicle_mesh.dart';
import 'package:thermion_dart/thermion_dart.dart';
// ignore: implementation_imports
import 'package:thermion_dart/src/filament/src/implementation/ffi_ktx1_bundle.dart';
// ignore: implementation_imports
import 'package:thermion_dart/src/filament/src/implementation/ffi_filament_app.dart';

/// Built-in GPU body kinds.
enum GpuBody { suv, sedan, truck, pedestrian, cyclist, cone }

/// Lazily built GPU vehicle assets shared by every renderer.
class GpuVehicleLibrary {
  GpuVehicleLibrary._();

  static final Map<GpuBody, VehicleGpuAsset> _cache = {};

  static VehicleGpuAsset of(GpuBody body) => _cache.putIfAbsent(body, () {
    final builder = switch (body) {
      GpuBody.suv => BuiltinVehicles.builderFor(BuiltinBody.suv),
      GpuBody.sedan => BuiltinVehicles.builderFor(BuiltinBody.sedan),
      GpuBody.truck => BuiltinVehicles.builderFor(BuiltinBody.truck),
      GpuBody.pedestrian => BuiltinFigures.pedestrianBuilder(),
      GpuBody.cyclist => BuiltinFigures.cyclistBuilder(),
      GpuBody.cone => BuiltinFigures.coneBuilder(),
    };
    return VehicleGpuGlb.build(builder, rearAxleX: 0);
  });

  /// Body for a tracked object (same SUV/sedan mix as the software path).
  static GpuBody bodyFor(TrackedObject object) {
    switch (object.kind) {
      case TrackedObjectKind.truck:
        return GpuBody.truck;
      case TrackedObjectKind.pedestrian:
        return GpuBody.pedestrian;
      case TrackedObjectKind.cyclist:
        return GpuBody.cyclist;
      case TrackedObjectKind.trafficCone:
        return GpuBody.cone;
      default:
        final set = RoadWorldPainter.builtinBodyFor(object);
        return identical(set, BuiltinVehicles.suvSet)
            ? GpuBody.suv
            : GpuBody.sedan;
    }
  }
}

/// Inputs for one GPU frame.
class GpuFrameInput {
  const GpuFrameInput({
    required this.scene,
    required this.director,
    required this.width,
    required this.height,
    this.theme = SceneTheme.clear,
    this.layers = const SceneLayers(),
    this.vehicle = EgoVehicleProfile.builtIn,
    this.egoPackGlb,
    this.egoPackKey,
    this.viewpoint = SceneViewpoint.chase,
    this.egoBodyNode,
    this.egoExcludeNodes = const {},
  });

  /// Nodes the pack manifest excludes from display (`excludeNodes`).
  final Set<String> egoExcludeNodes;

  /// Body node of an imported pack (manifest `nodes.body`), used to fit it
  /// and to hide staging props (cloths, stands) shipped in sample models.
  final String? egoBodyNode;

  final SceneViewpoint viewpoint;

  final RoadScene scene;
  final DirectorFrame director;
  final int width;
  final int height;
  final SceneTheme theme;
  final SceneLayers layers;
  final EgoVehicleProfile vehicle;

  /// GLB of an imported model pack for the ego (null = built-in SUV).
  final Uint8List? egoPackGlb;
  final String? egoPackKey;
}

class GpuFrameStats {
  const GpuFrameStats({
    required this.worldTriangles,
    required this.vehicles,
    required this.lights,
    required this.buildMs,
  });

  final int worldTriangles;
  final int vehicles;
  final int lights;
  final int buildMs;
}

class _Slot {
  _Slot(this.asset, this.layout, {this.mirror});

  final ThermionAsset asset;
  final VehicleGpuAsset? layout;
  final ThermionAsset? mirror;
  final _materials = <MeshRole, List<MaterialInstance>>{};
  final _mirrorMaterials = <MeshRole, List<MaterialInstance>>{};
  final _wheels = <String, ThermionEntity>{};
  final _mirrorWheels = <String, ThermionEntity>{};
  bool visible = true;
  double spin = 0;
  int? paint;
  final _lampState = <MeshRole, double>{};

  Future<void> bind(FilamentApp app) async {
    final layout = this.layout;
    if (layout == null) return;
    for (final (target, mats, wheels) in [
      (asset, _materials, _wheels),
      if (mirror != null) (mirror!, _mirrorMaterials, _mirrorWheels),
    ]) {
      for (final entry in layout.roles.entries) {
        final entity = await target.getChildEntity(entry.key);
        if (entity == null) continue;
        if (entry.key.startsWith('Wheel')) wheels[entry.key] = entity;
        for (var i = 0; i < entry.value.length; i++) {
          final role = entry.value[i];
          if (role != MeshRole.paint && !_isLamp(role)) continue;
          // thermion 0.7's ThermionAsset.getMaterialInstanceAt ignores the
          // primitive index, so ask the renderable manager directly.
          final mi = await app.renderableManager.getMaterialInstanceAt(
            entity,
            i,
          );
          if (mi == null) continue;
          (mats[role] ??= []).add(mi);
        }
      }
    }
  }

  static bool _isLamp(MeshRole r) => switch (r) {
    MeshRole.tail ||
    MeshRole.brake ||
    MeshRole.turnLeft ||
    MeshRole.turnRight ||
    MeshRole.reverse ||
    MeshRole.headlight => true,
    _ => false,
  };

  Future<void> setPaint(int argb) async {
    if (paint == argb) return;
    paint = argb;
    final c = _linear(argb);
    for (final mi in [...?_materials[MeshRole.paint]]) {
      await mi.setParameterFloat4('baseColorFactor', c[0], c[1], c[2], 1);
    }
    // Puddle reflections are darker than the car itself.
    for (final mi in [...?_mirrorMaterials[MeshRole.paint]]) {
      await mi.setParameterFloat4(
        'baseColorFactor',
        c[0] * 0.35,
        c[1] * 0.35,
        c[2] * 0.35,
        1,
      );
    }
  }

  Future<void> setLamp(MeshRole role, double strength) async {
    if (_lampState[role] == strength) return;
    _lampState[role] = strength;
    final color = GpuMaterials.lampColor(role);
    for (final mi in [...?_materials[role], ...?_mirrorMaterials[role]]) {
      await mi.setParameterFloat3(
        'emissiveFactor',
        color[0] * strength,
        color[1] * strength,
        color[2] * strength,
      );
    }
  }

  static List<double> _linear(int argb) {
    double ch(int s) {
      final c = ((argb >> s) & 0xFF) / 255.0;
      return c <= 0.04045
          ? c / 12.92
          : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    }

    return [ch(16), ch(8), ch(0)];
  }
}

/// Real-time PBR road view on Filament (via thermion): clearcoat paint and
/// glass with image-based reflections, soft PCSS sun shadows with contact
/// shadows, SSAO, bloom on lamps, fog, ACES tone mapping and MSAA+TAA;
/// day / sunset / night (headlights and street lamps light the road) and
/// rain (wet glossy asphalt with mirrored vehicle reflections).
///
/// The same class drives the phone view (thermion_flutter texture) and the
/// worker's headless captures (EGL surfaceless), so captures show exactly
/// the scene code, meshes and materials the app uses.
class GpuRoadRenderer {
  GpuRoadRenderer(this.viewer, {this.assetPrefix = 'asset://'});

  final ThermionViewer viewer;

  /// Prefix for bundled asset paths passed to the engine's resource loader.
  final String assetPrefix;

  FilamentApp get app => viewer.app;
  View get view => viewer.view;

  SceneTheme? _theme;
  RoadType? _roadType;
  SceneLook? _look;
  ThermionEntity? _sun;
  final _spots = <ThermionEntity>[];
  final _points = <ThermionEntity>[];
  ThermionAsset? _world;
  ThermionAsset? _ribbon;
  final _pools = <String, List<_Slot>>{};
  _Slot? _ego;
  String? _egoKey;
  GlbBounds? _egoFit;
  bool _postSet = false;

  static const _maxLampLights = 6;

  Future<void> _setupPost() async {
    if (_postSet) return;
    _postSet = true;
    await viewer.setPostProcessing(true);
    await view.setRenderQuality(QualityLevel.HIGH);
    await viewer.setAntiAliasing(true, false, true);
    await viewer.setShadowsEnabled(true);
    await view.setShadowType(ShadowType.PCSS);
    await view.setSoftShadowOptions(
      const SoftShadowOptions(penumbraScale: 2.2, penumbraRatioScale: 1.4),
    );
    await view.setAmbientOcclusionOptions(
      const AmbientOcclusionOptions(
        enabled: true,
        radius: 0.55,
        power: 1.3,
        intensity: 1.1,
        resolution: 0.5,
        quality: QualityLevel.HIGH,
        lowPassFilter: QualityLevel.HIGH,
        upsampling: QualityLevel.HIGH,
      ),
    );
    await view.setDithering(true);
    final grading = await view.createColorGradingBuilder();
    final mapper = await ToneMapper.pbrNeutral(app);
    grading
      ..quality(QualityLevel.HIGH)
      ..toneMapper(mapper)
      ..contrast(1.05)
      ..vibrance(1.0);
    await view.setColorGrading(await grading.build());
  }

  Future<void> _applyLook(SceneTheme theme, RoadType roadType) async {
    if (_theme == theme && _roadType == roadType) return;
    final look = SceneLook.resolve(theme, roadType);
    final themeChanged = _theme != theme;
    final wetChanged = (_look?.wetness ?? 0) > 0.5 != look.wetness > 0.5;
    _theme = theme;
    _roadType = roadType;
    _look = look;
    if (wetChanged) await _dropVehicles();
    if (themeChanged) {
      await viewer.loadIbl(
        '${assetPrefix}assets/environments/${look.environmentName}_ibl.ktx',
        intensity: look.iblIntensity,
      );
      await _loadSkybox(
        '${assetPrefix}assets/environments/${look.environmentName}_skybox.ktx',
        look,
      );
    }
    if (_sun != null) {
      await viewer.removeLight(_sun!);
      _sun = null;
    }
    final (sx, sy, sz) = look.sunDirection;
    final toLight = toFilament(sx, sy, sz);
    _sun = await viewer.addDirectLight(
      DirectLight(
        type: LightType.SUN,
        color: LinearColor(
          look.sunColor[0],
          look.sunColor[1],
          look.sunColor[2],
        ),
        intensity: look.sunLux,
        castShadows: look.sunLux > 1000,
        direction: Vector3(-toLight[0], -toLight[1], -toLight[2]),
        position: Vector3.zero(),
        sunAngularRadius: 1.2,
        sunHaloSize: 8,
        sunHaloFallof: 60,
      ),
    );
    await app.lightManager.setShadowOptions(
      _sun!,
      ShadowOptions(
        mapSize: 2048,
        shadowCascades: 3,
        shadowFar: 140,
        constantBias: 0.002,
        normalBias: 1.0,
        lispsm: true,
        screenSpaceContactShadows: true,
        stepCount: 16,
        maxShadowDistance: 0.35,
        shadowBulbRadius: 0.06,
      ),
    );
    await view.setBloom(true, look.bloom);
    await view.setFogOptions(
      FogOptions(
        enabled: true,
        distance: look.fogStart,
        density: look.fogDensity,
        height: 0,
        heightFalloff: 0.035,
        maximumOpacity: 0.92,
        // Keep the baked sky (at infinity) out of the fog.
        cutOffDistance: 900,
        linearColor: Vector3(
          look.fogColor[0],
          look.fogColor[1],
          look.fogColor[2],
        ),
        inScatteringStart: theme == SceneTheme.sunset ? 10 : 0,
        inScatteringSize: theme == SceneTheme.sunset ? 24 : -1,
      ),
    );
    final cam = await viewer.getActiveCamera();
    // EV100 = log2(N² / t) at ISO 100.
    const aperture = 16.0;
    final shutter = aperture * aperture / math.pow(2, look.ev100);
    await cam.setExposure(aperture, shutter.toDouble(), 100);
  }

  Skybox? _skybox;
  Texture? _skyTexture;

  /// Skybox at the same intensity as the IBL (thermion's loadSkybox uses a
  /// fixed default, which over-brightens night skies).
  Future<void> _loadSkybox(String path, SceneLook look) async {
    final data = await app.loadResource(path);
    final bundle =
        await FFIKtx1Bundle.create(app as FFIFilamentApp, data)
            as FFIKtx1Bundle;
    late Future<Texture> created;
    final released = withVoidCallback((id, callback) {
      created = bundle.createTexture(
        onTextureUploadComplete: callback,
        textureUploadCompleteRequestId: id,
      );
    });
    final texture = await created;
    final sky = await app.buildSkybox(
      texture: texture,
      intensity: look.iblIntensity,
      showSun: look.sunDiskRadiance > 0,
    );
    await (viewer as ThermionViewerFFI).scene.setSkybox(sky);
    final oldSky = _skybox, oldTexture = _skyTexture;
    _skybox = sky;
    _skyTexture = texture;
    await oldSky?.destroy();
    await oldTexture?.destroy();
    unawaited(released.then((_) => bundle.destroy()));
  }

  Future<void> _dropVehicles() async {
    for (final slot in [..._pools.values.expand((p) => p), ?_ego]) {
      await viewer.destroyAsset(slot.asset);
      if (slot.mirror != null) {
        await viewer.destroyAsset(slot.mirror!);
      }
    }
    _pools.clear();
    _ego = null;
  }

  Future<ThermionAsset> _load(Uint8List glb, {bool shadows = true}) async {
    final asset = await viewer.loadGltfFromBuffer(glb, addToScene: true);
    await asset.setCastShadows(shadows);
    await asset.setReceiveShadows(true);
    return asset;
  }

  Future<_Slot> _newSlot(
    String key,
    Uint8List glb,
    VehicleGpuAsset? layout,
  ) async {
    final asset = await _load(glb);
    ThermionAsset? mirror;
    if ((_look?.wetness ?? 0) > 0.5) {
      mirror = await _load(glb, shadows: false);
    }
    final slot = _Slot(asset, layout, mirror: mirror);
    await slot.bind(app);
    return slot;
  }

  Future<void> _hide(_Slot slot) async {
    if (!slot.visible) return;
    slot.visible = false;
    final far = Matrix4.translation(Vector3(0, -500, 0));
    await slot.asset.setTransform(far);
    await slot.mirror?.setTransform(far);
  }

  /// Places [slot] with its rear bumper at scene ([rearX], [leftY]), yaw
  /// (radians, left positive) and scale to the requested size.
  Future<void> _place(
    _Slot slot, {
    required double rearX,
    required double leftY,
    required double yaw,
    required double sx,
    required double sy,
    required double sz,
    required double layoutRearX,
    double layoutX = 0,
    double layoutY = 0,
    double steer = 0,
    double spinDelta = 0,
  }) async {
    slot.visible = true;
    // Pack frame: +Z forward, +X left, +Y up, origin at the rear bumper
    // (layoutRearX shifts packs whose origin is the rear axle; layoutX/Y
    // center imported packs laterally and put their wheels on the ground).
    final p = toFilament(rearX, leftY, 0);
    final m = Matrix4.translation(Vector3(p[0], p[1], p[2]))
      ..rotateY(math.pi + yaw)
      ..scaleByDouble(sy, sz, sx, 1)
      ..translateByDouble(-layoutX, -layoutY, -layoutRearX, 1);
    await slot.asset.setTransform(m);
    if (slot.mirror case final mirror?) {
      final mm = Matrix4.diagonal3Values(1, -1, 1)..multiply(m);
      await mirror.setTransform(mm);
    }
    final layout = slot.layout;
    if (layout == null) return;
    slot.spin += spinDelta;
    for (final entry in layout.wheelPivots.entries) {
      final front = entry.key.startsWith('Wheel_F');
      final w =
          Matrix4.translation(
              Vector3(entry.value[0], entry.value[1], entry.value[2]),
            )
            ..rotateY(front ? steer : 0)
            ..rotateX(slot.spin);
      final e = slot._wheels[entry.key];
      if (e != null) {
        await slot.asset.setTransform(w, entity: e);
      }
      final me = slot._mirrorWheels[entry.key];
      if (me != null) {
        await slot.mirror!.setTransform(w, entity: me);
      }
    }
  }

  double? _lastTime;

  Future<GpuFrameStats> update(GpuFrameInput input) async {
    final sw = Stopwatch()..start();
    final scene = input.scene;
    await _setupPost();
    await viewer.setViewport(input.width, input.height);
    await _applyLook(input.theme, scene.roadType);
    final look = _look!;
    final t = scene.monotonicTimeNanos / 1e9;
    final dt = _lastTime == null ? 0.0 : (t - _lastTime!).clamp(0.0, 0.5);
    _lastTime = t;

    // World (rebuilt every frame: it is ego-relative and scrolls).
    final world = RoadWorldGlb.build(
      scene,
      look,
      layers: input.layers.copyWithPath(false),
    );
    final newWorld = await _load(world.glb);
    final oldWorld = _world;
    _world = newWorld;
    if (oldWorld != null) {
      await viewer.destroyAsset(oldWorld);
    }

    var ribbonTris = 0;
    final oldRibbon = _ribbon;
    _ribbon = null;
    if (input.layers.path) {
      final ribbon = RoadWorldGlb.build(
        scene,
        look,
        layers: const SceneLayers(lanes: false, objects: false, scenery: false),
        path: input.director.path,
        ribbonOnly: true,
      );
      ribbonTris = ribbon.triangles;
      if (ribbon.triangles > 0) {
        _ribbon = await _load(ribbon.glb, shadows: false);
      }
    }
    if (oldRibbon != null) {
      await viewer.destroyAsset(oldRibbon);
    }

    // Ego.
    final egoKey = input.egoPackKey ?? 'builtin-suv';
    if (_egoKey != egoKey || _ego == null) {
      if (_ego != null) {
        await viewer.destroyAsset(_ego!.asset);
        if (_ego!.mirror != null) {
          await viewer.destroyAsset(_ego!.mirror!);
        }
      }
      final layout = input.egoPackGlb == null
          ? GpuVehicleLibrary.of(GpuBody.suv)
          : null;
      _ego = await _newSlot('ego', input.egoPackGlb ?? layout!.glb, layout);
      _egoKey = egoKey;
      if (input.egoPackGlb case final glb?) {
        final fit = GlbBounds.vehicle(
          glb,
          body: input.egoBodyNode,
          exclude: input.egoExcludeNodes,
        );
        _egoFit = fit?.bounds;
        for (final prop in fit?.props ?? const <String>{}) {
          for (final target in [_ego!.asset, ?_ego!.mirror]) {
            final e = await target.getChildEntity(prop);
            if (e != null) {
              await target.setTransform(
                Matrix4.translation(Vector3(0, -1000, 0)),
                entity: e,
              );
            }
          }
        }
      } else {
        _egoFit = null;
      }
    }
    final ego = _ego!;
    final dims = input.vehicle.dimensions;
    final egoLayout = ego.layout;
    var egoScale = (1.0, 1.0, 1.0);
    var egoRear = 0.0, egoX = 0.0, egoY = 0.0;
    if (egoLayout != null) {
      egoScale = (
        dims.length / egoLayout.length,
        dims.width / egoLayout.width,
        dims.height / egoLayout.height,
      );
      egoRear = egoLayout.rearX;
    } else {
      // Imported pack: fit its rendered bounds (node transforms applied)
      // to the manifest length, centered, wheels on the ground.
      final box = _egoFit;
      if (box != null) {
        final k = dims.length / math.max(1e-6, box.size.z);
        egoScale = (k, k, k);
        egoRear = box.min.z;
        egoX = box.center.x;
        egoY = box.min.y;
      }
    }
    final steer = (scene.steeringAngleDegrees / 15.5 * math.pi / 180).clamp(
      -0.6,
      0.6,
    );
    final wheelRadius = 0.36;
    if (input.viewpoint == SceneViewpoint.driver) {
      await _hide(ego);
    } else {
      ego.visible = true;
      await _place(
        ego,
        rearX: -dims.length,
        leftY: 0,
        yaw: 0,
        sx: egoScale.$1,
        sy: egoScale.$2,
        sz: egoScale.$3,
        layoutRearX: egoRear,
        layoutX: egoX,
        layoutY: egoY,
        steer: steer,
        spinDelta: scene.speedMps * dt / wheelRadius,
      );
    }
    await ego.setPaint(input.vehicle.appearance.paintArgb);
    final blink = (scene.monotonicTimeNanos ~/ 500000000).isEven;
    await ego.setLamp(
      MeshRole.tail,
      GpuMaterials.lampStrength(MeshRole.tail, on: look.headlights),
    );
    await ego.setLamp(
      MeshRole.brake,
      GpuMaterials.lampStrength(MeshRole.brake, on: scene.brakeActive),
    );
    await ego.setLamp(
      MeshRole.turnLeft,
      GpuMaterials.lampStrength(
        MeshRole.turnLeft,
        on: scene.leftBlinker && blink,
      ),
    );
    await ego.setLamp(
      MeshRole.turnRight,
      GpuMaterials.lampStrength(
        MeshRole.turnRight,
        on: scene.rightBlinker && blink,
      ),
    );
    await ego.setLamp(
      MeshRole.headlight,
      GpuMaterials.lampStrength(MeshRole.headlight, on: look.headlights),
    );
    await ego.setLamp(
      MeshRole.reverse,
      GpuMaterials.lampStrength(
        MeshRole.reverse,
        on: scene.gear == VehicleGear.reverse,
      ),
    );

    // Other road users.
    final used = <String, int>{};
    final lead = scene.leadObject;
    var shown = 0;
    final oncomingHeadlights = <(double, double)>[];
    for (final o in scene.objects) {
      if (!input.layers.objects) break;
      if (o.distanceMeters < -40 || o.distanceMeters > 200) continue;
      // Like the software view: vehicles well behind the ego would fill
      // the chase camera's near field.
      if (input.viewpoint != SceneViewpoint.topDown && o.distanceMeters < -6) {
        continue;
      }
      final body = switch (o.kind) {
        TrackedObjectKind.unknown => null,
        _ => GpuVehicleLibrary.bodyFor(o),
      };
      if (body == null) continue;
      final layout = GpuVehicleLibrary.of(body);
      final key = body.name;
      final pool = _pools.putIfAbsent(key, () => []);
      final index = used[key] = (used[key] ?? -1) + 1;
      if (index >= pool.length) {
        pool.add(await _newSlot(key, layout.glb, layout));
      }
      final slot = pool[index];
      final length = o.lengthMeters ?? layout.length;
      final yaw = _laneYaw(scene, o.distanceMeters + length / 2);
      final oncoming =
          o.relativeSpeedMps < -scene.speedMps - 1 &&
          body != GpuBody.pedestrian &&
          body != GpuBody.cone;
      final speed = (scene.speedMps + o.relativeSpeedMps).abs();
      await _place(
        slot,
        rearX: oncoming ? o.distanceMeters + length : o.distanceMeters,
        leftY: o.leftMeters,
        yaw: oncoming ? yaw + math.pi : yaw,
        sx: length / layout.length,
        sy: (o.widthMeters ?? layout.width) / layout.width,
        sz: (o.heightMeters ?? layout.height) / layout.height,
        layoutRearX: layout.rearX,
        spinDelta: speed * dt / (body == GpuBody.cyclist ? 0.34 : 0.36),
      );
      if (body == GpuBody.suv ||
          body == GpuBody.sedan ||
          body == GpuBody.truck) {
        await slot.setPaint(_paintFor(o, identical(o, lead), look));
        await slot.setLamp(
          MeshRole.tail,
          GpuMaterials.lampStrength(MeshRole.tail, on: look.headlights),
        );
        await slot.setLamp(
          MeshRole.brake,
          GpuMaterials.lampStrength(MeshRole.brake, on: o.brakeLights),
        );
        await slot.setLamp(
          MeshRole.headlight,
          GpuMaterials.lampStrength(MeshRole.headlight, on: look.headlights),
        );
        if (oncoming && look.headlights) {
          oncomingHeadlights.add((o.distanceMeters, o.leftMeters));
        }
      } else if (body == GpuBody.cyclist) {
        await slot.setLamp(
          MeshRole.tail,
          GpuMaterials.lampStrength(MeshRole.tail, on: true),
        );
      }
      shown++;
    }
    for (final entry in _pools.entries) {
      final n = (used[entry.key] ?? -1) + 1;
      for (var i = n; i < entry.value.length; i++) {
        await _hide(entry.value[i]);
      }
    }

    // Lights: ego headlights, tail glow, street lamps, oncoming beams.
    final lights = <DirectLight>[];
    final egoRearX = -dims.length;
    if (look.headlights) {
      for (final side in const [1.0, -1.0]) {
        final pos = toFilament(-0.15, side * dims.width * 0.36, 0.72);
        final aim = toFilament(28, side * 0.6 - steer * 6, -0.05);
        final dir = Vector3(aim[0] - pos[0], aim[1] - pos[1], aim[2] - pos[2])
          ..normalize();
        lights.add(
          DirectLight(
            type: LightType.FOCUSED_SPOT,
            color: const LinearColor(1.0, 0.96, 0.90),
            intensity: look.headlightLumens,
            position: Vector3(pos[0], pos[1], pos[2]),
            direction: dir,
            falloffRadius: 90,
            spotLightConeInner: 0.18,
            spotLightConeOuter: 0.62,
            castShadows: false,
          ),
        );
      }
      _tailGlow(
        lights,
        look,
        egoRearX,
        dims.width,
        scene.brakeActive ? (look.night ? 0.9 : 0.6) : 0.22,
      );
    } else if (scene.brakeActive) {
      _tailGlow(lights, look, egoRearX, dims.width, 0.4);
    }
    if (look.streetLights) {
      final lamps = [...world.lamps]
        ..sort((a, b) => (a.x - 10).abs().compareTo((b.x - 10).abs()));
      for (final lamp in lamps.take(_maxLampLights)) {
        final pos = toFilament(lamp.x, lamp.y, lamp.z);
        lights.add(
          DirectLight(
            type: LightType.FOCUSED_SPOT,
            color: const LinearColor(1.0, 0.80, 0.55),
            intensity: look.lampLumens,
            position: Vector3(pos[0], pos[1], pos[2]),
            direction: Vector3(0, -1, 0),
            falloffRadius: 26,
            spotLightConeInner: 0.6,
            spotLightConeOuter: 1.15,
          ),
        );
      }
    }
    for (final (x, y) in oncomingHeadlights.take(2)) {
      final pos = toFilament(x, y, 0.7);
      final aim = toFilament(x - 25, y, 0);
      lights.add(
        DirectLight(
          type: LightType.FOCUSED_SPOT,
          color: const LinearColor(1.0, 0.96, 0.90),
          intensity: look.headlightLumens,
          position: Vector3(pos[0], pos[1], pos[2]),
          direction: Vector3(aim[0] - pos[0], aim[1] - pos[1], aim[2] - pos[2])
            ..normalize(),
          falloffRadius: 60,
          spotLightConeInner: 0.2,
          spotLightConeOuter: 0.6,
        ),
      );
    }
    await _syncLights(lights);

    await _setCamera(input);
    return GpuFrameStats(
      worldTriangles: world.triangles + ribbonTris,
      vehicles: shown + 1,
      lights: lights.length + 1,
      buildMs: sw.elapsedMilliseconds,
    );
  }

  /// Red light the tail/brake lamps throw on the road behind the ego: a
  /// spot aimed backward and down from each lamp, so it lights the road
  /// and not the car's own tailgate. [level] = on-screen road brightness.
  void _tailGlow(
    List<DirectLight> lights,
    SceneLook look,
    double rearX,
    double width,
    double level,
  ) {
    for (final side in const [1.0, -1.0]) {
      final pos = toFilament(rearX - 0.08, side * width * 0.36, 0.85);
      final aim = toFilament(rearX - 3.2, side * width * 0.45, 0);
      lights.add(
        DirectLight(
          type: LightType.FOCUSED_SPOT,
          color: const LinearColor(1.0, 0.04, 0.05),
          intensity: level / look.exposure * 110,
          position: Vector3(pos[0], pos[1], pos[2]),
          direction: Vector3(aim[0] - pos[0], aim[1] - pos[1], aim[2] - pos[2])
            ..normalize(),
          falloffRadius: 7,
          spotLightConeInner: 0.35,
          spotLightConeOuter: 1.0,
        ),
      );
    }
  }

  Future<void> _syncLights(List<DirectLight> lights) async {
    // Simple and robust: recreate punctual lights each frame (few lights).
    for (final e in [..._spots, ..._points]) {
      await viewer.removeLight(e);
    }
    _spots.clear();
    _points.clear();
    for (final l in lights) {
      final e = await viewer.addDirectLight(l);
      (l.type == LightType.POINT ? _points : _spots).add(e);
    }
  }

  Future<void> _setCamera(GpuFrameInput input) async {
    final cam = await viewer.getActiveCamera();
    final camera = input.director.camera;
    final aspect = input.width / input.height;
    if (camera is PerspectiveCamera) {
      final fov = camera.verticalFov(camera.center.dy * 2) * 180 / math.pi;
      await cam.setProjectionFromVerticalFieldOfView(
        fov,
        camera.nearDepth * 0.6,
        1200,
        aspect,
      );
      final p = camera.pitchRadians;
      final e = camera.eye;
      final eye = toFilament(e.x, e.y, e.z);
      final fwd = toFilament(math.cos(p), 0, -math.sin(p));
      final up0 = toFilament(math.sin(p), 0, math.cos(p));
      final left = toFilament(0, 1, 0);
      final r = input.director.rollRadians;
      final up = [
        for (var i = 0; i < 3; i++)
          up0[i] * math.cos(r) + left[i] * math.sin(r),
      ];
      await cam.lookAt(
        Vector3(eye[0], eye[1], eye[2]),
        focus: Vector3(
          eye[0] + fwd[0] * 10,
          eye[1] + fwd[1] * 10,
          eye[2] + fwd[2] * 10,
        ),
        up: Vector3(up[0], up[1], up[2]),
      );
    } else {
      // Top-down: orthographic-like high perspective looking straight down.
      await cam.setProjectionFromVerticalFieldOfView(24, 1, 1200, aspect);
      await cam.lookAt(
        Vector3(0, 150, -12),
        focus: Vector3(0, 0, -12),
        up: Vector3(0, 0, -1),
      );
    }
  }

  static int _paintFor(TrackedObject o, bool lead, SceneLook look) {
    if (lead) return 0xFF4F6FE8;
    const colors = [
      0xFFF2F3F5,
      0xFFE6E8EA,
      0xFFB9BEC4,
      0xFF6B7178,
      0xFF23262A,
      0xFF2D3E5C,
      0xFFF2F3F5,
      0xFF8C2A2E,
    ];
    final id = o.id ?? (o.distanceMeters * 10).round();
    var h = (id * 0x27d4eb2d) & 0x7fffffff;
    h = (h ^ (h >> 15)) * 0x2c1b3c6d & 0x7fffffff;
    return colors[h % colors.length];
  }

  static double _laneYaw(RoadScene scene, double x) {
    if (scene.plannedPath.length < 2) return 0;
    final last = scene.plannedPath.last.forwardMeters;
    final a = math.min(x - 2, last - 4);
    final slope = (scene.pathLeftAt(a + 4) - scene.pathLeftAt(a)) / 4;
    return math.atan(slope).clamp(-0.6, 0.6);
  }

  Future<void> dispose() async {
    for (final e in [..._spots, ..._points]) {
      await viewer.removeLight(e);
    }
    if (_sun != null) {
      await viewer.removeLight(_sun!);
    }
    await viewer.destroyAssets();
    _pools.clear();
    _ego = null;
    _world = null;
    _ribbon = null;
  }
}

extension on SceneLayers {
  SceneLayers copyWithPath(bool path) =>
      SceneLayers(lanes: lanes, objects: objects, path: path, scenery: scenery);
}
