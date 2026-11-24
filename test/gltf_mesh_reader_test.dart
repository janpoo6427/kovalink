import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/models/vehicle_model_manifest.dart';
import 'package:kovalink/src/vehicle_mesh/builtin_vehicles.dart';
import 'package:kovalink/src/vehicle_mesh/glb_writer.dart';
import 'package:kovalink/src/vehicle_mesh/gltf_mesh_reader.dart';
import 'package:kovalink/src/vehicle_mesh/vehicle_mesh.dart';
import 'package:kovalink/src/vehicle_mesh/vehicle_mesh_loader.dart';
import 'package:kovalink/src/vehicle_pack/glb_inspector.dart';
import 'package:kovalink/src/vehicle_pack/safe_zip_reader.dart';

/// Unit cube (glTF frame), 8 positions + 12 triangles, with a chosen
/// index component type. Extra JSON can be merged for edge cases.
Uint8List cubeGlb({
  int indexType = 5123,
  bool normals = false,
  List<Map<String, dynamic>>? nodes,
  Map<String, dynamic> material = const {'name': 'Paint'},
  Map<String, dynamic> extra = const {},
  Map<String, dynamic> primitiveExtra = const {},
  Map<String, dynamic> positionExtra = const {},
  bool quantized = false,
}) {
  const corners = [
    [0, 0, 0],
    [1, 0, 0],
    [1, 1, 0],
    [0, 1, 0],
    [0, 0, 1],
    [1, 0, 1],
    [1, 1, 1],
    [0, 1, 1],
  ];
  const tris = [
    0, 2, 1, 0, 3, 2, // z = 0 (back, -Z)
    4, 5, 6, 4, 6, 7, // z = 1 (front, +Z)
    0, 1, 5, 0, 5, 4, // y = 0 (bottom)
    3, 7, 6, 3, 6, 2, // y = 1 (top)
    0, 4, 7, 0, 7, 3, // x = 0
    1, 2, 6, 1, 6, 5, // x = 1
  ];
  final bin = BytesBuilder();
  void pad() {
    while (bin.length % 4 != 0) {
      bin.addByte(0);
    }
  }

  final views = <Map<String, dynamic>>[];
  final accessors = <Map<String, dynamic>>[];
  // Positions.
  final posStart = bin.length;
  if (quantized) {
    final q = Int16List(24);
    for (var i = 0; i < 24; i++) {
      q[i] = corners[i ~/ 3][i % 3] * 32767;
    }
    bin.add(q.buffer.asUint8List());
  } else {
    bin.add(
      Float32List.fromList([
        for (final c in corners) ...c.map((v) => v.toDouble()),
      ]).buffer.asUint8List(),
    );
  }
  views.add({
    'buffer': 0,
    'byteOffset': posStart,
    'byteLength': bin.length - posStart,
  });
  accessors.add({
    'bufferView': 0,
    'componentType': quantized ? 5122 : 5126,
    'normalized': quantized,
    'count': 8,
    'type': 'VEC3',
    ...positionExtra,
  });
  pad();
  // Indices.
  final idxStart = bin.length;
  bin.add(switch (indexType) {
    5121 => Uint8List.fromList(tris),
    5123 => Uint16List.fromList(tris).buffer.asUint8List(),
    _ => Uint32List.fromList(tris).buffer.asUint8List(),
  });
  views.add({
    'buffer': 0,
    'byteOffset': idxStart,
    'byteLength': bin.length - idxStart,
  });
  accessors.add({
    'bufferView': 1,
    'componentType': indexType,
    'count': tris.length,
    'type': 'SCALAR',
  });
  pad();
  if (normals) {
    final nStart = bin.length;
    bin.add(
      Float32List.fromList([
        for (final c in corners) ...[c[0] - 0.5, c[1] - 0.5, c[2] - 0.5],
      ]).buffer.asUint8List(),
    );
    views.add({
      'buffer': 0,
      'byteOffset': nStart,
      'byteLength': bin.length - nStart,
    });
    accessors.add({
      'bufferView': 2,
      'componentType': 5126,
      'count': 8,
      'type': 'VEC3',
    });
  }
  final binBytes = bin.takeBytes();
  final gltf = <String, dynamic>{
    'asset': {'version': '2.0'},
    'nodes':
        nodes ??
        [
          {'name': 'Body', 'mesh': 0},
        ],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': {'POSITION': 0, if (normals) 'NORMAL': 2},
            'indices': 1,
            'material': 0,
            ...primitiveExtra,
          },
        ],
      },
    ],
    'materials': [material],
    'accessors': accessors,
    'bufferViews': views,
    'buffers': [
      {'byteLength': binBytes.length},
    ],
    ...extra,
  };
  var json = utf8.encode(jsonEncode(gltf));
  json = Uint8List.fromList([
    ...json,
    ...List.filled((4 - json.length % 4) % 4, 0x20),
  ]);
  final header = ByteData(20)
    ..setUint32(0, 0x46546C67, Endian.little)
    ..setUint32(4, 2, Endian.little)
    ..setUint32(8, 20 + json.length + 8 + binBytes.length, Endian.little)
    ..setUint32(12, json.length, Endian.little)
    ..setUint32(16, 0x4E4F534A, Endian.little);
  final chunk = ByteData(8)
    ..setUint32(0, binBytes.length, Endian.little)
    ..setUint32(4, 0x004E4942, Endian.little);
  return Uint8List.fromList([
    ...header.buffer.asUint8List(),
    ...json,
    ...chunk.buffer.asUint8List(),
    ...binBytes,
  ]);
}

