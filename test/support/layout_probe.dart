// Layout checks shared by test/device_layout_test.dart and the device
// capture tool: Flutter layout errors (RenderFlex overflow etc.), HUD parts
// leaving the screen or the safe area, HUD parts covering each other, the
// camera notice sitting where a navigation app's overlay goes, text running
// past the screen edge and ellipsized text.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/road_view/hud/drive_hud.dart';
import 'package:kovalink/src/features/road_view/road_view_screen.dart';
import 'package:kovalink/src/widgets/liquid_glass.dart';

class LayoutReport {
  final errors = <String>[];
  final offscreen = <String>[];
  final unsafe = <String>[];
  final overlaps = <String>[];

  /// KovaLink notices inside [navOverlayZoneOf].
  final navZone = <String>[];
  final clippedText = <String>[];

  /// Button / tab labels that had to wrap or cut (narrower than their
  /// one-line width).
  final wrappedLabels = <String>[];
  final ellipsized = <String>[];

  /// Where each checked part sat (logical px), for review.
  final parts = <String>[];

  /// Problems a layout must not have. Ellipsized text is listed for review
  /// but is a designed fallback, so it is not counted here.
  List<String> get problems => [
    for (final e in errors) '오류: $e',
    for (final e in offscreen) '화면 밖: $e',
    for (final e in unsafe) '안전 영역 침범: $e',
    for (final e in overlaps) '겹침: $e',
    for (final e in navZone) '내비 오버레이 자리 침범: $e',
    for (final e in clippedText) '글자 잘림: $e',
    for (final e in wrappedLabels) '버튼 글자 줄바꿈: $e',
  ];

  Map<String, Object> toJson() => {
    'errors': errors,
    'offscreen': offscreen,
    'unsafe': unsafe,
    'overlaps': overlaps,
    'navZone': navZone,
    'clippedText': clippedText,
    'wrappedLabels': wrappedLabels,
    'ellipsized': ellipsized,
    'parts': parts,
  };
}

/// Runs [body] and returns the Flutter errors it reported (instead of
/// failing the test on the first one).
Future<List<String>> collectFlutterErrors(Future<void> Function() body) async {
  final errors = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) => errors.add(describeError(details));
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}

/// One line: the error plus the widget that caused it (lib path:line).
String describeError(FlutterErrorDetails details) {
  final message = details.exceptionAsString().split('\n').first.trim();
  final full = details.toString();
  final where = RegExp(
    r'(lib/[\w/]+\.dart:\d+)',
  ).allMatches(full).map((m) => m.group(1)).toSet().take(2).join(', ');
  return where.isEmpty ? message : '$message [$where]';
}

Rect? _rectOf(Element element) {
  final render = element.renderObject;
  if (render is! RenderBox || !render.attached || !render.hasSize) return null;
  if (render.size.isEmpty) return null;
  // Through the transforms (a FittedBox scales its child down).
  return MatrixUtils.transformRect(
    render.getTransformTo(null),
    Offset.zero & render.size,
  );
}

/// HUD parts and floating buttons on the drive screen, by name.
List<(String, Rect)> driveScreenParts(WidgetTester tester) {
  final parts = <(String, Rect)>[];
  void add(String name, Finder finder) {
    for (final element in finder.evaluate()) {
      if (_rectOf(element) case final rect?) parts.add((name, rect));
    }
  }

  // The speed cluster is an L shape (number row, then the pills), so its
  // pieces are checked instead of its bounding box.
  final cluster = find.byType(SpeedCluster);
  add('속도 숫자', find.descendant(of: cluster, matching: find.byType(Row)).first);
  add(
    '속도 알약',
    find.descendant(of: cluster, matching: find.byType(LiquidGlass)),
  );
  add('신호 알약', find.byType(SignalPill));
  add('제한속도', find.byType(SpeedLimitSign));
  add('경로 카드', find.byType(RouteInfoCard));
  add('회전 표지', find.byType(TurnSign));
  add('차로 안내', find.byType(LaneGuidancePill));
  add('모델 가져오기 버튼', find.byTooltip('차량 모델 가져오기'));
  add('연결 버튼', find.byTooltip('장치 연결'));
  add('설정 버튼', find.byTooltip('설정'));
  for (final tip in ['카메라 화면으로 바꾸기', '카메라에 도로 겹쳐 보기', '3D 화면으로 바꾸기']) {
    add('화면 전환 버튼', find.byTooltip(tip));
  }
  final notice = find.byKey(const ValueKey('camera-notice'));
  // Builds from before the key: the card around the title.
  final oldCard = find.ancestor(
    of: find.text('카메라가 연결되지 않았어요'),
    matching: find.byType(LiquidGlass),
  );
  if (notice.evaluate().isNotEmpty) {
    add('카메라 안내', notice);
  } else if (oldCard.evaluate().isNotEmpty) {
    add('카메라 안내', oldCard.first);
  }
  return parts;
}

/// Parts that are KovaLink notices: they must stay out of the navigation
/// overlay zone. (HUD navigation parts such as the turn sign may sit there.)
const noticeParts = {'카메라 안내'};

