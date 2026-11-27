import 'dart:math' as math;
import 'dart:typed_data';

import 'package:kovalink/src/models/road_scene.dart';

/// Display smoothing for live model geometry (planned path, lane lines,
/// road edges), so the road view moves calmly instead of jumping with every
/// telemetry frame. Display only: nothing here feeds back to the car.
///
/// The method follows carrot-vision3d v2.15 (its GEO_SMOOTH and lane
/// gating), re-implemented here:
/// - each line is filtered on a fixed 33-point forward grid with an
///   alpha-beta filter (stronger near the car, calmer far away); a gap or a
///   jump near the car (lane change) restarts the line instead of sliding;
/// - lane lines appear and disappear with hysteresis on the model
///   probability and ease in/out instead of popping; outer lanes need a
///   plausible lane width and must not lie beyond a confident road edge;
/// - the road surface keeps one boundary per side and blends when its
///   source (road edge, lane line, planned path) changes;
/// - a late model frame keeps the last geometry briefly, a repeated model
///   frame does not step the filters.
class RoadGeometrySmoother {
  RoadGeometrySmoother();

  /// Filter grid (m): 33 points, denser near the car (192·(i/32)²).
  static final List<double> grid = List.unmodifiable([
    for (var i = 0; i <= 32; i++) 192 * (i / 32) * (i / 32),
  ]);

  /// Output sampling (m) handed to the painters.
  static final List<double> drawGrid = List.unmodifiable([
    for (var x = 0.0; x < 30; x += 1) x,
    for (var x = 30.0; x < 80; x += 2) x,
    for (var x = 80.0; x <= 192; x += 4) x,
  ]);

  static const alphaNear = 0.15;
  static const alphaFar = 0.07;
  static const nearM = 15.0;
  static const farM = 80.0;
  static const jumpM = 1.5;
  static const jumpAtM = 7.7;
  static const gapMs = 500.0;
  static const minStepS = 0.045;
  static const maxStepS = 0.2;
  static const maxRateMps = 8.0;

  /// Keep the last geometry this long when frames arrive without it.
  static const holdMs = 500.0;

  static const showProb = 0.5;
  static const hideProb = 0.3;
  static const egoShowProb = 0.35;
  static const egoHideProb = 0.2;
  static const minLaneM = 2.3;
  static const maxLaneM = 4.8;
  static const edgeGapM = 0.5;
  static const edgeMaxStd = 1.5;
  static const edgeShowStd = 2.0;
  static const edgeHideStd = 2.5;
  static const refNearM = 8.0;
  static const refFarM = 30.0;
  static const fadeS = 0.35;
  static const boundaryBlendS = 0.5;

  /// The planned path is drawn as lateral offset over forward distance; a
  /// path turning harder than this slope is cut where it does.
  static const maxPathSlope = 2.0;

  /// Road surface margins (same as the painters' fallbacks).
  static const laneMarginM = 0.6;
  static const pathHalfWidthM = 5.4;

  final _filters = <String, _LineFilter>{};
  final _laneOn = List<bool>.filled(4, false);
  final _laneLevel = List<double>.filled(4, 0);
  final _laneLast = List<List<ScenePoint>?>.filled(4, null);
  final _laneLastLine = List<LaneLine?>.filled(4, null);
  final _edgeOn = List<bool>.filled(2, false);
  final _bounds = [_Boundary(), _Boundary()];
  bool _ready = false;
  double? _lastMs;
  double _geometryMs = double.negativeInfinity;
  int? _lastFrameId;
  RoadScene? _out;

  void reset() {
    _filters.clear();
    _laneOn.fillRange(0, 4, false);
    _laneLevel.fillRange(0, 4, 0);
    _laneLast.fillRange(0, 4, null);
    _laneLastLine.fillRange(0, 4, null);
    _edgeOn.fillRange(0, 2, false);
    for (final b in _bounds) {
      b.reset();
    }
    _ready = false;
    _lastMs = null;
    _geometryMs = double.negativeInfinity;
    _lastFrameId = null;
    _out = null;
  }

