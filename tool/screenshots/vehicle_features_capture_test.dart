import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kova_routes.dart';
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:kovalink/src/features/settings/settings_screen.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'shot_support.dart';

void main() {
  testWidgets('vehicle features capture', (tester) async {
    await tester.runAsync(loadReviewFonts);
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    final gateway = GatewayController();
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: KovaLinkApp.theme(Brightness.dark),
          home: KovaPage(
            title: '설정',
            child: SettingsScreen(
              controller: gateway,
              initialTab: SettingsTab.kovapilot,
            ),
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text('이 차량의 운행 기능'));
    await tester.pump(const Duration(milliseconds: 100));
    await saveBoundary(tester, key, 'vehicle-features-top');
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pump(const Duration(milliseconds: 100));
    await saveBoundary(tester, key, 'vehicle-features-bottom');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    gateway.dispose();
    tester.view.reset();
  });
}
