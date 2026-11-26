import "dart:math" as math;
import "package:flutter_test/flutter_test.dart";
import "package:kovalink/src/models/road_scene.dart";

void main() {
  final p = [
    for (final x in [0, 10, 20, 30]) {"x": x, "y": .01 * x * x},
  ];
  final line = {"points": p, "probability": .9};
  final json = <String, dynamic>{
    "speedMps": 15,
    "monotonicTimeNanos": 1,
    "laneLines": [line, line, line, line],
    "plannedPath": [
      {"x": 0, "y": 0},
      {"x": 40, "y": 0},
    ],
    "leftBlindspot": true,
  };
  const car = TrackedObject(
    distanceMeters: 12,
    leftMeters: -4,
    relativeSpeedMps: -19,
  );
  test(
    "received curves orient both directions using vehicle centre, not lane side",
    () {
      final s = RoadScene.fromJson(json);
      expect(s.isOncoming(car), isTrue);
      expect(s.objectHeading(car, 4), closeTo(math.atan(.3) + math.pi, 1e-8));
      expect(s.leftBlindspot, isTrue);
      expect(s.rightBlindspot, isFalse);
      expect(s.objects, isEmpty);
      const slower = TrackedObject(
        distanceMeters: 12,
        leftMeters: 4,
        relativeSpeedMps: -17,
      );
      expect(s.isOncoming(slower), isFalse);
      expect(s.objectHeading(slower, 4), closeTo(math.atan(.3), 1e-8));
    },
  );
  test("uncertain lane pair uses the path instead", () {
    final s = RoadScene.fromJson({
      ...json,
      "laneLines": [
        line,
        {...line, "probability": .2},
        line,
        line,
      ],
    });
    expect(s.objectHeading(car, 4), closeTo(math.pi, 1e-8));
  });
}