  RoadScene apply(RoadScene scene) {
    final t = scene.monotonicTimeNanos / 1e6;
    final last = _lastMs;
    if (last != null && (t < last - 1 || t - last > 5000)) reset();
    final dt = _lastMs == null
        ? 0.0
        : ((t - _lastMs!) / 1000).clamp(0.0, 0.5).toDouble();
    _lastMs = t;

    final hasGeometry =
        scene.plannedPath.length >= 2 ||
        scene.laneLines.any((l) => l.points.length >= 2) ||
        scene.roadEdges.any((e) => e.length >= 2);
    final previous = _out;
    if (!hasGeometry) {
      if (previous != null && t - _geometryMs <= holdMs) {
        return _keep(scene, previous);
      }
      _filters.clear();
      _ready = false;
      _out = null;
      for (var i = 0; i < 4; i++) {
        _laneOn[i] = false;
        _laneLevel[i] = 0;
        _laneLast[i] = null;
      }
      for (final b in _bounds) {
        b.reset();
      }
      return scene;
    }
    final frameId = scene.modelFrameId;
    if (previous != null && frameId != null && frameId == _lastFrameId) {
      return _keep(scene, previous);
    }
    _lastFrameId = frameId;
    _geometryMs = t;

    final path = _line('path', _cutSteep(scene.plannedPath), t);

    // Lane slots 0..3 (far left, ego left, ego right, far right).
    final slots = List<LaneLine?>.filled(4, null);
    final extra = <LaneLine>[];
    final reported = scene.reportedLaneLines;
    if (reported == null) {
      if (scene.leftLane.length >= 2) {
        slots[1] = LaneLine(points: scene.leftLane, index: 1);
      }
      if (scene.rightLane.length >= 2) {
        slots[2] = LaneLine(points: scene.rightLane, index: 2);
      }
    } else if (reported.every((l) => l.index != null)) {
      for (final line in reported) {
        slots[line.index!] = line;
      }
    } else {
      extra.addAll(reported);
    }

    final lanes = List<List<ScenePoint>?>.filled(4, null);
    for (var i = 0; i < 4; i++) {
      final line = slots[i];
      if (line == null || line.points.length < 2) {
        _filters.remove('lane$i');
        continue;
      }
      lanes[i] = _line('lane$i', line.points, t);
    }

    final stds = scene.roadEdgeStds;
    final edges = List<List<ScenePoint>?>.filled(2, null);
    final edgeStd = List<double>.filled(2, double.infinity);
    for (var i = 0; i < 2; i++) {
      final edge = i < scene.roadEdges.length ? scene.roadEdges[i] : null;
      if (edge == null || edge.length < 2) {
        _filters.remove('edge$i');
        _edgeOn[i] = false;
        continue;
      }
      // Edges without a reported std (older gateways) count as confident.
      final std = i < stds.length ? stds[i] : 0.0;
      edgeStd[i] = std;
      _edgeOn[i] = _edgeOn[i] ? std <= edgeHideStd : std <= edgeShowStd;
      edges[i] = _line('edge$i', edge, t);
    }

    _gateLanes(slots, lanes, path, edges, edgeStd, dt);

    final outLanes = <LaneLine>[];
    for (var i = 0; i < 4; i++) {
      if (lanes[i] != null) {
        _laneLast[i] = lanes[i];
        _laneLastLine[i] = slots[i];
      }
      final points = lanes[i] ?? _laneLast[i];
      final base = slots[i] ?? _laneLastLine[i];
      if (_laneLevel[i] <= 0.01 || points == null || base == null) {
        if (_laneLevel[i] <= 0.01) _laneLast[i] = lanes[i];
        continue;
      }
      outLanes.add(base.withGeometry(_dense(points), fade: _laneLevel[i]));
    }
    for (var k = 0; k < extra.length; k++) {
      final line = extra[k];
      final points = _line('extra$k', line.points, t);
      if (points == null) continue;
      outLanes.add(line.withGeometry(_dense(points)));
    }

    final boundaries = <List<ScenePoint>>[];
    if (path != null ||
        lanes.any((l) => l != null) ||
        edges.any((e) => e != null)) {
      final left = _boundary(0, edges[0], lanes, path, dt);
      final right = _boundary(1, edges[1], lanes, path, dt);
      if (left != null && right != null) {
        boundaries
          ..add(_dense(left))
          ..add(_dense(right));
      }
    }

    final out = scene.withGeometry(
      plannedPath: path == null ? const [] : _dense(path),
      laneLines: outLanes,
      roadEdges: boundaries,
    );
    _out = out;
    return out;
  }

  RoadScene _keep(RoadScene scene, RoadScene previous) => scene.withGeometry(
    plannedPath: previous.plannedPath,
    laneLines: previous.laneLines,
    roadEdges: previous.roadEdges,
  );

  // ------------------------------------------------------------ lanes

