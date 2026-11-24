import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// One indexed triangle list with optional per-vertex colors and UVs, in
/// glTF frame (meters, +Y up). Used by [GltfSceneBuilder].
class GltfPrimitive {
  GltfPrimitive({
    required this.positions,
    required this.normals,
    required this.indices,
    required this.material,
    this.colors,
    this.uvs,
  }) : assert(positions.length == normals.length),
       assert(colors == null || colors.length == positions.length ~/ 3 * 4),
       assert(uvs == null || uvs.length == positions.length ~/ 3 * 2);

  final Float32List positions;
  final Float32List normals;
  final Uint32List indices;

  /// Linear RGBA, 4 floats per vertex.
  final Float32List? colors;
  final Float32List? uvs;
  final int material;

  int get vertexCount => positions.length ~/ 3;
}

/// Mutable accumulator for one primitive (positions/normals/colors).
class PrimitiveBuffer {
  PrimitiveBuffer({this.withColors = false});

  final bool withColors;
  final positions = <double>[];
  final normals = <double>[];
  final colors = <double>[];
  final indices = <int>[];

  int get vertexCount => positions.length ~/ 3;
  bool get isEmpty => indices.isEmpty;

  int vertex(
    double x,
    double y,
    double z,
    double nx,
    double ny,
    double nz, [
    List<double>? rgba,
  ]) {
    positions
      ..add(x)
      ..add(y)
      ..add(z);
    normals
      ..add(nx)
      ..add(ny)
      ..add(nz);
    if (withColors) colors.addAll(rgba ?? const [1, 1, 1, 1]);
    return vertexCount - 1;
  }

  void tri(int a, int b, int c) {
    indices
      ..add(a)
      ..add(b)
      ..add(c);
  }

  GltfPrimitive build(int material) => GltfPrimitive(
    positions: Float32List.fromList(positions),
    normals: Float32List.fromList(normals),
    indices: Uint32List.fromList(indices),
    colors: withColors ? Float32List.fromList(colors) : null,
    material: material,
  );
}

/// Small deterministic glTF 2.0 binary writer for generated scenes: many
/// meshes, node hierarchy, PBR materials with extensions (clearcoat,
/// emissive strength, unlit, transmission). No textures.
class GltfSceneBuilder {
  final _materials = <Map<String, Object?>>[];
  final _materialIndex = <String, int>{};
  final _meshes = <Map<String, Object>>[];
  final _nodes = <Map<String, Object>>[];
  final _roots = <int>[];
  final _bin = BytesBuilder();
  final _accessors = <Map<String, Object>>[];
  final _views = <Map<String, Object>>[];
  final _extensionsUsed = <String>{};

  /// Adds (or reuses by name) a glTF material JSON object.
  int material(Map<String, Object?> json) {
    final name = json['name'] as String;
    return _materialIndex.putIfAbsent(name, () {
      _materials.add(json);
      final ext = json['extensions'];
      if (ext is Map) _extensionsUsed.addAll(ext.keys.cast<String>());
      return _materials.length - 1;
    });
  }

  int get nodeCount => _nodes.length;

  /// Adds a mesh made of [primitives]; returns the mesh index or -1 when
  /// every primitive is empty.
  int mesh(String name, List<GltfPrimitive> primitives) {
    final prims = <Map<String, Object>>[];
    for (final p in primitives) {
      if (p.indices.isEmpty) continue;
      final attributes = <String, int>{
        'POSITION': _accessor(p.positions, 'VEC3', withBounds: true),
        'NORMAL': _accessor(p.normals, 'VEC3'),
      };
      if (p.colors case final c?) {
        attributes['COLOR_0'] = _accessor(c, 'VEC4');
      }
      if (p.uvs case final uv?) {
        attributes['TEXCOORD_0'] = _accessor(uv, 'VEC2');
      }
      prims.add({
        'attributes': attributes,
        'indices': _indexAccessor(p.indices, p.vertexCount),
        'material': p.material,
        'mode': 4,
      });
    }
    if (prims.isEmpty) return -1;
    _meshes.add({'name': name, 'primitives': prims});
    return _meshes.length - 1;
  }

