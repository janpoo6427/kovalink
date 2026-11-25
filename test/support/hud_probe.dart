// Drive HUD probes shared by the HUD readability tests and the HUD capture
// tool: a scene at a chosen speed and gear, the backdrops a HUD sits on
// (bright sky, snow / a white road, a dark view), the HUD drawn over one
// of them, and contrast measured on the rendered pixels.
//
// Only the public HUD types are used (DriveHud, SpeedCluster, GearRow,
// SignalPill, SpeedLimitSign), so the capture tool also runs on builds
// from before the fixed speed box.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:kovalink/src/features/road_view/hud/drive_hud.dart';
import 'package:kovalink/src/models/display_units.dart';
import 'package:kovalink/src/models/road_scene.dart';

/// [scene] at [kph] (and [gear], if given); everything else unchanged.
RoadScene sceneWith(
  RoadScene scene, {
  required double kph,
  VehicleGear? gear,
}) => RoadScene(
  monotonicTimeNanos: scene.monotonicTimeNanos,
  speedMps: kph / 3.6,
  setSpeedMps: scene.setSpeedMps,
  steeringAngleDegrees: scene.steeringAngleDegrees,
  engaged: scene.engaged,
  plannedPath: scene.plannedPath,
  leftLane: scene.leftLane,
  rightLane: scene.rightLane,
  objects: scene.objects,
  gear: gear ?? scene.gear,
  leftBlinker: scene.leftBlinker,
  rightBlinker: scene.rightBlinker,
  brakeActive: scene.brakeActive,
  speedLimitKph: scene.speedLimitKph,
  tbt: scene.tbt,
  cameraProjection: scene.cameraProjection,
  laneLines: scene.laneLines,
  roadEdges: scene.roadEdges,
  roadType: scene.roadType,
  odometerMeters: scene.odometerMeters,
  roadName: scene.roadName,
  trafficSignal: scene.trafficSignal,
  roadAlerts: scene.roadAlerts,
  laneGuidance: scene.laneGuidance,
);

/// What the road view may show behind the HUD.
enum HudBackdrop {
  /// Clear daytime sky over the road.
  sky('밝은 하늘', [Color(0xFFC9E2F8), Color(0xFFF3F8FD)]),

  /// Snow, a white wall or a sunlit concrete road.
  snow('눈·흰 도로', [Color(0xFFFFFFFF), Color(0xFFF0F2F4)]),

  /// Night or the camera view with no camera (the 16:39 device capture).
  night('어두운 화면', [Color(0xFF1E2634), Color(0xFF0B0E12)]);

  const HudBackdrop(this.label, this.colors);

  final String label;
  final List<Color> colors;
}

/// [DriveHud] on [backdrop], filling the test view, inside a repaint
/// boundary under [boundary].
Widget hudOn(
  HudBackdrop backdrop,
  RoadScene scene, {
  required GlobalKey boundary,
  required bool compact,
  SpeedUnit unit = SpeedUnit.kph,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: KovaLinkApp.theme(Brightness.dark),
  // A Material like the road view's Scaffold: the app's text style.
  home: RepaintBoundary(
    key: boundary,
    child: Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: backdrop.colors,
          ),
        ),
        child: DriveHud(scene: scene, compact: compact, unit: unit),
      ),
    ),
  ),
);

/// Where the HUD parts sit (logical pixels): the ones that must stay put
/// whatever the speed.
Map<String, Rect> hudParts(WidgetTester tester, {required String speed}) {
  final cluster = find.byType(SpeedCluster);
  Rect at(Finder finder) => tester.getRect(finder.first);
  return {
    'speedCluster': at(cluster),
    'numberRow': at(find.descendant(of: cluster, matching: find.byType(Row))),
    'unit': at(
      find.descendant(
        of: cluster,
        matching: find.byWidgetPredicate(
          (w) => w is Text && SpeedUnit.values.any((u) => u.label == w.data),
        ),
      ),
    ),
    'gear': at(find.byType(GearRow)),
    'signalRow': at(find.byType(SignalPill)),
    'blinkerLeft': at(find.byKey(const ValueKey('blinker-left'))),
    'blinkerRight': at(find.byKey(const ValueKey('blinker-right'))),
    'limitSign': at(find.byType(SpeedLimitSign)),
    'speedDigits': speedGlyphs(tester, speed),
  };
}

