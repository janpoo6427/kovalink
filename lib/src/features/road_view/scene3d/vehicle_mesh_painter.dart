import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/vehicle_mesh/vehicle_mesh.dart';

/// Lamp state for one vehicle (display only, from the frame's fields).
class VehicleLamps {
  const VehicleLamps({
    this.brake = false,
    this.tail = true,
    this.leftTurn = false,
    this.rightTurn = false,
    this.reverse = false,
  });

  final bool brake;
  final bool tail;
  final bool leftTurn;
  final bool rightTurn;
  final bool reverse;
}

/// Where and how large to draw a mesh in the road-scene frame.
class VehiclePose {
  const VehiclePose({
    required this.rearX,
    required this.leftY,
    required this.length,
    required this.width,
    required this.height,
    this.yaw = 0,
  });

  /// Rear bumper position (x forward, meters) and lateral center (y left).
  final double rearX;
  final double leftY;
  final double length;
  final double width;
  final double height;

  /// Heading relative to the ego, radians, counter-clockwise (toward +y).
  final double yaw;
}

/// Per-call numbers for tests and the frame-cost benchmark.
class MeshDrawStats {
  const MeshDrawStats(this.trianglesIn, this.trianglesDrawn, this.bounds);

  final int trianglesIn;
  final int trianglesDrawn;

  /// Screen-space bounds of the drawn triangles (empty when none).
  final Rect bounds;
}

/// Software rasterization of a [VehicleMesh] in the road camera:
/// per-vertex transform and projection, back-face culling in screen space,
/// painter's algorithm per triangle, Gouraud lighting (sun + sky/ground
/// ambient + Blinn-Phong highlight + Fresnel sky reflection), distance fog,
/// lamp emission with a soft glow, and a blurred contact shadow.
/// Drawn with one [Canvas.drawVertices] per vehicle.
class VehicleMeshPainter {
  const VehicleMeshPainter._();

  /// Decals are this many meters "closer" for sorting (they sit 5–10 mm
  /// above the surface under them).
  static const decalBias = 0.25;

