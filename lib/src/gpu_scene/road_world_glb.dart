import 'dart:math' as math;
import 'dart:typed_data';

import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart'
    show RoadGeometry, RoadWorldPainter, SceneLayers;
import 'package:kovalink/src/gpu_scene/gltf_scene_builder.dart';
import 'package:kovalink/src/gpu_scene/scene_look.dart';
import 'package:kovalink/src/models/road_scene.dart';

/// Scene frame (x forward, y left, z up) → glTF/Filament frame
/// (X right, Y up, camera looking along −Z = forward).
List<double> toFilament(double x, double y, double z) => [-y, z, -x];

/// A street lamp head in the scene frame, for the renderer's lights.
class StreetLamp {
  const StreetLamp(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;
}

/// Display styling of the planned-path ribbon for one frame (the scene
/// director animates these).
class PathStyle {
  const PathStyle({
    this.leadTone = 0,
    this.sweep = -1,
    this.intensity = 1,
    this.engaged = true,
  });

  /// 0 = far/safe lead (blue), 1 = close (amber → red).
  final double leadTone;

  /// Position (0..1 along the ribbon) of the engage light sweep; <0 off.
  final double sweep;
  final double intensity;
  final bool engaged;
}

/// Result of [RoadWorldGlb.build]: GLB bytes plus lamp positions.
class RoadWorldMesh {
  const RoadWorldMesh(this.glb, this.lamps, this.triangles);

  final Uint8List glb;
  final List<StreetLamp> lamps;
  final int triangles;
}

/// Builds the static-looking road world for one [RoadScene] frame as a GLB
/// for the GPU renderer: asphalt with tire tracks and seams, lane paint,
/// red edge bands, shoulders, guardrails or curbs, grass, trees, city
/// blocks with windows, street lamps and the glowing path ribbon. All
/// geometry is generated here (CC0, KovaLink project).
///
/// Dashes, seams and scenery scroll with `odometerMeters`, exactly like the
/// software renderer, so both paths show the same road.
class RoadWorldGlb {
  const RoadWorldGlb._();

  static const startX = -40.0;
  static const endX = 230.0;

  static RoadWorldMesh build(
    RoadScene scene,
    SceneLook look, {
    SceneLayers layers = const SceneLayers(),
    PathStyle path = const PathStyle(),
    bool ribbonOnly = false,
  }) {
    final b = _WorldBuilder(scene, look, layers, path);
    if (ribbonOnly) {
      b._pathRibbon();
    } else {
      b.run();
    }
    return RoadWorldMesh(
      b.out.toGlb(generator: 'KovaLink road world'),
      b.lamps,
      b.triangles,
    );
  }
}

class _WorldBuilder {
  _WorldBuilder(this.scene, this.look, this.layers, this.path)
    : road = RoadGeometry.fromScene(scene),
      city = scene.roadType == RoadType.city;

  final RoadScene scene;
  final SceneLook look;
  final SceneLayers layers;
  final PathStyle path;
  final RoadGeometry road;
  final bool city;
  final out = GltfSceneBuilder();
  final lamps = <StreetLamp>[];
  int triangles = 0;

  double get odo => scene.odometerMeters;
  double get wet => look.wetness;

  late final List<double> xs = () {
    final list = <double>[];
    for (
      var x = RoadWorldGlb.startX;
      x < RoadWorldGlb.endX;
      x += 1.0 + math.max(0, x) * 0.03
    ) {
      list.add(x);
    }
    list.add(RoadWorldGlb.endX);
    return list;
  }();

  int _mat(
    String name,
    List<double> rgb, {
    double metallic = 0,
    double roughness = 0.8,
    double alpha = 1,
    bool blend = false,
    List<double>? emissive,
    double emissiveStrength = 1,
    bool unlit = false,
    bool clearcoat = false,
    bool doubleSided = false,
  }) {
    return out.material({
      'name': name,
      if (blend) 'alphaMode': 'BLEND',
      if (doubleSided) 'doubleSided': true,
      'pbrMetallicRoughness': {
        'baseColorFactor': [...rgb, alpha],
        'metallicFactor': metallic,
        'roughnessFactor': roughness,
      },
      'emissiveFactor': ?emissive,
      if (unlit || clearcoat || (emissive != null && emissiveStrength != 1))
        'extensions': {
          if (unlit) 'KHR_materials_unlit': <String, Object>{},
          if (clearcoat)
            'KHR_materials_clearcoat': {
              'clearcoatFactor': 1.0,
              'clearcoatRoughnessFactor': 0.05,
            },
          if (emissive != null && emissiveStrength != 1)
            'KHR_materials_emissive_strength': {
              'emissiveStrength': emissiveStrength,
            },
        },
    });
  }

  void _emit(String name, PrimitiveBuffer buffer, int material) {
    if (buffer.isEmpty) return;
    triangles += buffer.indices.length ~/ 3;
    final mesh = out.mesh(name, [buffer.build(material)]);
    out.node(name, mesh: mesh);
  }

  void run() {
    _ground();
    _roadSurface();
    if (layers.lanes) _lanes();
    _edges();
    if (layers.scenery) {
      if (city) {
        _cityBlocks();
      } else {
        _trees();
      }
      _streetLamps();
    }
    if (layers.path) _pathRibbon();
  }

