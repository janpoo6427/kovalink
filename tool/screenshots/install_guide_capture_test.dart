import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kova_routes.dart';
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:kovalink/src/features/settings/settings_screen.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'shot_support.dart';

void main() {
  testWidgets('installation guide capture', (tester) async {
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
              initialTab: SettingsTab.install,
            ),
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text('설치 안내'));
    await tester.pumpAndSettle();
    await saveBoundary(tester, key, 'install-guide-top');
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();
    await saveBoundary(tester, key, 'install-guide-steps');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    gateway.dispose();
    tester.view.reset();
  });
}
