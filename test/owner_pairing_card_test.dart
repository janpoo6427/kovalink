// 소유자 등록 card against a real TLS fake Gateway (see owner_pairing_test).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/connect/owner_pairing_card.dart';
import 'package:kovalink/src/network/comma_registry.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/services/comma_link.dart';
import 'package:kovalink/src/settings/app_settings.dart';

import 'support/fake_wifi_gateway.dart';

void main() {
  late SettingsController settings;
  late CommaLink link;
  final gateways = <FakeWifiGateway>[];

  setUp(() {
    // The real TLS fake needs real sockets, not the widget binding's mock.
    HttpOverrides.global = null;
    settings = SettingsController(store: MemorySettingsStore());
    link = CommaLink(
      settings: settings,
      tokens: MemoryCommaTokenStore(),
      timeout: const Duration(seconds: 3),
    );
  });

  tearDown(() {
    link.dispose();
    settings.dispose();
  });

  Future<FakeWifiGateway> start() async {
    final g = await FakeWifiGateway.start(
      address: '127.0.0.2',
      localNetwork: true,
    );
    gateways.add(g);
    return g;
  }

  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  KovaDevice local(FakeWifiGateway g) => KovaDevice(
    host: g.address,
    port: g.port,
    bindScope: 'wifi',
    secure: true,
    localNetwork: true,
    pin: fixturePin(pinDeviceA),
  );

  testWidgets('card: 소유자로 등록 → code dialog → 등록됨', (tester) async {
    late FakeWifiGateway g;
    await tester.runAsync(() async {
      g = await start();
      await link.open(local(g));
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: link,
            builder: (context, _) => OwnerPairingCard(link: link),
          ),
        ),
      ),
    );
    expect(find.text('안 됨'), findsOneWidget);
    expect(find.textContaining('소유자로 등록하면'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('owner-pairing-start')));
    await until(
      tester,
      () =>
          find.byKey(const ValueKey('owner-code-dialog')).evaluate().isNotEmpty,
    );
    expect(find.byKey(const ValueKey('owner-code-dialog')), findsOneWidget);
    expect(find.textContaining('2분 안에'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('owner-code-field')),
      '12a45',
    );
    expect(find.text('1245'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('owner-code-submit')));
    await tester.pump();
    expect(find.text('숫자 6자리를 넣어 주세요.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('owner-code-field')),
      '000000',
    );
    await tester.tap(find.byKey(const ValueKey('owner-code-submit')));
    await until(
      tester,
      () => find.textContaining('번 더 넣을 수 있어요').evaluate().isNotEmpty,
    );
    expect(find.text('코드가 맞지 않아요. 4번 더 넣을 수 있어요.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('owner-code-field')),
      g.pairCode,
    );
    await tester.tap(find.byKey(const ValueKey('owner-code-submit')));
    await until(
      tester,
      () => find.byKey(const ValueKey('owner-code-dialog')).evaluate().isEmpty,
    );
    expect(find.byKey(const ValueKey('owner-code-dialog')), findsNothing);
    expect(find.text('등록됨'), findsOneWidget);
    expect(find.text('이 휴대폰을 소유자로 등록했어요.'), findsOneWidget);
    expect(find.byKey(const ValueKey('owner-forget')), findsOneWidget);
    expect(link.isOwner, isTrue);
    await tester.runAsync(() async {
      link.session?.close();
      gateways.remove(g);
      await g.close();
    });
  });
}