  static MeshDrawStats paint({
    required Canvas canvas,
    required SceneCamera camera,
    required ScenePalette palette,
    required VehicleMesh mesh,
    required VehiclePose pose,
    int? paintArgb,
    VehicleLamps lamps = const VehicleLamps(),
    bool shadow = true,
    double shadowStrength = 1,
  }) {
    final n = mesh.vertexCount;
    final (nl, nw, nh) = mesh.size;
    final sx = pose.length / nl, sy = pose.width / nw, sz = pose.height / nh;
    final cosY = math.cos(pose.yaw), sinY = math.sin(pose.yaw);
    final cx = pose.rearX + pose.length / 2;
    final world = Float64List(n * 3);
    final wn = Float64List(n * 3);
    final p = mesh.positions, nn = mesh.normals;
    final halfL = nl / 2;
    for (var v = 0; v < n; v++) {
      final lx = (p[v * 3] - halfL) * sx, ly = p[v * 3 + 1] * sy;
      world[v * 3] = cx + cosY * lx - sinY * ly;
      world[v * 3 + 1] = pose.leftY + sinY * lx + cosY * ly;
      world[v * 3 + 2] = p[v * 3 + 2] * sz;
      var ax = nn[v * 3] / sx, ay = nn[v * 3 + 1] / sy, az = nn[v * 3 + 2] / sz;
      final len = math.sqrt(ax * ax + ay * ay + az * az);
      if (len > 1e-12) {
        ax /= len;
        ay /= len;
        az /= len;
      }
      wn[v * 3] = cosY * ax - sinY * ay;
      wn[v * 3 + 1] = sinY * ax + cosY * ay;
      wn[v * 3 + 2] = az;
    }
    final screen = Float32List(n * 2);
    final depth = Float64List(n);
    camera.projectAll(world, screen, depth);
    final near = camera.nearDepth;

    final rearCenter = V3(pose.rearX, pose.leftY, pose.height * 0.4);
    final ppm = camera.pixelsPerMeter(camera.depthOf(rearCenter));
    if (shadow) {
      _shadow(canvas, camera, palette, pose, ppm, shadowStrength);
    }

    // Per-vertex lighting.
    final colors = Int32List(n);
    final vm = mesh.vertexMaterials;
    final eye = camera.eyePoint;
    final light = palette.lightDirection;
    final mats = mesh.materials;
    final lit = [for (final m in mats) _lampLevel(m.role, lamps)];
    final env = _Env(palette);
    for (var v = 0; v < n; v++) {
      final m = mats[vm[v]];
      var base = m.role == MeshRole.paint && paintArgb != null
          ? paintArgb
          : m.baseColor;
      final tint = mesh.colors?[v];
      if (tint != null) base = _multiply(base, tint);
      double vx, vy, vz;
      if (eye == null) {
        (vx, vy, vz) = (0, 0, -1);
      } else {
        vx = world[v * 3] - eye.x;
        vy = world[v * 3 + 1] - eye.y;
        vz = world[v * 3 + 2] - eye.z;
        final l = math.sqrt(vx * vx + vy * vy + vz * vz);
        vx /= l;
        vy /= l;
        vz /= l;
      }
      colors[v] = _shade(
        base,
        m,
        wn[v * 3],
        wn[v * 3 + 1],
        wn[v * 3 + 2],
        vx,
        vy,
        vz,
        light,
        env,
        lit[vm[v]],
        world[v * 3 + 2] / math.max(pose.height, 0.5),
        palette,
        depth[v],
      );
    }

    // Visible triangles, far to near.
    final tCount = mesh.triangleCount;
    final order = Int32List(tCount);
    final keys = Float64List(tCount);
    var visible = 0;
    final topDown = camera is TopDownCamera;
    final idx = mesh.indices, tm = mesh.triangleMaterials;
    for (var t = 0; t < tCount; t++) {
      final a = idx[t * 3], b = idx[t * 3 + 1], c = idx[t * 3 + 2];
      if (depth[a] < near || depth[b] < near || depth[c] < near) continue;
      final ax = screen[a * 2], ay = screen[a * 2 + 1];
      final area =
          (screen[b * 2] - ax) * (screen[c * 2 + 1] - ay) -
          (screen[b * 2 + 1] - ay) * (screen[c * 2] - ax);
      final m = mats[tm[t]];
      if (area >= 0 && !m.doubleSided) continue;
      if (area.abs() < 1e-6) continue;
      final onTop = m.drawsOnTop;
      keys[t] = topDown
          ? -(world[a * 3 + 2] + world[b * 3 + 2] + world[c * 3 + 2]) / 3 -
                (onTop ? 0.02 : 0)
          : (depth[a] + depth[b] + depth[c]) / 3 - (onTop ? decalBias : 0);
      order[visible++] = t;
    }
    final sorted = Int32List.sublistView(order, 0, visible)
      ..sort((x, y) => keys[y].compareTo(keys[x]));

    final pos = Float32List(visible * 6);
    final col = Int32List(visible * 3);
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    final glowPaths = <MeshRole, Path>{};
    for (var i = 0; i < visible; i++) {
      final t = sorted[i];
      for (var k = 0; k < 3; k++) {
        final v = idx[t * 3 + k];
        final x = screen[v * 2], y = screen[v * 2 + 1];
        pos[i * 6 + k * 2] = x;
        pos[i * 6 + k * 2 + 1] = y;
        col[i * 3 + k] = colors[v];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
      final m = mats[tm[t]];
      if (m.isLamp && lit[tm[t]] > 0.5) {
        final path = glowPaths.putIfAbsent(m.role, Path.new);
        final a = idx[t * 3], b = idx[t * 3 + 1], c = idx[t * 3 + 2];
        path.addPolygon([
          Offset(screen[a * 2], screen[a * 2 + 1]),
          Offset(screen[b * 2], screen[b * 2 + 1]),
          Offset(screen[c * 2], screen[c * 2 + 1]),
        ], true);
      }
    }
    if (visible > 0) {
      canvas.drawVertices(
        Vertices.raw(VertexMode.triangles, pos, colors: col),
        BlendMode.dst,
        Paint(),
      );
    }
    for (final MapEntry(key: role, value: path) in glowPaths.entries) {
      final glow = _glowColor(role);
      final fog =
          1 - math.exp(-palette.fogDensity * camera.depthOf(rearCenter));
      final alpha = (1 - fog * 0.8).clamp(0.15, 1.0);
      final sigma = math.max(1.2, ppm * (role == MeshRole.tail ? 0.035 : 0.07));
      canvas.drawPath(
        path,
        Paint()
          ..color = glow.withValues(alpha: 0.85 * alpha)
          ..blendMode = BlendMode.screen
          ..maskFilter = MaskFilter.blur(BlurStyle.outer, sigma),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = glow.withValues(alpha: 0.45 * alpha)
          ..blendMode = BlendMode.screen
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma * 2.6),
      );
    }
    return MeshDrawStats(
      tCount,
      visible,
      visible == 0 ? Rect.zero : Rect.fromLTRB(minX, minY, maxX, maxY),
    );
  }

