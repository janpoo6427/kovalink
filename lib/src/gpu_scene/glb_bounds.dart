import 'dart:convert';
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

/// World-space bounds of a GLB's default scene (node transforms applied,
/// from accessor min/max), in the glTF frame. Used to fit imported model
/// packs whose nodes carry their own scale/rotation (e.g. ToyCar 1e-4).
class GlbBounds {
  const GlbBounds(this.min, this.max);

  final Vector3 min;
  final Vector3 max;

  Vector3 get size => max - min;
  Vector3 get center => (min + max) * 0.5;

  static GlbBounds? of(Uint8List glb) => _scan(glb)?.$1;

  /// Bounds of every named mesh node (world space, transforms applied).
  static Map<String, GlbBounds> nodes(Uint8List glb) =>
      _scan(glb)?.$2 ?? const {};

  static (GlbBounds, Map<String, GlbBounds>)? _scan(Uint8List glb) {
    final perNode = <String, GlbBounds>{};
    if (glb.length < 20) return null;
    final bd = ByteData.sublistView(glb);
    if (bd.getUint32(0, Endian.little) != 0x46546C67) return null;
    final len = bd.getUint32(12, Endian.little);
    final json =
        jsonDecode(utf8.decode(glb.sublist(20, 20 + len)))
            as Map<String, dynamic>;
    final nodes = (json['nodes'] as List?) ?? const [];
    final meshes = (json['meshes'] as List?) ?? const [];
    final accessors = (json['accessors'] as List?) ?? const [];
    final scenes = (json['scenes'] as List?) ?? const [];
    final sceneIndex = (json['scene'] as int?) ?? 0;
    final roots = scenes.isEmpty
        ? [for (var i = 0; i < nodes.length; i++) i]
        : ((scenes[sceneIndex] as Map)['nodes'] as List).cast<int>();
    final lo = Vector3.all(double.infinity), hi = Vector3.all(-double.infinity);

    Matrix4 local(Map n) {
      if (n['matrix'] case final List m) {
        return Matrix4.fromList([for (final v in m) (v as num).toDouble()]);
      }
      final t =
          (n['translation'] as List?)
              ?.map((v) => (v as num).toDouble())
              .toList() ??
          [0.0, 0.0, 0.0];
      final r =
          (n['rotation'] as List?)
              ?.map((v) => (v as num).toDouble())
              .toList() ??
          [0.0, 0.0, 0.0, 1.0];
      final s =
          (n['scale'] as List?)?.map((v) => (v as num).toDouble()).toList() ??
          [1.0, 1.0, 1.0];
      return Matrix4.compose(
        Vector3(t[0], t[1], t[2]),
        Quaternion(r[0], r[1], r[2], r[3]),
        Vector3(s[0], s[1], s[2]),
      );
    }

    void visit(int index, Matrix4 parent, int depth) {
      if (depth > 64 || index >= nodes.length) return;
      final n = nodes[index] as Map;
      final world = parent * local(n) as Matrix4;
      if (n['mesh'] case final int m when m < meshes.length) {
        final nlo = Vector3.all(double.infinity),
            nhi = Vector3.all(-double.infinity);
        for (final p in ((meshes[m] as Map)['primitives'] as List)) {
          final a = ((p as Map)['attributes'] as Map)['POSITION'];
          if (a is! int || a >= accessors.length) continue;
          final acc = accessors[a] as Map;
          final mn = (acc['min'] as List?)
              ?.map((v) => (v as num).toDouble())
              .toList();
          final mx = (acc['max'] as List?)
              ?.map((v) => (v as num).toDouble())
              .toList();
          if (mn == null || mx == null) continue;
          for (var c = 0; c < 8; c++) {
            final v = world.transformed3(
              Vector3(
                c & 1 == 0 ? mn[0] : mx[0],
                c & 2 == 0 ? mn[1] : mx[1],
                c & 4 == 0 ? mn[2] : mx[2],
              ),
            );
            Vector3.min(lo, v, lo);
            Vector3.max(hi, v, hi);
            Vector3.min(nlo, v, nlo);
            Vector3.max(nhi, v, nhi);
          }
        }
        if (n['name'] case final String name when nlo.x.isFinite) {
          perNode[name] = GlbBounds(nlo, nhi);
        }
      }
      for (final child in (n['children'] as List?) ?? const []) {
        visit(child as int, world, depth + 1);
      }
    }

    for (final r in roots) {
      visit(r, Matrix4.identity(), 0);
    }
    if (!lo.x.isFinite) return null;
    return (GlbBounds(lo, hi), perNode);
  }

  /// Bounds of [body] grown to include nodes inside its footprint; nodes
  /// that reach well outside it (display stands, cloths, ground planes in
  /// sample models) are returned in [props] so a renderer can hide them.
  static ({GlbBounds bounds, Set<String> props})? vehicle(
    Uint8List glb, {
    String? body,
    Set<String> exclude = const {},
  }) {
    final scan = _scan(glb);
    if (scan == null) return null;
    final (all, perNode) = scan;
    final core = (body == null ? null : perNode[body]) ?? all;
    final lo = core.min.clone(), hi = core.max.clone();
    final props = <String>{...exclude};
    final s = core.size;
    for (final MapEntry(key: name, value: b) in perNode.entries) {
      final outside =
          exclude.contains(name) ||
          b.min.x < core.min.x - s.x * 0.25 ||
          b.max.x > core.max.x + s.x * 0.25 ||
          b.min.z < core.min.z - s.z * 0.25 ||
          b.max.z > core.max.z + s.z * 0.25;
      if (outside) {
        props.add(name);
      } else {
        Vector3.min(lo, b.min, lo);
        Vector3.max(hi, b.max, hi);
      }
    }
    return (bounds: GlbBounds(lo, hi), props: props);
  }
}
