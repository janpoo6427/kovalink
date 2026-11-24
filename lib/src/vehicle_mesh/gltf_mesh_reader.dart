import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:kovalink/src/vehicle_mesh/vehicle_mesh.dart';
import 'package:kovalink/src/vehicle_pack/safe_zip_reader.dart';

/// Role bindings for [GltfMeshReader]: glTF material names and node names
/// from the pack manifest, plus nodes to leave out (display stands,
/// ground cloths, cameras' helper meshes).
class GltfReadOptions {
  const GltfReadOptions({
    this.materialRoles = const {},
    this.nodeRoles = const {},
    this.excludeNodes = const {},
  });

  final Map<String, MeshRole> materialRoles;
  final Map<String, MeshRole> nodeRoles;
  final Set<String> excludeNodes;
}

/// A base color texture referenced by the mesh (PNG/JPEG bytes inside the
/// GLB). Baking it into vertex colors needs an image decoder, so it is done
/// by the Flutter-side loader.
class GltfTexture {
  const GltfTexture(this.bytes, this.mimeType);

  final Uint8List bytes;
  final String mimeType;
}

class GltfMeshData {
  const GltfMeshData({
    required this.mesh,
    required this.uvs,
    required this.vertexTexture,
    required this.textures,
    required this.warnings,
  });

  /// Mesh in the vehicle frame (x forward, y left, z up), GLB units.
  final VehicleMesh mesh;

  /// Texture coordinates per vertex (after KHR_texture_transform), or
  /// null when no material uses a base color texture.
  final Float32List? uvs;

  /// Index into [textures] per vertex, -1 when untextured.
  final Int16List vertexTexture;
  final List<GltfTexture> textures;
  final List<String> warnings;

  bool get hasTextures => textures.isNotEmpty && uvs != null;
}

/// Reads triangle geometry from a self-contained glTF 2.0 binary for the
/// in-app renderer. Data only: no URIs, no scripts, no network.
///
/// Supported: POSITION/NORMAL/TEXCOORD_n accessors in float or (normalized)
/// integer form (KHR_mesh_quantization), uint8/16/32 indices, triangle
/// lists/strips/fans, node matrix or TRS hierarchies, baseColorFactor,
/// metallic/roughness/emissive factors and base color textures.
/// Refused with a reason: external URIs, Draco/meshopt compression,
/// sparse accessors.
class GltfMeshReader {
  const GltfMeshReader._();

  static const _magic = 0x46546C67;
  static const _jsonChunk = 0x4E4F534A;
  static const _binChunk = 0x004E4942;

  /// Compression extensions the renderer cannot decode.
  static const compressionExtensions = {
    'KHR_draco_mesh_compression',
    'EXT_meshopt_compression',
    'KHR_meshopt_compression',
  };

  /// Hard cap while reading (the import validator refuses far earlier).
  static const maxTriangles = 400000;

  static GltfMeshData read(
    Uint8List bytes, {
    GltfReadOptions options = const GltfReadOptions(),
  }) {
    final (gltf, bin) = parseContainer(bytes);
    rejectUnsupported(gltf);
    return _Reader(gltf, bin, options).run();
  }

  /// Splits a GLB into its JSON document and BIN chunk.
  static (Map<String, dynamic>, Uint8List?) parseContainer(Uint8List bytes) {
    if (bytes.length < 20) {
      throw const ModelPackRejection('glb-invalid', 'GLB 파일이 너무 짧습니다.');
    }
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0, Endian.little) != _magic ||
        data.getUint32(4, Endian.little) != 2 ||
        data.getUint32(8, Endian.little) != bytes.length) {
      throw const ModelPackRejection('glb-invalid', 'glTF 2.0 GLB 파일이 아닙니다.');
    }
    final jsonLength = data.getUint32(12, Endian.little);
    if (data.getUint32(16, Endian.little) != _jsonChunk ||
        20 + jsonLength > bytes.length) {
      throw const ModelPackRejection('glb-invalid', 'GLB JSON 영역이 올바르지 않습니다.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(
        utf8.decode(Uint8List.sublistView(bytes, 20, 20 + jsonLength)),
      );
    } on FormatException {
      throw const ModelPackRejection('glb-invalid', 'GLB JSON을 읽을 수 없습니다.');
    }
    if (decoded is! Map<String, dynamic>) {
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
    return (decoded, bin);
  }

  /// Shared with the import inspector so both refuse the same files with
  /// the same reason.
  static void rejectUnsupported(Map<String, dynamic> gltf) {
    final names = {
      ...(gltf['extensionsUsed'] as List? ?? const []).whereType<String>(),
      ...(gltf['extensionsRequired'] as List? ?? const []).whereType<String>(),
    };
    final compressed = names.intersection(compressionExtensions);
    if (compressed.isNotEmpty) {
      throw ModelPackRejection(
        'glb-compressed',
        '압축된 메시(${compressed.join(', ')})는 지원하지 않습니다. '
            '내보낼 때 Draco·meshopt 압축을 끄고 다시 만드세요.',
      );
    }
    for (final key in const ['buffers', 'images']) {
      for (final item
          in (gltf[key] as List? ?? const [])
              .whereType<Map<String, dynamic>>()) {
        if (item.containsKey('uri')) {
          throw const ModelPackRejection(
            'external-uri',
            'GLB 밖의 파일(URI)을 참조하는 모델은 쓸 수 없습니다.',
          );
        }
      }
    }
  }
}

