// Tailscale VPN card for the owner on automatic Wi-Fi against a real TLS
// fake Gateway: it asks the comma by itself and follows the install.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/connect/tailscale_vpn_card.dart';
import 'package:kovalink/src/network/comma_registry.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/network/owner_pairing.dart';
import 'package:kovalink/src/services/comma_link.dart';
import 'package:kovalink/src/settings/app_settings.dart';

import 'support/fake_wifi_gateway.dart';

void main() {
  late SettingsController settings;
  late CommaLink link;

  setUp(() {
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

  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  Widget card() => MaterialApp(
    home: Scaffold(
      body: AnimatedBuilder(
        animation: link,
        builder: (context, _) => TailscaleVpnCard(
          key: ValueKey((link.registered?.pin, link.isOwner)),
          link: link,
        ),
      ),
    ),
  );

  Future<FakeWifiGateway> ownerOnAutomaticWifi(WidgetTester tester) async {
    late FakeWifiGateway g;
    await tester.runAsync(() async {
      g = await FakeWifiGateway.start(address: '127.0.0.2', localNetwork: true);
      await link.open(
        KovaDevice(
          host: g.address,
          port: g.port,
          bindScope: 'wifi',
          secure: true,
          localNetwork: true,
          pin: fixturePin(pinDeviceA),
        ),
      );
      await link.requestOwnerCode();
      expect(await link.confirmOwnerCode(g.pairCode), isA<OwnerCodeAccepted>());
    });
    return g;
  }

  testWidgets('the owner sees the install, then Tailscale 연결', (tester) async {
    final g = await ownerOnAutomaticWifi(tester);
    g.vpnState = 'installing';
    await tester.pumpWidget(card());
    await until(tester, () => g.vpnRequests > 0);
    await until(
      tester,
      () => find.textContaining('설치하고 있어요').evaluate().isNotEmpty,
    );
    expect(find.textContaining('설치하고 있어요'), findsOneWidget);
    expect(find.text('Tailscale 연결'), findsNothing);

    g.vpnState = 'installFailed';
    await tester.pump(const Duration(seconds: 3));
    await until(
      tester,
      () => find.textContaining('받지 못했어요').evaluate().isNotEmpty,
    );
    expect(find.textContaining('받지 못했어요'), findsOneWidget);
    expect(find.text('Tailscale 연결'), findsNothing);

    g.vpnState = 'needsLogin';
    await tester.pump(const Duration(seconds: 15));
    await until(tester, () => find.text('Tailscale 연결').evaluate().isNotEmpty);
    expect(find.text('Tailscale 연결'), findsOneWidget);
    expect(find.text('Tailscale 로그인이 필요해요.'), findsOneWidget);
    final asked = g.vpnRequests;
    await tester.pump(const Duration(seconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    expect(g.vpnRequests, asked, reason: 'needsLogin is not polled');
  });

  testWidgets('a phone that is not the owner asks nothing', (tester) async {
    late FakeWifiGateway g;
    await tester.runAsync(() async {
      g = await FakeWifiGateway.start(address: '127.0.0.2', localNetwork: true);
      await link.open(
        KovaDevice(
          host: g.address,
          port: g.port,
          bindScope: 'wifi',
          secure: true,
          localNetwork: true,
          pin: fixturePin(pinDeviceA),
        ),
      );
    });
    await tester.pumpWidget(card());
    await until(tester, () => false);
    expect(g.vpnRequests, 0);
    expect(find.textContaining('소유자 등록을 한 뒤'), findsOneWidget);
    expect(find.text('Tailscale 연결'), findsNothing);
  });
}
