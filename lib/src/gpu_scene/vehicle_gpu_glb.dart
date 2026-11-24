import 'dart:math' as math;
import 'dart:typed_data';

import 'package:kovalink/src/gpu_scene/gltf_scene_builder.dart';
import 'package:kovalink/src/vehicle_mesh/mesh_builder.dart';
import 'package:kovalink/src/vehicle_mesh/vehicle_mesh.dart';

/// Physically based material set for the GPU (Filament) renderer, keyed by
/// [MeshRole]. Paint gets a clearcoat layer, glass is a thin transparent
/// reflective layer and lamps are emissive so bloom can pick them up.
class GpuMaterials {
  const GpuMaterials._();

  /// glTF material JSON for a vehicle [MeshMaterial].
  static Map<String, Object?> vehicle(MeshMaterial m) {
    final base = GltfSceneBuilder.linear(m.baseColor);
    switch (m.role) {
      case MeshRole.paint:
        return {
          'name': m.name,
          'pbrMetallicRoughness': {
            'baseColorFactor': [...base, 1.0],
            'metallicFactor': 0.2,
            'roughnessFactor': 0.32,
          },
          'extensions': {
            'KHR_materials_clearcoat': {
              'clearcoatFactor': 1.0,
              'clearcoatRoughnessFactor': 0.03,
            },
          },
        };
      case MeshRole.glass:
        return {
          'name': m.name,
          'alphaMode': 'BLEND',
          'doubleSided': false,
          'pbrMetallicRoughness': {
            'baseColorFactor': [0.012, 0.016, 0.022, 0.8],
            'metallicFactor': 0.0,
            'roughnessFactor': 0.08,
          },
          'extensions': {
            'KHR_materials_clearcoat': {
              'clearcoatFactor': 1.0,
              'clearcoatRoughnessFactor': 0.0,
            },
          },
        };
      case MeshRole.tail ||
          MeshRole.brake ||
          MeshRole.turnLeft ||
          MeshRole.turnRight ||
          MeshRole.reverse ||
          MeshRole.headlight:
        return {
          'name': m.name,
          'pbrMetallicRoughness': {
            'baseColorFactor': [...base, 1.0],
            'metallicFactor': 0.0,
            'roughnessFactor': 0.12,
          },
          'emissiveFactor': lampColor(m.role),
          'extensions': {
            'KHR_materials_emissive_strength': {
              'emissiveStrength': lampStrength(m.role, on: false),
            },
          },
        };
      case MeshRole.plate:
        return {
          'name': m.name,
          'pbrMetallicRoughness': {
            'baseColorFactor': [...base, 1.0],
            'metallicFactor': 0.0,
            'roughnessFactor': 0.45,
          },
          'emissiveFactor': const [0.18, 0.18, 0.18],
        };
      case MeshRole.rim || MeshRole.chrome:
        return {
          'name': m.name,
          'pbrMetallicRoughness': {
            'baseColorFactor': [...base, 1.0],
            'metallicFactor': 1.0,
            'roughnessFactor': math.max(0.18, m.roughness),
          },
        };
      case MeshRole.tire:
        return {
          'name': m.name,
          'pbrMetallicRoughness': {
            'baseColorFactor': [...base, 1.0],
            'metallicFactor': 0.0,
            'roughnessFactor': 0.88,
          },
        };
      case MeshRole.trim || MeshRole.other:
        return {
          'name': m.name,
          'pbrMetallicRoughness': {
            'baseColorFactor': [...base, 1.0],
            'metallicFactor': m.metallic,
            'roughnessFactor': m.roughness,
          },
          if (m.emissive & 0xFFFFFF != 0)
            'emissiveFactor': GltfSceneBuilder.linear(m.emissive),
        };
    }
  }

  /// Linear emissive color of a lamp role.
  static List<double> lampColor(MeshRole role) => switch (role) {
    MeshRole.headlight => const [0.92, 0.96, 1.0],
    MeshRole.turnLeft || MeshRole.turnRight => const [1.0, 0.42, 0.04],
    MeshRole.reverse => const [0.95, 0.95, 0.95],
    _ => const [1.0, 0.035, 0.05],
  };

