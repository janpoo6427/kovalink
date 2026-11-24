import 'dart:math' as math;
import 'dart:typed_data';

/// What a material is for. The road renderer recolors [paint], dims or
/// lights the lamp roles from the frame's lamp state and gives [glass]
/// a sky reflection. Everything else keeps its own color.
enum MeshRole {
  paint,
  glass,
  tail,
  brake,
  turnLeft,
  turnRight,
  reverse,
  headlight,
  plate,
  tire,
  rim,
  trim,
  chrome,
  other,
}

/// One flat PBR-ish material: glTF `baseColorFactor`, `metallicFactor`,
/// `roughnessFactor` and `emissiveFactor`. Colors are 0xAARRGGBB.
class MeshMaterial {
  const MeshMaterial({
    required this.name,
    this.role = MeshRole.other,
    this.baseColor = 0xFFFFFFFF,
    this.metallic = 0,
    this.roughness = 0.6,
    this.emissive = 0xFF000000,
    this.doubleSided = false,
  });

  final String name;
  final MeshRole role;
  final int baseColor;
  final double metallic;
  final double roughness;
  final int emissive;
  final bool doubleSided;

  /// Materials whose name ends with `_Decal` (and all lamps/plates) sit a
  /// few millimeters above another surface. The painter's algorithm draws
  /// them after the surface under them.
  bool get drawsOnTop =>
      name.endsWith('_Decal') || isLamp || role == MeshRole.plate;

  bool get isLamp => switch (role) {
    MeshRole.tail ||
    MeshRole.brake ||
    MeshRole.turnLeft ||
    MeshRole.turnRight ||
    MeshRole.reverse ||
    MeshRole.headlight => true,
    _ => false,
  };

  MeshMaterial copyWith({MeshRole? role, int? baseColor}) => MeshMaterial(
    name: name,
    role: role ?? this.role,
    baseColor: baseColor ?? this.baseColor,
    metallic: metallic,
    roughness: roughness,
    emissive: emissive,
    doubleSided: doubleSided,
  );
}

/// Axis-aligned bounds in the vehicle frame.
class MeshBounds {
  const MeshBounds(
    this.minX,
    this.minY,
    this.minZ,
    this.maxX,
    this.maxY,
    this.maxZ,
  );

  final double minX;
  final double minY;
  final double minZ;
  final double maxX;
  final double maxY;
  final double maxZ;

  double get length => maxX - minX;
  double get width => maxY - minY;
  double get height => maxZ - minZ;
}

/// Indexed triangle mesh in the *vehicle frame*: `x` forward, `y` left,
/// `z` up, meters. After [fittedTo] the rear bumper is at x = 0, the body
/// is centered on y = 0 and the lowest point (tire contact) is z = 0.
///
/// Every vertex belongs to exactly one material (glTF primitives never
/// share vertices), so lighting can be computed per vertex.
class VehicleMesh {
  VehicleMesh({
    required this.positions,
    required this.normals,
    required this.indices,
    required this.triangleMaterials,
    required this.materials,
    this.colors,
    this.nominalSize,
  }) : assert(positions.length == normals.length),
       assert(indices.length == triangleMaterials.length * 3) {
    if (colors != null && colors!.length * 3 != positions.length) {
      throw ArgumentError('colors must have one entry per vertex');
    }
  }

  /// xyz per vertex.
  final Float32List positions;

  /// Unit normal per vertex.
  final Float32List normals;

  /// Optional per-vertex color multiplier (baked textures), 0xAARRGGBB.
  final Uint32List? colors;

  /// Three vertex indices per triangle, counter-clockwise from outside.
  final Uint32List indices;

  /// Material index per triangle.
  final Uint16List triangleMaterials;
  final List<MeshMaterial> materials;

  /// Body length/width/height the mesh stands for (meters). Mirrors and
  /// decals may stick out of it. Defaults to the bounds.
  final (double, double, double)? nominalSize;

  (double, double, double) get size =>
      nominalSize ?? (bounds.length, bounds.width, bounds.height);

  int get vertexCount => positions.length ~/ 3;
  int get triangleCount => indices.length ~/ 3;

  late final MeshBounds bounds = _computeBounds();

  /// Material index per vertex (first triangle that uses the vertex).
  late final Uint16List vertexMaterials = () {
    final out = Uint16List(vertexCount);
    final seen = Uint8List(vertexCount);
    for (var t = 0; t < triangleCount; t++) {
      for (var k = 0; k < 3; k++) {
        final v = indices[t * 3 + k];
        if (seen[v] == 0) {
          seen[v] = 1;
          out[v] = triangleMaterials[t];
        }
      }
    }
    return out;
  }();

