import 'dart:math' as math;
import 'dart:typed_data';

import 'package:kovalink/src/vehicle_mesh/vehicle_mesh.dart';

/// Small immutable 3D vector for mesh authoring (vehicle frame).
class P3 {
  const P3(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  P3 operator +(P3 o) => P3(x + o.x, y + o.y, z + o.z);
  P3 operator -(P3 o) => P3(x - o.x, y - o.y, z - o.z);
  P3 operator *(double s) => P3(x * s, y * s, z * s);
  double dot(P3 o) => x * o.x + y * o.y + z * o.z;
  P3 cross(P3 o) => P3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get length => math.sqrt(x * x + y * y + z * z);
  P3 get unit {
    final l = length;
    return l < 1e-12 ? const P3(0, 0, 1) : P3(x / l, y / l, z / l);
  }

  static P3 lerp(P3 a, P3 b, double t) =>
      P3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t);
}

/// Accumulates triangles for a [VehicleMesh]. Every polygon is oriented
/// from an outward hint, so callers never have to get winding right.
/// Triangles also carry a part name so a GLB export can split nodes.
class MeshBuilder {
  final _positions = <double>[];
  final _normals = <double>[];
  final _indices = <int>[];
  final _triMaterials = <int>[];
  final _triParts = <int>[];
  final materials = <MeshMaterial>[];
  final parts = <String>['Body'];
  final _materialIndex = <String, int>{};
  int _part = 0;

  int get triangleCount => _triMaterials.length;

  int material(MeshMaterial m) => _materialIndex.putIfAbsent(m.name, () {
    materials.add(m);
    return materials.length - 1;
  });

  /// Following triangles belong to node [name] (default `Body`).
  void part(String name) {
    var index = parts.indexOf(name);
    if (index < 0) {
      parts.add(name);
      index = parts.length - 1;
    }
    _part = index;
  }

  int _vertex(P3 p, P3 n) {
    _positions
      ..add(p.x)
      ..add(p.y)
      ..add(p.z);
    _normals
      ..add(n.x)
      ..add(n.y)
      ..add(n.z);
    return _positions.length ~/ 3 - 1;
  }

  void _tri(int a, int b, int c, int mat) {
    _indices
      ..add(a)
      ..add(b)
      ..add(c);
    _triMaterials.add(mat);
    _triParts.add(_part);
  }

  /// Convex planar polygon, flat shaded, facing [outward].
  void poly(List<P3> points, MeshMaterial m, P3 outward) {
    if (points.length < 3) return;
    var pts = points;
    var normal = _polyNormal(pts);
    if (normal.length < 1e-12) return;
    if (normal.dot(outward) < 0) {
      pts = pts.reversed.toList();
      normal = normal * -1;
    }
    final n = normal.unit;
    final mat = material(m);
    final ids = [for (final p in pts) _vertex(p, n)];
    for (var i = 1; i < ids.length - 1; i++) {
      _tri(ids[0], ids[i], ids[i + 1], mat);
    }
  }

  /// Quad with per-corner normals (smooth shading). Order a-b-c-d around
  /// the quad; flipped if its face normal disagrees with [outward].
  void smoothQuad(List<P3> p, List<P3> n, MeshMaterial m, P3 outward) {
    var pts = p, nrm = n;
    final face = _polyNormal(pts);
    if (face.length < 1e-14) return;
    if (face.dot(outward) < 0) {
      pts = pts.reversed.toList();
      nrm = nrm.reversed.toList();
    }
    final mat = material(m);
    final ids = [for (var i = 0; i < pts.length; i++) _vertex(pts[i], nrm[i])];
    // Skip zero-area halves of degenerate (collapsed) quads.
    for (var i = 1; i < ids.length - 1; i++) {
      final area = (pts[i] - pts[0]).cross(pts[i + 1] - pts[0]).length;
      if (area > 1e-10) _tri(ids[0], ids[i], ids[i + 1], mat);
    }
  }

