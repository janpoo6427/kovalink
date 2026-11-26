// Tailscale VPN card: missed checks (the app went to the browser, the
// phone switched networks), coming back to the app, and VPN on/off.
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

const _login = 'https://login.tailscale.com/a/testLogin1';
const _ip = '100.71.162.38';

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

  bool shows(String text) => find.textContaining(text).evaluate().isNotEmpty;

  Widget card() => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: AnimatedBuilder(
          animation: link,
          builder: (context, _) => TailscaleVpnCard(
            key: ValueKey((link.registered?.pin, link.isOwner)),
            link: link,
          ),
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

  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    // Let the HTTP client drop its idle connection.
    await tester.pump(const Duration(seconds: 16));
  }

  testWidgets('missed checks during the login keep asking, then VPN on/off', (
    tester,
  ) async {
    final g = await ownerOnAutomaticWifi(tester);
    g.vpnState = 'authorizing';
    g.vpnExtra = {'loginUrl': _login};
    await tester.pumpWidget(card());
    await until(tester, () => shows('브라우저에서 콤마 등록을 승인해 주세요.'));
    expect(find.text('브라우저에서 로그인'), findsOneWidget);
    expect(
      shows('다시 켤 때까지 꺼져 있어요'),
      isTrue,
      reason: 'how the VPN turns on/off',
    );

    // The phone is in the browser: the comma is not reached for a while.
    g.vpnDrop = true;
    final before = g.vpnRequests;
    await tester.pump(const Duration(seconds: 2));
    await until(tester, () => g.vpnRequests > before);
    await tester.pump(const Duration(seconds: 3));
    await until(tester, () => g.vpnRequests > before + 1);
    expect(shows('Wi-Fi 연결을 확인해 주세요'), isFalse);
    expect(shows('다시 닿으면'), isFalse, reason: 'one or two misses are quiet');
    await tester.pump(const Duration(seconds: 6));
    await until(tester, () => shows('다시 닿으면'));
    expect(shows('다시 닿으면 이어서 확인해요'), isTrue);
    expect(shows('Wi-Fi 연결을 확인해 주세요'), isFalse);

    // Reached again: logged in, the comma reports its VPN IP.
    g.vpnDrop = false;
    g.vpnState = 'connected';
    g.vpnExtra = {'host': _ip, 'port': 8083};
    await tester.pump(const Duration(seconds: 12));
    await until(tester, () => find.text('VPN 끄기').evaluate().isNotEmpty);
    expect(shows('콤마의 VPN이 켜져 있어요'), isTrue);
    expect(shows('다시 닿으면'), isFalse);
    expect(link.registered?.vpnHost, _ip);
    expect(link.registered?.vpnEndpoint, 'https://$_ip:8083');
    await tester.pump();
    expect(shows('VPN IP $_ip'), isTrue);
    expect(find.text('VPN으로 상태 보기'), findsNothing);

    await tester.tap(find.text('VPN 끄기'));
    await until(tester, () => find.text('VPN 켜기').evaluate().isNotEmpty);
    expect(g.vpnPosted, 'stop');
    expect(shows('콤마의 VPN이 꺼져 있어요.'), isTrue);
    expect(link.registered?.vpnHost, _ip, reason: 'the IP stays for next time');

    await tester.tap(find.text('VPN 켜기'));
    await until(tester, () => g.vpnPosted == 'connect');
    expect(g.vpnPosted, 'connect');
    await done(tester);
  });

  testWidgets('back in the app after a failed check asks again', (
    tester,
  ) async {
    final g = await ownerOnAutomaticWifi(tester);
    await tester.pumpWidget(card());
    await until(tester, () => find.text('Tailscale 연결').evaluate().isNotEmpty);

    // needsLogin is not a waiting state: a failed button press says so once.
    g.vpnDrop = true;
    await tester.tap(find.text('VPN 상태 확인'));
    await until(tester, () => shows('Wi-Fi 연결을 확인해 주세요'));
    expect(shows('콤마와의 Wi-Fi 연결을 확인해 주세요.'), isTrue);
    final asked = g.vpnRequests;
    await tester.pump(const Duration(seconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    expect(g.vpnRequests, asked);

    g.vpnDrop = false;
    g.vpnState = 'installing';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await until(tester, () => shows('설치하고 있어요'));
    expect(shows('설치하고 있어요'), isTrue);
    expect(shows('Wi-Fi 연결을 확인해 주세요'), isFalse);
    await done(tester);
  });
}
