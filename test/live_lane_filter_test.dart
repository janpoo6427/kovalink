import "package:flutter_test/flutter_test.dart";
import "package:kovalink/src/services/live_lane_filter.dart";

void main() {
  final pts = [
    for (final x in [0, 10]) {"x": x, "y": 1},
  ];
  Map<String, dynamic> frame(List<double> ps, {int stamp = 1}) => {
    "monotonicTimeNanos": stamp,
    "laneLines": [
      for (final p in ps) {"probability": p, "points": pts},
    ],
  };
  List<bool> visible(Map<String, dynamic> f) => [
    for (final l in f["laneLines"]) l["points"].isNotEmpty as bool,
  ];
  test("slot-specific hysteresis, stale frames and reset", () {
    final filter = LiveLaneFilter();
    expect(visible(filter.apply(frame([.49, .35, .35, .5]))), [
      false,
      true,
      true,
      true,
    ]);
    expect(visible(filter.apply(frame([.4, .2, .19, .3]))), [
      false,
      true,
      false,
      true,
    ]);
    expect(visible(filter.apply(frame([.4, .3, .3, .4], stamp: 600000002))), [
      false,
      false,
      false,
      false,
    ]);
    filter.apply(frame([1, 1, 1, 1]));
    filter.reset();
    expect(visible(filter.apply(frame([.4, .3, .3, .4]))), [
      false,
      false,
      false,
      false,
    ]);
  });
  test("empty geometry hides only its slot; legacy fields untouched", () {
    final f = frame([1, 1, 1, 1]);
    f["laneLines"][1]["points"] = [];
    final filter = LiveLaneFilter();
    expect(visible(filter.apply(f)), [true, false, true, true]);
    final legacy = {"leftLane": pts};
    expect(filter.apply(legacy), legacy);
  });
  test("road edge std gates by slot without mutating input", () {
    final f = {
      "roadEdges": [pts, pts],
      "roadEdgeStds": [2.5, 2.51],
    };
    expect(LiveLaneFilter().apply(f)["roadEdges"], [pts, []]);
    expect(f["roadEdges"], [pts, pts]);
  });
}
