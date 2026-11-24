import 'dart:math' as math;

import 'package:kovalink/src/vehicle_mesh/mesh_builder.dart';
import 'package:kovalink/src/vehicle_mesh/vehicle_mesh.dart';

/// Self-made CC0 low-poly vehicles, generated from code (KovaLink project).
///
/// Body = loft of cross-sections along x: rounded lower body (sill,
/// bulging side, shoulder) plus an optional greenhouse (side glass,
/// rounded roof). Stations without a greenhouse form the hood and the
/// tailgate/trunk; the span between such a station and the first cabin
/// station becomes the windshield or rear window. Raising the section
/// bottom over the wheels cuts the wheel arches. Lamps, plate, grille and
/// the sunroof are thin `_Decal`/lamp polygons a few millimeters above
/// the body.
///
/// Vehicle frame: x forward from the rear bumper, y left, z up, meters.
class BuiltinVehicles {
  const BuiltinVehicles._();

  static final VehicleMesh suv = _build(_suvSpec);
  static final VehicleMesh sedan = _build(_sedanSpec);
  static final VehicleMesh truck = _buildTruck();

  /// Rear axle of the SUV (pack origin rearAxleGround), meters from the
  /// rear bumper.
  static const suvRearAxleX = 0.95;

  /// Detail levels used by the road renderer (generated once).
  static final suvSet = VehicleMeshSet.fromMesh(suv);
  static final sedanSet = VehicleMeshSet.fromMesh(sedan);
  static final truckSet = VehicleMeshSet.fromMesh(truck);

  static VehicleMesh byKind(BuiltinBody body) => switch (body) {
    BuiltinBody.suv => suv,
    BuiltinBody.sedan => sedan,
    BuiltinBody.truck => truck,
  };

  /// Builder for GLB export (keeps part names for nodes).
  static MeshBuilder builderFor(BuiltinBody body) => switch (body) {
    BuiltinBody.suv => _builder(_suvSpec),
    BuiltinBody.sedan => _builder(_sedanSpec),
    BuiltinBody.truck => _truckBuilder(),
  };

  // ------------------------------------------------------------ materials

  static const paint = MeshMaterial(
    name: 'KL_BodyPaint',
    role: MeshRole.paint,
    baseColor: 0xFFE9ECEF,
    metallic: 0.35,
    roughness: 0.28,
  );
  static const glass = MeshMaterial(
    name: 'KL_Glass',
    role: MeshRole.glass,
    baseColor: 0xFF141B23,
    metallic: 0.0,
    roughness: 0.06,
  );
  static const pillar = MeshMaterial(
    name: 'KL_PillarBlack',
    role: MeshRole.trim,
    baseColor: 0xFF15191E,
    roughness: 0.18,
  );
  static const trim = MeshMaterial(
    name: 'KL_Trim',
    role: MeshRole.trim,
    baseColor: 0xFF2A2E33,
    roughness: 0.75,
  );
  static const underbody = MeshMaterial(
    name: 'KL_Underbody',
    role: MeshRole.trim,
    baseColor: 0xFF16181B,
    roughness: 0.9,
  );
  static const tire = MeshMaterial(
    name: 'KL_Tire',
    role: MeshRole.tire,
    baseColor: 0xFF1A1B1D,
    roughness: 0.92,
  );
  static const rim = MeshMaterial(
    name: 'KL_Rim',
    role: MeshRole.rim,
    baseColor: 0xFFA9AFB5,
    metallic: 0.8,
    roughness: 0.3,
  );
  static const hub = MeshMaterial(
    name: 'KL_Hub',
    role: MeshRole.rim,
    baseColor: 0xFF3B4046,
    metallic: 0.5,
    roughness: 0.4,
  );
  static const tail = MeshMaterial(
    name: 'KL_Tail',
    role: MeshRole.tail,
    baseColor: 0xFF8E1424,
    roughness: 0.2,
    emissive: 0xFF3A0006,
  );
  static const brake = MeshMaterial(
    name: 'KL_Brake',
    role: MeshRole.brake,
    baseColor: 0xFFA0172A,
    roughness: 0.2,
  );
  static const turnLeft = MeshMaterial(
    name: 'KL_TurnLeft',
    role: MeshRole.turnLeft,
    baseColor: 0xFF6E3A22,
    roughness: 0.2,
  );
  static const turnRight = MeshMaterial(
    name: 'KL_TurnRight',
    role: MeshRole.turnRight,
    baseColor: 0xFF6E3A22,
    roughness: 0.2,
  );
  static const reverse = MeshMaterial(
    name: 'KL_Reverse',
    role: MeshRole.reverse,
    baseColor: 0xFFB9BEC4,
    roughness: 0.15,
  );
  static const headlight = MeshMaterial(
    name: 'KL_Head',
    role: MeshRole.headlight,
    baseColor: 0xFFDDE6EE,
    roughness: 0.1,
    emissive: 0xFF5A6168,
  );
  static const plate = MeshMaterial(
    name: 'KL_Plate',
    role: MeshRole.plate,
    baseColor: 0xFFF6F7F8,
    roughness: 0.5,
    // Retroreflective plate lit by its lamp: stays white in shade.
    emissive: 0xFF3C3C3C,
  );
  static const grille = MeshMaterial(
    name: 'KL_Grille_Decal',
    role: MeshRole.trim,
    baseColor: 0xFF1C2024,
    roughness: 0.35,
  );
  static const trimDecal = MeshMaterial(
    name: 'KL_Trim_Decal',
    role: MeshRole.trim,
    baseColor: 0xFF24282D,
    roughness: 0.6,
  );
  static const chromeDecal = MeshMaterial(
    name: 'KL_Chrome_Decal',
    role: MeshRole.chrome,
    baseColor: 0xFFBFC5CB,
    metallic: 0.9,
    roughness: 0.2,
  );
  static const sunroof = MeshMaterial(
    name: 'KL_Sunroof_Decal',
    role: MeshRole.glass,
    baseColor: 0xFF10161C,
    roughness: 0.05,
  );
  static const cargo = MeshMaterial(
    name: 'KL_CargoBox',
    role: MeshRole.other,
    baseColor: 0xFFE4E7EA,
    roughness: 0.55,
  );

