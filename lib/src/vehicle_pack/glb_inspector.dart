import 'dart:convert';
import 'dart:typed_data';

import 'package:kovalink/src/vehicle_pack/safe_zip_reader.dart';

class GlbLimits {
  const GlbLimits({
    this.recommendedTriangles = 100000,
    this.maxTriangles = 200000,
    this.maxTextureSize = 2048,
    this.maxImages = 16,
  });

  /// Above this a warning is shown (mobile quality tier target).
  final int recommendedTriangles;

  /// Above this the pack is refused.
  final int maxTriangles;
  final int maxTextureSize;
  final int maxImages;
}

class GlbReport {
  const GlbReport({
    required this.triangles,
    required this.maxTextureSize,
    required this.imageCount,
    required this.nodeNames,
    required this.materialNames,
    required this.warnings,
  });

  final int triangles;
  final int maxTextureSize;
  final int imageCount;
  final Set<String> nodeNames;
  final Set<String> materialNames;
  final List<String> warnings;
}

/// Static, read-only inspection of a glTF 2.0 binary. The file is parsed as
/// data only: no scripts, no external URIs, no network.
class GlbInspector {
  const GlbInspector._();

  static const _magic = 0x46546C67; // 'glTF'
  static const _jsonChunk = 0x4E4F534A; // 'JSON'
  static const _binChunk = 0x004E4942; // 'BIN\0'

  /// Extensions a pack may *require*. Optional (`extensionsUsed`) entries
  /// are ignored by the renderer if unsupported, so they are not refused.
  static const allowedRequiredExtensions = {
    'KHR_materials_clearcoat',
    'KHR_materials_emissive_strength',
    'KHR_materials_ior',
    'KHR_materials_sheen',
    'KHR_materials_specular',
    'KHR_materials_transmission',
    'KHR_materials_unlit',
    'KHR_materials_volume',
    'KHR_mesh_quantization',
    'KHR_texture_transform',
  };

