import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:kovalink/src/vehicle_mesh/mesh_builder.dart';

/// Writes a [MeshBuilder] as a self-contained glTF 2.0 binary that follows
/// docs/VEHICLE_MODEL_PACK.md: meters, +Y up, +Z forward, +X left (glTF
/// convention), origin on the ground between the rear wheels. One node per
/// builder part (`Body`, `Wheel_FL`, …); wheel nodes are translated to the
/// wheel center so a renderer can spin them. Output is deterministic.
class GlbWriter {
  const GlbWriter._();

  static Uint8List write(
    MeshBuilder builder, {
    required double rearAxleX,
    String generator = 'KovaLink builtin_vehicles',
  }) {
    final mesh = builder.build();
    final parts = builder.triangleParts;
    final bin = BytesBuilder();
    final accessors = <Map<String, Object>>[];
    final views = <Map<String, Object>>[];
    final meshes = <Map<String, Object>>[];
    final nodes = <Map<String, Object>>[];

    int addView(Uint8List bytes, {int? target}) {
      while (bin.length % 4 != 0) {
        bin.addByte(0);
      }
      views.add({
        'buffer': 0,
        'byteOffset': bin.length,
        'byteLength': bytes.length,
        'target': ?target,
      });
      bin.add(bytes);
      return views.length - 1;
    }

    // glTF frame from the vehicle frame.
    List<double> g(int v) => [
      mesh.positions[v * 3 + 1],
      mesh.positions[v * 3 + 2],
      mesh.positions[v * 3] - rearAxleX,
    ];
    List<double> gn(int v) => [
      mesh.normals[v * 3 + 1],
      mesh.normals[v * 3 + 2],
      mesh.normals[v * 3],
    ];

    for (var part = 0; part < builder.parts.length; part++) {
      final tris = [
        for (var t = 0; t < mesh.triangleCount; t++)
          if (parts[t] == part) t,
      ];
      if (tris.isEmpty) continue;
      // Node origin: wheel center for wheels, pack origin for the body.
      var origin = const [0.0, 0.0, 0.0];
      if (builder.parts[part].startsWith('Wheel')) {
        final lo = [double.infinity, double.infinity, double.infinity];
        final hi = [-double.infinity, -double.infinity, -double.infinity];
        for (final t in tris) {
          for (var k = 0; k < 3; k++) {
            final p = g(mesh.indices[t * 3 + k]);
            for (var a = 0; a < 3; a++) {
              lo[a] = math.min(lo[a], p[a]);
              hi[a] = math.max(hi[a], p[a]);
            }
          }
        }
        origin = [for (var a = 0; a < 3; a++) (lo[a] + hi[a]) / 2];
      }
      final primitives = <Map<String, Object>>[];
      final materialIds = {
        for (final t in tris) mesh.triangleMaterials[t],
      }.toList()..sort();
      for (final material in materialIds) {
        final remap = <int, int>{};
        final pos = <double>[];
        final nrm = <double>[];
        final idx = <int>[];
        for (final t in tris) {
          if (mesh.triangleMaterials[t] != material) continue;
          for (var k = 0; k < 3; k++) {
            final v = mesh.indices[t * 3 + k];
            idx.add(
              remap.putIfAbsent(v, () {
                final p = g(v);
                pos.addAll([for (var a = 0; a < 3; a++) p[a] - origin[a]]);
                nrm.addAll(gn(v));
                return remap.length;
              }),
            );
          }
        }
        final lo = [double.infinity, double.infinity, double.infinity];
        final hi = [-double.infinity, -double.infinity, -double.infinity];
        for (var i = 0; i < pos.length; i++) {
          final f = Float32List.fromList([pos[i]])[0];
          lo[i % 3] = math.min(lo[i % 3], f);
          hi[i % 3] = math.max(hi[i % 3], f);
        }
        final count = pos.length ~/ 3;
        final posView = addView(
          Float32List.fromList(pos).buffer.asUint8List(),
          target: 34962,
        );
        accessors.add({
          'bufferView': posView,
          'componentType': 5126,
          'count': count,
          'type': 'VEC3',
          'min': lo,
          'max': hi,
        });
        final posAccessor = accessors.length - 1;
        final nrmView = addView(
          Float32List.fromList(nrm).buffer.asUint8List(),
          target: 34962,
        );
        accessors.add({
          'bufferView': nrmView,
          'componentType': 5126,
          'count': count,
          'type': 'VEC3',
        });
        final nrmAccessor = accessors.length - 1;
        final small = count < 65536;
        final idxView = addView(
          small
              ? Uint16List.fromList(idx).buffer.asUint8List()
              : Uint32List.fromList(idx).buffer.asUint8List(),
          target: 34963,
        );
        accessors.add({
          'bufferView': idxView,
          'componentType': small ? 5123 : 5125,
          'count': idx.length,
          'type': 'SCALAR',
        });
        primitives.add({
          'attributes': {'POSITION': posAccessor, 'NORMAL': nrmAccessor},
          'indices': accessors.length - 1,
          'material': material,
          'mode': 4,
        });
      }
      meshes.add({'name': builder.parts[part], 'primitives': primitives});
      nodes.add({
        'name': builder.parts[part],
        'mesh': meshes.length - 1,
        if (origin.any((v) => v != 0)) 'translation': origin,
      });
    }

    final materials = [
      for (final m in builder.materials)
        {
          'name': m.name,
          'pbrMetallicRoughness': {
            'baseColorFactor': [..._linear(m.baseColor), 1.0],
            'metallicFactor': m.metallic,
            'roughnessFactor': m.roughness,
          },
          if (m.emissive & 0xFFFFFF != 0) 'emissiveFactor': _linear(m.emissive),
        },
    ];
    while (bin.length % 4 != 0) {
      bin.addByte(0);
    }
    final binBytes = bin.takeBytes();
    final gltf = {
      'asset': {
        'version': '2.0',
        'generator': generator,
        'copyright': 'CC0-1.0 KovaLink project',
      },
      'scene': 0,
      'scenes': [
        {
          'nodes': [for (var i = 0; i < nodes.length; i++) i],
        },
      ],
      'nodes': nodes,
      'meshes': meshes,
      'materials': materials,
      'accessors': accessors,
      'bufferViews': views,
      'buffers': [
        {'byteLength': binBytes.length},
      ],
    };
    var json = utf8.encode(jsonEncode(gltf));
    json = Uint8List.fromList([
      ...json,
      ...List.filled((4 - json.length % 4) % 4, 0x20),
    ]);
    final total = 12 + 8 + json.length + 8 + binBytes.length;
    final header = ByteData(20)
      ..setUint32(0, 0x46546C67, Endian.little)
      ..setUint32(4, 2, Endian.little)
      ..setUint32(8, total, Endian.little)
      ..setUint32(12, json.length, Endian.little)
      ..setUint32(16, 0x4E4F534A, Endian.little);
    final binHeader = ByteData(8)
      ..setUint32(0, binBytes.length, Endian.little)
      ..setUint32(4, 0x004E4942, Endian.little);
    return Uint8List.fromList([
      ...header.buffer.asUint8List(),
      ...json,
      ...binHeader.buffer.asUint8List(),
      ...binBytes,
    ]);
  }

  /// sRGB ARGB → linear RGB factors (glTF colors are linear), rounded so
  /// the file is stable across platforms.
  static List<double> _linear(int argb) {
    double channel(int shift) {
      final c = ((argb >> shift) & 0xFF) / 255.0;
      final l = c <= 0.04045
          ? c / 12.92
          : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
      return (l * 1e6).round() / 1e6;
    }

    return [channel(16), channel(8), channel(0)];
  }
}