  // ------------------------------------------------------------ helpers

  static double _hash(int n) {
    var h = (n * 0x27d4eb2d) & 0x7fffffff;
    h = (h ^ (h >> 15)) * 0x2c1b3c6d & 0x7fffffff;
    h = (h ^ (h >> 12)) * 0x297a2d39 & 0x7fffffff;
    h ^= h >> 15;
    return (h & 0xffff) / 0x10000;
  }

  /// Smooth value noise on a world-fixed grid (scrolls with the odometer).
  static double _noise(double u, double v) {
    final i = u.floor(), j = v.floor();
    final fu = u - i, fv = v - j;
    double h(int a, int b) => _hash(a * 7919 + b * 104729 + 17);
    double s(double t) => t * t * (3 - 2 * t);
    final a = h(i, j), b2 = h(i + 1, j), c = h(i, j + 1), d = h(i + 1, j + 1);
    final x1 = a + (b2 - a) * s(fu), x2 = c + (d - c) * s(fu);
    return x1 + (x2 - x1) * s(fv);
  }

  /// Strip between two lateral functions along [samples] at height z, with
  /// optional per-vertex color, subdivided laterally every [cell] meters.
  void _strip(
    PrimitiveBuffer buf,
    List<double> samples,
    double Function(double) left,
    double Function(double) right,
    double z, {
    double cell = 0,
    List<double> Function(double x, double y)? color,
  }) {
    final cols = cell <= 0
        ? 1
        : math.max(1, ((left(0) - right(0)).abs() / cell).ceil());
    final rows = <List<int>>[];
    for (final x in samples) {
      final l = left(x), r = right(x);
      final row = <int>[];
      for (var c = 0; c <= cols; c++) {
        final y = l + (r - l) * c / cols;
        final p = toFilament(x, y, z);
        row.add(buf.vertex(p[0], p[1], p[2], 0, 1, 0, color?.call(x, y)));
      }
      rows.add(row);
    }
    for (var i = 0; i < rows.length - 1; i++) {
      for (var c = 0; c < cols; c++) {
        final a = rows[i][c],
            b = rows[i][c + 1],
            cc = rows[i + 1][c],
            d = rows[i + 1][c + 1];
        _orientUp(buf, a, cc, b);
        _orientUp(buf, b, cc, d);
      }
    }
  }

  void _quadUp(
    PrimitiveBuffer buf,
    List<List<double>> p, [
    List<double>? rgba,
  ]) {
    final a = buf.vertex(p[0][0], p[0][1], p[0][2], 0, 1, 0, rgba);
    final b = buf.vertex(p[1][0], p[1][1], p[1][2], 0, 1, 0, rgba);
    final c = buf.vertex(p[2][0], p[2][1], p[2][2], 0, 1, 0, rgba);
    final d = buf.vertex(p[3][0], p[3][1], p[3][2], 0, 1, 0, rgba);
    _orientUp(buf, a, b, c);
    _orientUp(buf, a, c, d);
  }

  /// Adds triangle a-b-c wound so its normal points +Y.
  void _orientUp(PrimitiveBuffer buf, int a, int b, int c) {
    final p = buf.positions;
    final ux = p[b * 3] - p[a * 3], uz = p[b * 3 + 2] - p[a * 3 + 2];
    final vx = p[c * 3] - p[a * 3], vz = p[c * 3 + 2] - p[a * 3 + 2];
    final ny = uz * vx - ux * vz;
    if (ny >= 0) {
      buf.tri(a, b, c);
    } else {
      buf.tri(a, c, b);
    }
  }

  /// Adds triangle a-b-c wound so its normal agrees with [n] (Filament).
  void _facing(PrimitiveBuffer buf, int a, int b, int c, List<double> n) {
    final p = buf.positions;
    final ux = p[b * 3] - p[a * 3],
        uy = p[b * 3 + 1] - p[a * 3 + 1],
        uz = p[b * 3 + 2] - p[a * 3 + 2];
    final vx = p[c * 3] - p[a * 3],
        vy = p[c * 3 + 1] - p[a * 3 + 1],
        vz = p[c * 3 + 2] - p[a * 3 + 2];
    final cx = uy * vz - uz * vy,
        cy = uz * vx - ux * vz,
        cz = ux * vy - uy * vx;
    if (cx * n[0] + cy * n[1] + cz * n[2] >= 0) {
      buf.tri(a, b, c);
    } else {
      buf.tri(a, c, b);
    }
  }

  /// Quad (scene-frame corners in order around it) facing scene normal.
  void _quad(
    PrimitiveBuffer buf,
    List<List<double>> scenePts,
    List<double> sceneNormal,
  ) {
    final n = toFilament(sceneNormal[0], sceneNormal[1], sceneNormal[2]);
    final ids = [
      for (final q in scenePts)
        () {
          final f = toFilament(q[0], q[1], q[2]);
          return buf.vertex(f[0], f[1], f[2], n[0], n[1], n[2]);
        }(),
    ];
    _facing(buf, ids[0], ids[1], ids[2], n);
    _facing(buf, ids[0], ids[2], ids[3], n);
  }

