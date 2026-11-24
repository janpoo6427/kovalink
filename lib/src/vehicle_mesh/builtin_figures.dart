import 'dart:math' as math;

import 'package:kovalink/src/vehicle_mesh/mesh_builder.dart';
import 'package:kovalink/src/vehicle_mesh/vehicle_mesh.dart';

/// Built-in pedestrian and cyclist meshes (made by the KovaLink project,
/// CC0-1.0). Same frame as the vehicles: x forward, y left, z up, meters,
/// origin on the ground at the rear of the figure's footprint.
class BuiltinFigures {
  const BuiltinFigures._();

  static const jacket = MeshMaterial(
    name: 'KL_Jacket',
    role: MeshRole.paint,
    baseColor: 0xFF3E6FB8,
    roughness: 0.7,
  );
  static const pants = MeshMaterial(
    name: 'KL_Pants',
    role: MeshRole.trim,
    baseColor: 0xFF2C3036,
    roughness: 0.8,
  );
  static const skin = MeshMaterial(
    name: 'KL_Skin',
    role: MeshRole.other,
    baseColor: 0xFFE0B596,
    roughness: 0.6,
  );
  static const hair = MeshMaterial(
    name: 'KL_Hair',
    role: MeshRole.trim,
    baseColor: 0xFF2A211C,
    roughness: 0.7,
  );
  static const shoe = MeshMaterial(
    name: 'KL_Shoe',
    role: MeshRole.trim,
    baseColor: 0xFF202226,
    roughness: 0.6,
  );
  static const frame = MeshMaterial(
    name: 'KL_BikeFrame',
    role: MeshRole.chrome,
    baseColor: 0xFFD8453A,
    metallic: 0.6,
    roughness: 0.3,
  );
  static const helmet = MeshMaterial(
    name: 'KL_Helmet',
    role: MeshRole.paint,
    baseColor: 0xFFF2F3F5,
    roughness: 0.3,
  );
  static const tire = MeshMaterial(
    name: 'KL_BikeTire',
    role: MeshRole.tire,
    baseColor: 0xFF18191B,
    roughness: 0.9,
  );
  static const rim = MeshMaterial(
    name: 'KL_BikeRim',
    role: MeshRole.rim,
    baseColor: 0xFFB8BEC4,
    metallic: 0.9,
    roughness: 0.25,
  );
  static const reflector = MeshMaterial(
    name: 'KL_BikeTail',
    role: MeshRole.tail,
    baseColor: 0xFFA0172A,
    roughness: 0.2,
    emissive: 0xFF3A0006,
  );

  static MeshBuilder pedestrianBuilder() {
    final b = MeshBuilder();
    const cx = 0.25;
    // Legs (slight stride), torso, arms, neck and head.
    for (final side in const [1.0, -1.0]) {
      final stride = side * 0.09;
      _limb(
        b,
        P3(cx + stride, side * 0.1, 0.06),
        P3(cx + stride * 0.4, side * 0.1, 0.92),
        0.075,
        0.095,
        pants,
      );
      b.box(
        P3(cx + stride - 0.06, side * 0.1 - 0.05, 0),
        P3(cx + stride + 0.16, side * 0.1 + 0.05, 0.07),
        shoe,
      );
      _limb(
        b,
        P3(cx, side * 0.24, 1.42),
        P3(cx - side * 0.04 + 0.05, side * 0.27, 0.86),
        0.05,
        0.045,
        jacket,
      );
      _ball(b, P3(cx + 0.05 - side * 0.04, side * 0.27, 0.83), 0.045, skin);
    }
    _lathe(b, cx, 0, [
      (0.88, 0.17, 0.11),
      (1.05, 0.18, 0.115),
      (1.30, 0.20, 0.12),
      (1.45, 0.21, 0.12),
      (1.50, 0.12, 0.08),
    ], jacket);
    _limb(b, P3(cx, 0, 1.48), P3(cx, 0, 1.58), 0.045, 0.045, skin);
    _ball(b, P3(cx + 0.01, 0, 1.66), 0.105, skin);
    _ball(b, P3(cx - 0.015, 0, 1.70), 0.1, hair, squashZ: 0.8);
    return b;
  }