String rejection(void Function() body) {
  try {
    body();
  } on ModelPackRejection catch (error) {
    return error.code;
  }
  return 'accepted';
}

void main() {
  group('glTF mesh reader', () {
    for (final type in const [5121, 5123, 5125]) {
      test('reads uint${type == 5121
              ? 8
              : type == 5123
              ? 16
              : 32} indices '
          'and maps glTF axes to the vehicle frame', () {
        final data = GltfMeshReader.read(cubeGlb(indexType: type));
        final mesh = data.mesh;
        expect(mesh.triangleCount, 12);
        // glTF +Z forward → x, +X left → y, +Y up → z.
        final b = mesh.bounds;
        expect(
          [b.minX, b.maxX, b.minY, b.maxY, b.minZ, b.maxZ],
          [0, 1, 0, 1, 0, 1],
        );
        expect(data.hasTextures, isFalse);
        // Computed normals point outward (cube centered at 0.5).
        for (var v = 0; v < mesh.vertexCount; v++) {
          final d =
              (mesh.positions[v * 3] - 0.5) * mesh.normals[v * 3] +
              (mesh.positions[v * 3 + 1] - 0.5) * mesh.normals[v * 3 + 1] +
              (mesh.positions[v * 3 + 2] - 0.5) * mesh.normals[v * 3 + 2];
          expect(d, greaterThan(0));
        }
      });
    }

    test(
      'applies the node hierarchy (TRS and matrix) and skips excluded nodes',
      () {
        final data = GltfMeshReader.read(
          cubeGlb(
            nodes: [
              {
                'name': 'Root',
                'translation': [0, 0, 10],
                'scale': [2, 2, 2],
                'children': [1, 2],
              },
              {
                'name': 'Wheel',
                'mesh': 0,
                // 90° about +Y: glTF +X goes to -Z.
                'rotation': [
                  0,
                  math.sin(math.pi / 4),
                  0,
                  math.cos(math.pi / 4),
                ],
              },
              {
                'name': 'Stand',
                'mesh': 0,
                'matrix': [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 50, 0, 0, 1],
              },
            ],
            extra: {
              'scenes': [
                {
                  'nodes': [0],
                },
              ],
            },
          ),
          options: const GltfReadOptions(excludeNodes: {'Stand'}),
        );
        expect(data.mesh.triangleCount, 12);
        final b = data.mesh.bounds;
        // Wheel: rotated cube spans glTF x 0..2, z 8..10 after scale+translate.
        expect(b.minX, closeTo(8, 1e-5));
        expect(b.maxX, closeTo(10, 1e-5));
        expect(b.minY, closeTo(0, 1e-5));
        expect(b.maxY, closeTo(2, 1e-5));
        expect(b.maxZ, closeTo(2, 1e-5));
      },
    );

    test('mirrored transforms flip the winding back to outward', () {
      final plain = GltfMeshReader.read(cubeGlb()).mesh;
      final mirrored = GltfMeshReader.read(
        cubeGlb(
          nodes: [
            {
              'name': 'Body',
              'mesh': 0,
              'scale': [-1, 1, 1],
            },
          ],
        ),
      ).mesh;
      double outward(VehicleMesh m) {
        var sum = 0.0;
        final cy = (m.bounds.minY + m.bounds.maxY) / 2;
        for (var t = 0; t < m.triangleCount; t++) {
          final p = [
            for (var k = 0; k < 3; k++)
              [
                for (var a = 0; a < 3; a++)
                  m.positions[m.indices[t * 3 + k] * 3 + a],
              ],
          ];
          final u = [for (var a = 0; a < 3; a++) p[1][a] - p[0][a]];
          final w = [for (var a = 0; a < 3; a++) p[2][a] - p[0][a]];
          final n = [
            u[1] * w[2] - u[2] * w[1],
            u[2] * w[0] - u[0] * w[2],
            u[0] * w[1] - u[1] * w[0],
          ];
          final c = [
            for (var a = 0; a < 3; a++) (p[0][a] + p[1][a] + p[2][a]) / 3,
          ];
          sum += n[0] * (c[0] - 0.5) + n[1] * (c[1] - cy) + n[2] * (c[2] - 0.5);
        }
        return sum;
      }

      expect(outward(plain), greaterThan(0));
      expect(outward(mirrored), greaterThan(0));
    });

    test('reads factors, binds roles and uses KovaLink standard names', () {
      final data = GltfMeshReader.read(
        cubeGlb(
          normals: true,
          material: {
            'name': 'CarPaint',
            'pbrMetallicRoughness': {
              'baseColorFactor': [0.214, 0.214, 0.214, 1],
              'metallicFactor': 0.4,
              'roughnessFactor': 0.3,
            },
            'emissiveFactor': [1, 0, 0],
          },
        ),
        options: const GltfReadOptions(
          materialRoles: {'CarPaint': MeshRole.paint},
        ),
      );
      final m = data.mesh.materials.single;
      expect(m.role, MeshRole.paint);
      // Linear 0.214 ≈ sRGB 128.
      expect((m.baseColor >> 16) & 0xFF, closeTo(128, 1));
      expect(m.metallic, closeTo(0.4, 1e-9));
      expect(m.roughness, closeTo(0.3, 1e-9));
      expect(m.emissive, 0xFFFF0000);
      final standard = GltfMeshReader.read(
        cubeGlb(material: const {'name': 'KL_Plate_Decal'}),
      );
      expect(standard.mesh.materials.single.role, MeshRole.plate);
      expect(standard.mesh.materials.single.drawsOnTop, isTrue);
    });

    test('node bindings light whole nodes (turn signals by node name)', () {
      final data = GltfMeshReader.read(
        cubeGlb(
          nodes: [
            {'name': 'Turn_L', 'mesh': 0},
          ],
        ),
        options: const GltfReadOptions(
          nodeRoles: {'Turn_L': MeshRole.turnLeft},
        ),
      );
      expect(data.mesh.materials.single.role, MeshRole.turnLeft);
    });

    test('KHR_mesh_quantization: normalized int16 positions', () {
      final data = GltfMeshReader.read(
        cubeGlb(
          quantized: true,
          extra: {
            'extensionsUsed': ['KHR_mesh_quantization'],
            'extensionsRequired': ['KHR_mesh_quantization'],
          },
        ),
      );
      expect(data.mesh.bounds.maxX, closeTo(1, 1e-4));
    });

    test('refuses compression, external URIs, sparse data and bad indices', () {
      expect(
        rejection(
          () => GltfMeshReader.read(
            cubeGlb(
              extra: {
                'extensionsUsed': ['KHR_draco_mesh_compression'],
              },
            ),
          ),
        ),
        'glb-compressed',
      );
      expect(
        rejection(
          () => GltfMeshReader.read(
            cubeGlb(
              primitiveExtra: {
                'extensions': {
                  'KHR_draco_mesh_compression': {
                    'bufferView': 0,
                    'attributes': {},
                  },
                },
              },
            ),
          ),
        ),
        'glb-compressed',
      );
      expect(
        rejection(
          () => GltfMeshReader.read(
            cubeGlb(
              extra: {
                'extensionsUsed': ['EXT_meshopt_compression'],
              },
            ),
          ),
        ),
        'glb-compressed',
      );
      expect(
        rejection(
          () => GltfMeshReader.read(
            cubeGlb(
              extra: {
                'buffers': [
                  {'byteLength': 4, 'uri': 'car.bin'},
                ],
              },
            ),
          ),
        ),
        'external-uri',
      );
      expect(
        rejection(
          () => GltfMeshReader.read(
            cubeGlb(
              positionExtra: {
                'sparse': {'count': 1},
              },
            ),
          ),
        ),
        'glb-unsupported',
      );
      expect(
        rejection(
          () => GltfMeshReader.read(cubeGlb(positionExtra: {'count': 4})),
        ),
        'glb-invalid',
      );
      expect(
        rejection(() => GltfMeshReader.read(Uint8List.fromList([1, 2, 3]))),
        'glb-invalid',
      );
    });

    test('the import inspector refuses Draco with the same reason', () {
      final glb = cubeGlb(
        extra: {
          'extensionsUsed': ['KHR_draco_mesh_compression'],
        },
      );
      expect(rejection(() => GlbInspector.inspect(glb)), 'glb-compressed');
      try {
        GlbInspector.inspect(glb);
      } on ModelPackRejection catch (error) {
        expect(error.message, contains('Draco'));
      }
    });

    test('inspector warns above the 20k render budget', () {
      // Header-only GLB: triangle count comes from the index accessor.
      final glb = cubeGlb(
        extra: {
          'accessors': [
            {
              'bufferView': 0,
              'componentType': 5126,
              'count': 8,
              'type': 'VEC3',
            },
            {
              'bufferView': 1,
              'componentType': 5125,
              'count': 3 * 30000,
              'type': 'SCALAR',
            },
          ],
        },
      );
      final report = GlbInspector.inspect(glb);
      expect(report.triangles, 30000);
      expect(report.warnings.single, contains('20000'));
    });
  });

  group('GLB writer and bundled packs', () {
    test('built-in SUV round-trips through GLB with named nodes', () {
      final builder = BuiltinVehicles.builderFor(BuiltinBody.suv);
      final bytes = GlbWriter.write(
        builder,
        rearAxleX: BuiltinVehicles.suvRearAxleX,
      );
      final report = GlbInspector.inspect(bytes);
      expect(
        report.nodeNames,
        containsAll(['Body', 'Wheel_FL', 'Wheel_FR', 'Wheel_RL', 'Wheel_RR']),
      );
      expect(
        report.materialNames,
        containsAll(['KL_BodyPaint', 'KL_Glass', 'KL_Brake', 'KL_Tail']),
      );
      final read = GltfMeshReader.read(bytes).mesh;
      final source = BuiltinVehicles.suv;
      expect(read.triangleCount, source.triangleCount);
      expect(read.bounds.minX, closeTo(source.bounds.minX - 0.95, 1e-4));
      expect(read.bounds.maxX, closeTo(source.bounds.maxX - 0.95, 1e-4));
      expect(read.bounds.maxZ, closeTo(source.bounds.maxZ, 1e-4));
      expect(read.bounds.width, closeTo(source.bounds.width, 1e-4));
      // Colors survive the linear round trip.
      final paint = read.materials.firstWhere((m) => m.name == 'KL_BodyPaint');
      expect(paint.role, MeshRole.paint);
      expect(paint.baseColor, BuiltinVehicles.paint.baseColor);
    });

    test('bundled kovalink_basic GLB is exactly the generator output', () {
      final bytes = GlbWriter.write(
        BuiltinVehicles.builderFor(BuiltinBody.suv),
        rearAxleX: BuiltinVehicles.suvRearAxleX,
      );
      final asset = File(
        'assets/vehicles/kovalink_basic/vehicle.glb',
      ).readAsBytesSync();
      expect(
        asset,
        bytes,
        reason: 'run dart run tool/make_builtin_vehicles.dart',
      );
    });

    test(
      'Khronos ToyCar loads through the same pipeline under the budget',
      () async {
        final manifest = VehicleModelManifest.fromJson(
          jsonDecode(
                File('assets/vehicles/toy_car/vehicle.json').readAsStringSync(),
              )
              as Map<String, dynamic>,
        );
        expect(manifest.excludeNodes, ['Fabric']);
        final bytes = File(
          'assets/vehicles/toy_car/vehicle.glb',
        ).readAsBytesSync();
        final data = GltfMeshReader.read(
          bytes,
          options: VehicleMeshLoader.optionsFor(manifest),
        );
        expect(
          data.mesh.triangleCount,
          greaterThan(VehicleMeshSet.renderTriangleBudget),
        );
        expect(data.hasTextures, isTrue);
        // Forward (x) is the longest axis once the display cloth is left out.
        final b = data.mesh.bounds;
        expect(b.length, greaterThan(b.width));
        expect(b.width, greaterThan(b.height));
        final set = VehicleMeshSet.fromMesh(
          data.mesh,
          length: manifest.dimensions.length,
          width: manifest.dimensions.width,
          height: manifest.dimensions.height,
        );
        expect(
          set.lod0.triangleCount,
          lessThanOrEqualTo(VehicleMeshSet.renderTriangleBudget),
        );
        expect(set.lod0.bounds.length, closeTo(4.5, 0.05));
        expect(
          set.lod2.triangleCount,
          lessThanOrEqualTo(VehicleMeshSet.lod2Triangles),
        );
      },
    );
  });
}