  void _gateLanes(
    List<LaneLine?> slots,
    List<List<ScenePoint>?> lanes,
    List<ScenePoint>? path,
    List<List<ScenePoint>?> edges,
    List<double> edgeStd,
    double dt,
  ) {
    double? ref(List<ScenePoint>? p) => p == null || p.length < 2
        ? null
        : (RoadScene.interpolateLeft(p, refNearM) +
                  RoadScene.interpolateLeft(p, refFarM)) /
              2;
    final o = [for (final l in lanes) ref(l)];
    final centre = o[1] != null && o[2] != null
        ? (o[1]! + o[2]!) / 2
        : (ref(path) ?? 0);
    double? leftEdge, rightEdge;
    for (var i = 0; i < 2; i++) {
      if (!_edgeOn[i] || edgeStd[i] > edgeMaxStd) continue;
      final e = ref(edges[i]);
      if (e == null) continue;
      if (e > centre) {
        leftEdge = leftEdge == null ? e : math.min(leftEdge, e);
      } else {
        rightEdge = rightEdge == null ? e : math.max(rightEdge, e);
      }
    }
    bool prob(int i, bool ego) {
      if (o[i] == null) return false;
      final p = slots[i]?.probability ?? 0;
      final show = ego ? egoShowProb : showProb;
      final hide = ego ? egoHideProb : hideProb;
      return _laneOn[i] ? p >= hide : p >= show;
    }

    double gap(int a, int b) => (o[a]! - o[b]!).abs();
    final on = List<bool>.filled(4, false);
    on[1] = prob(1, true) && !(leftEdge != null && o[1]! > leftEdge + edgeGapM);
    on[2] =
        prob(2, true) && !(rightEdge != null && o[2]! < rightEdge - edgeGapM);
    on[0] =
        on[1] &&
        prob(0, false) &&
        gap(0, 1) >= minLaneM &&
        gap(0, 1) <= maxLaneM &&
        !(leftEdge != null && o[0]! > leftEdge - edgeGapM);
    on[3] =
        on[2] &&
        prob(3, false) &&
        gap(3, 2) >= minLaneM &&
        gap(3, 2) <= maxLaneM &&
        !(rightEdge != null && o[3]! < rightEdge + edgeGapM);
    final step = _ready ? dt / fadeS : 1.0;
    for (var i = 0; i < 4; i++) {
      _laneOn[i] = on[i];
      final target = on[i] ? 1.0 : 0.0;
      final d = target - _laneLevel[i];
      _laneLevel[i] += d.sign * math.min(step, d.abs());
    }
    _ready = true;
  }

  // ------------------------------------------------------------ road boundary

  List<ScenePoint>? _boundary(
    int side,
    List<ScenePoint>? edge,
    List<List<ScenePoint>?> lanes,
    List<ScenePoint>? path,
    double dt,
  ) {
    final sign = side == 0 ? 1.0 : -1.0;
    final outer = side == 0 ? 0 : 3;
    final inner = side == 0 ? 1 : 2;
    List<ScenePoint>? source;
    var offset = 0.0;
    int kind;
    if (edge != null && _edgeOn[side]) {
      source = edge;
      kind = 0;
    } else if (lanes[outer] != null && _laneOn[outer]) {
      source = lanes[outer];
      offset = sign * laneMarginM;
      kind = 1;
    } else if (lanes[inner] != null && _laneOn[inner]) {
      source = lanes[inner];
      offset = sign * laneMarginM;
      kind = 2;
    } else if (path != null) {
      source = path;
      offset = sign * pathHalfWidthM;
      kind = 3;
    } else {
      return null;
    }
    final current = [
      for (final p in source!)
        ScenePoint(
          forwardMeters: p.forwardMeters,
          leftMeters: p.leftMeters + offset,
        ),
    ];
    return _bounds[side].update(kind, current, dt);
  }

  // ------------------------------------------------------------ filtering