  static GlbReport inspect(
    Uint8List bytes, {
    GlbLimits limits = const GlbLimits(),
  }) {
    if (bytes.length < 20) {
      throw const ModelPackRejection('glb-invalid', 'GLB 파일이 너무 짧습니다.');
    }
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0, Endian.little) != _magic) {
      throw const ModelPackRejection('glb-invalid', 'glTF 바이너리(GLB) 파일이 아닙니다.');
    }
    if (data.getUint32(4, Endian.little) != 2) {
      throw const ModelPackRejection('glb-version', 'glTF 2.0 GLB만 지원합니다.');
    }
    if (data.getUint32(8, Endian.little) != bytes.length) {
      throw const ModelPackRejection('glb-invalid', 'GLB 길이 정보가 파일과 다릅니다.');
    }
    final jsonLength = data.getUint32(12, Endian.little);
    if (data.getUint32(16, Endian.little) != _jsonChunk ||
        20 + jsonLength > bytes.length) {
      throw const ModelPackRejection('glb-invalid', 'GLB JSON 영역이 올바르지 않습니다.');
    }
    final Map<String, dynamic> gltf;
    try {
      final decoded = jsonDecode(
        utf8.decode(Uint8List.sublistView(bytes, 20, 20 + jsonLength)),
      );
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      gltf = decoded;
    } on FormatException {
      throw const ModelPackRejection('glb-invalid', 'GLB JSON을 읽을 수 없습니다.');
    }

    Uint8List? bin;
    final binHeader = 20 + ((jsonLength + 3) & ~3);
    if (binHeader + 8 <= bytes.length) {
      final binLength = data.getUint32(binHeader, Endian.little);
      if (data.getUint32(binHeader + 4, Endian.little) == _binChunk &&
          binHeader + 8 + binLength <= bytes.length) {
        bin = Uint8List.sublistView(
          bytes,
          binHeader + 8,
          binHeader + 8 + binLength,
        );
      }
    }

    final assetVersion = (gltf['asset'] as Map?)?['version'];
    if (assetVersion is! String || !assetVersion.startsWith('2.')) {
      throw const ModelPackRejection(
        'glb-version',
        'glTF asset.version 2.x가 필요합니다.',
      );
    }

    final required = (gltf['extensionsRequired'] as List? ?? const [])
        .whereType<String>()
        .where((name) => !allowedRequiredExtensions.contains(name))
        .toList();
    if (required.isNotEmpty) {
      throw ModelPackRejection(
        'glb-extension',
        '지원하지 않는 필수 glTF 확장: ${required.join(', ')}',
      );
    }

    List<Map<String, dynamic>> list(String key) =>
        (gltf[key] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();

    // Self-contained only: every buffer and image must live in the GLB.
    for (final buffer in list('buffers')) {
      if (buffer.containsKey('uri')) {
        throw ModelPackRejection(
          'external-uri',
          '외부 버퍼 참조는 허용하지 않습니다: ${_describeUri(buffer['uri'])}',
        );
      }
    }
    final images = list('images');
    for (final image in images) {
      if (image.containsKey('uri')) {
        throw ModelPackRejection(
          'external-uri',
          '외부 텍스처 참조는 허용하지 않습니다: ${_describeUri(image['uri'])}',
        );
      }
    }
    if (images.length > limits.maxImages) {
      throw ModelPackRejection(
        'too-many-textures',
        '텍스처가 너무 많습니다(${images.length}개, 최대 ${limits.maxImages}개).',
      );
    }

    final accessors = list('accessors');
    final bufferViews = list('bufferViews');
    var triangles = 0;
    for (final mesh in list('meshes')) {
      for (final primitive
          in (mesh['primitives'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()) {
        final mode = primitive['mode'] as int? ?? 4;
        final indices = primitive['indices'] as int?;
        final position = (primitive['attributes'] as Map?)?['POSITION'] as int?;
        final accessorIndex = indices ?? position;
        if (accessorIndex == null ||
            accessorIndex < 0 ||
            accessorIndex >= accessors.length) {
          continue;
        }
        final count = accessors[accessorIndex]['count'] as int? ?? 0;
        triangles += switch (mode) {
          4 => count ~/ 3,
          5 || 6 => count > 2 ? count - 2 : 0,
          _ => 0,
        };
      }
    }
    if (triangles > limits.maxTriangles) {
      throw ModelPackRejection(
        'too-many-triangles',
        '폴리곤이 너무 많습니다($triangles 삼각형, 최대 ${limits.maxTriangles}).',
      );
    }

    var maxTexture = 0;
    for (final image in images) {
      final mime = image['mimeType'];
      if (mime != 'image/png' && mime != 'image/jpeg') {
        throw ModelPackRejection(
          'texture-format',
          'PNG/JPEG 텍스처만 지원합니다: $mime',
        );
      }
      final viewIndex = image['bufferView'] as int?;
      if (bin == null ||
          viewIndex == null ||
          viewIndex < 0 ||
          viewIndex >= bufferViews.length) {
        throw const ModelPackRejection('glb-invalid', '텍스처 데이터 위치가 올바르지 않습니다.');
      }
      final view = bufferViews[viewIndex];
      final offset = view['byteOffset'] as int? ?? 0;
      final length = view['byteLength'] as int? ?? 0;
      if (offset < 0 || length <= 0 || offset + length > bin.length) {
        throw const ModelPackRejection('glb-invalid', '텍스처 데이터 위치가 올바르지 않습니다.');
      }
      final size = imageSize(
        Uint8List.sublistView(bin, offset, offset + length),
      );
      if (size == null) {
        throw const ModelPackRejection(
          'texture-format',
          '텍스처 이미지 크기를 읽을 수 없습니다.',
        );
      }
      final largest = size.$1 > size.$2 ? size.$1 : size.$2;
      if (largest > limits.maxTextureSize) {
        throw ModelPackRejection(
          'texture-too-large',
          '텍스처가 너무 큽니다(${size.$1}×${size.$2}, 최대 ${limits.maxTextureSize}px).',
        );
      }
      if (largest > maxTexture) maxTexture = largest;
    }

    final warnings = <String>[];
    if (triangles > limits.recommendedTriangles) {
      warnings.add(
        '폴리곤 $triangles개: 권장 ${limits.recommendedTriangles}개를 넘어 휴대폰에서 느릴 수 있습니다.',
      );
    }
    return GlbReport(
      triangles: triangles,
      maxTextureSize: maxTexture,
      imageCount: images.length,
      nodeNames: {
        for (final node in list('nodes'))
          if (node['name'] case final String name) name,
      },
      materialNames: {
        for (final material in list('materials'))
          if (material['name'] case final String name) name,
      },
      warnings: warnings,
    );
  }

  /// Width/height from PNG IHDR or JPEG SOFn, or null if unreadable.
  static (int, int)? imageSize(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    if (bytes.length >= 24 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return (data.getUint32(16), data.getUint32(20));
    }
    if (bytes.length >= 4 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      var offset = 2;
      while (offset + 9 < bytes.length) {
        if (bytes[offset] != 0xFF) return null;
        final marker = bytes[offset + 1];
        if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7)) {
          offset += 2;
          continue;
        }
        final length = data.getUint16(offset + 2);
        final isFrame =
            marker >= 0xC0 &&
            marker <= 0xCF &&
            marker != 0xC4 &&
            marker != 0xC8 &&
            marker != 0xCC;
        if (isFrame) {
          return (data.getUint16(offset + 7), data.getUint16(offset + 5));
        }
        offset += 2 + length;
      }
    }
    return null;
  }

  static String _describeUri(Object? uri) {
    if (uri is! String) return '(알 수 없음)';
    if (uri.startsWith('data:')) return 'data: URI';
    return uri.length > 60 ? '${uri.substring(0, 60)}…' : uri;
  }
}
