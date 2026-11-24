import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:kovalink/src/models/vehicle_model_manifest.dart';
import 'package:kovalink/src/vehicle_mesh/gltf_mesh_reader.dart';
import 'package:kovalink/src/vehicle_mesh/vehicle_mesh.dart';
import 'package:kovalink/src/vehicle_pack/safe_zip_reader.dart';

/// Loads a pack's GLB into [VehicleMeshSet] levels for the road renderer.
///
/// Parsing and level building run in a background isolate; base color
/// textures (optional) are decoded with the engine's image codec at a
/// small size and baked into vertex colors. Never throws: problems come
/// back as user-facing warnings and a null set (= built-in model).
class VehicleMeshLoader {
  const VehicleMeshLoader._();

  /// Longest side of a texture after decoding for vertex baking.
  static const bakeTextureSize = 256;

  static GltfReadOptions optionsFor(VehicleModelManifest manifest) {
    final m = manifest.materials;
    final n = manifest.nodes;
    return GltfReadOptions(
      materialRoles: {
        ?m.bodyPaint: MeshRole.paint,
        ?m.glass: MeshRole.glass,
        ?m.tailLights: MeshRole.tail,
        ?m.brakeLights: MeshRole.brake,
        ?m.leftTurnSignals: MeshRole.turnLeft,
        ?m.rightTurnSignals: MeshRole.turnRight,
        ?m.reverseLights: MeshRole.reverse,
      },
      nodeRoles: {
        for (final name in n.brakeLights) name: MeshRole.brake,
        for (final name in n.leftTurnSignals) name: MeshRole.turnLeft,
        for (final name in n.rightTurnSignals) name: MeshRole.turnRight,
        for (final name in n.reverseLights) name: MeshRole.reverse,
      },
      excludeNodes: manifest.excludeNodes.toSet(),
    );
  }

  /// Reads the GLB behind [glbAssetPath] (Flutter asset or `file://`).
  static Future<VehicleMeshLoad> load(
    String? glbAssetPath,
    VehicleModelManifest manifest, {
    AssetBundle? bundle,
  }) async {
    if (glbAssetPath == null) return const VehicleMeshLoad(null, []);
    final Uint8List bytes;
    try {
      bytes = glbAssetPath.startsWith('file://')
          ? await File(glbAssetPath.substring(7)).readAsBytes()
          : (await (bundle ?? rootBundle).load(
              glbAssetPath,
            )).buffer.asUint8List();
    } on Object catch (error) {
      return VehicleMeshLoad(null, ['GLB를 읽을 수 없어 기본 차량 모양으로 그립니다: $error']);
    }
    return fromBytes(bytes, manifest);
  }

  static Future<VehicleMeshLoad> fromBytes(
    Uint8List bytes,
    VehicleModelManifest manifest, {
    bool background = true,
  }) async {
    final options = optionsFor(manifest);
    final d = manifest.dimensions;
    try {
      final data = background
          ? await compute(_read, (bytes, options))
          : _read((bytes, options));
      var mesh = data.mesh;
      final warnings = [...data.warnings];
      if (data.hasTextures) {
        final baked = await bakeTextures(data);
        mesh = baked.$1;
        warnings.addAll(baked.$2);
      }
      final args = (mesh, d.length, d.width, d.height);
      final set = background ? await compute(_levels, args) : _levels(args);
      if (mesh.triangleCount > VehicleMeshSet.renderTriangleBudget) {
        warnings.add(
          '삼각형 ${mesh.triangleCount}개를 화면용으로 ${set.lod0.triangleCount}개까지 '
          '단순화했습니다(차량당 상한 ${VehicleMeshSet.renderTriangleBudget}).',
        );
      }
      return VehicleMeshLoad(set, List.unmodifiable(warnings));
    } on ModelPackRejection catch (rejection) {
      return VehicleMeshLoad(null, ['${rejection.message} 기본 차량 모양으로 그립니다.']);
    } on Object catch (error) {
      return VehicleMeshLoad(null, ['메시를 그릴 수 없어 기본 차량 모양으로 그립니다: $error']);
    }
  }

  static GltfMeshData _read((Uint8List, GltfReadOptions) args) =>
      GltfMeshReader.read(args.$1, options: args.$2);

  static VehicleMeshSet _levels((VehicleMesh, double, double, double) a) =>
      VehicleMeshSet.fromMesh(a.$1, length: a.$2, width: a.$3, height: a.$4);

  /// Samples each textured vertex's base color texture (nearest texel,
  /// repeat wrap) into a per-vertex color multiplier.
  static Future<(VehicleMesh, List<String>)> bakeTextures(
    GltfMeshData data,
  ) async {
    final warnings = <String>[];
    final decoded = <(Uint8List, int, int)?>[];
    for (final texture in data.textures) {
      try {
        final codec = await ui.instantiateImageCodec(
          texture.bytes,
          targetWidth: bakeTextureSize,
        );
        final frame = await codec.getNextFrame();
        final image = frame.image;
        final pixels = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        decoded.add(
          pixels == null
              ? null
              : (pixels.buffer.asUint8List(), image.width, image.height),
        );
        image.dispose();
        codec.dispose();
      } on Object {
        decoded.add(null);
        warnings.add('텍스처 하나를 읽지 못해 재질 색만 씁니다.');
      }
    }
    final mesh = data.mesh;
    final uvs = data.uvs!;
    final colors = Uint32List(mesh.vertexCount);
    for (var v = 0; v < mesh.vertexCount; v++) {
      final index = data.vertexTexture[v];
      final texture = index < 0 ? null : decoded[index];
      if (texture == null) {
        colors[v] = 0xFFFFFFFF;
        continue;
      }
      final (rgba, w, h) = texture;
      var u = uvs[v * 2], t = uvs[v * 2 + 1];
      u -= u.floorToDouble();
      t -= t.floorToDouble();
      final x = (u * (w - 1)).round().clamp(0, w - 1);
      final y = (t * (h - 1)).round().clamp(0, h - 1);
      final o = (y * w + x) * 4;
      colors[v] = 0xFF000000 | rgba[o] << 16 | rgba[o + 1] << 8 | rgba[o + 2];
    }
    return (
      VehicleMesh(
        positions: mesh.positions,
        normals: mesh.normals,
        colors: colors,
        indices: mesh.indices,
        triangleMaterials: mesh.triangleMaterials,
        materials: mesh.materials,
      ),
      warnings,
    );
  }
}

/// Mesh levels (null = draw the built-in model) and why.
class VehicleMeshLoad {
  const VehicleMeshLoad(this.mesh, this.warnings);

  final VehicleMeshSet? mesh;
  final List<String> warnings;
}