  /// Emissive strength of a lamp role when [on] (lit) or idle.
  static double lampStrength(MeshRole role, {required bool on}) =>
      switch (role) {
        MeshRole.tail => on ? 2.2 : 0.45,
        MeshRole.brake => on ? 4.0 : 0.05,
        MeshRole.turnLeft || MeshRole.turnRight => on ? 6.0 : 0.0,
        MeshRole.reverse => on ? 4.0 : 0.0,
        MeshRole.headlight => on ? 5.0 : 0.25,
        _ => 0,
      };
}

/// A GPU vehicle GLB and what the renderer needs to animate it.
class VehicleGpuAsset {
  const VehicleGpuAsset({
    required this.glb,
    required this.roles,
    required this.wheelPivots,
    required this.length,
    required this.width,
    required this.height,
    required this.rearX,
  });

  final Uint8List glb;

  /// Node name → material role of each primitive, in primitive order.
  final Map<String, List<MeshRole>> roles;

  /// Wheel node name → pivot (glTF frame, node translation).
  final Map<String, List<double>> wheelPivots;
  final double length;
  final double width;
  final double height;

  /// Rear bumper position along glTF +Z (forward), meters.
  final double rearX;
}

/// Converts a vehicle [MeshBuilder] into a GLB for the GPU renderer:
/// smooth (crease-angle) normals, [GpuMaterials] and one node per part
/// with wheels pivoted at their centers so they can spin and steer.
///
/// Frame: glTF (+Y up, +Z forward, +X left), origin on the ground at the
/// rear axle — the same as docs/VEHICLE_MODEL_PACK.md.
class VehicleGpuGlb {
  const VehicleGpuGlb._();

  static Uint8List write(
    MeshBuilder builder, {
    required double rearAxleX,
    double creaseDegrees = 40,
  }) => build(builder, rearAxleX: rearAxleX, creaseDegrees: creaseDegrees).glb;

  /// Like [write], also returning which material role each node primitive
  /// uses and the wheel pivots, so a renderer can recolor paint, light
  /// lamps and spin wheels per instance.
  static VehicleGpuAsset build(
    MeshBuilder builder, {
    required double rearAxleX,
    double creaseDegrees = 40,
  }) {
    final mesh = builder.build();
    final roles = <String, List<MeshRole>>{};
    final wheels = <String, List<double>>{};
    var lo = [double.infinity, double.infinity, double.infinity];
    var hi = [-double.infinity, -double.infinity, -double.infinity];
    for (var i = 0; i < mesh.positions.length; i++) {
      lo[i % 3] = math.min(lo[i % 3], mesh.positions[i]);
      hi[i % 3] = math.max(hi[i % 3], mesh.positions[i]);
    }
    final parts = builder.triangleParts;
    final out = GltfSceneBuilder();
    final materialIds = [
      for (final m in mesh.materials) out.material(GpuMaterials.vehicle(m)),
    ];
    final cosCrease = math.cos(creaseDegrees * math.pi / 180);

    // glTF frame from the vehicle frame (x fwd, y left, z up).
    (double, double, double) g(int v) => (
      mesh.positions[v * 3 + 1],
      mesh.positions[v * 3 + 2],
      mesh.positions[v * 3] - rearAxleX,
    );

    for (var part = 0; part < builder.parts.length; part++) {
      final tris = [
        for (var t = 0; t < mesh.triangleCount; t++)
          if (parts[t] == part) t,
      ];
      if (tris.isEmpty) continue;
      final name = builder.parts[part];
      var ox = 0.0, oy = 0.0, oz = 0.0;
      if (name.startsWith('Wheel')) {
        var lo = [double.infinity, double.infinity, double.infinity];
        var hi = [-double.infinity, -double.infinity, -double.infinity];
        for (final t in tris) {
          for (var k = 0; k < 3; k++) {
            final p = g(mesh.indices[t * 3 + k]);
            final a = [p.$1, p.$2, p.$3];
            for (var i = 0; i < 3; i++) {
              lo[i] = math.min(lo[i], a[i]);
              hi[i] = math.max(hi[i], a[i]);
            }
          }
        }
        ox = (lo[0] + hi[0]) / 2;
        oy = (lo[1] + hi[1]) / 2;
        oz = (lo[2] + hi[2]) / 2;
      }
      final prims = <GltfPrimitive>[];
      final byMaterial = <int, List<int>>{};
      for (final t in tris) {
        byMaterial.putIfAbsent(mesh.triangleMaterials[t], () => []).add(t);
      }
      final keys = byMaterial.keys.toList()..sort();
      for (final mat in keys) {
        prims.add(
          _smoothPrimitive(
            mesh,
            byMaterial[mat]!,
            g,
            (ox, oy, oz),
            cosCrease,
            materialIds[mat],
          ),
        );
      }
      final meshId = out.mesh(name, prims);
      out.node(name, mesh: meshId, translation: [ox, oy, oz]);
      roles[name] = [for (final mat in keys) mesh.materials[mat].role];
      if (name.startsWith('Wheel')) wheels[name] = [ox, oy, oz];
    }
    return VehicleGpuAsset(
      glb: out.toGlb(generator: 'KovaLink gpu vehicle'),
      roles: roles,
      wheelPivots: wheels,
      length: hi[0] - lo[0],
      width: hi[1] - lo[1],
      height: hi[2] - lo[2],
      rearX: lo[0] - rearAxleX,
    );
  }