  static MeshBuilder cyclistBuilder() {
    final b = MeshBuilder();
    const r = 0.34;
    for (final (name, x) in const [('Wheel_R', 0.36), ('Wheel_F', 1.44)]) {
      b.part(name);
      b.wheel(
        center: P3(x, 0, r),
        radius: r,
        width: 0.04,
        outerSign: 1,
        tire: tire,
        rim: rim,
        hub: rim,
        segments: 20,
      );
      b.wheel(
        center: P3(x, 0, r),
        radius: r,
        width: 0.04,
        outerSign: -1,
        tire: tire,
        rim: rim,
        hub: rim,
        segments: 20,
      );
    }
    b.part('Body');
    // Frame: seat tube, down tube, top tube, stays, fork, bars.
    const bb = P3(0.82, 0, 0.32),
        seat = P3(0.70, 0, 0.88),
        head = P3(1.30, 0, 0.86);
    _limb(b, bb, seat, 0.02, 0.02, frame);
    _limb(b, bb, head, 0.024, 0.024, frame);
    _limb(b, seat, head, 0.02, 0.02, frame);
    _limb(b, bb, const P3(0.36, 0, r), 0.015, 0.015, frame);
    _limb(b, seat, const P3(0.36, 0, r), 0.015, 0.015, frame);
    _limb(b, head, const P3(1.44, 0, r), 0.018, 0.018, frame);
    _limb(b, head, const P3(1.26, 0, 1.0), 0.02, 0.02, frame);
    _limb(
      b,
      const P3(1.26, 0.26, 1.0),
      const P3(1.26, -0.26, 1.0),
      0.016,
      0.016,
      rim,
    );
    b.box(const P3(0.60, -0.07, 0.90), const P3(0.80, 0.07, 0.95), shoe);
    b.part('Tail_C');
    b.box(const P3(0.30, -0.04, 0.80), const P3(0.32, 0.04, 0.86), reflector);
    b.part('Body');
    // Rider leaning forward.
    for (final side in const [1.0, -1.0]) {
      final knee = P3(0.98, side * 0.12, 0.70 + side * 0.06);
      _limb(b, P3(0.72, side * 0.1, 0.98), knee, 0.075, 0.06, pants);
      _limb(
        b,
        knee,
        P3(0.84 + side * 0.06, side * 0.12, 0.26 + side * 0.1),
        0.055,
        0.045,
        pants,
      );
      _limb(
        b,
        P3(0.94, side * 0.2, 1.40),
        P3(1.24, side * 0.24, 1.02),
        0.045,
        0.04,
        jacket,
      );
    }
    _limb(
      b,
      const P3(0.72, 0, 1.0),
      const P3(1.0, 0, 1.44),
      0.15,
      0.17,
      jacket,
    );
    _ball(b, const P3(1.10, 0, 1.56), 0.1, skin);
    _ball(b, const P3(1.08, 0, 1.62), 0.125, helmet, squashZ: 0.75);
    return b;
  }

  static final VehicleMesh pedestrian = pedestrianBuilder().build(
    nominalSize: (0.55, 0.6, 1.76),
  );
  static final VehicleMesh cyclist = cyclistBuilder().build(
    nominalSize: (1.8, 0.6, 1.72),
  );
  static final pedestrianSet = VehicleMeshSet.fromMesh(pedestrian);
  static final cyclistSet = VehicleMeshSet.fromMesh(cyclist);

  static const coneOrange = MeshMaterial(
    name: 'KL_ConeOrange',
    role: MeshRole.other,
    baseColor: 0xFFF07B2C,
    roughness: 0.45,
  );
  static const coneWhite = MeshMaterial(
    name: 'KL_ConeBand',
    role: MeshRole.other,
    baseColor: 0xFFF4F4F2,
    roughness: 0.3,
    emissive: 0xFF202020,
  );
  static const coneBase = MeshMaterial(
    name: 'KL_ConeBase',
    role: MeshRole.trim,
    baseColor: 0xFF2A2C30,
    roughness: 0.8,
  );

