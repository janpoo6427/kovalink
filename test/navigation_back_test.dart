// Back navigation: every full-screen page is a route, so the Android back
// button, the Android 13+ predictive back gesture and the iOS edge swipe
// all walk back to the drive screen; only the drive screen leaves the app.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kova_routes.dart';
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/safe_zip_reader.dart';

import 'support/fake_auto_connect.dart';

/// Every route on the app navigator, bottom first.
class _Stack extends NavigatorObserver {
  final routes = <Route<dynamic>>[];

  /// Names of the full-screen pages (dialogs left out).
  List<String?> get pages => [
    for (final r in routes)
      if (r is PageRoute) r.settings.name,
  ];

  int get popups => routes.whereType<PopupRoute<dynamic>>().length;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      routes.add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      routes.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      routes.remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    routes[routes.indexOf(oldRoute!)] = newRoute!;
  }
}

/// Platform calls the app makes (SystemNavigator.pop = the app closes).
class _Platform {
  _Platform(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  final calls = <MethodCall>[];

  bool get closed => calls.any((c) => c.method == 'SystemNavigator.pop');

  /// Last answer to "does Flutter handle back?" (false lets Android run its
  /// own predictive back-to-home animation).
  bool? get frameworkHandlesBack =>
      calls
              .lastWhere(
                (c) => c.method == 'SystemNavigator.setFrameworkHandlesBack',
                orElse: () => const MethodCall('none'),
              )
              .arguments
          as bool?;
}

/// Lets a page slide in or out (the platform transitions take 450 ms).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<_Stack> _pumpApp(
  WidgetTester tester, {
  AutoConnectController Function()? autoConnect,
  Future<Uint8List?> Function()? picker,
}) async {
  tester.view.physicalSize = const Size(800, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final stack = _Stack();
  await tester.pumpWidget(
    KovaLinkApp(
      settingsStore: MemorySettingsStore(),
      storageRoot: () async => Directory.systemTemp,
      navigatorObservers: [stack],
      modelPicker: picker ?? () async => null,
      autoConnectBuilder: autoConnect == null ? null : (_, _) => autoConnect(),
    ),
  );
  await tester.pump();
  await tester.pump();
  return stack;
}

/// Unmounts the app (stops the demo and 자동 연결 timers).
Future<void> _done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _systemBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await _settle(tester);
}

Future<Object?> _backGesture(
  WidgetTester tester,
  String method, [
  double progress = 0,
]) async {
  const codec = StandardMethodCodec();
  Object? result;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.backGesture.name,
    codec.encodeMethodCall(
      MethodCall(
        method,
        method.endsWith('Gesture') && method != 'startBackGesture'
            ? null
            : <String, Object?>{
                'touchOffset': <double>[5 + 300 * progress, 300],
                'progress': progress,
                'swipeEdge': 0,
              },
      ),
    ),
    (data) => result = data == null ? null : codec.decodeEnvelope(data),
  );
  return result;
}

ModalRoute<dynamic> _routeOf(WidgetTester tester, Finder finder) =>
    ModalRoute.of(tester.element(finder))!;

Finder _tab(String label) => find.descendant(
  of: find.byKey(const ValueKey('settings-tabs')),
  matching: find.text(label),
);