  // ------------------------------------------------------------ specs

  static final _suvSpec = _BodySpec(
    length: 4.60,
    halfWidth: 0.93,
    wheelRadius: 0.36,
    wheelWidth: 0.24,
    axles: const [0.95, 3.75],
    sill: 0.36,
    rb: 0.10,
    rs: 0.10,
    rr: 0.10,
    crown: 0.03,
    cladding: true,
    keys: const [
      // x, zb, zt, ws, wb
      _Key(0.00, 0.44, 1.00, 0.85, 0.81),
      _Key(0.10, 0.40, 1.01, 0.905, 0.865),
      _Key(0.30, 0.37, 1.02, 0.925, 0.885),
      _Key(2.35, 0.36, 1.02, 0.93, 0.89),
      _Key(3.10, 0.36, 1.03, 0.93, 0.89),
      _Key(3.70, 0.37, 1.04, 0.92, 0.885),
      _Key(4.20, 0.38, 0.98, 0.90, 0.87),
      _Key(4.48, 0.40, 0.86, 0.86, 0.82),
      _Key(4.60, 0.44, 0.74, 0.78, 0.74),
    ],
    extraStations: const [0.55, 1.20, 1.95, 2.08, 2.70],
    rearGlassBase: 0.10,
    cabinStart: 0.30,
    cabinEnd: 3.10,
    cowl: 3.70,
    roof: const [
      (0.30, 1.585),
      (0.60, 1.63),
      (1.50, 1.66),
      (2.40, 1.655),
      (3.10, 1.60),
    ],
    roofHalf: const [(0.30, 0.70), (1.50, 0.75), (3.10, 0.70)],
    glassSpans: const [(0.55, 1.95), (2.08, 3.10)],
    blackSpans: const [(1.95, 2.08)],
    lampBand: (0.86, 0.96),
    sunroof: (1.45, 2.65, 0.50),
    rear: _RearDecals(
      barZ: (0.905, 0.935),
      barHalf: 0.62,
      cornerY: (0.62, 0.80),
      cornerZ: (0.84, 0.97),
      stripY: (0.74, 0.80),
      stripZ: (0.68, 0.84),
      turnY: (0.64, 0.72),
      turnZ: (0.85, 0.89),
      reverseY: (0.64, 0.72),
      reverseZ: (0.90, 0.95),
      plateZ: (0.50, 0.61),
      bumperZ: 0.54,
      skidHalf: 0.46,
    ),
    mirrorX: (3.42, 3.62),
    mirrorZ: (1.07, 1.21),
  );

  static final _sedanSpec = _BodySpec(
    length: 4.60,
    halfWidth: 0.92,
    wheelRadius: 0.33,
    wheelWidth: 0.23,
    axles: const [0.95, 3.75],
    sill: 0.32,
    rb: 0.09,
    rs: 0.09,
    rr: 0.10,
    crown: 0.035,
    cladding: false,
    keys: const [
      _Key(0.00, 0.36, 0.96, 0.84, 0.80),
      _Key(0.12, 0.33, 0.99, 0.90, 0.86),
      _Key(0.40, 0.32, 1.00, 0.915, 0.875),
      _Key(0.80, 0.32, 0.995, 0.92, 0.88),
      _Key(3.05, 0.32, 0.97, 0.92, 0.88),
      _Key(3.80, 0.33, 0.93, 0.91, 0.875),
      _Key(4.30, 0.34, 0.84, 0.89, 0.86),
      _Key(4.52, 0.38, 0.74, 0.85, 0.81),
      _Key(4.60, 0.42, 0.66, 0.78, 0.74),
    ],
    extraStations: const [1.75, 2.30, 2.42],
    rearGlassBase: 0.80,
    cabinStart: 1.40,
    cabinEnd: 3.05,
    cowl: 3.80,
    roof: const [(1.40, 1.385), (1.75, 1.43), (2.40, 1.45), (3.05, 1.39)],
    roofHalf: const [(1.40, 0.62), (2.30, 0.66), (3.05, 0.62)],
    glassSpans: const [(1.75, 2.30), (2.42, 3.05)],
    blackSpans: const [(2.30, 2.42)],
    lampBand: (0.80, 0.93),
    rear: _RearDecals(
      barZ: (0.86, 0.885),
      barHalf: 0.60,
      cornerY: (0.58, 0.82),
      cornerZ: (0.80, 0.92),
      stripY: (0.76, 0.82),
      stripZ: (0.72, 0.80),
      turnY: (0.60, 0.68),
      turnZ: (0.81, 0.85),
      reverseY: (0.60, 0.68),
      reverseZ: (0.86, 0.905),
      plateZ: (0.37, 0.48),
      bumperZ: 0.405,
      skidHalf: 0.0,
    ),
    mirrorX: (3.45, 3.62),
    mirrorZ: (0.99, 1.11),
  );