  static Color _glowColor(MeshRole role) => switch (role) {
    MeshRole.turnLeft || MeshRole.turnRight => const Color(0xFFFFB12A),
    MeshRole.reverse || MeshRole.headlight => const Color(0xFFF2F6FF),
    _ => const Color(0xFFFF2A40),
  };

  /// 0 = off, 1 = fully lit.
  static double _lampLevel(MeshRole role, VehicleLamps lamps) => switch (role) {
    MeshRole.tail => lamps.brake ? 1.0 : (lamps.tail ? 0.42 : 0),
    MeshRole.brake => lamps.brake ? 1.0 : (lamps.tail ? 0.22 : 0),
    MeshRole.turnLeft => lamps.leftTurn ? 1.0 : 0,
    MeshRole.turnRight => lamps.rightTurn ? 1.0 : 0,
    MeshRole.reverse => lamps.reverse ? 1.0 : 0,
    MeshRole.headlight => 0.3,
    _ => 0,
  };

  static void _shadow(
    Canvas canvas,
    SceneCamera camera,
    ScenePalette palette,
    VehiclePose pose,
    double ppm,
    double strength,
  ) {
    final cosY = math.cos(pose.yaw), sinY = math.sin(pose.yaw);
    final cx = pose.rearX + pose.length / 2;
    // Light from behind-left above: the shadow leans forward-right a bit.
    final (lx, ly, _) = palette.lightDirection;
    final ox = -lx * 0.25, oy = -ly * 0.25;
    List<V3> rect(double halfL, double halfW, double round) {
      final pts = <V3>[];
      for (var i = 0; i < 24; i++) {
        final a = i / 24 * math.pi * 2;
        // Superellipse: flat sides, rounded corners.
        final c = math.cos(a), s = math.sin(a);
        final px = halfL * c.sign * math.pow(c.abs(), round);
        final py = halfW * s.sign * math.pow(s.abs(), round);
        pts.add(
          V3(
            cx + ox + cosY * px - sinY * py,
            pose.leftY + oy + sinY * px + cosY * py,
            0.012,
          ),
        );
      }
      return pts;
    }

    void draw(List<V3> pts, double alpha, double blurMeters) {
      final polygon = camera.projectPolygon(pts);
      if (polygon == null) return;
      canvas.drawPath(
        Path()..addPolygon(polygon, true),
        Paint()
          ..color = Color.fromRGBO(0, 0, 0, (alpha * strength).clamp(0.0, 1.0))
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            math.max(1.0, ppm * blurMeters),
          ),
      );
    }