  /// Box in the scene frame from [min] to [max] (x, y, z), flat normals.
  void _box(
    PrimitiveBuffer buf,
    List<double> min,
    List<double> max, {
    List<double>? rgba,
    bool bottom = false,
    double yaw = 0,
    List<double>? pivot,
  }) {
    final faces = <(List<int>, List<double>)>[
      ([0, 2, 6, 4], [-1, 0, 0]),
      ([1, 5, 7, 3], [1, 0, 0]),
      ([0, 4, 5, 1], [0, -1, 0]),
      ([2, 3, 7, 6], [0, 1, 0]),
      ([4, 6, 7, 5], [0, 0, 1]),
      if (bottom) ([0, 1, 3, 2], [0, 0, -1]),
    ];
    final cy = math.cos(yaw), sy = math.sin(yaw);
    final px = pivot?[0] ?? 0, py = pivot?[1] ?? 0;
    List<double> corner(int i) {
      var x = i & 1 == 0 ? min[0] : max[0];
      var y = i & 2 == 0 ? min[1] : max[1];
      final z = i & 4 == 0 ? min[2] : max[2];
      if (yaw != 0) {
        final dx = x - px, dy = y - py;
        x = px + dx * cy - dy * sy;
        y = py + dx * sy + dy * cy;
      }
      return [x, y, z];
    }

    for (final (ids, n) in faces) {
      final nx = n[0] * cy - n[1] * sy, ny = n[0] * sy + n[1] * cy;
      final fn = toFilament(nx, ny, n[2].toDouble());
      final v = [
        for (final i in ids)
          () {
            final c = corner(i);
            final f = toFilament(c[0], c[1], c[2]);
            return buf.vertex(f[0], f[1], f[2], fn[0], fn[1], fn[2], rgba);
          }(),
      ];
      _facing(buf, v[0], v[1], v[2], fn);
      _facing(buf, v[0], v[2], v[3], fn);
    }
  }

  // ------------------------------------------------------------ ground

  void _ground() {
    final grass = city
        ? GltfSceneBuilder.linear(0xFF9A9FA3)
        : GltfSceneBuilder.linear(0xFF7F9A5C);
    final mat = _mat('KL_Ground', grass, roughness: city ? 0.85 : 0.95);
    final buf = PrimitiveBuffer(withColors: true);
    // Two wide strips outside the shoulders, coarse grid with patchy color.
    final samples = [
      for (
        var x = RoadWorldGlb.startX;
        x <= RoadWorldGlb.endX + 300;
        x += x < 60 ? 4 : 20
      )
        x,
    ];
    List<double> tint(double x, double y) {
      final n =
          _noise((x + odo) / 9, y / 7) * 0.6 +
          _noise((x + odo) / 31, y / 23) * 0.4;
      final k = 0.78 + n * 0.38;
      return city ? [k, k, k, 1] : [k * 1.02, k, k * 0.92, 1];
    }

    _strip(
      buf,
      samples,
      (x) => road.leftEdge(x) + 2.9 + 260,
      (x) => road.leftEdge(x) + 2.9,
      -0.02,
      cell: 5,
      color: tint,
    );
    _strip(
      buf,
      samples,
      (x) => road.rightEdge(x) - 2.9,
      (x) => road.rightEdge(x) - 2.9 - 260,
      -0.02,
      cell: 5,
      color: tint,
    );
    _emit('Ground', buf, mat);
  }

  // ------------------------------------------------------------ road

  void _roadSurface() {
    // Wet roads are darker and glossy; the renderer mirrors vehicles below
    // a semi-transparent wet surface for puddle reflections.
    final base = GltfSceneBuilder.linear(city ? 0xFF55595E : 0xFF45494E);
    final dark = [for (final c in base) c * (1 - 0.45 * wet)];
    final rough = 0.82 - 0.7 * wet;
    final mat = _mat(
      'KL_Asphalt',
      dark,
      roughness: rough,
      alpha: wet > 0.5 ? 0.92 : 1,
      blend: wet > 0.5,
      clearcoat: wet > 0.5,
    );
    final buf = PrimitiveBuffer(withColors: true);
    final lanes = [
      for (final line in scene.laneLines)
        if (line.points.length >= 2) line.points,
    ];
    List<double> tint(double x, double y) {
      var k =
          0.86 +
          0.22 * _noise((x + odo) / 3.5, y / 2.5) +
          0.08 * _noise((x + odo) / 0.9, y / 0.9);
      // Tire tracks: darker polished bands ±0.85 m from each lane center.
      for (var i = 0; i < lanes.length - 1; i++) {
        final a = RoadScene.interpolateLeft(lanes[i], x);
        final c = (a + RoadScene.interpolateLeft(lanes[i + 1], x)) / 2;
        for (final track in const [-0.85, 0.85]) {
          final d = (y - (c + track)).abs();
          if (d < 0.45) k *= 1 - 0.13 * (1 - d / 0.45);
        }
      }
      return [k, k, k * 1.01, 1];
    }

    _strip(buf, xs, road.leftEdge, road.rightEdge, 0, cell: 0.6, color: tint);
    _emit('Asphalt', buf, mat);

    // Transverse seams every 12 m.
    final seamMat = _mat('KL_Seam', [
      for (final c in GltfSceneBuilder.linear(0xFF2E3236)) c * (1 - 0.3 * wet),
    ], roughness: 0.9 - 0.6 * wet);
    final seams = PrimitiveBuffer();
    final phase = odo % 12;
    for (var x = -phase - 12; x < RoadWorldGlb.endX; x += 12) {
      if (x < RoadWorldGlb.startX) continue;
      _quadUp(seams, [
        toFilament(x, road.leftEdge(x), 0.004),
        toFilament(x, road.rightEdge(x), 0.004),
        toFilament(x + 0.12, road.rightEdge(x + 0.12), 0.004),
        toFilament(x + 0.12, road.leftEdge(x + 0.12), 0.004),
      ]);
    }
    _emit('Seams', seams, seamMat);
  }

