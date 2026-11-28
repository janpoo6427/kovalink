import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kova_routes.dart';
import 'package:kovalink/src/app/kovalink_pages.dart';
import 'package:kovalink/src/features/settings/install_guide_panel.dart';
import 'package:kovalink/src/features/settings/settings_screen.dart';
import 'package:kovalink/src/services/gateway_controller.dart';

void main() {
  testWidgets('offline guide tab and exact address clipboard', (tester) async {
    final gateway = GatewayController();
    addTearDown(gateway.dispose);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsScreen(controller: gateway)),
      ),
    );
    await tester.ensureVisible(find.text('설치 안내'));
    await tester.tap(find.text('설치 안내'));
    await tester.pumpAndSettle();
    expect(find.text('KovaPilot 설치하기'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('copy-install-address')),
    );
    await tester.tap(find.byKey(const ValueKey('copy-install-address')));
    await tester.pumpAndSettle();
    expect(copied, 'installer.comma.ai/janpoo6427/kovapilot');
    expect(gateway.mode, GatewayMode.disconnected);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('install named route replaces settings and back returns home', (
    tester,
  ) async {
    final gateway = GatewayController();
    addTearDown(gateway.dispose);
    final pages = KovaLinkPages(controller: gateway);
    expect(
      KovaLinkPages.settingsRoute(SettingsTab.install),
      KovaRoutes.settingsInstall,
    );
    await tester.pumpWidget(
      MaterialApp(
        onGenerateRoute: pages.onGenerateRoute,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  Navigator.of(context).pushNamed(KovaRoutes.settingsApp),
              child: const Text('open-settings'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('설치 안내'));
    await tester.tap(find.text('설치 안내'));
    await tester.pumpAndSettle();
    expect(
      ModalRoute.of(
        tester.element(find.byType(InstallGuidePanel)),
      )?.settings.name,
      KovaRoutes.settingsInstall,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('open-settings'), findsOneWidget);
    expect(find.byType(InstallGuidePanel), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final width in [320.0, 412.0, 800.0]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets('guide readable at $width and text scale $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 915);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final gateway = GatewayController();
        addTearDown(gateway.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 915),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: SettingsScreen(
                  controller: gateway,
                  initialTab: SettingsTab.install,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.drag(find.byType(ListView), const Offset(0, -1800));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
