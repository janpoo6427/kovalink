/// Display-only filter for a normalized gateway frame. One instance per stream.
/// Hidden lines retain their slots so a left boundary cannot become a right one.
class LiveLaneFilter {
  final List<bool> _shown = [];
  int? _lastTime;

  void reset() {
    _shown.clear();
    _lastTime = null;
  }

  Map<String, dynamic> apply(Map<String, dynamic> frame) {
    final stamp = frame["monotonicTimeNanos"];
    if (stamp is int) {
      final prev = _lastTime;
      if (prev != null && (stamp < prev || stamp - prev > 500000000)) reset();
      _lastTime = stamp;
    }
    final result = Map<String, dynamic>.of(frame);
    final lanes = frame["laneLines"];
    if (lanes is List) {
      if (_shown.length != lanes.length) {
        _shown
          ..clear()
          ..addAll(List.filled(lanes.length, false));
      }
      result["laneLines"] = [
        for (var i = 0; i < lanes.length; i++) _lane(lanes[i], i, lanes.length),
      ];
    } else {
      _shown
          .clear(); // No synthesized typed lines: preserve legacy leftLane/rightLane.
    }
    final edges = frame["roadEdges"];
    final stds = frame["roadEdgeStds"];
    if (edges is List && stds is List) {
      result["roadEdges"] = [
        for (var i = 0; i < edges.length; i++)
          if (i < stds.length && _validStd(stds[i]))
            _points(edges[i])
          else
            <Map<String, dynamic>>[],
      ];
    }
    return result;
  }

  static bool _validStd(Object? v) =>
      v is num && v.isFinite && v >= 0 && v <= 2.5;

  static List<Map<String, dynamic>> _points(Object? raw) {
    final out = <Map<String, dynamic>>[];
    if (raw is! List) return out;
    num? prev;
    for (final p in raw.whereType<Map<String, dynamic>>()) {
      final x = p["x"], y = p["y"], z = p["z"];
      if (x is! num ||
          !x.isFinite ||
          y is! num ||
          !y.isFinite ||
          (z != null && (z is! num || !z.isFinite)) ||
          (prev != null && x <= prev)) {
        continue;
      }
      out.add(p);
      prev = x;
    }
    return out.length >= 2 ? out : [];
  }

  Map<String, dynamic> _lane(Object? raw, int index, int count) {
    final lane = raw is Map<String, dynamic> ? raw : <String, dynamic>{};
    final points = _points(lane["points"]);
    final p = lane.containsKey("probability") ? lane["probability"] : 1;
    final ego = count == 2 || (count == 4 && (index == 1 || index == 2));
    final threshold = _shown[index] ? (ego ? .2 : .3) : (ego ? .35 : .5);
    final valid = p is num && p.isFinite && p >= 0 && p <= 1;
    _shown[index] = points.isNotEmpty && valid && p >= threshold;
    return {
      ...lane,
      "probability": valid ? p : 0,
      "points": _shown[index] ? points : <Map<String, dynamic>>[],
    };
  }
}