  void _lanes() {
    final white = _mat(
      'KL_LaneWhite',
      GltfSceneBuilder.linear(0xFFEDEFF1),
      roughness: 0.55 - 0.35 * wet,
      emissive: look.night ? const [0.03, 0.03, 0.03] : null,
    );
    final yellow = _mat(
      'KL_LaneYellow',
      GltfSceneBuilder.linear(0xFFE0A417),
      roughness: 0.55 - 0.35 * wet,
      emissive: look.night ? const [0.03, 0.02, 0.0] : null,
    );
    final blue = _mat(
      'KL_LaneBlue',
      GltfSceneBuilder.linear(0xFF3E7BE0),
      roughness: 0.55,
    );
    final bufs = {
      white: PrimitiveBuffer(),
      yellow: PrimitiveBuffer(),
      blue: PrimitiveBuffer(),
    };
    // Lines easing in or out (display fade) go to blended copies of the
    // lane materials with the fade in the vertex alpha.
    final fadeMats = <int, int>{};
    final fadeBufs = <int, PrimitiveBuffer>{};
    int fadeMat(int base) => fadeMats.putIfAbsent(base, () {
      final rgb = base == yellow
          ? GltfSceneBuilder.linear(0xFFE0A417)
          : base == blue
          ? GltfSceneBuilder.linear(0xFF3E7BE0)
          : GltfSceneBuilder.linear(0xFFEDEFF1);
      return _mat(
        'KL_LaneFade$base',
        rgb,
        roughness: 0.55 - 0.35 * wet,
        blend: true,
      );
    });
    const half = RoadWorldPainter.laneHalfWidth;
    for (final line in scene.laneLines) {
      if (line.points.length < 2) continue;
      final fade = line.fade.clamp(0.0, 1.0);
      if (fade <= 0.01) continue;
      final base = switch (line.color) {
        LaneLineColor.yellow => yellow,
        LaneLineColor.blue => blue,
        _ => white,
      };
      final fading = fade < 0.99;
      final mat = fading ? fadeMat(base) : base;
      final buf = fading
          ? fadeBufs.putIfAbsent(mat, () => PrimitiveBuffer(withColors: true))
          : bufs[base]!;
      final rgba = fading ? [1.0, 1.0, 1.0, fade] : null;
      double at(double x) => RoadScene.interpolateLeft(line.points, x);
      // No straight extension past the last model point (it shoots off
      // the road in curves).
      final lx = xs.where((x) => x <= line.points.last.forwardMeters).toList();
      if (lx.length < 2) continue;
      void ribbon(List<double> s, double offset, double h) {
        if (s.length < 2) return;
        _ribbonStrip(buf, s, (x) => at(x) + offset, h, 0.008, rgba);
      }

      switch (line.style) {
        case LaneLineStyle.dashed:
          final phase = odo % RoadWorldPainter.dashPeriod;
          for (
            var s = lx.first - phase;
            s < lx.last;
            s += RoadWorldPainter.dashPeriod
          ) {
            final a = math.max(s, lx.first),
                e = math.min(s + RoadWorldPainter.dashLength, lx.last);
            if (e <= a) continue;
            ribbon([a, (a + e) / 2, e], 0, half);
          }
        case LaneLineStyle.doubleSolid:
          ribbon(lx, 0.12, half * 0.8);
          ribbon(lx, -0.12, half * 0.8);
        case LaneLineStyle.solid || LaneLineStyle.unknown:
          ribbon(lx, 0, half);
      }
    }
    for (final e in bufs.entries) {
      _emit('Lane_${e.key}', e.value, e.key);
    }
    for (final e in fadeBufs.entries) {
      _emit('LaneFade_${e.key}', e.value, e.key);
    }
  }

  /// Ribbon of half width [half] around [center], offset across the line's
  /// own direction so it keeps its width through curves.
  void _ribbonStrip(
    PrimitiveBuffer buf,
    List<double> samples,
    double Function(double) center,
    double half,
    double z,
    List<double>? rgba,
  ) {
    final rows = <List<int>>[];
    for (final x in samples) {
      final (lx, ly) = RoadWorldPainter.normalOffset(center, x, half);
      final (rx, ry) = RoadWorldPainter.normalOffset(center, x, -half);
      final l = toFilament(lx, ly, z), r = toFilament(rx, ry, z);
      rows.add([
        buf.vertex(l[0], l[1], l[2], 0, 1, 0, rgba),
        buf.vertex(r[0], r[1], r[2], 0, 1, 0, rgba),
      ]);
    }
    for (var i = 0; i < rows.length - 1; i++) {
      _orientUp(buf, rows[i][0], rows[i + 1][0], rows[i][1]);
      _orientUp(buf, rows[i][1], rows[i + 1][0], rows[i + 1][1]);
    }
  }