  MeshBounds _computeBounds() {
    if (vertexCount == 0) return const MeshBounds(0, 0, 0, 0, 0, 0);
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = -double.infinity,
        maxY = -double.infinity,
        maxZ = -double.infinity;
    for (var i = 0; i < positions.length; i += 3) {
      final x = positions[i], y = positions[i + 1], z = positions[i + 2];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      if (z < minZ) minZ = z;
      if (z > maxZ) maxZ = z;
    }
    return MeshBounds(minX, minY, minZ, maxX, maxY, maxZ);
  }

  /// Copy with new materials (same geometry), for recoloring/role binding.
  VehicleMesh withMaterials(List<MeshMaterial> replacement) {
    if (replacement.length != materials.length) {
      throw ArgumentError('material count must not change');
    }
    return VehicleMesh(
      positions: positions,
      normals: normals,
      colors: colors,
      indices: indices,
      triangleMaterials: triangleMaterials,
      materials: List.unmodifiable(replacement),
      nominalSize: nominalSize,
    );
  }

  /// Places the mesh in the vehicle frame for a pack with the given
  /// dimensions (meters). The GLB's own units do not matter: the length
  /// sets one uniform scale, so mirrors and wheels keep their proportions.
  /// Width or height that would end up more than 25 % off the declared
  /// value is scaled per axis instead (authoring mistakes stay bounded).
  /// Normals use the inverse-transpose and are renormalized.
  VehicleMesh fittedTo(double length, double width, double height) {
    final b = bounds;
    if (b.length <= 0 || b.width <= 0 || b.height <= 0) {
      throw StateError('mesh has no volume');
    }
    final s = length / b.length;
    double axis(double extent, double target) =>
        ((extent * s - target).abs() / target) > 0.25 ? target / extent : s;
    final sx = s, sy = axis(b.width, width), sz = axis(b.height, height);
    final cy = (b.minY + b.maxY) / 2;
    final p = Float32List(positions.length);
    final n = Float32List(normals.length);
    for (var i = 0; i < positions.length; i += 3) {
      p[i] = (positions[i] - b.minX) * sx;
      p[i + 1] = (positions[i + 1] - cy) * sy;
      p[i + 2] = (positions[i + 2] - b.minZ) * sz;
      var nx = normals[i] / sx, ny = normals[i + 1] / sy;
      var nz = normals[i + 2] / sz;
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (len > 0) {
        nx /= len;
        ny /= len;
        nz /= len;
      } else {
        nz = 1;
      }
      n[i] = nx;
      n[i + 1] = ny;
      n[i + 2] = nz;
    }
    return VehicleMesh(
      positions: p,
      normals: n,
      colors: colors,
      indices: indices,
      triangleMaterials: triangleMaterials,
      materials: materials,
      nominalSize: (length, width, height),
    );
  }

  /// Vertex-clustering simplification down to at most [maxTriangles].
  /// Vertices are merged per grid cell, per material and per dominant
  /// normal direction, so hard edges and material borders survive.
  /// Returns this mesh when it is already small enough.
  VehicleMesh simplified(int maxTriangles) {
    if (triangleCount <= maxTriangles) return this;
    final b = bounds;
    final longest = math.max(b.length, math.max(b.width, b.height));
    var cells = 96;
    VehicleMesh? result;
    while (cells >= 2) {
      result = _cluster(longest / cells);
      if (result.triangleCount <= maxTriangles) return result;
      cells = (cells * 0.78).floor();
    }
    return result ?? this;
  }