  static VehicleMesh _build(_BodySpec spec) =>
      _builder(spec).build(nominalSize: spec.nominal);

  static MeshBuilder _builder(_BodySpec spec) {
    final b = MeshBuilder();
    _loftBody(b, spec);
    _rearDecals(b, spec);
    _frontDecals(b, spec);
    _mirrors(b, spec);
    _wheels(b, spec);
    if (spec.sunroof case final roof?) _sunroof(b, spec, roof);
    return b;
  }

  // ------------------------------------------------------------ body loft

  static List<_Station> _stations(_BodySpec spec) {
    final xs = <double>{
      for (final k in spec.keys) k.x,
      ...spec.extraStations,
      spec.cabinStart,
      spec.cabinEnd,
    };
    final arch = spec.arch;
    for (final axle in spec.axles) {
      for (final d in const [
        -0.52,
        -0.43,
        -0.30,
        -0.15,
        0,
        0.15,
        0.30,
        0.43,
        0.52,
      ]) {
        xs.add(axle + d * arch / 0.44);
      }
    }
    final sorted = xs.where((x) => x >= 0 && x <= spec.length).toList()..sort();
    return [for (final x in sorted) _station(spec, x)];
  }

  static _Station _station(_BodySpec spec, double x) {
    final arch = spec.arch;
    final k = spec.keys;
    var i = 0;
    while (i < k.length - 2 && k[i + 1].x < x) {
      i++;
    }
    final a = k[i], c = k[i + 1];
    final t = ((x - a.x) / (c.x - a.x)).clamp(0.0, 1.0);
    double l(double p, double q) => p + (q - p) * t;
    var zb = l(a.zb, c.zb);
    for (final axle in spec.axles) {
      final d = (x - axle).abs();
      if (d < arch) {
        zb = math.max(zb, spec.wheelRadius + math.sqrt(arch * arch - d * d));
      }
    }
    final zt = l(a.zt, c.zt);
    final cabin = x >= spec.cabinStart - 1e-9 && x <= spec.cabinEnd + 1e-9;
    final zone = spec.glassZone(x);
    return _Station(
      zone: zone,
      x: x,
      zb: zb,
      zt: zt,
      ws: l(a.ws, c.ws),
      wb: l(a.wb, c.wb),
      zr: cabin ? _piecewise(spec.roof, x) : null,
      wr: cabin ? _piecewise(spec.roofHalf, x) : null,
    );
  }

  static double _piecewise(List<(double, double)> points, double x) {
    if (x <= points.first.$1) return points.first.$2;
    for (var i = 0; i < points.length - 1; i++) {
      final (x0, y0) = points[i];
      final (x1, y1) = points[i + 1];
      if (x <= x1) return y0 + (y1 - y0) * (x - x0) / (x1 - x0);
    }
    return points.last.$2;
  }