  void _edges() {
    final red = _mat(
      'KL_EdgeBand',
      GltfSceneBuilder.linear(0xFFC4706C),
      roughness: 0.7 - 0.4 * wet,
    );
    final redBuf = PrimitiveBuffer();
    _strip(redBuf, xs, road.leftEdge, (x) => road.leftEdge(x) - 0.32, 0.006);
    _strip(redBuf, xs, (x) => road.rightEdge(x) + 0.32, road.rightEdge, 0.006);
    _emit('EdgeBands', redBuf, red);

    final shoulderMat = _mat(
      'KL_Shoulder',
      GltfSceneBuilder.linear(city ? 0xFFBFC2C4 : 0xFFB9BBB8),
      roughness: 0.85 - 0.45 * wet,
    );
    final sh = PrimitiveBuffer(withColors: true);
    List<double> tint(double x, double y) {
      final k = 0.9 + 0.16 * _noise((x + odo) / 2.2, y / 1.7);
      return [k, k, k, 1];
    }

    final z = city ? 0.15 : 0.0;
    _strip(
      sh,
      xs,
      (x) => road.leftEdge(x) + 2.9,
      road.leftEdge,
      z,
      cell: 1.0,
      color: tint,
    );
    _strip(
      sh,
      xs,
      road.rightEdge,
      (x) => road.rightEdge(x) - 2.9,
      z,
      cell: 1.0,
      color: tint,
    );
    _emit('Shoulders', sh, shoulderMat);

    if (city) {
      // Curb faces.
      final curbMat = _mat(
        'KL_Curb',
        GltfSceneBuilder.linear(0xFFD5D7D8),
        roughness: 0.7,
      );
      final curb = PrimitiveBuffer();
      for (final side in const [1, -1]) {
        for (var i = 0; i < xs.length - 1; i++) {
          final x0 = xs[i], x1 = xs[i + 1];
          final e0 = side > 0 ? road.leftEdge(x0) : road.rightEdge(x0);
          final e1 = side > 0 ? road.leftEdge(x1) : road.rightEdge(x1);
          _quad(
            curb,
            [
              [x0, e0, 0],
              [x1, e1, 0],
              [x1, e1, 0.15],
              [x0, e0, 0.15],
            ],
            [0, -side.toDouble(), 0],
          );
        }
      }
      _emit('Curbs', curb, curbMat);
    } else {
      _guardrails();
    }
  }

  void _guardrails() {
    final railMat = _mat(
      'KL_Guardrail',
      GltfSceneBuilder.linear(0xFFC9CED3),
      metallic: 0.85,
      roughness: 0.32 - 0.12 * wet,
    );
    final postMat = _mat(
      'KL_GuardPost',
      GltfSceneBuilder.linear(0xFF8D9399),
      metallic: 0.6,
      roughness: 0.5,
    );
    final rail = PrimitiveBuffer();
    final posts = PrimitiveBuffer();
    final railXs = xs.where((x) => x < 160).toList();
    for (final side in const [1, -1]) {
      double at(double x) =>
          (side > 0 ? road.leftEdge(x) : road.rightEdge(x)) + side * 2.5;
      // Two-sided W-beam approximated by an upper and lower slanted band.
      for (final (z0, z1, tilt) in const [
        (0.52, 0.66, 0.05),
        (0.66, 0.80, -0.05),
      ]) {
        for (var i = 0; i < railXs.length - 1; i++) {
          final x0 = railXs[i], x1 = railXs[i + 1];
          final ny = -side * math.cos(tilt), nz = math.sin(tilt) * side;
          _quad(
            rail,
            [
              [x0, at(x0), z0],
              [x1, at(x1), z0],
              [x1, at(x1), z1],
              [x0, at(x0), z1],
            ],
            [0, ny, nz],
          );
        }
      }
      final phase = odo % 4;
      for (var x = -phase; x < 140; x += 4) {
        if (x < RoadWorldGlb.startX) continue;
        final y = at(x) + side * 0.12;
        _box(posts, [x - 0.05, y - 0.06, 0], [x + 0.05, y + 0.06, 0.78]);
      }
    }
    _emit('Guardrails', rail, railMat);
    _emit('GuardPosts', posts, postMat);
  }

  // ------------------------------------------------------------ scenery

  void _trees() {
    final trunk = _mat(
      'KL_Trunk',
      GltfSceneBuilder.linear(0xFF6A5444),
      roughness: 0.9,
    );
    final leaf = _mat(
      'KL_Foliage',
      GltfSceneBuilder.linear(0xFF6C9A5E),
      roughness: 0.85,
    );
    final tb = PrimitiveBuffer();
    final lb = PrimitiveBuffer(withColors: true);
    const spacing = 19.0;
    for (final side in const [1, -1]) {
      final first = ((odo - 30) / spacing).floor() - 1;
      final last = ((odo + 190) / spacing).ceil();
      for (var n = first; n <= last; n++) {
        final h = _hash(n * 2 + (side > 0 ? 0 : 1));
        if (h < 0.18) continue;
        final x = n * spacing + _hash(n * 7 + side) * spacing * 0.6 - odo;
        if (x < -30 || x > 190) continue;
        final edge = side > 0 ? road.leftEdge(x) : road.rightEdge(x);
        final y = edge + side * (5.0 + _hash(n * 13 + side * 5) * 16);
        final scale = 0.8 + _hash(n * 17 + side) * 0.7;
        _tree(tb, lb, x, y, scale, n * 3 + side);
        // A second, smaller tree behind some of them for depth.
        if (_hash(n * 23 + side) > 0.45) {
          _tree(
            tb,
            lb,
            x + 6 * _hash(n * 29),
            y + side * (7 + 6 * _hash(n * 31)),
            scale * 0.85,
            n * 5 + side + 1,
          );
        }
      }
    }
    _emit('Trunks', tb, trunk);
    _emit('Foliage', lb, leaf);
  }