  /// Adds a node; root nodes are listed in the scene. Returns its index.
  int node(
    String name, {
    int mesh = -1,
    List<double>? translation,
    List<double>? rotation,
    List<double>? scale,
    List<int> children = const [],
    bool root = true,
  }) {
    _nodes.add({
      'name': name,
      if (mesh >= 0) 'mesh': mesh,
      if (translation != null && translation.any((v) => v != 0))
        'translation': _round(translation),
      if (rotation != null) 'rotation': _round(rotation),
      if (scale != null) 'scale': _round(scale),
      if (children.isNotEmpty) 'children': children,
    });
    final index = _nodes.length - 1;
    if (root) _roots.add(index);
    return index;
  }

  int _view(Uint8List bytes, int target) {
    while (_bin.length % 4 != 0) {
      _bin.addByte(0);
    }
    _views.add({
      'buffer': 0,
      'byteOffset': _bin.length,
      'byteLength': bytes.length,
      'target': target,
    });
    _bin.add(bytes);
    return _views.length - 1;
  }

  int _accessor(Float32List data, String type, {bool withBounds = false}) {
    final width = switch (type) {
      'VEC2' => 2,
      'VEC3' => 3,
      _ => 4,
    };
    final view = _view(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      34962,
    );
    final count = data.length ~/ width;
    final accessor = <String, Object>{
      'bufferView': view,
      'componentType': 5126,
      'count': count,
      'type': type,
    };
    if (withBounds) {
      final lo = List.filled(width, double.infinity);
      final hi = List.filled(width, -double.infinity);
      for (var i = 0; i < data.length; i++) {
        lo[i % width] = math.min(lo[i % width], data[i]);
        hi[i % width] = math.max(hi[i % width], data[i]);
      }
      accessor['min'] = lo;
      accessor['max'] = hi;
    }
    _accessors.add(accessor);
    return _accessors.length - 1;
  }

  int _indexAccessor(Uint32List indices, int vertexCount) {
    final small = vertexCount < 65536;
    final bytes = small
        ? Uint16List.fromList(indices).buffer.asUint8List()
        : indices.buffer.asUint8List(
            indices.offsetInBytes,
            indices.lengthInBytes,
          );
    final view = _view(bytes, 34963);
    _accessors.add({
      'bufferView': view,
      'componentType': small ? 5123 : 5125,
      'count': indices.length,
      'type': 'SCALAR',
    });
    return _accessors.length - 1;
  }

  Uint8List toGlb({String generator = 'KovaLink gpu scene'}) {
    while (_bin.length % 4 != 0) {
      _bin.addByte(0);
    }
    final binBytes = _bin.takeBytes();
    final gltf = <String, Object>{
      'asset': {
        'version': '2.0',
        'generator': generator,
        'copyright': 'CC0-1.0 KovaLink project',
      },
      if (_extensionsUsed.isNotEmpty)
        'extensionsUsed': (_extensionsUsed.toList()..sort()),
      'scene': 0,
      'scenes': [
        {'nodes': _roots},
      ],
      'nodes': _nodes,
      if (_meshes.isNotEmpty) 'meshes': _meshes,
      if (_materials.isNotEmpty) 'materials': _materials,
      if (_accessors.isNotEmpty) 'accessors': _accessors,
      if (_views.isNotEmpty) 'bufferViews': _views,
      if (binBytes.isNotEmpty)
        'buffers': [
          {'byteLength': binBytes.length},
        ],
    };
    var json = utf8.encode(jsonEncode(gltf));
    final jsonPad = (4 - json.length % 4) % 4;
    final out = BytesBuilder(copy: false);
    final jsonLength = json.length + jsonPad;
    final total =
        12 + 8 + jsonLength + (binBytes.isEmpty ? 0 : 8 + binBytes.length);
    out.add(
      (ByteData(20)
            ..setUint32(0, 0x46546C67, Endian.little)
            ..setUint32(4, 2, Endian.little)
            ..setUint32(8, total, Endian.little)
            ..setUint32(12, jsonLength, Endian.little)
            ..setUint32(16, 0x4E4F534A, Endian.little))
          .buffer
          .asUint8List(),
    );
    out.add(json);
    out.add(List.filled(jsonPad, 0x20));
    if (binBytes.isNotEmpty) {
      out.add(
        (ByteData(8)
              ..setUint32(0, binBytes.length, Endian.little)
              ..setUint32(4, 0x004E4942, Endian.little))
            .buffer
            .asUint8List(),
      );
      out.add(binBytes);
    }
    return out.takeBytes();
  }

  static List<double> _round(List<double> v) => [
    for (final x in v) (x * 1e6).round() / 1e6,
  ];

  /// sRGB ARGB → linear RGB (glTF factors are linear).
  static List<double> linear(int argb) {
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