  static GltfPrimitive _smoothPrimitive(
    VehicleMesh mesh,
    List<int> tris,
    (double, double, double) Function(int) g,
    (double, double, double) origin,
    double cosCrease,
    int material,
  ) {
    // Face normals (glTF frame) and area weights.
    final fn = Float64List(tris.length * 3);
    final corners = <(double, double, double)>[];
    for (var i = 0; i < tris.length; i++) {
      final t = tris[i];
      final a = g(mesh.indices[t * 3]);
      final b = g(mesh.indices[t * 3 + 1]);
      final c = g(mesh.indices[t * 3 + 2]);
      corners
        ..add(a)
        ..add(b)
        ..add(c);
      final ux = b.$1 - a.$1, uy = b.$2 - a.$2, uz = b.$3 - a.$3;
      final vx = c.$1 - a.$1, vy = c.$2 - a.$2, vz = c.$3 - a.$3;
      var nx = uy * vz - uz * vy;
      var ny = uz * vx - ux * vz;
      var nz = ux * vy - uy * vx;
      // Keep the authored orientation: agree with the stored normal.
      final v0 = mesh.indices[t * 3];
      final sx = mesh.normals[v0 * 3 + 1];
      final sy = mesh.normals[v0 * 3 + 2];
      final sz = mesh.normals[v0 * 3];
      if (nx * sx + ny * sy + nz * sz < 0) {
        nx = -nx;
        ny = -ny;
        nz = -nz;
      }
      fn[i * 3] = nx;
      fn[i * 3 + 1] = ny;
      fn[i * 3 + 2] = nz;
    }
    String key((double, double, double) p) =>
        '${(p.$1 * 2000).round()},${(p.$2 * 2000).round()},${(p.$3 * 2000).round()}';
    final shared = <String, List<int>>{};
    for (var c = 0; c < corners.length; c++) {
      shared.putIfAbsent(key(corners[c]), () => []).add(c);
    }
    final positions = Float32List(corners.length * 3);
    final normals = Float32List(corners.length * 3);
    final indices = Uint32List(corners.length);
    for (var c = 0; c < corners.length; c++) {
      final f = c ~/ 3;
      final fx = fn[f * 3], fy = fn[f * 3 + 1], fz = fn[f * 3 + 2];
      final fl = math.sqrt(fx * fx + fy * fy + fz * fz);
      var nx = 0.0, ny = 0.0, nz = 0.0;
      for (final other in shared[key(corners[c])]!) {
        final o = other ~/ 3;
        final ox = fn[o * 3], oy = fn[o * 3 + 1], oz = fn[o * 3 + 2];
        final ol = math.sqrt(ox * ox + oy * oy + oz * oz);
        if (fl < 1e-14 || ol < 1e-14) continue;
        if ((fx * ox + fy * oy + fz * oz) / (fl * ol) < cosCrease) continue;
        nx += ox;
        ny += oy;
        nz += oz;
      }
      var l = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (l < 1e-14) {
        nx = fx;
        ny = fy;
        nz = fz;
        l = math.max(fl, 1e-14);
      }
      final p = corners[c];
      positions[c * 3] = p.$1 - origin.$1;
      positions[c * 3 + 1] = p.$2 - origin.$2;
      positions[c * 3 + 2] = p.$3 - origin.$3;
      normals[c * 3] = nx / l;
      normals[c * 3 + 1] = ny / l;
      normals[c * 3 + 2] = nz / l;
      indices[c] = c;
    }
    return GltfPrimitive(
      positions: positions,
      normals: normals,
      indices: indices,
      material: material,
    );
  }
}