void main() {
  testWidgets('the app opens on the drive screen and back there closes it', (
    tester,
  ) async {
    final platform = _Platform(tester);
    final stack = await _pumpApp(tester);
    expect(stack.pages, [KovaRoutes.drive]);
    expect(find.byTooltip('설정'), findsOneWidget);
    await _systemBack(tester);
    expect(platform.closed, isTrue);
    await _done(tester);
  });

  testWidgets('settings opens as a page and back returns to the drive', (
    tester,
  ) async {
    final platform = _Platform(tester);
    // The app tells Android whether Flutter takes back only once running.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final stack = await _pumpApp(tester);
    expect(platform.frameworkHandlesBack, isNot(isTrue));
    await tester.tap(find.byTooltip('설정'));
    await _settle(tester);
    expect(stack.pages, [KovaRoutes.drive, KovaRoutes.settingsApp]);
    expect(find.byKey(const ValueKey('settings-tabs')), findsOneWidget);
    expect(platform.frameworkHandlesBack, isTrue);

    await _systemBack(tester);
    expect(stack.pages, [KovaRoutes.drive]);
    expect(find.byKey(const ValueKey('settings-tabs')), findsNothing);
    expect(find.byTooltip('설정'), findsOneWidget);
    expect(platform.closed, isFalse);
    // Back on the drive screen is the system's again (back to home).
    expect(platform.frameworkHandlesBack, isFalse);
    await _done(tester);
  });

  testWidgets('settings tabs replace each other: one back from any tab', (
    tester,
  ) async {
    final platform = _Platform(tester);
    final stack = await _pumpApp(tester);
    await tester.tap(find.byTooltip('설정'));
    await _settle(tester);
    await tester.tap(_tab('연결 상태'));
    await _settle(tester);
    expect(stack.pages, [KovaRoutes.drive, KovaRoutes.settingsSession]);
    expect(find.byKey(const ValueKey('session-card')), findsOneWidget);
    await tester.tap(_tab('kovapilot'));
    await _settle(tester);
    expect(stack.pages, [KovaRoutes.drive, KovaRoutes.settingsKovapilot]);
    expect(find.byKey(const ValueKey('kova-connection-card')), findsOneWidget);
    await tester.tap(_tab('앱'));
    await _settle(tester);
    expect(stack.pages, [KovaRoutes.drive, KovaRoutes.settingsApp]);
    await tester.tap(_tab('kovapilot'));
    await _settle(tester);

    await _systemBack(tester);
    expect(stack.pages, [KovaRoutes.drive]);
    expect(find.byTooltip('설정'), findsOneWidget);
    expect(platform.closed, isFalse);
    await _done(tester);
  });

  testWidgets('the page back button goes to the drive screen too', (
    tester,
  ) async {
    final stack = await _pumpApp(tester);
    await tester.tap(find.byTooltip('설정'));
    await _settle(tester);
    await tester.tap(_tab('연결 상태'));
    await _settle(tester);
    await tester.tap(find.byTooltip(KovaRoutes.backToDrive));
    await _settle(tester);
    expect(stack.pages, [KovaRoutes.drive]);

    await tester.tap(find.byTooltip('장치 연결'));
    await _settle(tester);
    expect(stack.pages, [KovaRoutes.drive, KovaRoutes.connect]);
    await tester.tap(find.byTooltip(KovaRoutes.backToDrive));
    await _settle(tester);
    expect(stack.pages, [KovaRoutes.drive]);
    await _done(tester);
  });

  testWidgets('장치 연결 from the button and from the 자동 연결 chip', (tester) async {
    final platform = _Platform(tester);
    final stack = await _pumpApp(
      tester,
      autoConnect: () => AutoConnectController(
        target: FakeTarget(),
        probe: FakeProbe(),
        listNetworks: () async => const [],
      ),
    );
    await tester.tap(find.byTooltip('장치 연결'));
    await _settle(tester);
    expect(stack.pages, [KovaRoutes.drive, KovaRoutes.connect]);
    expect(find.byKey(const ValueKey('auto-connect-panel')), findsOneWidget);
    await _systemBack(tester);
    expect(stack.pages, [KovaRoutes.drive]);

    await tester.tap(find.byKey(const ValueKey('auto-connect-chip')));
    await _settle(tester);
    expect(stack.pages, [KovaRoutes.drive, KovaRoutes.connect]);
    await _systemBack(tester);
    expect(stack.pages, [KovaRoutes.drive]);
    expect(platform.closed, isFalse);
    await _done(tester);
  });

  testWidgets('진단 is a deeper page: back returns to settings first', (
    tester,
  ) async {
    final stack = await _pumpApp(tester);
    await tester.tap(find.byTooltip('설정'));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('diagnostics-entry')));
    await _settle(tester);
    expect(stack.pages, [
      KovaRoutes.drive,
      KovaRoutes.settingsApp,
      KovaRoutes.diagnostics,
    ]);
    expect(find.byKey(const ValueKey('diagnostics-copy')), findsOneWidget);
    expect(find.byTooltip(KovaRoutes.backToSettings), findsOneWidget);

    await _systemBack(tester);
    expect(stack.pages, [KovaRoutes.drive, KovaRoutes.settingsApp]);
    expect(find.byKey(const ValueKey('settings-tabs')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('diagnostics-entry')));
    await _settle(tester);
    await tester.tap(find.byTooltip(KovaRoutes.backToSettings));
    await _settle(tester);
    expect(stack.pages, [KovaRoutes.drive, KovaRoutes.settingsApp]);
    await _systemBack(tester);
    expect(stack.pages, [KovaRoutes.drive]);
    await _done(tester);
  });

  testWidgets('a dialog closes first; the next back closes the app', (
    tester,
  ) async {
    final platform = _Platform(tester);
    final stack = await _pumpApp(
      tester,
      picker: () async => throw const ModelPackRejection(
        'archive-too-large',
        '파일이 너무 커요. 32 MB 이하만 가져올 수 있어요.',
      ),
    );
    await tester.tap(find.byTooltip('차량 모델 가져오기'));
    await _settle(tester);
    expect(find.text('가져오지 못했어요'), findsOneWidget);
    expect(stack.popups, 1);

    await _systemBack(tester);
    expect(find.text('가져오지 못했어요'), findsNothing);
    expect(stack.popups, 0);
    expect(stack.pages, [KovaRoutes.drive]);
    expect(platform.closed, isFalse);

    await _systemBack(tester);
    expect(platform.closed, isTrue);
    await _done(tester);
  });

  testWidgets('a link straight to a settings tab still backs out to drive', (
    tester,
  ) async {
    tester.platformDispatcher.defaultRouteNameTestValue =
        KovaRoutes.settingsKovapilot;
    addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
    final stack = await _pumpApp(tester);
    expect(stack.pages, [KovaRoutes.drive, KovaRoutes.settingsKovapilot]);
    expect(find.byKey(const ValueKey('kova-connection-card')), findsOneWidget);
    await _systemBack(tester);
    expect(stack.pages, [KovaRoutes.drive]);
    await _done(tester);
  });

  testWidgets('Android predictive back: the page follows the gesture', (
    tester,
  ) async {
    final platform = _Platform(tester);
    final stack = await _pumpApp(tester);
    // On the drive screen Flutter does not take the gesture: Android shows
    // its own back-to-home animation and closes the app.
    expect(await _backGesture(tester, 'startBackGesture'), isFalse);

    await tester.tap(find.byTooltip('설정'));
    await _settle(tester);
    await tester.tap(_tab('kovapilot'));
    await _settle(tester);
    final page = _routeOf(tester, find.byKey(const ValueKey('settings-tabs')));
    expect(await _backGesture(tester, 'startBackGesture'), isTrue);
    await _backGesture(tester, 'updateBackGestureProgress', 0.5);
    await tester.pump();
    expect(page.animation!.value, lessThan(1));
    expect(find.byTooltip('설정'), findsOneWidget, reason: 'drive shows under');

    // Let go before committing: the page comes back.
    await _backGesture(tester, 'cancelBackGesture');
    await _settle(tester);
    expect(stack.pages, [KovaRoutes.drive, KovaRoutes.settingsKovapilot]);
    expect(page.animation!.value, 1);

    await _backGesture(tester, 'startBackGesture');
    await _backGesture(tester, 'updateBackGestureProgress', 0.6);
    await tester.pump();
    await _backGesture(tester, 'commitBackGesture');
    await _settle(tester);
    expect(stack.pages, [KovaRoutes.drive]);
    expect(platform.closed, isFalse);
    await _done(tester);
  });

  testWidgets(
    'iOS edge swipe goes back to the drive screen from any tab',
    (tester) async {
      final stack = await _pumpApp(tester);
      await tester.tap(find.byTooltip('설정'));
      await _settle(tester);
      await tester.tap(_tab('연결 상태'));
      await _settle(tester);
      expect(stack.pages, [KovaRoutes.drive, KovaRoutes.settingsSession]);

      final gesture = await tester.startGesture(const Offset(5, 300));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(500, 0));
      await tester.pump();
      await gesture.up();
      await _settle(tester);
      expect(stack.pages, [KovaRoutes.drive]);
      expect(find.byTooltip('설정'), findsOneWidget);
      await _done(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
