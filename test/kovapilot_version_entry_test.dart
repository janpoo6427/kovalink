// 설정 → kovapilot → kovapilot 버전 is a pushed route: back returns to the
// kovapilot tab, and the app can open it by name.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kova_routes.dart';
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:kovalink/src/app/kovalink_pages.dart';
import 'package:kovalink/src/features/kovapilot_git/kovapilot_version_screen.dart';
import 'package:kovalink/src/features/settings/settings_screen.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';

class _Names extends NavigatorObserver {
  final names = <String?>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) names.add(route.settings.name);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) names.remove(route.settings.name);
  }
}

void main() {
  testWidgets('kovapilot tab → kovapilot 버전 → back', (tester) async {
    tester.view.physicalSize = const Size(824, 1830);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final gateway = GatewayController();
    final kova = KovaParamsController();
    addTearDown(gateway.dispose);
    addTearDown(kova.dispose);
    final names = _Names();
    final pages = KovaLinkPages(controller: gateway, kovaParams: kova);
    await tester.pumpWidget(
      MaterialApp(
        theme: KovaLinkApp.theme(Brightness.dark),
        navigatorObservers: [names],
        onGenerateRoute: pages.onGenerateRoute,
        initialRoute: KovaRoutes.settingsKovapilot,
      ),
    );
    await tester.pumpAndSettle();
    final entry = find.byKey(const ValueKey('kovapilot-version-entry'));
    await tester.scrollUntilVisible(
      entry,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('kovapilot 버전'), findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(KovapilotVersionScreen), findsOneWidget);
    expect(names.names.last, KovaRoutes.kovapilotVersion);
    // No comma here (flutter test answers every HTTP request with 400):
    // the screen says it could not read, nothing else.
    expect(find.byType(SettingsScreen), findsNothing);
    await tester.tap(find.byTooltip(KovaRoutes.backToSettings));
    await tester.pumpAndSettle();
    expect(find.byType(KovapilotVersionScreen), findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(names.names.last, KovaRoutes.settingsKovapilot);
  });

  test('the route is known by name and reads from the found comma', () {
    final gateway = GatewayController();
    addTearDown(gateway.dispose);
    final route = KovaLinkPages(
      controller: gateway,
    ).route(KovaRoutes.kovapilotVersion);
    expect(route, isNotNull);
    expect(route!.settings.name, KovaRoutes.kovapilotVersion);
    expect(
      const AppSettings(
        lastDeviceEndpoint: 'http://192.168.0.40:8082',
      ).settingsEndpoint,
      'http://192.168.0.40:8082',
    );
  });
}
