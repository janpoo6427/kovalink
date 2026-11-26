import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:kovalink/src/app/kova_routes.dart";

void main() {
  testWidgets("상단바는 본문과 따로 고정되고 큰 글자에서도 내용을 표시한다", (tester) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final scale in [1.0, 2.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: KovaPage(
              title: "콤마 등록",
              subtitle: "연결 정보를 확인해요",
              child: ListView(
                children: List.generate(
                  40,
                  (i) => ListTile(title: Text("항목 $i")),
                ),
              ),
            ),
          ),
        ),
      );
      final back = find.byTooltip(KovaRoutes.backToDrive);
      final title = find.text("콤마 등록");
      final subtitle = find.text("연결 정보를 확인해요");
      expect(tester.getSize(back).width, greaterThanOrEqualTo(48));
      expect(tester.getCenter(back).dx, lessThan(tester.getTopLeft(title).dx));
      expect(
        tester.getBottomLeft(title).dy,
        lessThanOrEqualTo(tester.getTopLeft(subtitle).dy),
      );
      final before = tester.getTopLeft(title);
      expect(
        tester.getBottomLeft(subtitle).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.byType(ListView)).dy),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -320));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(title), before);
      expect(tester.takeException(), isNull);
    }
  });
}