  /// Right-half section (y >= 0 here; mirrored for the right side).
  static List<(double, double)> _half(_BodySpec spec, _Station s) {
    final height = s.zt - s.zb;
    final rb = math.min(spec.rb, height * 0.4);
    final rs = math.min(spec.rs, height * 0.4);
    final out = <(double, double)>[(0, s.zb), (s.wb - rb, s.zb)];
    for (final deg in const [-60.0, -30.0, 0.0]) {
      final a = deg * math.pi / 180;
      out.add((s.wb - rb + math.cos(a) * rb, s.zb + rb + math.sin(a) * rb));
    }
    final shoulderY = s.ws - 0.012;
    out.add((s.ws, s.zb + rb + (s.zt - rs - s.zb - rb) * 0.42));
    out.add((shoulderY, s.zt - rs));
    for (final deg in const [45.0, 90.0]) {
      final a = deg * math.pi / 180;
      out.add((
        shoulderY - rs + math.cos(a) * rs,
        s.zt - rs + math.sin(a) * rs,
      ));
    }
    final wg = shoulderY - rs - 0.035;
    final crown = spec.crown;
    if (s.zr case final zr?) {
      final wr = s.wr!;
      final rr = spec.rr;
      out.add((wg, s.zt + 0.004));
      out.add(((wg + wr) / 2 + 0.01, (s.zt + zr - rr) / 2));
      out.add((wr, zr - rr));
      out.add((
        wr - rr + math.cos(math.pi / 4) * rr,
        zr - rr + math.sin(math.pi / 4) * rr,
      ));
      out.add((wr - rr, zr));
      out.add((0, zr + crown));
    } else if (s.zone case (final from, final to)) {
      // Windshield / rear glass: straight between the zone ends.
      final h0 = _half(spec, _station(spec, from));
      final h1 = _half(spec, _station(spec, to));
      final t = (s.x - from) / (to - from);
      for (var k = 9; k < _halfPoints; k++) {
        out.add((
          h0[k].$1 + (h1[k].$1 - h0[k].$1) * t,
          h0[k].$2 + (h1[k].$2 - h0[k].$2) * t,
        ));
      }
    } else {
      for (final f in const [1.0, 0.8, 0.6, 0.4, 0.2]) {
        out.add((wg * f, s.zt + crown * (1 - f * f) + 0.004 * f));
      }
      out.add((0, s.zt + crown));
    }
    assert(out.length == _halfPoints);
    return out;
  }

  static const _halfPoints = 15;
  static const _ringPoints = _halfPoints * 2 - 1;

  static List<P3> _ring(_BodySpec spec, _Station s) {
    final half = _half(spec, s);
    return [
      for (var k = 0; k < _halfPoints; k++) P3(s.x, -half[k].$1, half[k].$2),
      for (var k = _halfPoints - 2; k >= 0; k--)
        P3(s.x, half[k].$1, half[k].$2),
    ];
  }

  static int _rowK(int row) =>
      row < _halfPoints - 1 ? row : _ringPoints - 2 - row;

  static int _group(int k) => k == 0
      ? 0
      : k <= 8
      ? 1
      : k <= 10
      ? 2
      : 3;

  static MeshMaterial _material(
    _BodySpec spec,
    _Station a,
    _Station b,
    int k,
    int side,
  ) {
    final mid = (a.x + b.x) / 2;
    final cabinA = a.zr != null;
    if (k == 0) return underbody;
    if (spec.cladding && k <= 3) return trim;
    // Lamp clusters wrap around the rear corners.
    if (a.x < 0.2 && (k == 6 || k == 7)) {
      final z = (a.zt + b.zt) / 2;
      if (z >= spec.lampBand.$1) return brake;
    }
    if (k <= 8) return paint;
    if (spec.glassZone(mid) != null) {
      // Windshield / rear window span. Outer rows are the A/D pillars.
      return k >= 11 ? glass : pillar;
    }
    if (!cabinA) return paint; // hood and trunk/tailgate top
    if (k <= 10) {
      for (final (x0, x1) in spec.blackSpans) {
        if (mid > x0 && mid < x1) return pillar;
      }
      for (final (x0, x1) in spec.glassSpans) {
        if (mid > x0 && mid < x1) return glass;
      }
      return paint; // C/D pillar
    }
    return paint; // roof
  }

  static void _loftBody(MeshBuilder b, _BodySpec spec) {
    final stations = _stations(spec);
    final rings = [for (final s in stations) _ring(spec, s)];
    final spans = stations.length - 1;
    const rows = _ringPoints - 1;
    // Face normals for smoothing.
    final faces = List.generate(
      spans,
      (i) => List.generate(rows, (r) {
        final a = rings[i][r], bb = rings[i + 1][r];
        final c = rings[i + 1][r + 1], d = rings[i][r + 1];
        final n = (c - a).cross(d - bb);
        final mid = (a + bb + c + d) * 0.25;
        final zc = (stations[i].zb + stations[i].zt) / 2;
        final hint = P3((mid.x - spec.length / 2) * 0.3, mid.y, mid.z - zc);
        return n.dot(hint) < 0 ? n * -1 : n;
      }),
    );
    // Hood→windshield and roof→glass edges stay sharp.
    final edges = [
      ?spec.rearGlassBase,
      spec.cabinStart,
      spec.cabinEnd,
      ?spec.cowl,
    ];
    final creaseStations = <int>{
      for (var i = 1; i < stations.length - 1; i++)
        if (edges.any((x) => (stations[i].x - x).abs() < 1e-9)) i,
    };
    P3 normalAt(int station, int j, int span, int row) {
      final group = _group(_rowK(row));
      var sum = const P3(0, 0, 0);
      for (final si in [station - 1, station]) {
        if (si < 0 || si >= spans) continue;
        if (creaseStations.contains(station) && si != span) continue;
        for (final rj in [j - 1, j]) {
          if (rj < 0 || rj >= rows) continue;
          if (_group(_rowK(rj)) != group) continue;
          sum = sum + faces[si][rj];
        }
      }
      return sum.length < 1e-12 ? faces[span][row].unit : sum.unit;
    }

    for (var i = 0; i < spans; i++) {
      for (var r = 0; r < rows; r++) {
        final face = faces[i][r];
        if (face.length < 1e-12) continue;
        final k = _rowK(r);
        final side = r < _halfPoints - 1 ? -1 : 1;
        final m = _material(spec, stations[i], stations[i + 1], k, side);
        b.smoothQuad(
          [rings[i][r], rings[i + 1][r], rings[i + 1][r + 1], rings[i][r + 1]],
          [
            normalAt(i, r, i, r),
            normalAt(i + 1, r, i, r),
            normalAt(i + 1, r + 1, i, r),
            normalAt(i, r + 1, i, r),
          ],
          m,
          face,
        );
      }
    }
    // End caps: horizontal strips across the section.
    for (final (index, outward) in [(0, -1.0), (stations.length - 1, 1.0)]) {
      final ring = rings[index];
      for (var k = 0; k < _halfPoints - 1; k++) {
        final m = k == 0
            ? underbody
            : (spec.cladding && k <= 2 && outward < 0)
            ? trim
            : paint;
        b.poly(
          [
            ring[k],
            ring[k + 1],
            ring[_ringPoints - 2 - k],
            ring[_ringPoints - 1 - k],
          ],
          m,
          P3(outward, 0, 0),
        );
      }
    }
  }