/// The speed's paragraph in the cluster (the first text that is [speed]).
RenderParagraph speedParagraph(WidgetTester tester, String speed) {
  final text = find.descendant(
    of: find.byType(SpeedCluster),
    matching: find.text(speed),
  );
  return tester.renderObject<RenderParagraph>(
    find.descendant(of: text.first, matching: find.byType(RichText)).first,
  );
}

/// Glyph boxes of [paragraph]'s text, in global logical pixels.
Rect glyphRect(RenderParagraph paragraph) {
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(
      baseOffset: 0,
      extentOffset: paragraph.text.toPlainText().length,
    ),
  );
  var rect = boxes.first.toRect();
  for (final box in boxes.skip(1)) {
    rect = rect.expandToInclude(box.toRect());
  }
  return MatrixUtils.transformRect(paragraph.getTransformTo(null), rect);
}

/// Where the speed digits are drawn.
Rect speedGlyphs(WidgetTester tester, String speed) =>
    glyphRect(speedParagraph(tester, speed));

/// Where the unit (km/h, mph) beside the speed is drawn.
Rect unitGlyphs(WidgetTester tester) {
  final unit = find.descendant(
    of: find.byType(SpeedCluster),
    matching: find.byWidgetPredicate(
      (w) => w is Text && SpeedUnit.values.any((u) => u.label == w.data),
    ),
  );
  return glyphRect(
    tester.renderObject<RenderParagraph>(
      find.descendant(of: unit.first, matching: find.byType(RichText)).first,
    ),
  );
}

/// Each gear letter (P, R, N, D) where it is drawn.
Map<String, Rect> gearGlyphs(WidgetTester tester) => {
  for (final element
      in find
          .descendant(of: find.byType(GearRow), matching: find.byType(RichText))
          .evaluate())
    (element.renderObject! as RenderParagraph).text.toPlainText(): glyphRect(
      element.renderObject! as RenderParagraph,
    ),
};

/// Pixels of the boundary under [key], drawn at [pixelRatio].
class HudPixels {
  HudPixels._(this.rgba, this.width, this.height, this.pixelRatio);

  final ByteData rgba;
  final int width;
  final int height;
  final double pixelRatio;

  static Future<HudPixels> capture(
    WidgetTester tester,
    GlobalKey key, {
    double pixelRatio = 2,
  }) async => (await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final pixels = HudPixels._(data!, image.width, image.height, pixelRatio);
    image.dispose();
    return pixels;
  }))!;

  /// Relative luminance (WCAG 2) of every pixel inside [rect] (logical).
  List<double> luminances(Rect rect) {
    final r = Rect.fromLTRB(
      rect.left * pixelRatio,
      rect.top * pixelRatio,
      rect.right * pixelRatio,
      rect.bottom * pixelRatio,
    );
    final x0 = math.max(0, r.left.floor());
    final y0 = math.max(0, r.top.floor());
    final x1 = math.min(width, r.right.ceil());
    final y1 = math.min(height, r.bottom.ceil());
    return [
      for (var y = y0; y < y1; y++)
        for (var x = x0; x < x1; x++)
          relativeLuminance(
            Color.fromARGB(
              255,
              rgba.getUint8((y * width + x) * 4),
              rgba.getUint8((y * width + x) * 4 + 1),
              rgba.getUint8((y * width + x) * 4 + 2),
            ),
          ),
    ];
  }

  /// Contrast between the dark and the light pixels in [rect]: the 5th and
  /// the 95th percentile of luminance, so a few antialiased edge pixels do
  /// not count. Around a glyph that is the letter against what is right
  /// behind it.
  ({double dark, double light, double ratio}) contrastIn(Rect rect) {
    final values = luminances(rect)..sort();
    if (values.isEmpty) return (dark: 0, light: 0, ratio: 1);
    final dark = values[(values.length * 0.05).floor()];
    final light =
        values[math.min(values.length - 1, (values.length * 0.95).floor())];
    return (dark: dark, light: light, ratio: (light + 0.05) / (dark + 0.05));
  }
}

/// WCAG 2 relative luminance of an opaque color.
double relativeLuminance(Color c) {
  double channel(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// WCAG 2 contrast ratio of two opaque colors (1 to 21).
double contrastRatio(Color a, Color b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// [top] drawn over the opaque [below] (source-over).
Color over(Color top, Color below) => Color.alphaBlend(top, below);