  void _tree(
    PrimitiveBuffer tb,
    PrimitiveBuffer lb,
    double x,
    double y,
    double s,
    int seed,
  ) {
    final trunkH = 2.3 * s;
    _cylinder(tb, x, y, 0, 0.16 * s, 0.11 * s, trunkH + 0.6 * s, 6);
    final hue = _hash(seed * 41);
    final tint = [
      0.82 + 0.3 * hue,
      0.9 + 0.18 * _hash(seed * 43),
      0.78 + 0.2 * (1 - hue),
      1.0,
    ];
    final blobs = [
      (0.0, 0.0, trunkH + 1.6 * s, 2.0 * s),
      (0.9 * s, 0.5 * s, trunkH + 1.0 * s, 1.35 * s),
      (-0.8 * s, -0.4 * s, trunkH + 1.2 * s, 1.45 * s),
      (0.2 * s, -0.6 * s, trunkH + 2.6 * s, 1.25 * s),
    ];
    for (final (dx, dy, z, r) in blobs) {
      _icosphere(lb, x + dx, y + dy, z, r, seed, tint);
    }
  }

  void _cylinder(
    PrimitiveBuffer buf,
    double x,
    double y,
    double z0,
    double r0,
    double r1,
    double h,
    int seg,
  ) {
    final ids = <int>[];
    for (var i = 0; i <= seg; i++) {
      final a = i / seg * math.pi * 2;
      final c = math.cos(a), s = math.sin(a);
      final n = toFilament(c, s, 0);
      final p0 = toFilament(x + c * r0, y + s * r0, z0);
      final p1 = toFilament(x + c * r1, y + s * r1, z0 + h);
      ids.add(buf.vertex(p0[0], p0[1], p0[2], n[0], n[1], n[2]));
      ids.add(buf.vertex(p1[0], p1[1], p1[2], n[0], n[1], n[2]));
    }
    for (var i = 0; i < seg; i++) {
      final a = ids[i * 2],
          b = ids[i * 2 + 1],
          c = ids[i * 2 + 2],
          d = ids[i * 2 + 3];
      final n = [
        buf.normals[a * 3],
        buf.normals[a * 3 + 1],
        buf.normals[a * 3 + 2],
      ];
      _facing(buf, a, c, b, n);
      _facing(buf, b, c, d, n);
    }
  }

  static final List<List<double>> _ico = () {
    final t = (1 + math.sqrt(5)) / 2;
    final v = <List<double>>[
      [-1, t, 0],
      [1, t, 0],
      [-1, -t, 0],
      [1, -t, 0],
      [0, -1, t],
      [0, 1, t],
      [0, -1, -t],
      [0, 1, -t],
      [t, 0, -1],
      [t, 0, 1],
      [-t, 0, -1],
      [-t, 0, 1],
    ];
    return [
      for (final p in v)
        () {
          final l = math.sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
          return [p[0] / l, p[1] / l, p[2] / l];
        }(),
    ];
  }();
  static const _icoFaces = [
    [0, 11, 5],
    [0, 5, 1],
    [0, 1, 7],
    [0, 7, 10],
    [0, 10, 11],
    [1, 5, 9],
    [5, 11, 4],
    [11, 10, 2],
    [10, 7, 6],
    [7, 1, 8],
    [3, 9, 4],
    [3, 4, 2],
    [3, 2, 6],
    [3, 6, 8],
    [3, 8, 9],
    [4, 9, 5],
    [2, 4, 11],
    [6, 2, 10],
    [8, 6, 7],
    [9, 8, 1],
  ];