  /// Traffic cone, 0.4 m footprint, 0.72 m tall (origin at its rear).
  static MeshBuilder coneBuilder() {
    final b = MeshBuilder();
    b.box(const P3(0, -0.2, 0), const P3(0.4, 0.2, 0.04), coneBase);
    _lathe(
      b,
      0.2,
      0,
      const [(0.04, 0.17, 0.17), (0.30, 0.115, 0.115)],
      coneOrange,
      segments: 14,
    );
    _lathe(
      b,
      0.2,
      0,
      const [(0.30, 0.115, 0.115), (0.44, 0.085, 0.085)],
      coneWhite,
      segments: 14,
    );
    _lathe(
      b,
      0.2,
      0,
      const [(0.44, 0.085, 0.085), (0.72, 0.02, 0.02)],
      coneOrange,
      segments: 14,
    );
    return b;
  }

  /// Tapered tube from [a] to [b] with radii [ra], [rb] and round caps.
  static void _limb(
    MeshBuilder b,
    P3 a,
    P3 c,
    double ra,
    double rb,
    MeshMaterial m, {
    int segments = 8,
  }) {
    final axis = c - a;
    final len = axis.length;
    if (len < 1e-6) return;
    final w = axis * (1 / len);
    final helper = w.z.abs() < 0.9 ? const P3(0, 0, 1) : const P3(1, 0, 0);
    final u = w.cross(helper).unit;
    final v = w.cross(u).unit;
    P3 ringAt(P3 p, double r, int i) {
      final t = i / segments * math.pi * 2;
      return p + (u * math.cos(t) + v * math.sin(t)) * r;
    }

    for (var i = 0; i < segments; i++) {
      final p0 = ringAt(a, ra, i), p1 = ringAt(a, ra, i + 1);
      final q0 = ringAt(c, rb, i), q1 = ringAt(c, rb, i + 1);
      final n0 = (p0 - a).unit, n1 = (p1 - a).unit;
      b.smoothQuad([p0, p1, q1, q0], [n0, n1, n1, n0], m, (p0 + p1) * 0.5 - a);
    }
    _ball(b, a, ra, m);
    _ball(b, c, rb, m);
  }

  /// Body of revolution around the vertical axis at ([x], [y]): rings of
  /// (height, half-width y, half-depth x).
  static void _lathe(
    MeshBuilder b,
    double x,
    double y,
    List<(double, double, double)> rings,
    MeshMaterial m, {
    int segments = 12,
  }) {
    P3 at((double, double, double) r, int i) {
      final t = i / segments * math.pi * 2;
      return P3(x + math.cos(t) * r.$3, y + math.sin(t) * r.$2, r.$1);
    }

    for (var k = 0; k < rings.length - 1; k++) {
      for (var i = 0; i < segments; i++) {
        final a0 = at(rings[k], i), a1 = at(rings[k], i + 1);
        final b0 = at(rings[k + 1], i), b1 = at(rings[k + 1], i + 1);
        P3 n(P3 p, double z) => P3(p.x - x, p.y - y, 0).unit;
        b.smoothQuad(
          [a0, a1, b1, b0],
          [n(a0, 0), n(a1, 0), n(b1, 0), n(b0, 0)],
          m,
          P3(a0.x - x, a0.y - y, 0),
        );
      }
    }
    // Caps.
    for (final (r, up) in [(rings.first, -1.0), (rings.last, 1.0)]) {
      b.poly([for (var i = 0; i < segments; i++) at(r, i)], m, P3(0, 0, up));
    }
  }

  static void _ball(
    MeshBuilder b,
    P3 c,
    double r,
    MeshMaterial m, {
    double squashZ = 1,
    int segments = 10,
    int rings = 6,
  }) {
    P3 at(int ring, int i) {
      final phi = ring / rings * math.pi;
      final t = i / segments * math.pi * 2;
      return P3(
        c.x + math.sin(phi) * math.cos(t) * r,
        c.y + math.sin(phi) * math.sin(t) * r,
        c.z + math.cos(phi) * r * squashZ,
      );
    }

    for (var k = 0; k < rings; k++) {
      for (var i = 0; i < segments; i++) {
        final p = [at(k, i), at(k, i + 1), at(k + 1, i + 1), at(k + 1, i)];
        final n = [for (final q in p) (q - c).unit];
        b.smoothQuad(p, n, m, (p[0] + p[2]) * 0.5 - c);
      }
    }
  }
}