    final a = palette.shadowAlpha;
    draw(
      rect(pose.length / 2 + 0.45, pose.width / 2 + 0.38, 0.35),
      a * 0.55,
      0.42,
    );
    draw(
      rect(pose.length / 2 + 0.05, pose.width / 2 + 0.02, 0.25),
      a * 0.95,
      0.13,
    );
  }

  static int _multiply(int a, int b) {
    int ch(int s) => ((((a >> s) & 0xFF) * ((b >> s) & 0xFF)) / 255).round();
    return 0xFF000000 | ch(16) << 16 | ch(8) << 8 | ch(0);
  }

  static int _shade(
    int base,
    MeshMaterial m,
    double nx,
    double ny,
    double nz,
    double vx,
    double vy,
    double vz,
    (double, double, double) light,
    _Env env,
    double lampLevel,
    double heightFraction,
    ScenePalette palette,
    double depth,
  ) {
    final br = ((base >> 16) & 0xFF) / 255.0;
    final bg = ((base >> 8) & 0xFF) / 255.0;
    final bb = (base & 0xFF) / 255.0;
    // Double-sided materials seen from the back: light the visible side.
    var ndv = nx * vx + ny * vy + nz * vz;
    if (ndv > 0 && m.doubleSided) {
      nx = -nx;
      ny = -ny;
      nz = -nz;
      ndv = -ndv;
    }
    final (lx, ly, lz) = light;
    final ndl = math.max(0.0, nx * lx + ny * ly + nz * lz);
    // Hemispheric ambient, darker toward the ground (fake occlusion).
    final occlusion = 0.80 + 0.20 * heightFraction.clamp(0.0, 1.0);
    final ambient = (0.58 + 0.14 * nz) * occlusion;
    final metallic = m.metallic;
    final diffuse = (ambient + 0.46 * ndl) * (1 - metallic * 0.45);
    var r = br * diffuse, g = bg * diffuse, b = bb * diffuse;

    // Reflection of sky/ground (Fresnel-weighted, clear coat for paint).
    final rx = vx - 2 * ndv * nx,
        ry = vy - 2 * ndv * ny,
        rz = vz - 2 * ndv * nz;
    final (er, eg, eb) = env.sample(rx, ry, rz);
    final cosT = (-ndv).clamp(0.0, 1.0);
    final coat = switch (m.role) {
      MeshRole.paint => 0.06,
      MeshRole.glass => 0.07,
      MeshRole.chrome || MeshRole.rim => 0.25,
      _ => 0.035,
    };
    final f0r = coat + (br - coat) * metallic * 0.6;
    final f0g = coat + (bg - coat) * metallic * 0.6;
    final f0b = coat + (bb - coat) * metallic * 0.6;
    final fres = math.pow(1 - cosT, 5).toDouble();
    final gloss = (1 - m.roughness).clamp(0.0, 1.0);
    final k = gloss * gloss;
    final fr = (f0r + (1 - f0r) * fres) * k;
    final fg = (f0g + (1 - f0g) * fres) * k;
    final fb = (f0b + (1 - f0b) * fres) * k;
    r = r * (1 - fr) + er * fr;
    g = g * (1 - fg) + eg * fg;
    b = b * (1 - fb) + eb * fb;

    // Sun highlight (Blinn-Phong).
    var hx = lx - vx, hy = ly - vy, hz = lz - vz;
    final hl = math.sqrt(hx * hx + hy * hy + hz * hz);
    if (hl > 1e-9 && ndl > 0) {
      hx /= hl;
      hy /= hl;
      hz /= hl;
      final ndh = math.max(0.0, nx * hx + ny * hy + nz * hz);
      final shininess = 8 + 120 * k;
      final spec = math.pow(ndh, shininess) * 0.55 * k;
      r += spec;
      g += spec;
      b += spec;
    }

    // Lamps: lit lenses glow toward a hot core color.
    if (lampLevel > 0) {
      final (cr, cg, cb) = switch (m.role) {
        MeshRole.turnLeft || MeshRole.turnRight => (1.0, 0.70, 0.16),
        MeshRole.reverse || MeshRole.headlight => (0.97, 0.98, 1.0),
        _ => (1.0, 0.16, 0.24),
      };
      final t = lampLevel.clamp(0.0, 1.0);
      r = r + (cr - r) * t;
      g = g + (cg - g) * t;
      b = b + (cb - b) * t;
    } else if (m.emissive & 0xFFFFFF != 0) {
      r += ((m.emissive >> 16) & 0xFF) / 255.0;
      g += ((m.emissive >> 8) & 0xFF) / 255.0;
      b += (m.emissive & 0xFF) / 255.0;
    }

    // Distance fog (lamps cut through it a little).
    final fogAmount =
        ((1 - math.exp(-palette.fogDensity * math.max(0, depth))) *
                (1 - 0.35 * lampLevel))
            .clamp(0.0, 0.96);
    final fog = palette.fog;
    r = r + (fog.r - r) * fogAmount;
    g = g + (fog.g - g) * fogAmount;
    b = b + (fog.b - b) * fogAmount;
    int c(double x) => (x.clamp(0.0, 1.0) * 255).round();
    return 0xFF000000 | c(r) << 16 | c(g) << 8 | c(b);
  }
}

/// Sky above the horizon, darker road/ground below, for reflections.
class _Env {
  _Env(ScenePalette p)
    : top = (p.skyTop.r, p.skyTop.g, p.skyTop.b),
      horizon = (p.skyHorizon.r, p.skyHorizon.g, p.skyHorizon.b),
      ground = (
        p.asphaltNear.r * 0.7 + p.fog.r * 0.3,
        p.asphaltNear.g * 0.7 + p.fog.g * 0.3,
        p.asphaltNear.b * 0.7 + p.fog.b * 0.3,
      ),
      dusk = (p.fog.r * 0.82, p.fog.g * 0.82, p.fog.b * 0.82);

  final (double, double, double) top;
  final (double, double, double) horizon;
  final (double, double, double) ground;
  final (double, double, double) dusk;

  (double, double, double) sample(double x, double y, double z) {
    if (z >= 0) {
      final t = math.sqrt(z.clamp(0.0, 1.0));
      return (
        horizon.$1 + (top.$1 - horizon.$1) * t,
        horizon.$2 + (top.$2 - horizon.$2) * t,
        horizon.$3 + (top.$3 - horizon.$3) * t,
      );
    }
    final t = math.min(1.0, -z * 4);
    return (
      dusk.$1 + (ground.$1 - dusk.$1) * t,
      dusk.$2 + (ground.$2 - dusk.$2) * t,
      dusk.$3 + (ground.$3 - dusk.$3) * t,
    );
  }
}