  /// Subdivided icosahedron with jittered radius and smooth normals: a
  /// soft low-poly foliage blob (Filament frame center from scene coords).
  void _icosphere(
    PrimitiveBuffer buf,
    double x,
    double y,
    double z,
    double r,
    int seed,
    List<double> tint,
  ) {
    final c = toFilament(x, y, z);
    final verts = <List<double>>[..._ico];
    final cache = <int, int>{};
    int mid(int a, int b) {
      final key = a < b ? a * 1000 + b : b * 1000 + a;
      return cache.putIfAbsent(key, () {
        final p = [for (var i = 0; i < 3; i++) (verts[a][i] + verts[b][i]) / 2];
        final l = math.sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
        verts.add([p[0] / l, p[1] / l, p[2] / l]);
        return verts.length - 1;
      });
    }

    final faces = <List<int>>[];
    for (final f in _icoFaces) {
      final a = mid(f[0], f[1]), b = mid(f[1], f[2]), cc = mid(f[2], f[0]);
      faces
        ..add([f[0], a, cc])
        ..add([f[1], b, a])
        ..add([f[2], cc, b])
        ..add([a, b, cc]);
    }
    final ids = <int>[];
    for (var i = 0; i < verts.length; i++) {
      final v = verts[i];
      final k = 1 + 0.16 * (_hash(seed * 131 + i) - 0.5);
      // Squash slightly and darken the underside (fake self-occlusion).
      final shade = 0.72 + 0.28 * (v[1] * 0.5 + 0.5);
      ids.add(
        buf.vertex(
          c[0] + v[0] * r * k,
          c[1] + v[1] * r * k * 0.86,
          c[2] + v[2] * r * k,
          v[0],
          v[1],
          v[2],
          [tint[0] * shade, tint[1] * shade, tint[2] * shade, 1],
        ),
      );
    }
    for (final f in faces) {
      _facing(buf, ids[f[0]], ids[f[1]], ids[f[2]], verts[f[0]]);
    }
  }

  void _cityBlocks() {
    final facade = _mat(
      'KL_Facade',
      GltfSceneBuilder.linear(0xFFCDD1D5),
      roughness: 0.8,
    );
    final facadeDark = _mat(
      'KL_FacadeWarm',
      GltfSceneBuilder.linear(0xFFB8AEA6),
      roughness: 0.8,
    );
    final night =
        look.night || look.theme.name == 'rain' || look.theme.name == 'sunset';
    final glass = _mat(
      'KL_Windows',
      GltfSceneBuilder.linear(0xFF2A3644),
      metallic: 0.0,
      roughness: 0.08,
      clearcoat: true,
    );
    final lit = _mat(
      'KL_WindowsLit',
      const [1.0, 0.78, 0.48],
      roughness: 0.3,
      emissive: const [1.0, 0.72, 0.42],
      emissiveStrength: look.night ? 2.2 : 0.8,
    );
    final a = PrimitiveBuffer(withColors: true),
        b = PrimitiveBuffer(withColors: true),
        w = PrimitiveBuffer(),
        wl = PrimitiveBuffer();
    const spacing = 28.0;
    for (final side in const [1, -1]) {
      final first = ((odo - 30) / spacing).floor() - 1;
      final last = ((odo + 220) / spacing).ceil();
      for (var n = first; n <= last; n++) {
        final x = n * spacing + _hash(n * 7 + side) * spacing * 0.3 - odo;
        if (x < -40 || x > 220) continue;
        final edge = side > 0 ? road.leftEdge(x) : road.rightEdge(x);
        final offset = 6.0 + _hash(n * 13 + side * 5) * 5;
        final depthX = 10 + _hash(n * 3) * 10;
        final lengthX = 14 + _hash(n * 11 + side) * 10;
        final height = 9 + _hash(n * 19 + side) * 30;
        final near = edge + side * offset;
        final far = near + side * depthX;
        final k = 0.9 + 0.2 * _hash(n * 37 + side);
        final buf = _hash(n * 53 + side) > 0.5 ? a : b;
        _box(
          buf,
          [x, math.min(near, far), 0],
          [x + lengthX, math.max(near, far), height],
          rgba: [k, k, k, 1],
        );
        // Window bands on the road-facing side.
        final faceY = near - side * 0.03;
        final floors = (height / 3.3).floor();
        for (var f = 1; f < floors; f++) {
          final z0 = f * 3.3 + 0.9, z1 = z0 + 1.5;
          for (var c = 0; c < (lengthX / 3).floor(); c++) {
            final x0 = x + 0.8 + c * 3.0, x1 = x0 + 2.0;
            if (x1 > x + lengthX - 0.6) break;
            final on = night && _hash(n * 977 + f * 31 + c * 7 + side) > 0.55;
            final target = on ? wl : w;
            _quad(
              target,
              [
                [x0, faceY, z0],
                [x1, faceY, z0],
                [x1, faceY, z1],
                [x0, faceY, z1],
              ],
              [0, -side.toDouble(), 0],
            );
          }
        }
      }
    }
    _emit('Buildings', a, facade);
    _emit('BuildingsWarm', b, facadeDark);
    _emit('Windows', w, glass);
    _emit('WindowsLit', wl, lit);
  }