  // ------------------------------------------------------------ details

  static void _rect(
    MeshBuilder b,
    double x,
    (double, double) y,
    (double, double) z,
    MeshMaterial m,
    double facing,
  ) {
    b.poly(
      [
        P3(x, y.$1, z.$1),
        P3(x, y.$2, z.$1),
        P3(x, y.$2, z.$2),
        P3(x, y.$1, z.$2),
      ],
      m,
      P3(facing, 0, 0),
    );
  }

  static void _rearDecals(MeshBuilder b, _BodySpec spec) {
    final r = spec.rear;
    const x = -0.006;
    const x2 = -0.009;
    // Lamp groups are separate nodes (Brake_L, Turn_RL, …) so packs can
    // bind lamps by node name as well as by material.
    for (final side in const [1.0, -1.0]) {
      final s = side > 0 ? 'L' : 'R';
      (double, double) ys((double, double) v) =>
          side > 0 ? (v.$1, v.$2) : (-v.$2, -v.$1);
      b.part('Brake_$s');
      _rect(b, x, ys(r.cornerY), r.cornerZ, brake, -1);
      _rect(b, x, ys(r.stripY), r.stripZ, brake, -1);
      b.part('Turn_R$s');
      _rect(b, x2, ys(r.turnY), r.turnZ, side > 0 ? turnLeft : turnRight, -1);
      b.part('Reverse_$s');
      _rect(b, x2, ys(r.reverseY), r.reverseZ, reverse, -1);
    }
    b.part('Tail');
    _rect(b, x, (-r.barHalf, r.barHalf), r.barZ, tail, -1);
    b.part('Body');
    _rect(b, x, (-0.26, 0.26), r.plateZ, plate, -1);
    final zb = spec.keys.first.zb;
    _rect(
      b,
      x,
      (-spec.keys.first.wb + 0.02, spec.keys.first.wb - 0.02),
      (zb + 0.002, r.bumperZ),
      trimDecal,
      -1,
    );
    if (r.skidHalf > 0) {
      _rect(
        b,
        x2,
        (-r.skidHalf, r.skidHalf),
        (zb + 0.01, zb + 0.045),
        chromeDecal,
        -1,
      );
    }
    // High-mounted stop lamp at the top of the rear glass.
    final glassBase = spec.rearGlassBase;
    if (glassBase == null) return;
    final a = _ring(spec, _station(spec, glassBase))[_halfPoints - 1];
    final c = _ring(spec, _station(spec, spec.cabinStart))[_halfPoints - 1];
    final dir = (c - a).unit;
    final outward = P3(-dir.z, 0, dir.x); // rear/up
    P3 at(double t, double y) {
      final p = P3.lerp(a, c, t) + outward * 0.012;
      // Follow the crowned roof line toward the sides.
      return P3(p.x, y, p.z - spec.crown * (y.abs() / 0.7) * 0.6);
    }

    b.part('Brake_C');
    b.poly(
      [at(0.90, -0.24), at(0.90, 0.24), at(0.95, 0.24), at(0.95, -0.24)],
      brake,
      outward,
    );
    b.part('Body');
  }