/// Right middle of the road view (right 40 %, middle 30 % of the height):
/// where navigation apps such as T map float their turn overlay over other
/// apps. KovaLink does not draw anything for it.
Rect navOverlayZoneOf(Rect road) => Rect.fromLTRB(
  road.left + road.width * 0.6,
  road.top + road.height * 0.35,
  road.right,
  road.top + road.height * 0.65,
);

String _r(Rect r) =>
    '(${r.left.round()},${r.top.round()} ${r.width.round()}×${r.height.round()})';

/// Checks the drive screen: every HUD part on screen and inside the safe
/// area, and no two parts covering each other.
void checkDriveScreen(WidgetTester tester, LayoutReport report) {
  final view = tester.view;
  final screen = Offset.zero & (view.physicalSize / view.devicePixelRatio);
  final p = view.padding;
  final dpr = view.devicePixelRatio;
  final safe = Rect.fromLTRB(
    p.left / dpr,
    p.top / dpr,
    screen.width - p.right / dpr,
    screen.height - p.bottom / dpr,
  );
  final parts = driveScreenParts(tester);
  report.parts.addAll([for (final (n, r) in parts) '$n ${_r(r)}']);
  final road = find.byType(RoadViewScreen);
  if (road.evaluate().isNotEmpty) {
    final zone = navOverlayZoneOf(tester.getRect(road.first));
    for (final (name, rect) in parts) {
      final hit = rect.deflate(1).intersect(zone);
      if (noticeParts.contains(name) && hit.width > 0 && hit.height > 0) {
        report.navZone.add('$name ${_r(rect)}');
      }
    }
  }
  for (final (name, rect) in parts) {
    if (!screen.inflate(0.5).contains(rect.topLeft) ||
        !screen.inflate(0.5).contains(rect.bottomRight)) {
      report.offscreen.add('$name ${_r(rect)}');
    } else if (!safe.inflate(0.5).contains(rect.topLeft) ||
        !safe.inflate(0.5).contains(rect.bottomRight)) {
      report.unsafe.add('$name ${_r(rect)}');
    }
  }
  for (var i = 0; i < parts.length; i++) {
    for (var j = i + 1; j < parts.length; j++) {
      final (a, ra) = parts[i];
      final (b, rb) = parts[j];
      final hit = ra.deflate(1).intersect(rb.deflate(1));
      if (hit.width > 0 && hit.height > 0) {
        report.overlaps.add('$a ↔ $b');
      }
    }
  }
}

/// Visible text running past the screen's left/right edge (vertical is
/// left to scrolling) and text cut with an ellipsis.
void checkVisibleText(WidgetTester tester, LayoutReport report) {
  final view = tester.view;
  final width = view.physicalSize.width / view.devicePixelRatio;
  for (final element in find.byType(RichText).hitTestable().evaluate()) {
    final render = element.renderObject;
    if (render is! RenderParagraph) continue;
    final rect = _rectOf(element);
    if (rect == null) continue;
    final text = render.text.toPlainText().replaceAll('\n', ' ').trim();
    if (text.isEmpty) continue;
    if (rect.left < -0.5 || rect.right > width + 0.5) {
      report.clippedText.add('"$text" ${_r(rect)}');
    }
    if (render.didExceedMaxLines) report.ellipsized.add('"$text"');
    var inButton = false;
    element.visitAncestorElements((a) {
      final w = a.widget;
      if (w is ButtonStyleButton || w is SegmentedButton) {
        inButton = true;
        return false;
      }
      return true;
    });
    if (inButton &&
        render.getMaxIntrinsicWidth(double.infinity) >
            render.size.width + 0.5) {
      report.wrappedLabels.add('"$text"');
    }
  }
}

/// The floating back button on the connect/settings screens must not sit
/// on the page text.
void checkBackButton(WidgetTester tester, LayoutReport report) {
  final back = find.byTooltip('주행 화면으로 돌아가기');
  if (back.evaluate().isEmpty) return;
  final button = _rectOf(back.evaluate().first);
  if (button == null) return;
  report.parts.add('뒤로 버튼 ${_r(button)}');
  for (final element in find.byType(RichText).hitTestable().evaluate()) {
    if (element.findAncestorWidgetOfExactType<Tooltip>()?.message ==
        '주행 화면으로 돌아가기') {
      continue;
    }
    final rect = _rectOf(element);
    if (rect == null) continue;
    final hit = rect.deflate(1).intersect(button.deflate(1));
    if (hit.width > 0 && hit.height > 0) {
      final text = (element.renderObject! as RenderParagraph).text
          .toPlainText()
          .trim();
      report.overlaps.add('뒤로 버튼 ↔ "$text"');
    }
  }
}

/// Text scale for the next pump; reset with [resetTextScale].
void setTextScale(WidgetTester tester, double scale) {
  tester.platformDispatcher.textScaleFactorTestValue = scale;
}

void resetTextScale(WidgetTester tester) {
  tester.platformDispatcher.clearTextScaleFactorTestValue();
}