  VehicleMesh _cluster(double cell) {
    final b = bounds;
    final vm = vertexMaterials;
    final clusterOf = Int32List(vertexCount);
    final keys = <int, int>{};
    final sums = <double>[]; // px py pz nx ny nz r g b count
    for (var v = 0; v < vertexCount; v++) {
      final x = positions[v * 3], y = positions[v * 3 + 1];
      final z = positions[v * 3 + 2];
      final nx = normals[v * 3], ny = normals[v * 3 + 1];
      final nz = normals[v * 3 + 2];
      final ix = ((x - b.minX) / cell).floor();
      final iy = ((y - b.minY) / cell).floor();
      final iz = ((z - b.minZ) / cell).floor();
      final ax = nx.abs(), ay = ny.abs(), az = nz.abs();
      final bucket = ax >= ay && ax >= az
          ? (nx >= 0 ? 0 : 1)
          : ay >= az
          ? (ny >= 0 ? 2 : 3)
          : (nz >= 0 ? 4 : 5);
      final key = (((ix * 1024 + iy) * 1024 + iz) * 8 + bucket) * 4096 + vm[v];
      var id = keys[key];
      if (id == null) {
        id = keys.length;
        keys[key] = id;
        sums.addAll(const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
      }
      clusterOf[v] = id;
      final o = id * 10;
      sums[o] += x;
      sums[o + 1] += y;
      sums[o + 2] += z;
      sums[o + 3] += nx;
      sums[o + 4] += ny;
      sums[o + 5] += nz;
      final c = colors?[v] ?? 0xFFFFFFFF;
      sums[o + 6] += (c >> 16) & 0xFF;
      sums[o + 7] += (c >> 8) & 0xFF;
      sums[o + 8] += c & 0xFF;
      sums[o + 9] += 1;
    }
    final count = keys.length;
    final p = Float32List(count * 3);
    final n = Float32List(count * 3);
    final c = colors == null ? null : Uint32List(count);
    for (var id = 0; id < count; id++) {
      final o = id * 10;
      final k = sums[o + 9];
      p[id * 3] = sums[o] / k;
      p[id * 3 + 1] = sums[o + 1] / k;
      p[id * 3 + 2] = sums[o + 2] / k;
      var nx = sums[o + 3], ny = sums[o + 4], nz = sums[o + 5];
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (len > 1e-9) {
        nx /= len;
        ny /= len;
        nz /= len;
      } else {
        nz = 1;
      }
      n[id * 3] = nx;
      n[id * 3 + 1] = ny;
      n[id * 3 + 2] = nz;
      if (c != null) {
        c[id] =
            0xFF000000 |
            ((sums[o + 6] / k).round() << 16) |
            ((sums[o + 7] / k).round() << 8) |
            (sums[o + 8] / k).round();
      }
    }
    final outIndices = <int>[];
    final outMaterials = <int>[];
    final seen = <int>{};
    for (var t = 0; t < triangleCount; t++) {
      final a = clusterOf[indices[t * 3]];
      final bb = clusterOf[indices[t * 3 + 1]];
      final cc = clusterOf[indices[t * 3 + 2]];
      if (a == bb || bb == cc || a == cc) continue;
      // Canonical rotation keeps the winding while detecting duplicates.
      final (r0, r1, r2) = a < bb && a < cc
          ? (a, bb, cc)
          : bb < cc
          ? (bb, cc, a)
          : (cc, a, bb);
      if (!seen.add((r0 * 2097152 + r1) * 2097152 + r2)) continue;
      outIndices
        ..add(a)
        ..add(bb)
        ..add(cc);
      outMaterials.add(triangleMaterials[t]);
    }
    return VehicleMesh(
      positions: p,
      normals: n,
      colors: c,
      indices: Uint32List.fromList(outIndices),
      triangleMaterials: Uint16List.fromList(outMaterials),
      materials: materials,
      nominalSize: nominalSize,
    );
  }
}

/// Three detail levels of one vehicle. The painter picks a level from the
/// vehicle's on-screen length so far cars cost a few hundred triangles.
class VehicleMeshSet {
  VehicleMeshSet({required this.lod0, required this.lod1, required this.lod2});

  /// Fits [mesh] to a pack's dimensions and derives the far levels by
  /// vertex clustering. [budget] caps the near level (per vehicle).
  factory VehicleMeshSet.fromMesh(
    VehicleMesh mesh, {
    double? length,
    double? width,
    double? height,
    int budget = renderTriangleBudget,
  }) {
    final fitted = length == null
        ? mesh
        : mesh.fittedTo(length, width ?? mesh.size.$2, height ?? mesh.size.$3);
    final lod0 = fitted.simplified(budget);
    final lod1 = lod0.simplified(math.min(lod1Triangles, budget));
    final lod2 = lod1.simplified(math.min(lod2Triangles, budget));
    return VehicleMeshSet(lod0: lod0, lod1: lod1, lod2: lod2);
  }

  /// Per-vehicle triangle budget for the software renderer.
  static const renderTriangleBudget = 20000;
  static const lod1Triangles = 1600;
  static const lod2Triangles = 360;

  /// On-screen body length (pixels) above which a level is used.
  static const lod0MinPixels = 220.0;
  static const lod1MinPixels = 48.0;

  final VehicleMesh lod0;
  final VehicleMesh lod1;
  final VehicleMesh lod2;

  VehicleMesh forScreenLength(double pixels) => pixels >= lod0MinPixels
      ? lod0
      : pixels >= lod1MinPixels
      ? lod1
      : lod2;
}