  static void _frontDecals(MeshBuilder b, _BodySpec spec) {
    final front = spec.keys.last;
    final x = spec.length + 0.006;
    final zb = front.zb;
    _rect(b, x, (-0.46, 0.46), (zb + 0.03, zb + 0.20), grille, 1);
    for (final side in const [1.0, -1.0]) {
      final ys = side > 0 ? (0.46, front.ws - 0.06) : (-front.ws + 0.06, -0.46);
      _rect(b, x, ys, (front.zt - 0.10, front.zt - 0.04), headlight, 1);
      b.part(side > 0 ? 'Turn_FL' : 'Turn_FR');
      final turn = side > 0
          ? (front.ws - 0.20, front.ws - 0.07)
          : (-front.ws + 0.07, -front.ws + 0.20);
      _rect(
        b,
        x + 0.003,
        turn,
        (front.zt - 0.155, front.zt - 0.12),
        side > 0 ? turnLeft : turnRight,
        1,
      );
      b.part('Body');
    }
    _rect(b, x, (-0.26, 0.26), (zb + 0.06, zb + 0.17), plate, 1);
  }

  static void _mirrors(MeshBuilder b, _BodySpec spec) {
    final (x0, x1) = spec.mirrorX;
    final (z0, z1) = spec.mirrorZ;
    final ws = spec.halfWidth - 0.02;
    for (final side in const [1.0, -1.0]) {
      final yIn = side * (ws - 0.10), yOut = side * (ws + 0.13);
      final min = P3(x0, math.min(yIn, yOut), z0);
      final max = P3(x1, math.max(yIn, yOut), z1);
      b.box(min, max, paint);
      // Dark lower housing.
      b.poly(
        [
          P3(x0 - 0.002, min.y, z0),
          P3(x0 - 0.002, max.y, z0),
          P3(x0 - 0.002, max.y, z0 + 0.035),
          P3(x0 - 0.002, min.y, z0 + 0.035),
        ],
        trimDecal,
        const P3(-1, 0, 0),
      );
    }
  }

  static void _wheels(MeshBuilder b, _BodySpec spec) {
    final names = [
      ['Wheel_RR', 'Wheel_RL'],
      ['Wheel_FR', 'Wheel_FL'],
    ];
    for (final (index, axle) in spec.axles.indexed) {
      for (final side in const [-1, 1]) {
        b.part(names[index][side > 0 ? 1 : 0]);
        final outer = spec.keys[2].wb - 0.012;
        b.wheel(
          center: P3(
            axle,
            side * (outer - spec.wheelWidth / 2),
            spec.wheelRadius,
          ),
          radius: spec.wheelRadius,
          width: spec.wheelWidth,
          outerSign: side,
          tire: tire,
          rim: rim,
          hub: hub,
        );
      }
    }
    b.part('Body');
  }

  static void _sunroof(
    MeshBuilder b,
    _BodySpec spec,
    (double, double, double) roof,
  ) {
    final (x0, x1, half) = roof;
    double zAt(double x, double y) {
      final zr = _piecewise(spec.roof, x);
      final wr = _piecewise(spec.roofHalf, x) - spec.rr;
      return zr + spec.crown * (1 - (y.abs() / wr).clamp(0.0, 1.0)) + 0.009;
    }

    for (final (ya, yb) in [(-half, 0.0), (0.0, half)]) {
      for (final (xa, xb) in [(x0, (x0 + x1) / 2), ((x0 + x1) / 2, x1)]) {
        b.poly(
          [
            P3(xa, ya, zAt(xa, ya)),
            P3(xb, ya, zAt(xb, ya)),
            P3(xb, yb, zAt(xb, yb)),
            P3(xa, yb, zAt(xa, yb)),
          ],
          sunroof,
          const P3(0, 0, 1),
        );
      }
    }
  }

  // ------------------------------------------------------------ truck

  static VehicleMesh _buildTruck() =>
      _truckBuilder().build(nominalSize: truckSize);

  static const truckSize = (9.0, 2.5, 3.2);