  static P3 _polyNormal(List<P3> pts) {
    // Newell's method: robust for slightly non-planar polygons.
    var nx = 0.0, ny = 0.0, nz = 0.0;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % pts.length];
      nx += (a.y - b.y) * (a.z + b.z);
      ny += (a.z - b.z) * (a.x + b.x);
      nz += (a.x - b.x) * (a.y + b.y);
    }
    return P3(nx, ny, nz);
  }

  /// Axis-aligned box without the bottom face.
  void box(P3 min, P3 max, MeshMaterial m, {bool bottom = false}) {
    P3 v(int i) => P3(
      i & 1 == 0 ? min.x : max.x,
      i & 2 == 0 ? min.y : max.y,
      i & 4 == 0 ? min.z : max.z,
    );
    poly([v(0), v(2), v(6), v(4)], m, const P3(-1, 0, 0));
    poly([v(1), v(3), v(7), v(5)], m, const P3(1, 0, 0));
    poly([v(0), v(1), v(5), v(4)], m, const P3(0, -1, 0));
    poly([v(2), v(3), v(7), v(6)], m, const P3(0, 1, 0));
    poly([v(4), v(5), v(7), v(6)], m, const P3(0, 0, 1));
    if (bottom) poly([v(0), v(1), v(3), v(2)], m, const P3(0, 0, -1));
  }

  /// Wheel: tread cylinder around the y axis plus an outer face with tire
  /// sidewall, rim and hub. [outerSign] is +1 for left wheels.
  void wheel({
    required P3 center,
    required double radius,
    required double width,
    required int outerSign,
    required MeshMaterial tire,
    required MeshMaterial rim,
    required MeshMaterial hub,
    int segments = 18,
  }) {
    final yo = center.y + outerSign * width / 2;
    final yi = center.y - outerSign * width / 2;
    P3 ring(double r, double y, int i) {
      // Half-step offset puts a vertex exactly at the contact point.
      final a = (i + 0.5) / segments * math.pi * 2;
      return P3(center.x + math.cos(a) * r, y, center.z + math.sin(a) * r);
    }

    for (var i = 0; i < segments; i++) {
      final a0 = ring(radius, yo, i), a1 = ring(radius, yo, i + 1);
      final b0 = ring(radius, yi, i), b1 = ring(radius, yi, i + 1);
      final n0 = P3(a0.x - center.x, 0, a0.z - center.z).unit;
      final n1 = P3(a1.x - center.x, 0, a1.z - center.z).unit;
      final mid = (a0 + a1 + b0 + b1) * 0.25;
      smoothQuad(
        [a0, a1, b1, b0],
        [n0, n1, n1, n0],
        tire,
        P3(mid.x - center.x, 0, mid.z - center.z),
      );
    }
    final out = P3(0, outerSign.toDouble(), 0);
    final face = yo + outerSign * 0.004;
    final rimR = radius * 0.64;
    for (var i = 0; i < segments; i++) {
      // Sidewall ring (tire) and rim disc with darker hub.
      poly(
        [
          ring(radius, yo, i),
          ring(radius, yo, i + 1),
          ring(rimR, face, i + 1),
          ring(rimR, face, i),
        ],
        tire,
        out,
      );
      poly(
        [
          ring(rimR, face, i),
          ring(rimR, face, i + 1),
          ring(rimR * 0.3, face, i + 1),
          ring(rimR * 0.3, face, i),
        ],
        i.isEven ? rim : hub,
        out,
      );
      poly(
        [
          ring(rimR * 0.3, face, i),
          ring(rimR * 0.3, face, i + 1),
          P3(center.x, face, center.z),
        ],
        hub,
        out,
      );
    }
  }

  VehicleMesh build({(double, double, double)? nominalSize}) => VehicleMesh(
    positions: Float32List.fromList(_positions),
    normals: Float32List.fromList(_normals),
    indices: Uint32List.fromList(_indices),
    triangleMaterials: Uint16List.fromList(_triMaterials),
    materials: List.unmodifiable(materials),
    nominalSize: nominalSize,
  );

  /// Part index per triangle (index into [parts]).
  Uint16List get triangleParts => Uint16List.fromList(_triParts);
}