  /// Points up to where the path turns harder than [maxPathSlope].
  static List<ScenePoint> _cutSteep(List<ScenePoint> points) {
    if (points.length < 2) return points;
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1], b = points[i];
      final dx = b.forwardMeters - a.forwardMeters;
      if ((b.leftMeters - a.leftMeters).abs() > maxPathSlope * dx) {
        return i >= 2 ? points.sublist(0, i) : const [];
      }
    }
    return points;
  }

  static (double, double) _gains(double x) {
    final u = ((x - nearM) / (farM - nearM)).clamp(0.0, 1.0);
    final a = alphaNear + (alphaFar - alphaNear) * (u * u * (3 - 2 * u));
    return (a, a * a / (2 - a));
  }

  static final _gridGains = [for (final x in grid) _gains(x)];
  static final _jumpAt = () {
    var best = 0;
    for (var i = 0; i < grid.length; i++) {
      if ((grid[i] - jumpAtM).abs() < (grid[best] - jumpAtM).abs()) best = i;
    }
    return best;
  }();

  List<ScenePoint>? _line(String key, List<ScenePoint> points, double t) {
    if (points.length < 2) {
      _filters.remove(key);
      return null;
    }
    final f = _filters.putIfAbsent(key, _LineFilter.new);
    final first = points.first.forwardMeters;
    final last = points.last.forwardMeters;
    final elapsed = t - f.t;
    final step = (elapsed / 1000).clamp(minStepS, maxStepS);
    var restart = !(elapsed < gapMs);
    final j = _jumpAt;
    if (!restart &&
        grid[j] >= first &&
        grid[j] <= last &&
        f.seen[j] == f.t &&
        (RoadScene.interpolateLeft(points, grid[j]) - f.y[j]).abs() > jumpM) {
      restart = true;
    }
    final out = <ScenePoint>[];
    for (var e = 0; e < grid.length; e++) {
      final x = grid[e];
      if (x < first - 1e-6) continue;
      if (x > last + 1e-6) break;
      final value = RoadScene.interpolateLeft(points, x);
      if (restart || t - f.seen[e] > gapMs) {
        f.y[e] = value;
        f.v[e] = 0;
      } else {
        final (a, b) = _gridGains[e];
        final predicted = f.y[e] + f.v[e] * step;
        final error = value - predicted;
        f.y[e] = predicted + a * error;
        f.v[e] = (f.v[e] + b * error / step).clamp(-maxRateMps, maxRateMps);
      }
      f.seen[e] = t;
      out.add(ScenePoint(forwardMeters: x, leftMeters: f.y[e]));
    }
    f.t = t;
    if (out.length < 2) return points;
    final end = out.last;
    if (last - end.forwardMeters > 0.5) {
      final raw = RoadScene.interpolateLeft(points, end.forwardMeters);
      out.add(
        ScenePoint(
          forwardMeters: last,
          leftMeters: end.leftMeters + (points.last.leftMeters - raw),
        ),
      );
    }
    return out;
  }

  /// Cubic Hermite resampling onto [drawGrid] inside the line's range.
  static List<ScenePoint> _dense(List<ScenePoint> p) {
    final n = p.length;
    if (n < 3) return List.unmodifiable(p);
    double slope(int i) {
      final a = math.max(0, i - 1), b = math.min(n - 1, i + 1);
      return (p[b].leftMeters - p[a].leftMeters) /
          math.max(1e-4, p[b].forwardMeters - p[a].forwardMeters);
    }

    final first = p.first.forwardMeters, last = p.last.forwardMeters;
    final out = <ScenePoint>[p.first];
    var k = 0;
    for (final x in drawGrid) {
      if (x <= first + 1e-6) continue;
      if (x >= last - 1e-6) break;
      while (k < n - 2 && p[k + 1].forwardMeters < x) {
        k++;
      }
      final x0 = p[k].forwardMeters, x1 = p[k + 1].forwardMeters;
      final h = math.max(1e-4, x1 - x0);
      final s = ((x - x0) / h).clamp(0.0, 1.0);
      final s2 = s * s, s3 = s2 * s;
      final y =
          (2 * s3 - 3 * s2 + 1) * p[k].leftMeters +
          (s3 - 2 * s2 + s) * h * slope(k) +
          (-2 * s3 + 3 * s2) * p[k + 1].leftMeters +
          (s3 - s2) * h * slope(k + 1);
      out.add(ScenePoint(forwardMeters: x, leftMeters: y));
    }
    out.add(p.last);
    return List.unmodifiable(out);
  }
}

class _LineFilter {
  final y = Float64List(RoadGeometrySmoother.grid.length);
  final v = Float64List(RoadGeometrySmoother.grid.length);
  final seen = Float64List(RoadGeometrySmoother.grid.length)
    ..fillRange(0, RoadGeometrySmoother.grid.length, double.negativeInfinity);
  double t = double.negativeInfinity;
}

/// One road-surface boundary: follows its source and, when the source kind
/// changes, blends from the previous boundary over
/// [RoadGeometrySmoother.boundaryBlendS] instead of jumping.
class _Boundary {
  int? kind;
  List<ScenePoint>? from;
  List<ScenePoint>? last;
  double blend = 1;

  void reset() {
    kind = null;
    from = null;
    last = null;
    blend = 1;
  }

  List<ScenePoint> update(int newKind, List<ScenePoint> current, double dt) {
    if (kind != null && newKind != kind && last != null) {
      from = last;
      blend = 0;
    }
    kind = newKind;
    if (from != null && blend < 1) {
      blend = math.min(1, blend + dt / RoadGeometrySmoother.boundaryBlendS);
      final k = blend * blend * (3 - 2 * blend);
      final old = from!;
      current = [
        for (final p in current)
          ScenePoint(
            forwardMeters: p.forwardMeters,
            leftMeters:
                RoadScene.interpolateLeft(old, p.forwardMeters) +
                (p.leftMeters -
                        RoadScene.interpolateLeft(old, p.forwardMeters)) *
                    k,
          ),
      ];
      if (blend >= 1) from = null;
    }
    last = current;
    return current;
  }
}