class _Reader {
  _Reader(this.gltf, this.bin, this.options);

  final Map<String, dynamic> gltf;
  final Uint8List? bin;
  final GltfReadOptions options;

  final positions = <double>[];
  final normals = <double>[];
  final uvs = <double>[];
  final vertexTexture = <int>[];
  final indices = <int>[];
  final triMaterials = <int>[];
  final materials = <MeshMaterial>[];
  final materialKeys = <String, int>{};
  final textures = <GltfTexture>[];
  final textureKeys = <int, int>{};
  final warnings = <String>{};
  var anyTexture = false;

  List<Map<String, dynamic>> list(String key) =>
      (gltf[key] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  late final nodes = list('nodes');
  late final meshes = list('meshes');
  late final accessors = list('accessors');
  late final views = list('bufferViews');
  late final gltfMaterials = list('materials');

  GltfMeshData run() {
    final roots = _roots();
    for (final root in roots) {
      _visit(root, _Mat4.identity, null, 0);
    }
    if (indices.isEmpty) {
      throw const ModelPackRejection('glb-empty', 'GLB에 그릴 수 있는 삼각형 메시가 없습니다.');
    }
    return GltfMeshData(
      mesh: VehicleMesh(
        positions: Float32List.fromList(positions),
        normals: Float32List.fromList(normals),
        indices: Uint32List.fromList(indices),
        triangleMaterials: Uint16List.fromList(triMaterials),
        materials: List.unmodifiable(materials),
      ),
      uvs: anyTexture ? Float32List.fromList(uvs) : null,
      vertexTexture: Int16List.fromList(vertexTexture),
      textures: List.unmodifiable(textures),
      warnings: List.unmodifiable(warnings),
    );
  }

  List<int> _roots() {
    final scenes = list('scenes');
    if (scenes.isNotEmpty) {
      final index = (gltf['scene'] as int?) ?? 0;
      final scene = scenes[index.clamp(0, scenes.length - 1)];
      return (scene['nodes'] as List? ?? const []).whereType<int>().toList();
    }
    final children = <int>{
      for (final node in nodes)
        ...(node['children'] as List? ?? const []).whereType<int>(),
    };
    return [
      for (var i = 0; i < nodes.length; i++)
        if (!children.contains(i)) i,
    ];
  }

  void _visit(int index, _Mat4 parent, MeshRole? inherited, int depth) {
    if (index < 0 || index >= nodes.length || depth > 64) {
      throw const ModelPackRejection('glb-invalid', 'GLB 노드 구조가 올바르지 않습니다.');
    }
    final node = nodes[index];
    final name = node['name'] as String?;
    if (name != null && options.excludeNodes.contains(name)) return;
    final world = parent * _Mat4.ofNode(node);
    final role = (name == null ? null : options.nodeRoles[name]) ?? inherited;
    final mesh = node['mesh'];
    if (mesh is int) {
      if (mesh < 0 || mesh >= meshes.length) {
        throw const ModelPackRejection('glb-invalid', 'GLB 메시 번호가 올바르지 않습니다.');
      }
      for (final primitive
          in (meshes[mesh]['primitives'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()) {
        _primitive(primitive, world, role);
      }
    }
    for (final child
        in (node['children'] as List? ?? const []).whereType<int>()) {
      _visit(child, world, role, depth + 1);
    }
  }

  void _primitive(Map<String, dynamic> primitive, _Mat4 world, MeshRole? role) {
    if ((primitive['extensions'] as Map?)?.keys.any(
          GltfMeshReader.compressionExtensions.contains,
        ) ??
        false) {
      throw const ModelPackRejection(
        'glb-compressed',
        '압축된 메시(Draco)는 지원하지 않습니다. 압축 없이 다시 내보내세요.',
      );
    }
    final mode = primitive['mode'] as int? ?? 4;
    if (mode != 4 && mode != 5 && mode != 6) {
      warnings.add('점·선 프리미티브는 그리지 않습니다.');
      return;
    }
    final attributes = primitive['attributes'] as Map? ?? const {};
    final positionAccessor = attributes['POSITION'];
    if (positionAccessor is! int) return;
    final local = _read(positionAccessor, 3);
    final count = local.length ~/ 3;
    if (count == 0) return;
    final normalAccessor = attributes['NORMAL'];
    final localNormals = normalAccessor is int
        ? _read(normalAccessor, 3)
        : null;
    if (localNormals != null && localNormals.length != local.length) {
      throw const ModelPackRejection(
        'glb-invalid',
        'NORMAL 개수가 POSITION과 다릅니다.',
      );
    }

    // Material.
    final materialIndex = primitive['material'] as int?;
    final (material, texture) = _material(materialIndex, role);
    final matId = materialKeys.putIfAbsent(
      '${material.name}|${material.role.name}|${material.baseColor}',
      () {
        materials.add(material);
        return materials.length - 1;
      },
    );
    Float64List? localUv;
    var textureId = -1;
    if (texture != null) {
      final uvAccessor = attributes['TEXCOORD_${texture.texCoord}'];
      if (uvAccessor is int) {
        localUv = _read(uvAccessor, 2);
        if (localUv.length ~/ 2 != count) localUv = null;
      }
      if (localUv != null) {
        textureId = textureKeys.putIfAbsent(texture.image, () {
          textures.add(texture.data);
          return textures.length - 1;
        });
        anyTexture = true;
      }
    }

    // Triangle list.
    final indexAccessor = primitive['indices'];
    final raw = indexAccessor is int
        ? _readIndices(indexAccessor, count)
        : List<int>.generate(count, (i) => i);
    final tris = <int>[];
    switch (mode) {
      case 4:
        for (var i = 0; i + 2 < raw.length; i += 3) {
          tris
            ..add(raw[i])
            ..add(raw[i + 1])
            ..add(raw[i + 2]);
        }
      case 5:
        for (var i = 0; i + 2 < raw.length; i++) {
          if (i.isEven) {
            tris
              ..add(raw[i])
              ..add(raw[i + 1])
              ..add(raw[i + 2]);
          } else {
            tris
              ..add(raw[i + 1])
              ..add(raw[i])
              ..add(raw[i + 2]);
          }
        }
      case 6:
        for (var i = 1; i + 1 < raw.length; i++) {
          tris
            ..add(raw[0])
            ..add(raw[i])
            ..add(raw[i + 1]);
        }
    }
    if (triMaterials.length + tris.length ~/ 3 > GltfMeshReader.maxTriangles) {
      throw const ModelPackRejection('too-many-triangles', '삼각형이 너무 많습니다.');
    }

    final flip = world.determinant3 < 0;
    final normalMatrix = world.normalMatrix();
    final base = positions.length ~/ 3;
    final computed = localNormals == null ? _smoothNormals(local, tris) : null;
    for (var v = 0; v < count; v++) {
      final (x, y, z) = world.transformPoint(
        local[v * 3],
        local[v * 3 + 1],
        local[v * 3 + 2],
      );
      // glTF (+X left, +Y up, +Z forward) → vehicle frame (x fwd, y left, z up).
      positions
        ..add(z)
        ..add(x)
        ..add(y);
      final src = localNormals ?? computed!;
      var (nx, ny, nz) = normalMatrix.transformVector(
        src[v * 3],
        src[v * 3 + 1],
        src[v * 3 + 2],
      );
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (len > 1e-12) {
        nx /= len;
        ny /= len;
        nz /= len;
      } else {
        ny = 1;
      }
      normals
        ..add(nz)
        ..add(nx)
        ..add(ny);
      if (localUv != null) {
        final (u, w) = texture!.transform(localUv[v * 2], localUv[v * 2 + 1]);
        uvs
          ..add(u)
          ..add(w);
      } else {
        uvs
          ..add(0)
          ..add(0);
      }
      vertexTexture.add(textureId);
    }
    for (var i = 0; i + 2 < tris.length; i += 3) {
      final a = tris[i], b = tris[i + 1], c = tris[i + 2];
      if (a >= count || b >= count || c >= count) {
        throw const ModelPackRejection('glb-invalid', '인덱스가 정점 범위를 벗어납니다.');
      }
      indices
        ..add(base + a)
        ..add(base + (flip ? c : b))
        ..add(base + (flip ? b : c));
      triMaterials.add(matId);
    }
  }

  static Float64List _smoothNormals(Float64List p, List<int> tris) {
    final n = Float64List(p.length);
    for (var i = 0; i + 2 < tris.length; i += 3) {
      final a = tris[i] * 3, b = tris[i + 1] * 3, c = tris[i + 2] * 3;
      if (a >= p.length || b >= p.length || c >= p.length) continue;
      final ux = p[b] - p[a],
          uy = p[b + 1] - p[a + 1],
          uz = p[b + 2] - p[a + 2];
      final vx = p[c] - p[a],
          vy = p[c + 1] - p[a + 1],
          vz = p[c + 2] - p[a + 2];
      final nx = uy * vz - uz * vy,
          ny = uz * vx - ux * vz,
          nz = ux * vy - uy * vx;
      for (final o in [a, b, c]) {
        n[o] += nx;
        n[o + 1] += ny;
        n[o + 2] += nz;
      }
    }
    return n;
  }

  (MeshMaterial, _TextureRef?) _material(int? index, MeshRole? nodeRole) {
    if (index == null || index < 0 || index >= gltfMaterials.length) {
      return (
        MeshMaterial(
          name: 'default',
          role: nodeRole ?? MeshRole.other,
          baseColor: 0xFFBFC4C9,
        ),
        null,
      );
    }
    final m = gltfMaterials[index];
    final name = m['name'] as String? ?? 'material$index';
    final pbr = m['pbrMetallicRoughness'] as Map? ?? const {};
    final factor = (pbr['baseColorFactor'] as List? ?? const [1, 1, 1, 1])
        .whereType<num>()
        .map((v) => v.toDouble())
        .toList();
    final emissive = (m['emissiveFactor'] as List? ?? const [0, 0, 0])
        .whereType<num>()
        .map((v) => v.toDouble())
        .toList();
    // See-through materials (KHR_materials_transmission or blended with
    // low alpha) are glass even without a KovaLink role name.
    final extensions = m['extensions'] as Map? ?? const {};
    final alpha = factor.length >= 4 ? factor[3] : 1.0;
    final seeThrough =
        extensions.containsKey('KHR_materials_transmission') ||
        (m['alphaMode'] == 'BLEND' && alpha < 0.8);
    final role =
        nodeRole ??
        options.materialRoles[name] ??
        standardRoles[_stripDecal(name)] ??
        (seeThrough ? MeshRole.glass : MeshRole.other);
    _TextureRef? texture;
    final baseTexture = pbr['baseColorTexture'];
    if (baseTexture is Map) {
      texture = _texture(baseTexture);
    }
    final hasEmissiveTexture = m['emissiveTexture'] != null;
    return (
      MeshMaterial(
        name: name,
        role: role,
        // Glass shows the dark cabin behind it (the software renderer adds
        // the sky reflection), not its pale transmission tint.
        baseColor: seeThrough
            ? _tintedGlass(_argb(factor.length >= 3 ? factor : const [1, 1, 1]))
            : _argb(factor.length >= 3 ? factor : const [1, 1, 1]),
        metallic: ((pbr['metallicFactor'] as num?)?.toDouble() ?? 1).clamp(
          0,
          1,
        ),
        roughness: ((pbr['roughnessFactor'] as num?)?.toDouble() ?? 1).clamp(
          0,
          1,
        ),
        // An emissive texture with factor 1 would light the whole body;
        // without decoding it we keep only plain emissive factors.
        emissive: hasEmissiveTexture || emissive.length < 3
            ? 0xFF000000
            : _argb(emissive),
        doubleSided: m['doubleSided'] == true,
      ),
      texture,
    );
  }

  static int _tintedGlass(int argb) {
    int ch(int shift, int dark) =>
        ((((argb >> shift) & 0xFF) * 0.1) + dark * 0.9).round().clamp(0, 255);
    return 0xFF000000 | ch(16, 0x14) << 16 | ch(8, 0x1B) << 8 | ch(0, 0x23);
  }

  static String _stripDecal(String name) =>
      name.endsWith('_Decal') ? name.substring(0, name.length - 6) : name;

  /// KovaLink standard material names (docs/VEHICLE_MODEL_PACK.md).
  static const standardRoles = {
    'KL_BodyPaint': MeshRole.paint,
    'KL_Glass': MeshRole.glass,
    'KL_Sunroof': MeshRole.glass,
    'KL_Tail': MeshRole.tail,
    'KL_Brake': MeshRole.brake,
    'KL_TurnLeft': MeshRole.turnLeft,
    'KL_TurnRight': MeshRole.turnRight,
    'KL_Reverse': MeshRole.reverse,
    'KL_Head': MeshRole.headlight,
    'KL_Plate': MeshRole.plate,
    'KL_Tire': MeshRole.tire,
    'KL_Rim': MeshRole.rim,
    'KL_Hub': MeshRole.rim,
    'KL_Trim': MeshRole.trim,
    'KL_PillarBlack': MeshRole.trim,
    'KL_Underbody': MeshRole.trim,
    'KL_Grille': MeshRole.trim,
    'KL_Chrome': MeshRole.chrome,
  };

  _TextureRef? _texture(Map info) {
    final textureIndex = info['index'];
    final texturesJson = list('textures');
    if (textureIndex is! int ||
        textureIndex < 0 ||
        textureIndex >= texturesJson.length) {
      return null;
    }
    final source = texturesJson[textureIndex]['source'];
    final images = list('images');
    if (source is! int || source < 0 || source >= images.length) return null;
    final image = images[source];
    final viewIndex = image['bufferView'];
    final mime = image['mimeType'];
    if (viewIndex is! int || (mime != 'image/png' && mime != 'image/jpeg')) {
      return null;
    }
    final (offset, length, _) = _view(viewIndex);
    final transform =
        (info['extensions'] as Map?)?['KHR_texture_transform'] as Map?;
    List<double> vec(Object? v, List<double> d) =>
        (v as List?)?.whereType<num>().map((e) => e.toDouble()).toList() ?? d;
    return _TextureRef(
      image: source,
      texCoord:
          (transform?['texCoord'] as int?) ?? (info['texCoord'] as int? ?? 0),
      data: GltfTexture(
        Uint8List.sublistView(bin!, offset, offset + length),
        mime as String,
      ),
      offset: vec(transform?['offset'], const [0, 0]),
      scale: vec(transform?['scale'], const [1, 1]),
      rotation: (transform?['rotation'] as num?)?.toDouble() ?? 0,
    );
  }

  static int _argb(List<double> linear) {
    int channel(double v) {
      final c = v.clamp(0.0, 1.0);
      final s = c <= 0.0031308
          ? c * 12.92
          : 1.055 * math.pow(c, 1 / 2.4) - 0.055;
      return (s * 255).round().clamp(0, 255);
    }

    return 0xFF000000 |
        channel(linear[0]) << 16 |
        channel(linear[1]) << 8 |
        channel(linear[2]);
  }

  (int, int, int) _view(int index) {
    if (index < 0 || index >= views.length || bin == null) {
      throw const ModelPackRejection(
        'glb-invalid',
        'GLB bufferView가 올바르지 않습니다.',
      );
    }
    final view = views[index];
    if ((view['buffer'] as int? ?? 0) != 0) {
      throw const ModelPackRejection('glb-invalid', 'GLB 안의 버퍼만 쓸 수 있습니다.');
    }
    final offset = view['byteOffset'] as int? ?? 0;
    final length = view['byteLength'] as int? ?? 0;
    if (offset < 0 || length < 0 || offset + length > bin!.length) {
      throw const ModelPackRejection(
        'glb-invalid',
        'GLB bufferView 범위가 파일을 벗어납니다.',
      );
    }
    return (offset, length, view['byteStride'] as int? ?? 0);
  }

  static int _componentSize(int type) => switch (type) {
    5120 || 5121 => 1,
    5122 || 5123 => 2,
    5125 || 5126 => 4,
    _ => throw const ModelPackRejection(
      'glb-invalid',
      '알 수 없는 accessor 형식입니다.',
    ),
  };

  ({ByteData data, int start, int stride, int count, int type, bool normalized})
  _accessor(int index, int components) {
    if (index < 0 || index >= accessors.length) {
      throw const ModelPackRejection(
        'glb-invalid',
        'GLB accessor 번호가 올바르지 않습니다.',
      );
    }
    final a = accessors[index];
    const typeNames = {1: 'SCALAR', 2: 'VEC2', 3: 'VEC3'};
    if (a['type'] != typeNames[components]) {
      throw ModelPackRejection(
        'glb-invalid',
        'accessor 형식이 ${typeNames[components]}가 아닙니다.',
      );
    }
    if (a.containsKey('sparse')) {
      throw const ModelPackRejection(
        'glb-unsupported',
        'sparse accessor(모프·부분 갱신용 압축 데이터)는 지원하지 않습니다.',
      );
    }
    final type = a['componentType'] as int? ?? 0;
    final count = a['count'] as int? ?? 0;
    final viewIndex = a['bufferView'];
    if (viewIndex is! int) {
      throw const ModelPackRejection(
        'glb-invalid',
        'accessor에 bufferView가 없습니다.',
      );
    }
    final (offset, length, viewStride) = _view(viewIndex);
    final size = _componentSize(type);
    final element = size * components;
    final stride = viewStride == 0 ? element : viewStride;
    final start = offset + (a['byteOffset'] as int? ?? 0);
    if (count < 0 ||
        (count > 0 &&
            start + stride * (count - 1) + element > offset + length)) {
      throw const ModelPackRejection(
        'glb-invalid',
        'accessor 범위가 bufferView를 벗어납니다.',
      );
    }
    return (
      data: ByteData.sublistView(bin!),
      start: start,
      stride: stride,
      count: count,
      type: type,
      normalized: a['normalized'] == true,
    );
  }

  Float64List _read(int index, int components) {
    final a = _accessor(index, components);
    final out = Float64List(a.count * components);
    final size = _componentSize(a.type);
    for (var i = 0; i < a.count; i++) {
      for (var c = 0; c < components; c++) {
        final o = a.start + i * a.stride + c * size;
        final double v = switch (a.type) {
          5126 => a.data.getFloat32(o, Endian.little),
          5120 =>
            a.normalized
                ? math.max(a.data.getInt8(o) / 127.0, -1.0)
                : a.data.getInt8(o).toDouble(),
          5121 =>
            a.normalized
                ? a.data.getUint8(o) / 255.0
                : a.data.getUint8(o).toDouble(),
          5122 =>
            a.normalized
                ? math.max(a.data.getInt16(o, Endian.little) / 32767.0, -1.0)
                : a.data.getInt16(o, Endian.little).toDouble(),
          5123 =>
            a.normalized
                ? a.data.getUint16(o, Endian.little) / 65535.0
                : a.data.getUint16(o, Endian.little).toDouble(),
          _ => a.data.getUint32(o, Endian.little).toDouble(),
        };
        if (!v.isFinite) {
          throw const ModelPackRejection(
            'glb-invalid',
            'GLB에 숫자가 아닌 좌표가 있습니다.',
          );
        }
        out[i * components + c] = v;
      }
    }
    return out;
  }

  List<int> _readIndices(int index, int vertexCount) {
    final a = _accessor(index, 1);
    if (a.type != 5121 && a.type != 5123 && a.type != 5125) {
      throw const ModelPackRejection('glb-invalid', '인덱스는 uint8/16/32여야 합니다.');
    }
    final out = List<int>.filled(a.count, 0);
    for (var i = 0; i < a.count; i++) {
      final o = a.start + i * a.stride;
      out[i] = switch (a.type) {
        5121 => a.data.getUint8(o),
        5123 => a.data.getUint16(o, Endian.little),
        _ => a.data.getUint32(o, Endian.little),
      };
    }
    return out;
  }
}

class _TextureRef {
  const _TextureRef({
    required this.image,
    required this.texCoord,
    required this.data,
    required this.offset,
    required this.scale,
    required this.rotation,
  });

  final int image;
  final int texCoord;
  final GltfTexture data;
  final List<double> offset;
  final List<double> scale;
  final double rotation;

  (double, double) transform(double u, double v) {
    final su = u * (scale.isNotEmpty ? scale[0] : 1);
    final sv = v * (scale.length > 1 ? scale[1] : 1);
    final c = math.cos(rotation), s = math.sin(rotation);
    return (
      c * su + s * sv + (offset.isNotEmpty ? offset[0] : 0),
      -s * su + c * sv + (offset.length > 1 ? offset[1] : 0),
    );
  }
}

/// Column-major 4×4 affine matrix (glTF convention).
class _Mat4 {
  const _Mat4(this.m);

  final List<double> m;

  static const identity = _Mat4([
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
  ]);

  factory _Mat4.ofNode(Map<String, dynamic> node) {
    final matrix = node['matrix'];
    if (matrix is List && matrix.length == 16) {
      return _Mat4([for (final v in matrix) (v as num).toDouble()]);
    }
    List<double> vec(Object? v, List<double> d) =>
        (v as List?)?.whereType<num>().map((e) => e.toDouble()).toList() ?? d;
    final t = vec(node['translation'], const [0, 0, 0]);
    final r = vec(node['rotation'], const [0, 0, 0, 1]);
    final s = vec(node['scale'], const [1, 1, 1]);
    if (t.length != 3 || r.length != 4 || s.length != 3) {
      throw const ModelPackRejection('glb-invalid', 'GLB 노드 변환 값이 올바르지 않습니다.');
    }
    final (x, y, z, w) = (r[0], r[1], r[2], r[3]);
    final r00 = 1 - 2 * (y * y + z * z), r01 = 2 * (x * y - z * w);
    final r02 = 2 * (x * z + y * w);
    final r10 = 2 * (x * y + z * w), r11 = 1 - 2 * (x * x + z * z);
    final r12 = 2 * (y * z - x * w);
    final r20 = 2 * (x * z - y * w), r21 = 2 * (y * z + x * w);
    final r22 = 1 - 2 * (x * x + y * y);
    return _Mat4([
      r00 * s[0],
      r10 * s[0],
      r20 * s[0],
      0,
      r01 * s[1],
      r11 * s[1],
      r21 * s[1],
      0,
      r02 * s[2],
      r12 * s[2],
      r22 * s[2],
      0,
      t[0],
      t[1],
      t[2],
      1,
    ]);
  }

  _Mat4 operator *(_Mat4 o) {
    final out = List<double>.filled(16, 0);
    for (var c = 0; c < 4; c++) {
      for (var r = 0; r < 4; r++) {
        var sum = 0.0;
        for (var k = 0; k < 4; k++) {
          sum += m[k * 4 + r] * o.m[c * 4 + k];
        }
        out[c * 4 + r] = sum;
      }
    }
    return _Mat4(out);
  }

  (double, double, double) transformPoint(double x, double y, double z) => (
    m[0] * x + m[4] * y + m[8] * z + m[12],
    m[1] * x + m[5] * y + m[9] * z + m[13],
    m[2] * x + m[6] * y + m[10] * z + m[14],
  );

  (double, double, double) transformVector(double x, double y, double z) => (
    m[0] * x + m[4] * y + m[8] * z,
    m[1] * x + m[5] * y + m[9] * z,
    m[2] * x + m[6] * y + m[10] * z,
  );

  double get determinant3 =>
      m[0] * (m[5] * m[10] - m[9] * m[6]) -
      m[4] * (m[1] * m[10] - m[9] * m[2]) +
      m[8] * (m[1] * m[6] - m[5] * m[2]);

  /// Inverse-transpose of the upper 3×3 (cofactor matrix; scale-free use).
  _Mat4 normalMatrix() {
    final a = m;
    final c00 = a[5] * a[10] - a[9] * a[6];
    final c01 = -(a[1] * a[10] - a[9] * a[2]);
    final c02 = a[1] * a[6] - a[5] * a[2];
    final c10 = -(a[4] * a[10] - a[8] * a[6]);
    final c11 = a[0] * a[10] - a[8] * a[2];
    final c12 = -(a[0] * a[6] - a[4] * a[2]);
    final c20 = a[4] * a[9] - a[8] * a[5];
    final c21 = -(a[0] * a[9] - a[8] * a[1]);
    final c22 = a[0] * a[5] - a[4] * a[1];
    // Columns of the cofactor matrix map normals like (M^-1)^T up to scale.
    return _Mat4([
      c00,
      c10,
      c20,
      0,
      c01,
      c11,
      c21,
      0,
      c02,
      c12,
      c22,
      0,
      0,
      0,
      0,
      1,
    ]);
  }
}