  static MeshBuilder _truckBuilder() {
    final b = MeshBuilder();
    const half = 1.25;
    // Cargo box: rounded loft, white.
    final boxSpec = _BodySpec(
      length: 6.6,
      halfWidth: half,
      wheelRadius: 0.5,
      wheelWidth: 0.5,
      axles: const [],
      sill: 0.95,
      rb: 0.04,
      rs: 0.07,
      rr: 0.05,
      crown: 0.0,
      cladding: false,
      keys: const [
        _Key(0.00, 0.95, 3.20, 1.235, 1.235),
        _Key(0.05, 0.95, 3.20, 1.25, 1.25),
        _Key(6.55, 0.95, 3.20, 1.25, 1.25),
        _Key(6.60, 0.95, 3.20, 1.235, 1.235),
      ],
      extraStations: const [],
      cabinStart: 99,
      cabinEnd: 99,
      roof: const [(0, 0)],
      roofHalf: const [(0, 0)],
      glassSpans: const [],
      blackSpans: const [],
      lampBand: (9, 9),
      rear: _RearDecals.none,
      mirrorX: (0, 0),
      mirrorZ: (0, 0),
    );
    final boxStations = [for (final k in boxSpec.keys) _station(boxSpec, k.x)];
    final boxRings = [for (final s in boxStations) _ring(boxSpec, s)];
    for (var i = 0; i < boxRings.length - 1; i++) {
      for (var r = 0; r < _ringPoints - 1; r++) {
        final a = boxRings[i][r], c = boxRings[i + 1][r];
        final d = boxRings[i + 1][r + 1], e = boxRings[i][r + 1];
        final mid = (a + c + d + e) * 0.25;
        b.poly(
          [a, c, d, e],
          _rowK(r) == 0 ? underbody : cargo,
          P3(0, mid.y, mid.z - 2.07),
        );
      }
    }
    for (final (index, outward) in [(0, -1.0), (boxRings.length - 1, 1.0)]) {
      final ring = boxRings[index];
      for (var k = 0; k < _halfPoints - 1; k++) {
        b.poly(
          [
            ring[k],
            ring[k + 1],
            ring[_ringPoints - 2 - k],
            ring[_ringPoints - 1 - k],
          ],
          cargo,
          P3(outward, 0, 0),
        );
      }
    }
    // Rear doors: seam, hinges and handles.
    _rect(b, -0.006, (-0.012, 0.012), (1.0, 3.12), trimDecal, -1);
    for (final y in const [-1.16, 1.16]) {
      for (final z in const [1.25, 2.1, 2.9]) {
        _rect(b, -0.006, (y - 0.04, y + 0.04), (z, z + 0.10), trimDecal, -1);
      }
    }
    _rect(b, -0.006, (-0.20, -0.05), (1.55, 1.62), chromeDecal, -1);
    _rect(b, -0.006, (0.05, 0.20), (1.55, 1.62), chromeDecal, -1);
    // Chassis and rear bumper bar with lamps and plate.
    b.box(const P3(0.4, -0.5, 0.55), const P3(8.2, 0.5, 0.95), underbody);
    b.box(const P3(0.0, -1.16, 0.44), const P3(0.16, 1.16, 0.64), trim);
    for (final side in const [1.0, -1.0]) {
      (double, double) ys(double a, double c) => side > 0 ? (a, c) : (-c, -a);
      _rect(b, -0.006, ys(0.82, 1.10), (0.48, 0.60), brake, -1);
      _rect(
        b,
        -0.008,
        ys(0.66, 0.80),
        (0.48, 0.60),
        side > 0 ? turnLeft : turnRight,
        -1,
      );
      _rect(b, -0.006, ys(1.10, 1.20), (3.04, 3.12), tail, -1);
    }
    _rect(b, -0.006, (-0.26, 0.26), (0.485, 0.595), plate, -1);
    // Cab: small loft with windshield.
    final cabSpec = _BodySpec(
      length: 9.0,
      halfWidth: 1.2,
      wheelRadius: 0.5,
      wheelWidth: 0.3,
      axles: const [7.7],
      sill: 0.55,
      rb: 0.06,
      rs: 0.10,
      rr: 0.12,
      crown: 0.04,
      cladding: false,
      keys: const [
        _Key(6.70, 0.55, 1.75, 1.14, 1.12),
        _Key(6.80, 0.55, 1.75, 1.18, 1.16),
        _Key(8.55, 0.55, 1.75, 1.20, 1.18),
        _Key(8.80, 0.58, 1.62, 1.18, 1.16),
        _Key(9.00, 0.62, 1.45, 1.10, 1.06),
      ],
      extraStations: const [7.4],
      cabinStart: 6.70,
      cabinEnd: 8.50,
      cowl: 8.80,
      roof: const [(6.70, 2.70), (7.6, 2.75), (8.50, 2.62)],
      roofHalf: const [(6.70, 1.05), (8.50, 1.02)],
      glassSpans: const [(7.4, 8.5)],
      blackSpans: const [],
      lampBand: (9, 9),
      rear: _RearDecals.none,
      mirrorX: (8.30, 8.42),
      mirrorZ: (1.9, 2.25),
    );
    final cabStations = _stations(cabSpec).where((s) => s.x >= 6.70).toList();
    final cabRings = [for (final s in cabStations) _ring(cabSpec, s)];
    for (var i = 0; i < cabRings.length - 1; i++) {
      for (var r = 0; r < _ringPoints - 1; r++) {
        final a = cabRings[i][r], c = cabRings[i + 1][r];
        final d = cabRings[i + 1][r + 1], e = cabRings[i][r + 1];
        final mid = (a + c + d + e) * 0.25;
        final zc = (cabStations[i].zb + cabStations[i].zt) / 2;
        b.poly(
          [a, c, d, e],
          _material(cabSpec, cabStations[i], cabStations[i + 1], _rowK(r), 0),
          P3((mid.x - 7.8) * 0.3, mid.y, mid.z - zc),
        );
      }
    }
    final front = cabRings.last;
    for (var k = 0; k < _halfPoints - 1; k++) {
      b.poly(
        [
          front[k],
          front[k + 1],
          front[_ringPoints - 2 - k],
          front[_ringPoints - 1 - k],
        ],
        paint,
        const P3(1, 0, 0),
      );
    }
    _rect(b, 9.006, (-0.70, 0.70), (0.75, 1.15), grille, 1);
    for (final side in const [1.0, -1.0]) {
      _rect(
        b,
        9.006,
        side > 0 ? (0.75, 1.0) : (-1.0, -0.75),
        (1.0, 1.15),
        headlight,
        1,
      );
      final yIn = side * 1.18, yOut = side * 1.38;
      b.box(
        P3(8.30, math.min(yIn, yOut), 1.9),
        P3(8.42, math.max(yIn, yOut), 2.25),
        trim,
      );
    }
    for (final (name, axle, width) in const [
      ('Wheel_R', 2.2, 0.5),
      ('Wheel_F', 7.7, 0.3),
    ]) {
      for (final side in const [-1, 1]) {
        b.part('$name${side > 0 ? 'L' : 'R'}');
        b.wheel(
          center: P3(axle, side * (1.20 - width / 2), 0.5),
          radius: 0.5,
          width: width,
          outerSign: side,
          tire: tire,
          rim: rim,
          hub: hub,
        );
      }
    }
    b.part('Body');
    return b;
  }
}