  void _streetLamps() {
    final pole = _mat(
      'KL_LampPole',
      GltfSceneBuilder.linear(0xFF5E656C),
      metallic: 0.7,
      roughness: 0.4,
    );
    final head = _mat(
      'KL_LampHead',
      const [1.0, 0.86, 0.66],
      roughness: 0.3,
      emissive: const [1.0, 0.82, 0.58],
      emissiveStrength: look.streetLights ? 6.0 : 0.0,
    );
    final pb = PrimitiveBuffer(), hb = PrimitiveBuffer();
    const spacing = 36.0;
    final first = ((odo - 20) / spacing).floor();
    final last = ((odo + 200) / spacing).ceil();
    for (var n = first; n <= last; n++) {
      for (final side in const [1, -1]) {
        if (!city && side < 0) continue;
        final x = n * spacing + (side < 0 ? spacing / 2 : 0) - odo;
        if (x < -20 || x > 200) continue;
        final edge = side > 0 ? road.leftEdge(x) : road.rightEdge(x);
        final y = edge + side * (city ? 1.2 : 3.2);
        _box(pb, [x - 0.09, y - 0.09, 0], [x + 0.09, y + 0.09, 8.6]);
        final armEnd = y - side * 2.2;
        _box(
          pb,
          [x - 0.06, math.min(y, armEnd), 8.45],
          [x + 0.06, math.max(y, armEnd), 8.6],
        );
        _box(
          hb,
          [x - 0.35, armEnd - 0.18, 8.28],
          [x + 0.35, armEnd + 0.18, 8.45],
          bottom: true,
        );
        if (wet > 0.5) {
          // Mirror image under the wet road surface (puddle reflection).
          _box(
            hb,
            [x - 0.35, armEnd - 0.18, -8.45],
            [x + 0.35, armEnd + 0.18, -8.28],
            bottom: true,
          );
          _box(pb, [x - 0.09, y - 0.09, -8.6], [x + 0.09, y + 0.09, -0.05]);
        }
        lamps.add(StreetLamp(x, armEnd, 8.2));
      }
    }
    _emit('LampPoles', pb, pole);
    _emit('LampHeads', hb, head);
  }

  // ------------------------------------------------------------ path

  void _pathRibbon() {
    final pts = scene.plannedPath;
    if (pts.length < 2) return;
    final lead = scene.leadObject;
    final end = math.min(
      pts.last.forwardMeters,
      lead == null ? double.infinity : lead.distanceMeters - 0.8,
    );
    const start = 0.4;
    if (end <= start + 1) return;
    final samples = <double>[];
    for (var x = start; x < end; x += 0.5 + x * 0.03) {
      samples.add(x);
    }
    samples.add(end);
    double center(double x) => RoadScene.interpolateLeft(pts, x);
    // Teal → blue → violet; tone shifts toward amber/red as the lead nears.
    final tone = path.leadTone.clamp(0.0, 1.0);
    List<double> mix(List<double> a, List<double> b, double t) => [
      for (var i = 0; i < 4; i++) a[i] + (b[i] - a[i]) * t,
    ];
    const teal = [0.10, 0.95, 0.85, 1.0];
    const blue = [0.20, 0.55, 1.0, 1.0];
    const violet = [0.62, 0.36, 1.0, 1.0];
    const amber = [1.0, 0.62, 0.12, 1.0];
    const red = [1.0, 0.16, 0.18, 1.0];
    final warm = tone < 0.5
        ? mix(blue, amber, tone * 2)
        : mix(amber, red, tone * 2 - 1);
    final k =
        path.intensity *
        (look.night ? 1.1 : 0.62) *
        (path.engaged ? 1.0 : 0.55);
    List<double> colorAt(double x, double edgeFade) {
      final u = ((x - start) / (end - start)).clamp(0.0, 1.0);
      var c = u < 0.35
          ? mix(teal, blue, u / 0.35)
          : u < 0.7
          ? mix(blue, violet, (u - 0.35) / 0.35)
          : violet;
      c = mix(c, warm, tone * (0.35 + 0.65 * u));
      final fadeIn = ((x - start) / 4.0).clamp(0.0, 1.0);
      final fadeOut = 1 - math.pow(u, 3).toDouble();
      var a = 0.78 * fadeIn * fadeOut * edgeFade;
      var boost = 1.0;
      if (path.sweep >= 0) {
        final d = (u - path.sweep).abs();
        if (d < 0.12) {
          final s = 1 - d / 0.12;
          boost += 1.6 * s * s;
          a = math.min(0.95, a + 0.3 * s);
        }
      }
      return [c[0] * k * boost, c[1] * k * boost, c[2] * k * boost, a];
    }

    final mat = _mat(
      'KL_PathRibbon',
      const [1, 1, 1],
      unlit: true,
      blend: true,
      alpha: 1,
    );
    final buf = PrimitiveBuffer(withColors: true);
    // Five lateral columns so the ribbon fades softly at its edges.
    const cols = [-1.45, -1.0, -0.55, 0.0, 0.55, 1.0, 1.45];
    const fades = [0.0, 0.5, 0.95, 1.0, 0.95, 0.5, 0.0];
    final rows = <List<int>>[];
    for (final x in samples) {
      final cy = center(x);
      final slope = (center(x + 0.25) - center(x - 0.25)) / 0.5;
      final s = slope.isFinite ? slope : 0.0;
      final inv = 1 / math.sqrt(1 + s * s);
      rows.add([
        for (var c = 0; c < cols.length; c++)
          () {
            // Across the ribbon's own direction (constant width in curves).
            final off = cols[c] * RoadWorldPainter.pathHalfWidth;
            final p = toFilament(x - s * off * inv, cy + off * inv, 0.03);
            return buf.vertex(p[0], p[1], p[2], 0, 1, 0, colorAt(x, fades[c]));
          }(),
      ]);
    }
    for (var i = 0; i < rows.length - 1; i++) {
      for (var c = 0; c < cols.length - 1; c++) {
        final a = rows[i][c],
            b = rows[i][c + 1],
            cc = rows[i + 1][c],
            d = rows[i + 1][c + 1];
        _orientUp(buf, a, cc, b);
        _orientUp(buf, b, cc, d);
      }
    }
    _emit('PathRibbon', buf, mat);
  }
}