enum BuiltinBody { suv, sedan, truck }

class _Key {
  const _Key(this.x, this.zb, this.zt, this.ws, this.wb);

  final double x;
  final double zb;
  final double zt;
  final double ws;
  final double wb;
}

class _Station {
  const _Station({
    required this.zone,
    required this.x,
    required this.zb,
    required this.zt,
    required this.ws,
    required this.wb,
    this.zr,
    this.wr,
  });

  final double x;
  final double zb;
  final double zt;
  final double ws;
  final double wb;
  final double? zr;
  final double? wr;

  /// Glass transition zone (from, to) this station lies inside, if any.
  final (double, double)? zone;
}

class _RearDecals {
  const _RearDecals({
    required this.barZ,
    required this.barHalf,
    required this.cornerY,
    required this.cornerZ,
    required this.stripY,
    required this.stripZ,
    required this.turnY,
    required this.turnZ,
    required this.reverseY,
    required this.reverseZ,
    required this.plateZ,
    required this.bumperZ,
    required this.skidHalf,
  });

  static const none = _RearDecals(
    barZ: (0, 0),
    barHalf: 0,
    cornerY: (0, 0),
    cornerZ: (0, 0),
    stripY: (0, 0),
    stripZ: (0, 0),
    turnY: (0, 0),
    turnZ: (0, 0),
    reverseY: (0, 0),
    reverseZ: (0, 0),
    plateZ: (0, 0),
    bumperZ: 0,
    skidHalf: 0,
  );

  final (double, double) barZ;
  final double barHalf;
  final (double, double) cornerY;
  final (double, double) cornerZ;
  final (double, double) stripY;
  final (double, double) stripZ;
  final (double, double) turnY;
  final (double, double) turnZ;
  final (double, double) reverseY;
  final (double, double) reverseZ;
  final (double, double) plateZ;
  final double bumperZ;
  final double skidHalf;
}

class _BodySpec {
  const _BodySpec({
    required this.length,
    required this.halfWidth,
    required this.wheelRadius,
    required this.wheelWidth,
    required this.axles,
    required this.sill,
    required this.rb,
    required this.rs,
    required this.rr,
    required this.crown,
    required this.cladding,
    required this.keys,
    required this.extraStations,
    required this.cabinStart,
    required this.cabinEnd,
    required this.roof,
    required this.roofHalf,
    required this.glassSpans,
    required this.blackSpans,
    required this.lampBand,
    required this.rear,
    required this.mirrorX,
    required this.mirrorZ,
    this.sunroof,
    this.rearGlassBase,
    this.cowl,
  });

  /// Where the rear glass meets the tailgate/trunk and where the
  /// windshield meets the hood (null = no such glass).
  final double? rearGlassBase;
  final double? cowl;

  double get arch => axles.isEmpty ? 0 : wheelRadius + 0.08;

  (double, double, double) get nominal =>
      (length, halfWidth * 2, roof.map((p) => p.$2).reduce(math.max) + crown);

  (double, double)? glassZone(double x) {
    if (rearGlassBase case final g?
        when x > g + 1e-9 && x < cabinStart - 1e-9) {
      return (g, cabinStart);
    }
    if (cowl case final c? when x > cabinEnd + 1e-9 && x < c - 1e-9) {
      return (cabinEnd, c);
    }
    return null;
  }

  final double length;
  final double halfWidth;
  final double wheelRadius;
  final double wheelWidth;
  final List<double> axles;
  final double sill;
  final double rb;
  final double rs;
  final double rr;
  final double crown;
  final bool cladding;
  final List<_Key> keys;
  final List<double> extraStations;
  final double cabinStart;
  final double cabinEnd;
  final List<(double, double)> roof;
  final List<(double, double)> roofHalf;
  final List<(double, double)> glassSpans;
  final List<(double, double)> blackSpans;
  final (double, double) lampBand;
  final _RearDecals rear;
  final (double, double) mirrorX;
  final (double, double) mirrorZ;
  final (double, double, double)? sunroof;
}
